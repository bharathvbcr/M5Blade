import XCTest
import FanKit
import SimSupport
@testable import ProfileKit

/// The resolver decides which profile drives the fans. Its precedence rules are
/// short enough to read and long enough to get wrong, and the state it carries
/// (dwell and debounce clocks) makes the wrong version fail only intermittently.
final class ResolverFuzzTests: XCTestCase {

    private let floor = SafetyFloor()
    private let profileIDs = Profile.builtIns(fanCount: 2).map(\.id)

    private func randomRule(_ rng: inout SplitMix64, index: Int) -> Rule {
        let pool: [Condition] = [
            .powerSource(.ac), .powerSource(.battery),
            .batteryBelow(percent: Int.random(in: 0...100, using: &rng)),
            .thermalAtLeast(ThermalPressure(rawValue: Int.random(in: 0...3, using: &rng)) ?? .fair),
            .displaysAsleep(Bool.random(using: &rng)),
            .externalDisplayCount(atLeast: Int.random(in: 0...3, using: &rng)),
            .macOSPowerMode(Bool.random(using: &rng) ? .low : .automatic),
            .sustainedLoad(cpuPercent: Double.random(in: 0...100, using: &rng),
                           forSeconds: Double.random(in: 0...120, using: &rng)),
        ]
        let count = Int.random(in: 0...3, using: &rng)
        let conditions = (0..<count).compactMap { _ in pool.randomElement(using: &rng) }
        return Rule(name: "r\(index)",
                    enabled: Int.random(in: 0..<10, using: &rng) > 1,
                    conditions: conditions,
                    targetProfileID: profileIDs.randomElement(using: &rng)!,
                    minDwell: Double.random(in: 0...60, using: &rng),
                    debounce: Double.random(in: 0...30, using: &rng))
    }

    private func randomState(_ rng: inout SplitMix64, now: Date) -> SystemState {
        SystemState(timestamp: now,
                    maxTempC: Bool.random(using: &rng) ? Double.random(in: 20...115, using: &rng) : nil,
                    thermalPressure: ThermalPressure(rawValue: Int.random(in: 0...3, using: &rng)) ?? .nominal,
                    cpuPercent: Double.random(in: 0...100, using: &rng),
                    loadSustainedFor: Double.random(in: 0...300, using: &rng),
                    powerSource: Bool.random(using: &rng) ? .ac : .battery,
                    batteryPercent: Double.random(in: 0...100, using: &rng),
                    displaysAsleep: Bool.random(using: &rng),
                    externalDisplayCount: Int.random(in: 0...3, using: &rng),
                    macOSPowerMode: Bool.random(using: &rng) ? .low : .automatic)
    }

    /// The precedence contract from DESIGN §2.4, asserted on every tick of every
    /// randomised timeline: emergency > manual pin > rules > default, and the
    /// answer is always a profile that exists.
    func testPrecedenceHoldsAcrossRandomTimelines() {
        for seed in UInt64(1)...30 {
            var rng = SplitMix64(seed: seed)
            var resolver = ProfileResolver(defaultProfileID: Profile.balancedID)
            let rules = (0..<Int.random(in: 0...6, using: &rng)).map { randomRule(&rng, index: $0) }
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            var pin: ManualPin?

            for tick in 0..<400 {
                now.addTimeInterval(Double.random(in: 0.5...5, using: &rng))
                let state = randomState(&rng, now: now)

                if Int.random(in: 0..<25, using: &rng) == 0 {
                    pin = ManualPin(profileID: profileIDs.randomElement(using: &rng)!,
                                    setAt: now,
                                    expiresAt: Bool.random(using: &rng)
                                        ? now.addingTimeInterval(Double.random(in: 1...120, using: &rng))
                                        : nil,
                                    powerSourceAtPin: state.powerSource)
                }
                if Int.random(in: 0..<40, using: &rng) == 0 { pin = nil }

                let resolution = resolver.resolve(state: state, rules: rules, pin: pin,
                                                  floor: floor, now: now)
                let context = "seed \(seed) tick \(tick)"

                XCTAssertTrue(profileIDs.contains(resolution.profileID),
                              "resolved an unknown profile — \(context)")

                let emergency = floor.requiresEmergency(tempC: state.maxTempC ?? 0,
                                                        pressure: state.thermalPressure)
                if emergency {
                    XCTAssertEqual(resolution.source, .emergency, "emergency was overridden — \(context)")
                    XCTAssertEqual(resolution.profileID, Profile.maxCoolingID, context)
                    XCTAssertTrue(resolution.releaseCeiling, context)
                    continue
                }
                XCTAssertFalse(resolution.releaseCeiling,
                               "the ceiling was released outside an emergency — \(context)")

                if let pin, pin.isValid(at: now, state: state) {
                    XCTAssertEqual(resolution.source, .manualPin,
                                   "a valid pin lost to a rule — \(context)")
                    XCTAssertEqual(resolution.profileID, pin.profileID, context)
                    continue
                }

                // Without a pin the answer is either a rule or the default, and a
                // rule answer must name a rule that exists and is enabled.
                switch resolution.source {
                case .rule(let id, _):
                    XCTAssertTrue(rules.contains { $0.id == id && $0.enabled },
                                  "resolved to a rule that is absent or disabled — \(context)")
                case .defaultProfile:
                    XCTAssertEqual(resolution.profileID, Profile.balancedID, context)
                default:
                    XCTFail("unexpected source \(resolution.source) — \(context)")
                }
            }
        }
    }

