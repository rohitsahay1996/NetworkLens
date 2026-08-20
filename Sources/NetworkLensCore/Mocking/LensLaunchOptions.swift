//
//  LensLaunchOptions.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 20/08/26.
//

import Foundation

/// Reads the options a test runner or CI job can pass in at launch.
///
/// The bridge out of the app. Everything else in this package assumes a human
/// is holding the device: a breakpoint needs someone to resume it, a variant
/// needs someone to pick it. A `UITest` has nobody, so the setup has to arrive
/// from outside the process or it cannot exist at all.
///
/// Takes the arguments and environment rather than reaching for
/// `ProcessInfo.processInfo`, so the parsing is testable without a subprocess.
public enum LensLaunchOptions {

    /// `-NetworkLensScenario "cart empty"`, or `-NetworkLensScenario=cart empty`.
    public static let scenarioFlag = "-NetworkLensScenario"

    /// `NETWORKLENS_SCENARIO=cart empty`. The form a CI job usually finds
    /// easier — a scheme's environment variables outlive its arguments when a
    /// test plan is involved.
    public static let scenarioEnvironmentKey = "NETWORKLENS_SCENARIO"

    /// The scenario to apply at launch, if one was named.
    ///
    /// An argument beats the environment: the environment is set once for the
    /// scheme, and an argument is what a single test run overrides it with.
    public static func scenarioName(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let fromArguments = value(of: scenarioFlag, in: arguments) { return fromArguments }
        return trimmedOrNil(environment[scenarioEnvironmentKey])
    }

    /// Accepts both `--flag value` and `--flag=value`.
    ///
    /// Xcode's "Arguments Passed On Launch" is one argument per row, so the
    /// separated form is what a scheme produces; the joined form is what
    /// someone typing into a terminal reaches for. Supporting one and not the
    /// other produces a silent no-op, which is the failure this whole file
    /// exists to avoid.
    static func value(of flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                // The next argument, unless there is none or it is itself a
                // flag — `-NetworkLensScenario -SomethingElse` names nothing.
                guard index + 1 < arguments.count else { return nil }
                let next = arguments[index + 1]
                guard !next.hasPrefix("-") else { return nil }
                return trimmedOrNil(next)
            }
            if argument.hasPrefix(flag + "=") {
                return trimmedOrNil(String(argument.dropFirst(flag.count + 1)))
            }
        }
        return nil
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What an attempt to apply a scenario by name did.
///
/// Named rather than optional, because the interesting case is the failure. A
/// UI test that asks for "cart empty", silently gets live traffic and passes
/// anyway is worse than one that fails — it reports green about a state it
/// never entered.
public enum ScenarioActivation: Sendable, Equatable {

    case applied(name: String, outcome: Scenarios.Outcome)

    /// No saved scenario carries that name. Lists what was there instead: the
    /// cause is almost always a typo or an empty store, and both are obvious
    /// the moment the available names are in front of you.
    case noSuchScenario(name: String, available: [String])

    public var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    /// One line for a log or an overlay notice.
    public var summary: String {
        switch self {
        case .applied(let name, let outcome):
            let base = "Applied scenario “\(name)” to \(outcome.applied) "
                + (outcome.applied == 1 ? "endpoint" : "endpoints")
            guard !outcome.missing.isEmpty else { return base }
            return base + " — \(outcome.missing.count) could not be reached, "
                + "their rule or variant no longer exists."
        case .noSuchScenario(let name, let available):
            guard !available.isEmpty else {
                return "No scenario named “\(name)”, and none are saved. "
                    + "Persistence must be on for a launch argument to find one."
            }
            return "No scenario named “\(name)”. Saved: "
                + available.map { "“\($0)”" }.joined(separator: ", ") + "."
        }
    }
}
