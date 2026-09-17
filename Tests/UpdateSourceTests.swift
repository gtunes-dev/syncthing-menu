import Foundation
import Testing
@testable import SyncthingMenu

/// A scripted mechanism for the policy engine: results are set by the test, and
/// `holdCheck`/`holdApply` park an operation mid-flight so single-flight and
/// cross-channel serialization can be observed while it hangs.
private final class FakeUpdateSource: UpdateSource {
    var version: String? = "1.0.0"
    var checkResult: Result<UpdateState, Error> = .success(.upToDate)
    var applyResult: Result<Void, Error> = .success(())
    var holdCheck = false
    var holdApply = false

    private(set) var checkCount = 0
    private(set) var applyCount = 0
    /// Applies that ran to a successful completion (the mechanism's success
    /// path, as opposed to a decline or failure).
    private(set) var completedCount = 0
    private(set) var lastUserInitiated: Bool?

    override func fetchVersion() async -> String? { version }

    override func checkForUpdate() async throws -> UpdateState {
        checkCount += 1
        while holdCheck { try? await Task.sleep(nanoseconds: 1_000_000) }
        return try checkResult.get()
    }

    override func applyUpdate(userInitiated: Bool) async throws {
        applyCount += 1
        lastUserInitiated = userInitiated
        while holdApply { try? await Task.sleep(nanoseconds: 1_000_000) }
        try applyResult.get()
        completedCount += 1
    }
}

private struct AnyError: Error {}

/// Scenario tests for the shared update-policy engine (`UpdateSource`) — the one
/// policy both channels run. Mechanisms are scripted (`FakeUpdateSource`);
/// settings are isolated per test; each test gets its own coordinator, never the
/// app-wide singleton.
@MainActor
struct UpdateSourcePolicyTests {

    /// Isolated settings + a fake channel. The brief sleep lets the settings
    /// sinks' initial replayed emissions land (they no-op before availability),
    /// so tests observe only transitions they cause.
    private func makeSource(autoCheck: Bool, autoInstall: Bool,
                            gatesMajors: Bool = false,
                            pollInterval: TimeInterval = 3600,
                            coordinator: UpdateInstallCoordinator = .init()
    ) async -> FakeUpdateSource {
        let suiteName = "io.github.gtunes-dev.SyncthingMenuTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // Unique prefix per source: the registration domain is process-global,
        // so a shared prefix would leak defaults across concurrent tests.
        let settings = UpdateChannelSettings(
            defaults: defaults, prefix: "test-\(UUID().uuidString)",
            autoCheckDefault: autoCheck, autoInstallDefault: autoInstall)
        let source = FakeUpdateSource(
            name: "Fake", settings: settings, pollInterval: pollInterval,
            gatesMajorUpdates: gatesMajors, coordinator: coordinator)
        try? await Task.sleep(nanoseconds: 20_000_000)
        return source
    }

    // MARK: - Auto-check

