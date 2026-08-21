import XCTest
@testable import HistoryKit

/// The sentence the Insights page shows. It is the whole point of recording a
/// spike, and it is the easiest place in the app to say something confident and
/// wrong — so each branch is pinned to the evidence it claims to rest on.
final class SpikeExplanationTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func spike(from: Double = 58, to: Double = 92,
                       cpuFrom: Double = 8, cpuTo: Double = 8,
                       group: String = "SoC",
                       profileChanged: Bool = false,
                       namesRecorded: Bool = true,
                       processes: [ProcessShare] = []) -> Spike {
        Spike(id: 1,
              start: base,
              peak: base.addingTimeInterval(70),
              end: base.addingTimeInterval(300),
              fromTempC: from,
              peakTempC: to,
              cpuAtStartPercent: cpuFrom,
              peakCPUPercent: cpuTo,
              hottestGroup: group,
              peakFanRPM: 4_200,
              peakFanDutyPercent: 88,
              profileName: "Balanced",
              profileChanged: profileChanged,
              recordedProcessNames: namesRecorded,
              processes: processes)
    }

    func testAnApplicationThatOwnedTheWorkIsNamed() {
        let explanation = SpikeExplanation.explain(
            spike(cpuFrom: 9, cpuTo: 96,
                  processes: [.init(name: "swift-frontend", percent: 71),
                              .init(name: "Xcode", percent: 18)]))

        XCTAssertEqual(explanation.cause, .application)
        XCTAssertTrue(explanation.headline.contains("swift-frontend"), explanation.headline)
        XCTAssertTrue(explanation.detail.contains("Xcode"), "runners-up belong in the evidence")
        XCTAssertNil(explanation.suggestion, "nothing left to suggest — it answered the question")
    }

    /// The trap. Attribution measures CPU-seconds, so during a graphics spike
    /// whatever happened to be using the processor gets a high share while
    /// having nothing to do with the heat.
    func testANamedApplicationIsNotBlamedWhenLoadNeverRose() {
        let explanation = SpikeExplanation.explain(
            spike(cpuFrom: 12, cpuTo: 15, group: "GPU",
                  processes: [.init(name: "Finder", percent: 90)]))

        XCTAssertEqual(explanation.cause, .graphics)
        XCTAssertFalse(explanation.headline.contains("Finder"), explanation.headline)
    }

    func testLoadThatRoseWithNoNamesIsProcessorLoad() {
        let explanation = SpikeExplanation.explain(
            spike(cpuFrom: 5, cpuTo: 88, namesRecorded: false))

        XCTAssertEqual(explanation.cause, .processorLoad)
        XCTAssertNotNil(explanation.suggestion, "turning attribution on would have helped")
    }

    /// A machine already pinned at 90% that stays at 90% did not spike *because*
    /// of new CPU work, however high the number is.
    func testLoadThatWasAlreadyHighIsNotTreatedAsTheCause() {
        let explanation = SpikeExplanation.explain(spike(cpuFrom: 91, cpuTo: 93))
        XCTAssertNotEqual(explanation.cause, .processorLoad)
        XCTAssertNotEqual(explanation.cause, .application)
    }

    func testTheSSDGettingHotIsSaidPlainly() {
        XCTAssertEqual(SpikeExplanation.explain(spike(group: "Storage")).cause, .storage)
    }

    func testAProfileChangeIsOfferedOnlyWhenNothingElseExplainsIt() {
        XCTAssertEqual(SpikeExplanation.explain(spike(profileChanged: true)).cause, .profileChange)
        // A profile change during a spike the CPU clearly caused is a
        // coincidence, not the reason.
        XCTAssertEqual(SpikeExplanation.explain(
            spike(cpuFrom: 4, cpuTo: 90, profileChanged: true)).cause, .processorLoad)
    }

    func testAnUnexplainedRiseSaysSoRatherThanGuessing() {
        let explanation = SpikeExplanation.explain(spike())
        XCTAssertEqual(explanation.cause, .background)
        XCTAssertNotNil(explanation.suggestion)
    }

    /// Once attribution is already on, "turn on attribution" is noise.
    func testNoSuggestionIsOfferedWhenNamesWereAlreadyBeingRecorded() {
        let explanation = SpikeExplanation.explain(spike(namesRecorded: true))
        XCTAssertEqual(explanation.cause, .background)
        XCTAssertFalse(explanation.suggestion?.contains("Turn on") ?? false)
    }

    /// The reader has to be able to disagree with the headline, which means the
    /// numbers it was inferred from have to be on screen beside it.
    func testEveryExplanationCarriesTheMeasurementsBehindIt() {
        for candidate in [spike(), spike(cpuFrom: 4, cpuTo: 90), spike(group: "GPU"),
                          spike(group: "Storage"), spike(profileChanged: true)] {
            let explanation = SpikeExplanation.explain(candidate)
            XCTAssertTrue(explanation.detail.contains("58 → 92 °C"), explanation.detail)
            XCTAssertTrue(explanation.detail.contains("load"), explanation.detail)
            XCTAssertFalse(explanation.headline.isEmpty)
        }
    }

    func testDurationsReadTheSameEverywhere() {
        XCTAssertEqual(HistoryFormatting.duration(0), "0s")
        XCTAssertEqual(HistoryFormatting.duration(45), "45s")
        XCTAssertEqual(HistoryFormatting.duration(300), "5m")
        XCTAssertEqual(HistoryFormatting.duration(305), "5m 5s")
        XCTAssertEqual(HistoryFormatting.duration(-10), "0s", "never a negative duration")
    }
}
