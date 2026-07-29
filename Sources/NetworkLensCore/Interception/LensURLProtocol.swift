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

    private var work: Task<Void, Never>?

    /// Identifies this instance to the breakpoint coordinator, so
    /// `stopLoading` can tear down UI that belongs to this request alone.
    private let instanceID = UUID()

    // MARK: - URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool {
        guard NetworkLens.isActive else { return false }
        // Already ours — this is the passthrough leg. Must be first.
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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

        let screen = URLProtocol.property(forKey: Self.screenKey, in: request) as? String
            ?? ScreenContext.shared.current
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
            startedAt: startedAt
        )
        // Record in flight so the overlay shows the row while it is pending.
        NetworkLens.record(exchange)

        // --- Request breakpoint ------------------------------------------------
        if Breakpoints.shared.shouldPauseRequest(for: outgoing) {
            let outcome = await BreakpointCoordinator.shared.pause(
                .request(outgoing),
                owner: instanceID,
                endpointKey: exchange.endpointKey,
                timeout: outgoing.timeoutInterval
            )
            guard !Task.isCancelled else { return }

            switch outcome {
            case .proceed(let edited):
                if case .request(let editedRequest) = edited {
                    outgoing = editedRequest
                    var snapshot = RequestSnapshot(request: outgoing)
                    snapshot.bodyTruncated = requestSnapshot.bodyTruncated
                    exchange = exchange.replacingRequest(snapshot, source: .edited)
                    NetworkLens.record(exchange)
                }
            case .abort(let error):
                exchange = exchange.failed(FailureInfo(error: error))
                NetworkLens.record(exchange)
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }

        // --- Network -----------------------------------------------------------
        let result = await perform(outgoing, cap: configuration.maxCapturedResponseBodyBytes)
        guard !Task.isCancelled else { return }

        var payload: ResponsePayload
        switch result {
        case .success(let received):
            payload = received
        case .failure(let error):
            exchange = exchange.failed(FailureInfo(error: error), timing: nil)
            NetworkLens.record(exchange)
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // --- Response breakpoint -----------------------------------------------
        if Breakpoints.shared.shouldPauseResponse(for: outgoing) {
            let outcome = await BreakpointCoordinator.shared.pause(
                .response(payload),
                owner: instanceID,
                endpointKey: exchange.endpointKey,
                timeout: outgoing.timeoutInterval
            )
            guard !Task.isCancelled else { return }

            switch outcome {
            case .proceed(let edited):
                if case .response(let editedPayload) = edited {
                    if editedPayload.body != payload.body
                        || editedPayload.response.statusCode != payload.response.statusCode {
                        exchange = exchange.withSource(.edited)
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

        guard !Task.isCancelled else { return }

        exchange = exchange.completed(response: payload.snapshot, timing: payload.timing)
        NetworkLens.record(exchange)

        client?.urlProtocol(self, didReceive: payload.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - Passthrough

    private func perform(
        _ request: URLRequest, cap: Int
    ) async -> Swift.Result<ResponsePayload, Error> {
        // The tag is what stops the recursion. Set on a mutable copy of the
        // request we are about to send, never on the one we were handed.
        let tagged = request.taggedAsHandled()
        let collector = MetricsCollector()
        do {
            let (data, response) = try await PassthroughSession.shared.session.data(
                for: tagged, delegate: collector
            )
            guard let http = response as? HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            let truncated = data.count > cap
            return .success(
                ResponsePayload(
                    response: http,
                    body: data,
                    timing: collector.timing,
                    bodyTruncated: truncated
                )
            )
        } catch {
            return .failure(error)
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

// MARK: - Passthrough session

/// The session used for the real network leg.
///
/// Built without `LensURLProtocol` in its protocol list. The handled tag alone
/// would be enough, but excluding the class as well means a bug in the tagging
/// degrades to "not captured" rather than to an infinite loop.
final class PassthroughSession: @unchecked Sendable {

    static let shared = PassthroughSession()

    let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = (configuration.protocolClasses ?? [])
            .filter { $0 != LensURLProtocol.self }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }
}

/// Collects `URLSessionTaskMetrics` for one task.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var collected: Timing?

    var timing: Timing? {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = Timing(metrics: metrics)
        lock.unlock()
    }
}
