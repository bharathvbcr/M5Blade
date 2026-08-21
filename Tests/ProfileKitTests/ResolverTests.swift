import XCTest
import FanKit
@testable import ProfileKit

final class ResolverTests: XCTestCase {

    private let floor = SafetyFloor()

    private func makeResolver() -> ProfileResolver {
        ProfileResolver(defaultProfileID: Profile.balancedID)
    }

    /// Dwell exists to stop a rule flapping when its *conditions* wobble. It was
    /// also holding rules the user had just switched off, so disabling a rule
    /// appeared to do nothing for up to `minDwell` seconds.
    func testDisablingARuleTakesEffectImmediatelyDespiteDwell() {
        var resolver = makeResolver()
        var rule = Rule(name: "on battery", conditions: [.powerSource(.battery)],
                        targetProfileID: Profile.silentID, minDwell: 600, debounce: 0)
        let onBattery = SystemState(powerSource: .battery)
        let t0 = Date()

        let active = resolver.resolve(state: onBattery, rules: [rule], pin: nil, floor: floor, now: t0)
        XCTAssertEqual(active.profileID, Profile.silentID)

        rule.enabled = false
        let after = resolver.resolve(state: onBattery, rules: [rule], pin: nil,
                                     floor: floor, now: t0.addingTimeInterval(1))
        XCTAssertEqual(after.profileID, Profile.balancedID)
        XCTAssertEqual(after.source, .defaultProfile)
    }

    func testDeletingTheActiveRuleFallsBackImmediately() {
        var resolver = makeResolver()
        let rule = Rule(name: "on battery", conditions: [.powerSource(.battery)],
                        targetProfileID: Profile.silentID, minDwell: 600, debounce: 0)
        let onBattery = SystemState(powerSource: .battery)
        let t0 = Date()

        _ = resolver.resolve(state: onBattery, rules: [rule], pin: nil, floor: floor, now: t0)
        let after = resolver.resolve(state: onBattery, rules: [], pin: nil,
                                     floor: floor, now: t0.addingTimeInterval(1))
        XCTAssertEqual(after.profileID, Profile.balancedID)
    }

    func testDefaultWhenNothingMatches() {
        var resolver = makeResolver()
        let result = resolver.resolve(state: SystemState(maxTempC: 45),
                                      rules: [], pin: nil, floor: floor, now: Date())
        XCTAssertEqual(result.profileID, Profile.balancedID)
        XCTAssertEqual(result.source, .defaultProfile)
    }

    /// Precedence rule 1: emergency cannot be overridden by anything.
    func testEmergencyBeatsManualPinAndRules() {
        var resolver = makeResolver()
        let pin = ManualPin(profileID: Profile.silentID, setAt: Date(), powerSourceAtPin: .ac)
        let rule = Rule(name: "always", conditions: [.powerSource(.ac)],
                        targetProfileID: Profile.silentID, minDwell: 0, debounce: 0)
        let state = SystemState(maxTempC: 60, thermalPressure: .critical)

        let result = resolver.resolve(state: state, rules: [rule], pin: pin,
                                      floor: floor, now: Date())
        XCTAssertEqual(result.source, .emergency)
        XCTAssertTrue(result.releaseCeiling)
    }

    /// Precedence rule 2: a manual pin outranks rules.
    func testManualPinBeatsRules() {
        var resolver = makeResolver()
        let pin = ManualPin(profileID: Profile.performanceID, setAt: Date(),
                            powerSourceAtPin: .ac)
        let rule = Rule(name: "silent on ac", conditions: [.powerSource(.ac)],
                        targetProfileID: Profile.silentID, minDwell: 0, debounce: 0)
        let result = resolver.resolve(state: SystemState(maxTempC: 50, powerSource: .ac),
                                      rules: [rule], pin: pin, floor: floor, now: Date())
        XCTAssertEqual(result.profileID, Profile.performanceID)
        XCTAssertEqual(result.source, .manualPin)
    }

