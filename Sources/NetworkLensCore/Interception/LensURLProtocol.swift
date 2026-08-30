//
//  LensURLProtocol.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Intercepts `URLSession` traffic.
///
/// `startLoading()` does **not** do the work synchronously. `URLProtocol` only
/// requires that the client callbacks are eventually called, so the work is
/// deferred onto a `Task` and the method returns immediately. That is what lets
/// a breakpoint hold a request without blocking a thread: the obvious
/// semaphore-in-`startLoading` implementation deadlocks the moment two
/// breakpoints fire together, and burns a thread per paused request.
public final class LensURLProtocol: URLProtocol, @unchecked Sendable {

    /// Marks a request as already handled. Without this, the passthrough
    /// request we issue re-enters `canInit` and recurses forever.
    static let handledKey = "com.networklens.handled"

    /// Screen name stamped at task-creation time on the caller's thread.
    static let screenKey = "com.networklens.screen"

    /// Identity carried from task creation so the recorded exchange and any
    /// breakpoint UI refer to the same thing.
    static let exchangeIDKey = "com.networklens.exchangeID"

    /// Set when the tool fired this request itself, naming the exchange it
    /// repeats.
    static let replayOfKey = "com.networklens.replayOf"

    private var work: Task<Void, Never>?

    /// Identifies this instance to the breakpoint coordinator, so
    /// `stopLoading` can tear down UI that belongs to this request alone.
    private let instanceID = UUID()

    // MARK: - URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool {
        // `isEnabled` as well as `isActive`, and not only for tidiness:
        // `URLProtocol.registerClass` is process-wide and cannot be relied on
        // to have been skipped — an earlier enabled `start()` in the same
        // process leaves this class registered. The gate has to be re-checked
        // on the request path or "disabled" means "disabled until something
        // enabled it once".
        guard NetworkLens.isActive, NetworkLens.isEnabled else { return false }
        // Already ours — this is the passthrough leg. Must be first.
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        // Last, because it is the only check here that reads the configuration
        // behind a lock. A host outside the allowlist is dropped at this line
        // and never reaches the store, the trace or the mocking engine.
        return NetworkLens.capturesHost(request.url?.host)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override class func requestIsCacheEquivalent(
        _ a: URLRequest, to b: URLRequest
    ) -> Bool {
        false
    }

