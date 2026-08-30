//
//  LensControlChannel.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/08/26.
//

import Foundation

/// One instruction left with the sidecar for the app to collect.
public struct ControlCommand: Decodable, Sendable {

    public var id: Int
    public var kind: String
    public var endpointKey: String?
    public var variantName: String?
    public var status: Int?
    public var body: String?
    public var delay: TimeInterval?
    public var note: String?
    public var pack: ScenarioPack?

    /// Whole rules, in the shape `session.json` stores them, so a caller that already
    /// built a variant set does not have to describe it one field at a time.
    public var rules: [MockRule]?

    public var scenarios: [Scenario]?

    /// Matched as substrings, because the caller's idea of what is armed can be older than the app's.
    public var removeEndpointKeys: [String]?

    public var isMockingEnabled: Bool?
}

/// What the app hands back for one command. Fields are optional so every verb reports through one shape.
public struct ControlOutcome: Encodable, Sendable {

    public var rules: [MockRule]?
    public var isMockingEnabled: Bool?
    public var breakpoints: [Breakpoint]?
    public var pack: ScenarioPack?
    public var appliedCount: Int?
    public var missingEndpointKeys: [String]?
    public var upsertedCount: Int?
    public var removedCount: Int?

    public init() {
        // Every field is filled by the verb that produced it; none has a useful default.
    }
}

/// Applies commands an agent left with the sidecar, so a rule changes without a relaunch.
/// Polls rather than listens: a listener trips iOS's local-network prompt and dies with the app, while a sidecar queue survives a relaunch.
public final class LensControlChannel: @unchecked Sendable {

    public static let shared = LensControlChannel()

    private let lock = NSLock()
    private var options: ControlOptions?
    private var pollTask: Task<Void, Never>?