    /// Dwell and debounce exist to stop flapping. With conditions that oscillate
    /// every tick, the resolved profile must change far less often than the
    /// conditions do.
    func testDwellAndDebounceSuppressFlapping() {
        var resolver = ProfileResolver(defaultProfileID: Profile.balancedID)
        let rule = Rule(name: "on battery", conditions: [.powerSource(.battery)],
                        targetProfileID: Profile.silentID, minDwell: 30, debounce: 5)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var previous: UUID?
        var changes = 0

        for tick in 0..<600 {
            now.addTimeInterval(1)
            let state = SystemState(powerSource: tick % 2 == 0 ? .battery : .ac)
            let resolution = resolver.resolve(state: state, rules: [rule], pin: nil,
                                              floor: floor, now: now)
            if let previous, previous != resolution.profileID { changes += 1 }
            previous = resolution.profileID
        }
        XCTAssertLessThan(changes, 30,
                          "\(changes) profile changes in 600 ticks of a 1 Hz oscillation is flapping")
    }

    /// A pin taken on AC must not follow the machine onto battery, no matter how
    /// the timeline is shuffled.
    func testPinNeverSurvivesAPowerSourceChange() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            var resolver = ProfileResolver(defaultProfileID: Profile.balancedID)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let pinnedOn: PowerSource = Bool.random(using: &rng) ? .ac : .battery
            let pin = ManualPin(profileID: Profile.performanceID, setAt: now,
                                powerSourceAtPin: pinnedOn)
            let other: PowerSource = pinnedOn == .ac ? .battery : .ac
            let resolution = resolver.resolve(state: SystemState(powerSource: other),
                                              rules: [], pin: pin, floor: floor,
                                              now: now.addingTimeInterval(1))
            XCTAssertEqual(resolution.source, .defaultProfile)
        }
    }

    /// Resolution must depend only on its inputs. Two resolvers fed the same
    /// timeline must agree at every step — otherwise something in the state
    /// machine is order- or identity-dependent and will differ between launches.
    func testResolutionIsDeterministicForTheSameTimeline() {
        for seed in UInt64(50)...60 {
            var rngA = SplitMix64(seed: seed)
            var rngB = SplitMix64(seed: seed)
            var a = ProfileResolver(defaultProfileID: Profile.balancedID)
            var b = ProfileResolver(defaultProfileID: Profile.balancedID)
            let rules = (0..<4).map { randomRule(&rngA, index: $0) }
            _ = (0..<4).map { randomRule(&rngB, index: $0) }

            var now = Date(timeIntervalSince1970: 1_700_000_000)
            for _ in 0..<300 {
                now.addTimeInterval(1)
                var rngState = SplitMix64(seed: UInt64(now.timeIntervalSince1970))
                let state = randomState(&rngState, now: now)
                let ra = a.resolve(state: state, rules: rules, pin: nil, floor: floor, now: now)
                let rb = b.resolve(state: state, rules: rules, pin: nil, floor: floor, now: now)
                XCTAssertEqual(ra.profileID, rb.profileID)
                XCTAssertEqual(ra.source, rb.source)
            }
        }
    }
}
