//
//  HostLockTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 28/08/26.
//

import XCTest
@testable import NetworkLensCore

/// The lock decides what is intercepted, so the failures worth catching are the
/// ones that look like a broken tool: a lock that captures nothing, a lock that
/// silently admits a subdomain it was never given, and an inventory that stops
/// listing the host you need in order to unlock the right thing.
final class HostLockTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.networklens.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        HostLock.shared.unlock()
        NetworkLens.start(configuration: LensConfiguration())
        super.tearDown()
    }

    // MARK: - Verdict

    func testNoLockDefersToConfiguration() {
        let lock = HostLock(defaults: defaults)
        XCTAssertNil(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"))
        XCTAssertNil(lock.verdict(for: nil))
    }

    func testLockedHostIsCaptured() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        XCTAssertEqual(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"), true)
    }

    func testUnpinnedHostIsRefusedWhileLocked() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        XCTAssertEqual(lock.verdict(for: "static-uatb.gdn-app.com"), false)
        XCTAssertEqual(lock.verdict(for: "app-analytics-services-att.com"), false)
    }

    /// A subdomain is a different host. `capturedHostPatterns` expands suffixes
    /// on purpose; the lock must not, or pinning one API host would readmit
    /// every shard behind it.
    func testSubdomainOfPinnedHostIsRefused() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["gdn-app.com"])
        XCTAssertEqual(lock.verdict(for: "static-uatb.gdn-app.com"), false)
        XCTAssertEqual(lock.verdict(for: "gdn-app.com"), true)
    }

    func testMalformedHostIsRefusedWhileLocked() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        XCTAssertEqual(lock.verdict(for: nil), false)
        XCTAssertEqual(lock.verdict(for: ""), false)
    }

    func testHostMatchingIsCaseInsensitive() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["BWA-QA2-GCP.GDN-APP.COM"])
        XCTAssertEqual(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"), true)
    }

    /// An empty set has to unlock rather than lock everything out — a lock that
    /// captures nothing is indistinguishable from capture having broken.
    func testLockingToNothingUnlocks() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: [String]())
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"))
    }

    func testUnlockRestoresConfigurationControl() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.verdict(for: "static-uatb.gdn-app.com"))
    }

    // MARK: - Per-host

    /// The point of the per-row control: a second domain joins the lock
    /// without the first being released.
    func testPinningASecondHostKeepsTheFirst() {
        let lock = HostLock(defaults: defaults)
        lock.pin("bwa-qa2-gcp.gdn-app.com")
        lock.pin("wwwuatb.gdn-app.com")

        XCTAssertEqual(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"), true)
        XCTAssertEqual(lock.verdict(for: "wwwuatb.gdn-app.com"), true)
        XCTAssertEqual(lock.verdict(for: "static-uatb.gdn-app.com"), false)
    }

    func testUnpinningTheLastHostUnlocksEntirely() {
        let lock = HostLock(defaults: defaults)
        lock.pin("bwa-qa2-gcp.gdn-app.com")
        lock.unpin("bwa-qa2-gcp.gdn-app.com")

        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.verdict(for: "static-uatb.gdn-app.com"))
    }

    func testUnpinningOneOfTwoLeavesTheOtherLocked() {
        let lock = HostLock(defaults: defaults)
        lock.pin("bwa-qa2-gcp.gdn-app.com")
        lock.pin("wwwuatb.gdn-app.com")
        lock.unpin("wwwuatb.gdn-app.com")

        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.verdict(for: "wwwuatb.gdn-app.com"), false)
        XCTAssertEqual(lock.verdict(for: "bwa-qa2-gcp.gdn-app.com"), true)
    }

    func testToggleReportsTheResultingState() {
        let lock = HostLock(defaults: defaults)
        XCTAssertTrue(lock.toggle("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertTrue(lock.isPinned("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertFalse(lock.toggle("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertFalse(lock.isPinned("bwa-qa2-gcp.gdn-app.com"))
    }

    func testPinIsCaseInsensitive() {
        let lock = HostLock(defaults: defaults)
        lock.pin("BWA-QA2-GCP.GDN-APP.COM")
        XCTAssertTrue(lock.isPinned("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertEqual(lock.hosts.count, 1)
    }

    func testPinnedHostsSurviveAFreshInstance() {
        let lock = HostLock(defaults: defaults)
        lock.pin("bwa-qa2-gcp.gdn-app.com")
        lock.pin("wwwuatb.gdn-app.com")
        XCTAssertEqual(HostLock(defaults: defaults).hosts.count, 2)
    }

    // MARK: - Persistence

    func testLockSurvivesAFreshInstance() {
        HostLock(defaults: defaults).lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        let relaunched = HostLock(defaults: defaults)
        XCTAssertTrue(relaunched.isLocked)
        XCTAssertEqual(relaunched.verdict(for: "bwa-qa2-gcp.gdn-app.com"), true)
        XCTAssertEqual(relaunched.verdict(for: "static-uatb.gdn-app.com"), false)
    }

    func testUnlockClearsWhatWasPersisted() {
        let lock = HostLock(defaults: defaults)
        lock.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        lock.unlock()
        XCTAssertFalse(HostLock(defaults: defaults).isLocked)
    }

    // MARK: - Inventory

    /// The lock's escape route. A host that is refused must still be listed, or
    /// there is no way to discover it and nothing to unlock towards.
    func testInventoryRecordsHostsItDoesNotCapture() {
        let inventory = HostInventory(defaults: defaults)
        inventory.record("bwa-qa2-gcp.gdn-app.com")
        inventory.record("static-uatb.gdn-app.com")
        XCTAssertEqual(inventory.hosts, ["bwa-qa2-gcp.gdn-app.com", "static-uatb.gdn-app.com"])
    }

    func testInventoryIgnoresEmptyAndNilHosts() {
        let inventory = HostInventory(defaults: defaults)
        inventory.record(nil)
        inventory.record("")
        XCTAssertTrue(inventory.hosts.isEmpty)
    }

    func testInventoryDeduplicatesCaseInsensitively() {
        let inventory = HostInventory(defaults: defaults)
        inventory.record("BWA-QA2-GCP.GDN-APP.COM")
        inventory.record("bwa-qa2-gcp.gdn-app.com")
        XCTAssertEqual(inventory.hosts.count, 1)
    }

    func testInventorySurvivesAFreshInstance() {
        HostInventory(defaults: defaults).record("bwa-qa2-gcp.gdn-app.com")
        XCTAssertEqual(HostInventory(defaults: defaults).hosts, ["bwa-qa2-gcp.gdn-app.com"])
    }

    func testClearEmptiesTheInventory() {
        let inventory = HostInventory(defaults: defaults)
        inventory.record("bwa-qa2-gcp.gdn-app.com")
        inventory.clear()
        XCTAssertTrue(inventory.hosts.isEmpty)
        XCTAssertTrue(HostInventory(defaults: defaults).hosts.isEmpty)
    }

    // MARK: - Capture gate

    /// The gate is what the interception path calls, so the precedence has to
    /// hold there and not only inside `HostLock`.
    func testGateLetsTheLockOverrideConfiguredPatterns() {
        NetworkLens.start(configuration: LensConfiguration(capturedHostPatterns: ["wwwuatb.gdn-app.com"]))
        XCTAssertTrue(NetworkLens.capturesHost("wwwuatb.gdn-app.com"))
        XCTAssertFalse(NetworkLens.capturesHost("bwa-qa2-gcp.gdn-app.com"))

        HostLock.shared.lock(to: ["bwa-qa2-gcp.gdn-app.com"])
        XCTAssertTrue(NetworkLens.capturesHost("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertFalse(NetworkLens.capturesHost("wwwuatb.gdn-app.com"))

        HostLock.shared.unlock()
        XCTAssertTrue(NetworkLens.capturesHost("wwwuatb.gdn-app.com"))
        XCTAssertFalse(NetworkLens.capturesHost("bwa-qa2-gcp.gdn-app.com"))
    }
}
