//
//  ScreenContext.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// The stack of screens currently on display, newest last.
///
/// Foundation only. The `UIViewController` swizzle that feeds it lives in
/// `NetworkLensUI`, because Core must stay usable from a headless test process
/// with no UIKit.
///
/// Reads happen on the caller's thread at task-creation time. By the time
/// `canInit` runs you may be on the session's delegate queue with no relation
/// to the calling thread, so reading the stack there gives the wrong screen or
/// none at all.
public final class ScreenContext: @unchecked Sendable {

    public static let shared = ScreenContext()

    private let lock = NSLock()
    private var stack: [Entry] = []

    private struct Entry {
        let token: UUID
        let name: String
    }

    public init() {}

    /// Innermost screen, or `nil` when nothing has been pushed.
    public var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return stack.last?.name
    }

    /// Full stack, outermost first. Useful for a "Home > Cart > Checkout" trail.
    public var trail: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stack.map(\.name)
    }

    /// Pushes a screen and returns the token needed to pop it.
    ///
    /// Token-based rather than balanced push/pop because view controller
    /// appearance is not reliably nested — a dismissal can land out of order,
    /// and popping blindly would remove the wrong screen.
    @discardableResult
    public func push(_ name: String) -> UUID {
        let token = UUID()
        lock.lock()
        stack.append(Entry(token: token, name: name))
        lock.unlock()
        return token
    }

    public func pop(_ token: UUID) {
        lock.lock()
        stack.removeAll { $0.token == token }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        stack.removeAll()
        lock.unlock()
    }
}