    @Test func autoCheckOnChecksAtAvailability() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))

        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }
        #expect(source.currentVersion == "1.0.0")
        #expect(source.checkCount == 1)
        #expect(source.settings.lastChecked != nil)
    }

    /// Auto-check OFF: the channel never checks on its own and surfaces nothing —
    /// but the header still learns the current version.
    @Test func autoCheckOffSurfacesNothing() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))

        source.makeAvailable()
        try await expectEventually { source.currentVersion == "1.0.0" }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.state == .unknown)
        #expect(source.checkCount == 0)
        #expect(source.settings.lastChecked == nil)
    }

    /// Only the Check Now button probes an opted-out channel.
    @Test func manualCheckProbesDespiteAutoCheckOff() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.makeAvailable()
        try await expectEventually { source.currentVersion != nil }

        source.checkNow()
        try await expectEventually { source.state == .upToDate }
        #expect(source.checkCount == 1)
        #expect(source.settings.lastChecked != nil)
    }

    @Test func disablingAutoCheckClearsSurfacedState() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }

        source.settings.autoCheckEnabled = false
        try await expectEventually { source.state == .unknown }
    }

    @Test func overlappingChecksAreSingleFlight() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.makeAvailable()
        try await expectEventually { source.currentVersion != nil }

        source.holdCheck = true
        source.checkNow()
        try await expectEventually { source.checkCount == 1 }
        source.checkNow()                 // lands mid-flight: must be ignored
        source.holdCheck = false
        try await expectEventually { source.state == .upToDate }
        #expect(source.checkCount == 1)
    }

    @Test func failedCheckResetsToUnknown() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.checkResult = .failure(AnyError())
        source.makeAvailable()
        try await expectEventually { source.currentVersion != nil }

        source.checkNow()
        try await expectEventually { source.checkCount == 1 && source.state == .unknown }
        #expect(source.settings.lastChecked == nil)
    }

    /// A failed check retries on its own (much sooner than the poll interval),
    /// and a retry that succeeds ends the retrying.
    @Test func failedCheckRetriesUntilSuccess() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkRetryInterval = 0.15
        source.checkResult = .failure(AnyError())

        source.makeAvailable()
        try await expectEventually { source.checkCount == 1 && source.state == .unknown }

        // First retry fires and fails too …
        try await expectEventually { source.checkCount == 2 }
        // … then the cause clears and the next retry succeeds.
        source.checkResult = .success(.upToDate)
        try await expectEventually { source.state == .upToDate }
        #expect(source.settings.lastChecked != nil)

        // Success ended the retrying: no further checks accumulate.
        let settled = source.checkCount
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(source.checkCount == settled)
    }

    /// A completed check cancels a pending retry — no double-checking after
    /// the user's manual Check Now resolves the failure early.
    @Test func completedCheckCancelsPendingRetry() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkRetryInterval = 0.4
        source.checkResult = .failure(AnyError())

        source.makeAvailable()
        try await expectEventually { source.checkCount == 1 && source.state == .unknown }

        // Manual check succeeds; the pending retry is cancelled by completion.
        // (A retry may legitimately fire before the manual check lands if the
        // scheduler stalls — so assert quiescence, not an exact count.)
        source.checkResult = .success(.upToDate)
        source.checkNow()
        try await expectEventually { source.state == .upToDate }

        try await Task.sleep(nanoseconds: 500_000_000)
        let settled = source.checkCount
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(source.checkCount == settled)
    }

    /// Turning auto-check off ends the retrying: an opted-out channel goes
    /// quiet. (One retry may legitimately land while the toggle is still
    /// propagating — the pinned guarantee is quiescence, not zero strays:
    /// nothing can RE-arm after the toggle, because arming reads the setting
    /// synchronously.)
    @Test func disablingAutoCheckEndsRetrying() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkRetryInterval = 0.15
        source.checkResult = .failure(AnyError())

        source.makeAvailable()
        try await expectEventually { source.checkCount >= 1 }

        source.settings.autoCheckEnabled = false
        // Window for any in-flight stray to land and fail (it cannot re-arm) …
        try await Task.sleep(nanoseconds: 500_000_000)
        // … then the channel must be silent.
        let settled = source.checkCount
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(source.checkCount == settled)
    }

    /// With auto-check off, a failed manual check does NOT retry — only the
    /// user probes an opted-out channel.
    @Test func noRetryWhenAutoCheckOff() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.checkRetryInterval = 0.15
        source.checkResult = .failure(AnyError())
        source.makeAvailable()
        try await expectEventually { source.currentVersion != nil }

        source.checkNow()
        try await expectEventually { source.checkCount == 1 && source.state == .unknown }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(source.checkCount == 1)
    }

    /// A check superseded by unavailability discards its result — no stale state,
    /// no recorded check.
    @Test func unavailabilitySupersedesInFlightCheck() async throws {
        let source = await makeSource(autoCheck: false, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually { source.currentVersion != nil }

        source.holdCheck = true
        source.checkNow()
        try await expectEventually { source.checkCount == 1 }
        source.makeUnavailable()
        source.holdCheck = false
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.state == .unknown)
        #expect(source.settings.lastChecked == nil)
    }

    // MARK: - Auto-install and the major gate

    @Test func autoInstallAppliesFoundUpdateImmediately() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: true)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))

        source.makeAvailable()
        try await expectEventually { source.completedCount == 1 }
        #expect(source.applyCount == 1)
        #expect(source.lastUserInitiated == false)
        // Success leaves .installing: the mechanism's completion hands off to a
        // relaunch (app), or — for a mechanism that takes its backing down and
        // up (Syncthing) — to the deferred availability that re-arms the channel.
        #expect(source.state == .installing)
    }

    /// A mechanism that stops and restarts its backing mid-install (the
    /// Syncthing channel around its binary swap) must not bounce the card:
    /// availability changes during an install are deferred, and the last one
    /// (backing came back) re-arms the channel with a fresh check once the
    /// install ends — the card reads Updating… throughout, then Up to date.
    @Test func availabilityChangesDuringInstallAreDeferredUntilItEnds() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually { source.state == .available(version: "2.0.0", isMajor: false) }
        let checksBefore = source.checkCount

        source.holdApply = true
        source.installAvailable()
        try await expectEventually { source.applyCount == 1 }
        #expect(source.state == .installing)

        source.makeUnavailable()             // the daemon stopped
        #expect(source.state == .installing)
        source.makeAvailable()               // the new daemon connected
        #expect(source.state == .installing)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.checkCount == checksBefore)   // no check ran under the install

        source.checkResult = .success(.upToDate)
        source.holdApply = false
        try await expectEventually { source.state == .upToDate }
        #expect(source.completedCount == 1)
        #expect(source.checkCount == checksBefore + 1)
        #expect(source.isAvailable)
    }

    /// A failed install is not auto-retried in a loop. The Syncthing mechanism
    /// restarts the previous daemon after a failure, and that availability
    /// bounce runs a fresh check which finds the same version: it must be
    /// OFFERED again but not INSTALLED again until the next scheduled poll —
    /// one attempt per interval, the daemon's own scheduler's cadence.
    @Test func failedInstallIsNotAutoRetriedUntilTheNextPoll() async throws {
        // The poll interval must comfortably outlast the failed-install dance
        // below (under a loaded parallel suite it takes up to ~1s), so the
        // "offered, not re-installed" check runs before the tick can fire.
        let source = await makeSource(autoCheck: true, autoInstall: true, pollInterval: 3.0)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.applyResult = .failure(AnyError())
        source.holdApply = true
        source.makeAvailable()
        try await expectEventually { source.applyCount == 1 }

        source.makeUnavailable()             // the daemon stopped for the swap
        source.makeAvailable()               // and the previous one came back
        source.holdApply = false             // the install fails
        try await expectEventually { source.state == .available(version: "2.0.0", isMajor: false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(source.applyCount == 1)      // offered, not re-installed

        // The next poll tick lifts the suppression: exactly one more attempt.
        try await expectEventually(timeout: 10) { source.applyCount == 2 }
    }

    /// The suppression is for the automatic path only: the user's Update
    /// click retries a failed version at once.
    @Test func userCanRetryAFailedInstallImmediately() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: true)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.applyResult = .failure(AnyError())
        source.holdApply = true
        source.makeAvailable()
        try await expectEventually { source.applyCount == 1 }
        source.makeUnavailable()
        source.makeAvailable()
        source.holdApply = false
        try await expectEventually { source.state == .available(version: "2.0.0", isMajor: false) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.applyCount == 1)

        source.installAvailable()
        try await expectEventually { source.applyCount == 2 }
        #expect(source.lastUserInitiated == true)
    }

    /// The backing going down during an install and not coming back (the
    /// restarted daemon failed) lands after the install as plain unavailable.
    @Test func backingLostDuringInstallLandsAfterIt() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually { source.state == .available(version: "2.0.0", isMajor: false) }

        source.holdApply = true
        source.applyResult = .failure(AnyError())
        source.installAvailable()
        try await expectEventually { source.applyCount == 1 }
        source.makeUnavailable()
        #expect(source.state == .installing)
        #expect(source.isAvailable)

        source.holdApply = false
        try await expectEventually { !source.isAvailable }
        #expect(source.state == .unknown)
        #expect(source.completedCount == 0)
    }

    /// Only the install ends `.installing`: turning auto-check off mid-install
    /// must not write over it, or the deferral of availability changes stops
    /// working halfway and a stale deferred transition lands on a live channel.
    @Test func autoCheckOffDuringInstallKeepsTheDeferralIntact() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually { source.state == .available(version: "2.0.0", isMajor: false) }

        source.holdApply = true
        source.installAvailable()
        try await expectEventually { source.applyCount == 1 }
        source.makeUnavailable()                       // backing went down
        source.settings.autoCheckEnabled = false       // user opts out mid-install
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.state == .installing)
        source.makeAvailable()                         // backing came back: still deferred
        #expect(source.state == .installing)

        source.checkResult = .success(.upToDate)
        source.holdApply = false
        try await expectEventually { source.applyCount == 1 && source.isAvailable && source.state != .installing }
        // Re-armed with auto-check off: available (version surfaced), no check ran.
        #expect(source.state == .unknown)
    }

    /// The one policy difference between channels: a major on a gating channel
    /// never auto-installs — the explicit Update click is the consent.
    @Test func gatedMajorWaitsForExplicitConsent() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: true, gatesMajors: true)
        source.checkResult = .success(.available(version: "3.0.0", isMajor: true))

        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "3.0.0", isMajor: true)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.applyCount == 0)

        source.installAvailable()         // the click is the consent
        try await expectEventually { source.completedCount == 1 }
        #expect(source.lastUserInitiated == true)
    }

    /// A channel that doesn't gate majors (Syncthing Menu) auto-installs them.
    @Test func ungatedChannelAutoInstallsMajors() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: true)
        source.checkResult = .success(.available(version: "3.0.0", isMajor: true))

        source.makeAvailable()
        try await expectEventually { source.completedCount == 1 }
    }

    /// Turning auto-install on while an update is already showing applies it.
    @Test func enablingAutoInstallAppliesPendingUpdate() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }

        source.settings.autoInstallEnabled = true
        try await expectEventually { source.completedCount == 1 }
        #expect(source.lastUserInitiated == false)
    }

    // MARK: - Install outcomes

    /// Decline is not failure: the prior offer is restored and the button works
    /// again immediately.
    @Test func declineRestoresTheOffer() async throws {
        let coordinator = UpdateInstallCoordinator()
        let source = await makeSource(autoCheck: true, autoInstall: false,
                                      coordinator: coordinator)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.applyResult = .failure(UpdateDeclinedError())
        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }

        source.installAvailable()
        try await expectEventually { source.applyCount == 1 }
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }
        #expect(source.completedCount == 0)
        #expect(coordinator.installingChannel == nil)
    }

    @Test func failedInstallResetsToUnknownAndReleasesClaim() async throws {
        let coordinator = UpdateInstallCoordinator()
        let source = await makeSource(autoCheck: true, autoInstall: false,
                                      coordinator: coordinator)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.applyResult = .failure(AnyError())
        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }

        source.installAvailable()
        try await expectEventually { source.state == .unknown }
        #expect(coordinator.installingChannel == nil)
    }


    /// A successful apply keeps `.installing` — completion belongs to the
    /// channel's own reset (the app's relaunch; the daemon restart's
    /// availability bounce), and flipping the card back early would lie.
    @Test func terminalInstallStaysInstalling() async throws {
        let source = await makeSource(autoCheck: true, autoInstall: false)
        source.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        source.makeAvailable()
        try await expectEventually {
            source.state == .available(version: "2.0.0", isMajor: false)
        }

        source.installAvailable()
        try await expectEventually { source.completedCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.state == .installing)
    }

    // MARK: - Cross-channel serialization

    /// Never two installs at once: while channel A installs, channel B's found
    /// update stays `.available` (deferred, not queued) — and B's auto-install
    /// re-evaluates the moment A's install finishes.
    @Test func installsSerializeAcrossChannels() async throws {
        let coordinator = UpdateInstallCoordinator()
        let a = await makeSource(autoCheck: true, autoInstall: true,
                                 coordinator: coordinator)
        let b = await makeSource(autoCheck: true, autoInstall: true,
                                 coordinator: coordinator)
        a.checkResult = .success(.available(version: "2.0.0", isMajor: false))
        b.checkResult = .success(.available(version: "5.0.0", isMajor: false))

        // A finds its update and starts installing — and hangs mid-install.
        a.holdApply = true
        a.makeAvailable()
        try await expectEventually { a.state == .installing }

        // B finds its update; its auto-install must defer, not run or queue.
        b.makeAvailable()
        try await expectEventually {
            b.state == .available(version: "5.0.0", isMajor: false)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(b.applyCount == 0)
        #expect(coordinator.installingChannel === a)

        // A finishes: the released claim re-evaluates B's deferred auto-install.
        a.holdApply = false
        try await expectEventually { b.completedCount == 1 }
        #expect(b.lastUserInitiated == false)
        #expect(a.completedCount == 1)
        try await expectEventually { coordinator.installingChannel == nil }
    }
}