    public override func startLoading() {
        work = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    public override func stopLoading() {
        work?.cancel()
        work = nil
        // A user navigating away mid-pause is normal, not an edge case. Any
        // queued or presented breakpoint for this request has to go with it or
        // we strand a modal nobody can dismiss.
        BreakpointCoordinator.shared.dismissPending(for: instanceID)
    }

    // MARK: - Work

    private func run() async {
        let configuration = NetworkLens.configuration
        var outgoing = request

        // Materialise a stream body before anything else. It can only be read
        // once, and both the capture and any edit need it as Data.
        let materialised = BodyReader.materialisingStreamBody(
            in: outgoing, cap: configuration.maxCapturedRequestBodyBytes
        )
        outgoing = materialised.request

        // Header first: a networking module that cannot import the lens can
        // still say which screen it is serving, and that is the most specific
        // answer available. Then the stamped property, then the ambient stack.
        let screen = outgoing.lensScreenHeader()
            ?? URLProtocol.property(forKey: Self.screenKey, in: request) as? String
            ?? ScreenContext.shared.current

        // Removed before anything else looks at the request, so it reaches
        // neither the server nor the capture nor a curl export.
        outgoing = outgoing.strippingLensHeaders()
        let exchangeID = URLProtocol.property(forKey: Self.exchangeIDKey, in: request) as? UUID
            ?? UUID()
        let startedAt = Date()

        var requestSnapshot = RequestSnapshot(request: outgoing)
        if let capture = materialised.capture {
            requestSnapshot.body = capture.data
            requestSnapshot.bodyTruncated = capture.truncated
            requestSnapshot.originalBodyByteCount = capture.originalByteCount
        }

        var exchange = NetworkExchange(
            id: exchangeID,
            endpointKey: NetworkLens.endpointKey(for: outgoing),
            screen: screen,
            request: requestSnapshot,
            startedAt: startedAt,
            replayOf: URLProtocol.property(forKey: Self.replayOfKey, in: request) as? UUID
        )
        // Record in flight so the overlay shows the row while it is pending.
        NetworkLens.record(exchange)

        // Kept unredacted and in memory only, so this request can be fired
        // again later. `requestSnapshot` cannot serve — it is redacted on the
        // way into the store, and replaying `Authorization: ***` earns a 401
        // that has nothing to do with what was under test.
        ReplayStore.shared.record(outgoing, for: exchange.id)

        // --- Mock --------------------------------------------------------------
        // Claimed before the request breakpoint, and exactly once: a mocked
        // request never leaves the device, so there is nothing to hold and edit
        // on the way out, and the production-host guard has nothing to protect.
        let mock = Mocks.shared.resolve(outgoing)

        // --- Request breakpoint ------------------------------------------------
        if mock == nil, Breakpoints.shared.shouldPauseRequest(for: outgoing) {
            let outcome = await BreakpointCoordinator.shared.pause(
                .request(outgoing),
                owner: instanceID,
                exchangeID: exchange.id,
                endpointKey: exchange.endpointKey,
                timeout: outgoing.timeoutInterval
            )
            guard !Task.isCancelled else { return recordCancelled(exchange) }

            switch outcome {
            case .proceed(let edited):
                if case .request(let editedRequest) = edited {
                    let before = outgoing.httpBody
                    outgoing = editedRequest
                    var snapshot = RequestSnapshot(request: outgoing)
                    snapshot.bodyTruncated = requestSnapshot.bodyTruncated
                    exchange = exchange.replacingRequest(snapshot, source: .edited)
                    if let record = Self.editRecord(
                        stage: .request, from: before, to: outgoing.httpBody
                    ) {
                        exchange = exchange.loggingEdit(record)
                    }
                    NetworkLens.record(exchange)
                }
            case .abort(let error):
                exchange = exchange.failed(FailureInfo(error: error))
                NetworkLens.record(exchange)
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }

        // --- Request rewrite ---------------------------------------------------
        // The one outcome that reaches a real server, so it is the one with a
        // guard: fabricated data sent to production can create real records,
        // and no debugging convenience is worth that.
        var rewriteRecorded = false
        if let mock, let rewrite = mock.outcome.rewrite {
            let host = outgoing.url?.host ?? ""
            if configuration.isProductionHost(host) {
                NetworkLens.noteBlockedRewrite(host: host, endpointKey: exchange.endpointKey)
            } else if !rewrite.isEmpty {
                let before = outgoing.httpBody
                outgoing = rewrite.applied(to: outgoing)

                var snapshot = RequestSnapshot(request: outgoing)
                snapshot.bodyTruncated = requestSnapshot.bodyTruncated
                exchange = exchange.replacingRequest(snapshot, source: .edited)
                if let record = Self.editRecord(
                    stage: .request, from: before, to: outgoing.httpBody
                ) {
                    exchange = exchange.loggingEdit(record)
                }
                NetworkLens.record(exchange)
                rewriteRecorded = true
            }
        }

        // --- Network, or the mock in its place ---------------------------------
        let leg: NetworkLeg
        if let mock, mock.outcome.rewrite != nil {
            // Rewritten and sent: the server still answers. `rewriteRecorded`
            // only says whether anything actually changed.
            _ = rewriteRecorded
            leg = await perform(outgoing)
        } else if let mock, mock.outcome.isHang {
            // Answers nothing until told to. The exchange stays recorded in
            // flight so the row shows what the app is showing, and the client
            // is left untouched — whatever the app does about its own timeout
            // is the app's real behaviour, which is the thing under test.
            exchange = exchange.servedFromMock()
            NetworkLens.record(exchange)

            switch await hangUntilReleasedOrCancelled(exchangeID: exchange.id) {
            case .cancelled:
                return recordCancelled(exchange)
            case .released:
                // Resumes where it was suspended rather than synthesising a
                // response: the loaded state has to be the server's, not the
                // tool's invention.
                exchange = exchange.resumedToNetwork()
                leg = await perform(outgoing)
            }
        } else if let mock {
            exchange = exchange.servedFromMock()
            NetworkLens.record(exchange)
            // A mocked 3xx is delivered as the response it is: following it
            // would send the app to a real server, and a mock that reaches the
            // network is no longer a mock.
            leg = NetworkLeg(result: await serve(mock, for: outgoing), redirect: nil)
        } else {
            leg = await perform(outgoing)
        }
        guard !Task.isCancelled else { return recordCancelled(exchange) }

        var payload: ResponsePayload
        switch leg.result {
        case .success(let received):
            payload = received
        case .failure(let error):
            exchange = exchange.failed(FailureInfo(error: error), timing: nil)
            NetworkLens.record(exchange)
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // --- Redirect ----------------------------------------------------------
        // Handed back to the URL loading system rather than followed here, which
        // is what puts the app's own `willPerformHTTPRedirection` back in the
        // loop and gives each hop its own row. The system tears this instance
        // down and starts the next request, which is intercepted like any other.
        if let redirect = leg.redirect {
            exchange = exchange.completed(
                response: payload.snapshot(cap: configuration.maxCapturedResponseBodyBytes),
                timing: payload.timing
            )
            NetworkLens.record(exchange)
            client?.urlProtocol(
                self, wasRedirectedTo: redirect.request, redirectResponse: redirect.response
            )
            return
        }

        // --- Perturbations -----------------------------------------------------
        // Before the breakpoint, so a tester who stops here sees the payload the
        // app would actually have received rather than one the tool is about to
        // change behind them.
        applyPerturbations(to: &payload, exchange: &exchange)

        // --- Response breakpoint -----------------------------------------------
        if Breakpoints.shared.shouldPauseResponse(for: outgoing) {
            let outcome = await BreakpointCoordinator.shared.pause(
                .response(payload),
                owner: instanceID,
                exchangeID: exchange.id,
                endpointKey: exchange.endpointKey,
                timeout: outgoing.timeoutInterval
            )
            guard !Task.isCancelled else { return recordCancelled(exchange) }

            switch outcome {
            case .proceed(let edited):
                if case .response(let editedPayload) = edited {
                    if editedPayload.body != payload.body
                        || editedPayload.response.statusCode != payload.response.statusCode {
                        exchange = exchange.addingSource(.edited)
                        if let record = Self.editRecord(
                            stage: .response, from: payload.body, to: editedPayload.body
                        ) {
                            exchange = exchange.loggingEdit(record)
                        }
                    }
                    payload = editedPayload
                }
            case .abort(let error):
                exchange = exchange.failed(FailureInfo(error: error), timing: payload.timing)
                NetworkLens.record(exchange)
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }

        guard !Task.isCancelled else { return recordCancelled(exchange) }

        exchange = exchange.completed(
            response: payload.snapshot(cap: configuration.maxCapturedResponseBodyBytes),
            timing: payload.timing
        )
        NetworkLens.record(exchange)

        client?.urlProtocol(self, didReceive: payload.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - Cancellation

    /// Closes out an exchange whose task was cancelled.
    ///
    /// Every early return on cancellation used to leave the exchange exactly as
    /// it was recorded on the way in — request only, no response, no failure —
    /// which `isInFlight` reads as still running. A user navigating away
    /// mid-request is ordinary behaviour, so the traffic list accumulated rows
    /// that never resolved and `SessionStats.inFlight` counted them forever.
    ///
    /// Nothing is said to the client here on purpose: cancellation arrives
    /// through `stopLoading`, after which `URLProtocol` forbids further
    /// callbacks. This records what happened, it does not deliver it.
    private func recordCancelled(_ exchange: NetworkExchange) {
        guard exchange.isInFlight else { return }
        NetworkLens.record(exchange.failed(FailureInfo(error: URLError(.cancelled))))
    }

    // MARK: - Mock

    /// Serves a claimed mock, imposing its delay first.
    ///
    /// The delay is bounded by the request's own `timeoutInterval`, and a delay
    /// that reaches it fails with `.timedOut` rather than sleeping past it. A
    /// mock is the one thing that can hang an app forever — the real stack
    /// always eventually times out — so it has to time out too.
    private func serve(
        _ mock: MockResolution, for request: URLRequest
    ) async -> Swift.Result<ResponsePayload, Error> {
        let startedAt = Date()

        if let timedOut = await imposeDelay(mock.outcome.delay, timeout: request.timeoutInterval) {
            return .failure(timedOut)
        }

        switch mock.outcome {
        case .fail(let failure):
            // Handed over as a plain `URLError`, so the app's retry and
            // offline paths cannot tell it from the real thing.
            return .failure(failure.urlError)

        case .respond(let response):
            let url = request.url ?? URL(string: "about:blank")!
            return .success(
                response.payload(for: url, elapsed: Date().timeIntervalSince(startedAt))
            )

        case .hang, .rewrite:
            // Both are handled in `run()` before this point — one never
            // answers, the other lets the server answer. Reaching here would
            // mean an outcome had been turned into something else, so fail
            // loudly rather than inventing a response.
            assertionFailure("hang and rewrite must be handled before serve(_:for:)")
            return .failure(URLError(.timedOut))
        }
    }

    // MARK: - Edit records

    /// Describes a hand edit as the ops that produced it.
    ///
    /// A saved perturbation has always recorded this; an edit made by a human
    /// at a breakpoint recorded only that *something* changed. That is the
    /// weaker half of the audit trail and the one that matters more — a bug
    /// report says "with this field set to null", and only the ops can prove
    /// that is what happened.
    ///
    /// Bodies that are not both JSON still produce a record, with no ops: the
    /// stage and the original's hash are worth keeping even when the change
    /// cannot be expressed as a patch.
    private static func editRecord(
        stage: EditRecord.Stage, from before: Data?, to after: Data?
    ) -> EditRecord? {
        guard before != after else { return nil }

        let originalTree = (before?.isEmpty == false) ? try? JSONNodeParser.parse(before!) : nil
        let editedTree = (after?.isEmpty == false) ? try? JSONNodeParser.parse(after!) : nil

        let ops: [PatchOp]
        if let originalTree, let editedTree {
            ops = JSONDiff.ops(from: originalTree, to: editedTree)
        } else {
            ops = []
        }

        return EditRecord(
            stage: stage,
            originalHash: originalTree?.contentHash ?? "",
            ops: ops
        )
    }

    // MARK: - Perturbations

    /// Applies every armed perturbation for this endpoint, in save order.
    ///
    /// Stored as ops rather than as a whole payload, so an edit written months
    /// ago against three fields keeps meaning the same thing after the server
    /// adds a fourth. A body that is not JSON is left alone: there is nothing
    /// for a JSON Pointer to address, and rewriting bytes blind would corrupt
    /// the payload rather than perturb it.
    ///
    /// One `EditRecord` per perturbation, so the exchange can prove afterwards
    /// exactly what was changed and by which saved edit — the thing that makes
    /// a mocked bug report believable.
    private func applyPerturbations(
        to payload: inout ResponsePayload, exchange: inout NetworkExchange
    ) {
        let armed = Breakpoints.shared.enabledPerturbations(forEndpointKey: exchange.endpointKey)
        guard !armed.isEmpty else { return }
        guard var tree = try? JSONNodeParser.parse(payload.body) else { return }

        var applied = false
        for perturbation in armed {
            let originalHash = tree.contentHash
            guard let outcome = try? perturbation.apply(to: tree) else {
                // A pointer that no longer resolves is a contract change, not a
                // reason to fail the request. Skip this one, keep the rest.
                continue
            }
            tree = outcome.result
            applied = true
            exchange = exchange
                .loggingEdit(
                    EditRecord(
                        stage: .response,
                        originalHash: originalHash,
                        ops: perturbation.ops,
                        perturbationName: perturbation.name,
                        shapeDrifted: outcome.shapeDrifted
                    )
                )
                .addingSource(.perturbed(name: perturbation.name))
        }

        guard applied else { return }
        payload = payload.replacingBody(JSONNodeSerializer.data(from: tree))
        NetworkLens.record(exchange)
    }

    private enum HangEnding {
        case released
        case cancelled
    }

    /// Stays pending until someone releases it or the task is cancelled.
    ///
    /// Polls rather than sleeping once for a very long time so that both
    /// endings land promptly: `stopLoading` — the app navigating away — and a
    /// tester tapping "Load it now" from the overlay.
    private func hangUntilReleasedOrCancelled(exchangeID: UUID) async -> HangEnding {
        HangingRequests.shared.register(exchangeID)
        defer { HangingRequests.shared.unregister(exchangeID) }

        while !Task.isCancelled {
            if HangingRequests.shared.isReleased(exchangeID) { return .released }
            do {
                try await NetworkLens.clock.sleep(for: 0.1)
            } catch {
                return .cancelled
            }
        }
        return .cancelled
    }

    /// Sleeps for `delay`, or returns the error the real stack would raise if
    /// the wait outlives the request's timeout.
    private func imposeDelay(_ delay: TimeInterval, timeout: TimeInterval) async -> URLError? {
        let delay = max(0, delay)
        guard delay > 0 else { return nil }

        // A zero or negative `timeoutInterval` means "no timeout"; the ceiling
        // then only exists to keep the sleep out of overflow range.
        let ceiling: TimeInterval = timeout > 0 ? timeout : 600
        do {
            try await NetworkLens.clock.sleep(for: min(delay, ceiling))
        } catch {
            return URLError(.cancelled)
        }
        return delay >= ceiling ? URLError(.timedOut) : nil
    }

    // MARK: - Passthrough

    /// One trip to the server, and whatever it asked for next.
    private struct NetworkLeg {
        let result: Swift.Result<ResponsePayload, Error>
        /// Set when the server answered 3xx and the hop was not followed here.
        let redirect: PassthroughObserver.Redirect?
    }

    /// Sends the real request. The body comes back whole — the app is entitled
    /// to every byte of it, and `snapshot(cap:)` decides what is *kept*.
    private func perform(_ request: URLRequest) async -> NetworkLeg {
        // The tag is what stops the recursion. Set on a mutable copy of the
        // request we are about to send, never on the one we were handed.
        let tagged = request.taggedAsHandled()
        let observer = PassthroughObserver()
        do {
            let (data, response) = try await PassthroughSession.shared.session.data(
                for: tagged, delegate: observer
            )
            guard let http = response as? HTTPURLResponse else {
                return NetworkLeg(result: .failure(URLError(.badServerResponse)), redirect: nil)
            }
            return NetworkLeg(
                result: .success(
                    ResponsePayload(response: http, body: data, timing: observer.timing)
                ),
                redirect: observer.offeredRedirect
            )
        } catch {
            return NetworkLeg(result: .failure(error), redirect: nil)
        }
    }
}

// MARK: - Tagging

extension URLRequest {

    /// `URLProtocol.setProperty` needs an `NSMutableURLRequest`. Bridging
    /// through it and back is the only supported way to tag a `URLRequest`.
    func taggedAsHandled() -> URLRequest {
        guard let mutable = (self as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return self
        }
        URLProtocol.setProperty(true, forKey: LensURLProtocol.handledKey, in: mutable)
        return mutable as URLRequest
    }

    /// Marks a request as a replay of `exchangeID`.
    func stampedAsReplay(of exchangeID: UUID) -> URLRequest {
        guard let mutable = (self as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return self
        }
        URLProtocol.setProperty(exchangeID, forKey: LensURLProtocol.replayOfKey, in: mutable)
        return mutable as URLRequest
    }

    func stamped(screen: String?, exchangeID: UUID) -> URLRequest {
        guard let mutable = (self as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return self
        }
        if let screen {
            URLProtocol.setProperty(screen, forKey: LensURLProtocol.screenKey, in: mutable)
        }
        URLProtocol.setProperty(exchangeID, forKey: LensURLProtocol.exchangeIDKey, in: mutable)
        return mutable as URLRequest
    }
}