    /// Its own session, marked handled on every request, so the channel's own traffic is never
    /// captured, mocked or breakpointed by the lens it drives.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public init() {
        // Nothing runs until `start` is called with options.
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pollTask != nil
    }

    /// Idempotent: a second `start` while the channel is up is a no-op rather than a second poller.
    public func start(_ options: ControlOptions) {
        lock.lock()
        guard pollTask == nil else {
            lock.unlock()
            return
        }
        self.options = options
        let task = Task { [weak self] in
            guard let self else { return }
            await self.pollUntilCancelled(options)
        }
        pollTask = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let task = pollTask
        pollTask = nil
        options = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Polling

    private func pollUntilCancelled(_ options: ControlOptions) async {
        while !Task.isCancelled {
            await drainOnce(options)
            do {
                try await NetworkLens.clock.sleep(for: options.pollInterval)
            } catch {
                return
            }
        }
    }

    /// A sidecar that is down is the ordinary case, not an error worth reporting on a two-second timer.
    private func drainOnce(_ options: ControlOptions) async {
        guard let commands = await collect(options), !commands.isEmpty else { return }
        for command in commands.prefix(options.maxCommandsPerPoll) {
            guard !Task.isCancelled else { return }
            await applyAndReport(command, options: options)
        }
    }

    private func collect(_ options: ControlOptions) async -> [ControlCommand]? {
        let url = options.endpoint.appendingPathComponent("commands")
        let poll = request(url: url, method: "GET")
        guard let data = try? await send(poll) else { return nil }
        return try? JSONDecoder().decode(CommandEnvelope.self, from: data).commands
    }

    private func applyAndReport(_ command: ControlCommand, options: ControlOptions) async {
        let report: Data?
        do {
            let outcome = try apply(command)
            let result = CommandResult(id: command.id, value: outcome)
            report = try? JSONEncoder().encode(result)
        } catch {
            let failure = CommandFailure(id: command.id, error: "\(error)")
            report = try? JSONEncoder().encode(failure)
        }
        guard let report else { return }
        let url = options.endpoint.appendingPathComponent("result")
        var post = request(url: url, method: "POST")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = report
        _ = try? await send(post)
    }

    // MARK: - Verbs

    /// Verb names match the browser lens exactly, so an agent's vocabulary does not fork per platform.
    func apply(_ command: ControlCommand) throws -> ControlOutcome {
        switch command.kind {
            case "state":
                return currentState()
            case "arm":
                return try arm(command)
            case "disarm":
                return disarm(command)
            case "variant":
                return try activateVariant(command)
            case "scenario":
                return try applyScenario(command)
            case "edit":
                return try edit(command)
            case "export":
                return exportPack(command)
            default:
                throw ControlError.unknownCommand(command.kind)
        }
    }

    private func currentState() -> ControlOutcome {
        var outcome = ControlOutcome()
        outcome.rules = Mocks.shared.all
        outcome.isMockingEnabled = Mocks.shared.isMockingEnabled
        outcome.breakpoints = Breakpoints.shared.all
        return outcome
    }

    /// Adds a variant to whatever is already armed rather than replacing the rule — an existing rule is someone's work.
    private func arm(_ command: ControlCommand) throws -> ControlOutcome {
        guard let endpointKey = command.endpointKey,
            !endpointKey.isEmpty
        else {
            throw ControlError.missingEndpointKey
        }
        let response = MockResponse(
            statusCode: command.status ?? 200,
            headers: ["Content-Type": "application/json"],
            body: Data((command.body ?? "").utf8),
            delay: command.delay ?? 0
        )
        let variant = MockVariant(name: command.variantName ?? "agent", steps: [.respond(response)])
        if let existing = Mocks.shared.rule(forEndpointKey: endpointKey) {
            let merged = MockRule(
                id: existing.id,
                endpointKey: existing.endpointKey,
                variants: existing.variants + [variant],
                activeVariantID: variant.id,
                isEnabled: true,
                match: existing.match
            )
            Mocks.shared.set(merged)
        } else {
            let fresh = MockRule(endpointKey: endpointKey, variants: [variant])
            Mocks.shared.set(fresh)
        }
        Mocks.shared.setMockingEnabled(true)
        return currentState()
    }

    /// Disables rather than removes, so the variants stay for the next arm.
    private func disarm(_ command: ControlCommand) -> ControlOutcome {
        guard let endpointKey = command.endpointKey,
            !endpointKey.isEmpty
        else {
            Mocks.shared.disableAll()
            return currentState()
        }
        if var existing = Mocks.shared.rule(forEndpointKey: endpointKey) {
            existing.isEnabled = false
            Mocks.shared.set(existing)
        }
        return currentState()
    }

    private func activateVariant(_ command: ControlCommand) throws -> ControlOutcome {
        guard let endpointKey = command.endpointKey,
            !endpointKey.isEmpty
        else {
            throw ControlError.missingEndpointKey
        }
        guard let existing = Mocks.shared.rule(forEndpointKey: endpointKey) else {
            throw ControlError.nothingArmed(endpointKey)
        }
        let wanted = command.variantName ?? ""
        guard let target = existing.variants.first(where: { $0.name == wanted }) else {
            let available = existing.variants.map { $0.name }.joined(separator: ", ")
            throw ControlError.noSuchVariant(endpointKey: endpointKey, wanted: wanted, available: available)
        }
        Mocks.shared.activateVariant(target.id, forRuleID: existing.id)
        Mocks.shared.setMockingEnabled(true)
        return currentState()
    }

    /// Imports the pack before applying, because a scenario alone is a set of pointers that resolves to nothing here.
    private func applyScenario(_ command: ControlCommand) throws -> ControlOutcome {
        guard let pack = command.pack else { throw ControlError.missingPack }
        _ = pack.import()
        guard let scenario = pack.scenarios.first else { throw ControlError.missingScenario }
        let result = Scenarios.shared.apply(scenario)
        Mocks.shared.setMockingEnabled(true)
        var outcome = currentState()
        outcome.appliedCount = result.applied
        outcome.missingEndpointKeys = result.missing.map { $0.endpointKey }
        return outcome
    }

    /// Installs rules the caller has already assembled, so logic that reads a trace stays where the trace is.
    /// Removal runs first: a caller replacing a rule sends both, and doing it the other way round deletes what it just wrote.
    private func edit(_ command: ControlCommand) throws -> ControlOutcome {
        let rules = command.rules ?? []
        let scenarios = command.scenarios ?? []
        let removals = command.removeEndpointKeys ?? []
        guard !rules.isEmpty || !scenarios.isEmpty || !removals.isEmpty || command.isMockingEnabled != nil else {
            throw ControlError.emptyEdit
        }
        var removed = 0
        for needle in removals {
            let lowered = needle.lowercased()
            for rule in Mocks.shared.all where rule.endpointKey.lowercased().contains(lowered) {
                Mocks.shared.remove(id: rule.id)
                removed += 1
            }
        }
        for rule in rules {
            Mocks.shared.set(rule)
        }
        for scenario in scenarios {
            Scenarios.shared.save(scenario)
        }
        if let enabled = command.isMockingEnabled {
            Mocks.shared.setMockingEnabled(enabled)
        }
        var outcome = currentState()
        outcome.upsertedCount = rules.count
        outcome.removedCount = removed
        return outcome
    }

    private func exportPack(_ command: ControlCommand) -> ControlOutcome {
        let name = command.note ?? "device"
        let pack = ScenarioPack.exporting(Scenarios.shared.all, from: Mocks.shared.all, named: name)
        var outcome = ControlOutcome()
        outcome.pack = pack
        return outcome
    }

    // MARK: - Transport

    /// Marked handled so `canInit` refuses it — otherwise the channel's own poll is captured twice a second forever.
    private func request(url: URL, method: String) -> URLRequest {
        var plain = URLRequest(url: url)
        plain.httpMethod = method
        guard let mutable = (plain as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return plain
        }
        URLProtocol.setProperty(true, forKey: LensURLProtocol.handledKey, in: mutable)
        guard let marked = mutable.copy() as? URLRequest else { return plain }
        return marked
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, _) = try await session.data(for: request)
        return data
    }

    private struct CommandEnvelope: Decodable {
        var commands: [ControlCommand]
    }

    private struct CommandResult: Encodable {
        var id: Int
        var value: ControlOutcome
    }

    private struct CommandFailure: Encodable {
        var id: Int
        var error: String
    }
}

/// Reported back as the command's result, so a miss reaches the agent as data rather than as silence.
public enum ControlError: Error, CustomStringConvertible {

    case unknownCommand(String)
    case missingEndpointKey
    case missingPack
    case emptyEdit
    case missingScenario
    case nothingArmed(String)
    case noSuchVariant(endpointKey: String, wanted: String, available: String)

    public var description: String {
        switch self {
            case .unknownCommand(let kind):
                return "Unknown command \"\(kind)\"."
            case .missingEndpointKey:
                return "That command needs an endpointKey."
            case .missingPack:
                return "That command carries no pack."
            case .emptyEdit:
                return "That edit carries no rules, scenarios, removals or mocking flag."
            case .missingScenario:
                return "That pack carries no scenario."
            case .nothingArmed(let endpointKey):
                return "Nothing armed on \(endpointKey)."
            case .noSuchVariant(let endpointKey, let wanted, let available):
                return "\(endpointKey) has no variant \"\(wanted)\". It has: \(available)."
        }
    }
}