    func testPinIsClearedByPowerSourceChange() {
        var resolver = makeResolver()
        let pin = ManualPin(profileID: Profile.performanceID, setAt: Date(),
                            powerSourceAtPin: .ac)
        let result = resolver.resolve(state: SystemState(maxTempC: 50, powerSource: .battery),
                                      rules: [], pin: pin, floor: floor, now: Date())
        XCTAssertEqual(result.source, .defaultProfile)
    }

    func testFirstMatchingRuleWins() {
        var resolver = makeResolver()
        let first = Rule(name: "first", conditions: [.powerSource(.ac)],
                         targetProfileID: Profile.performanceID, minDwell: 0, debounce: 0)
        let second = Rule(name: "second", conditions: [.powerSource(.ac)],
                          targetProfileID: Profile.silentID, minDwell: 0, debounce: 0)
        let result = resolver.resolve(state: SystemState(maxTempC: 50, powerSource: .ac),
                                      rules: [first, second], pin: nil,
                                      floor: floor, now: Date())
        XCTAssertEqual(result.profileID, Profile.performanceID)
    }

    func testDebounceDelaysRuleActivation() {
        var resolver = makeResolver()
        let rule = Rule(name: "delayed", conditions: [.powerSource(.battery)],
                        targetProfileID: Profile.silentID, minDwell: 0, debounce: 5)
        let start = Date()
        let state = SystemState(maxTempC: 50, powerSource: .battery)

        let immediate = resolver.resolve(state: state, rules: [rule], pin: nil,
                                         floor: floor, now: start)
        XCTAssertEqual(immediate.source, .defaultProfile, "rule fired before debounce")

        let later = resolver.resolve(state: state, rules: [rule], pin: nil,
                                     floor: floor, now: start.addingTimeInterval(6))
        XCTAssertEqual(later.profileID, Profile.silentID)
    }

    /// Anti-flapping: once a rule wins it holds for minDwell even when its
    /// conditions stop matching.
    func testDwellHoldsRuleAfterConditionsStopMatching() {
        var resolver = makeResolver()
        let rule = Rule(name: "sticky", conditions: [.powerSource(.battery)],
                        targetProfileID: Profile.silentID, minDwell: 30, debounce: 0)
        let start = Date()
        let onBattery = SystemState(maxTempC: 50, powerSource: .battery)
        let onAC = SystemState(maxTempC: 50, powerSource: .ac)

        _ = resolver.resolve(state: onBattery, rules: [rule], pin: nil, floor: floor, now: start)
        let held = resolver.resolve(state: onAC, rules: [rule], pin: nil,
                                    floor: floor, now: start.addingTimeInterval(5))
        XCTAssertEqual(held.profileID, Profile.silentID, "dwell did not hold")

        let released = resolver.resolve(state: onAC, rules: [rule], pin: nil,
                                        floor: floor, now: start.addingTimeInterval(40))
        XCTAssertEqual(released.source, .defaultProfile)
    }

    func testProcessRuleRequiresSustainedCPU() {
        var resolver = makeResolver()
        let rule = Rule(name: "xcode build",
                        conditions: [.processActive(match: .executableName("swift-frontend"),
                                                    sustainedCPU: 50, forSeconds: 15)],
                        targetProfileID: Profile.performanceID, minDwell: 0, debounce: 0)

        // Running but idle — must not trigger. "Xcode is running" is true all day.
        let idle = SystemState(maxTempC: 50, processes: [
            ProcessSnapshot(pid: 1, executableName: "swift-frontend",
                            cpuPercent: 4, activeFor: 600)
        ])
        XCTAssertEqual(resolver.resolve(state: idle, rules: [rule], pin: nil,
                                        floor: floor, now: Date()).source, .defaultProfile)

        let busy = SystemState(maxTempC: 50, processes: [
            ProcessSnapshot(pid: 1, executableName: "swift-frontend",
                            cpuPercent: 320, activeFor: 30)
        ])
        XCTAssertEqual(resolver.resolve(state: busy, rules: [rule], pin: nil,
                                        floor: floor, now: Date()).profileID,
                       Profile.performanceID)
    }
}
