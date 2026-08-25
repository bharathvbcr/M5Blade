import XCTest
import CoreGraphics
import HistoryKit
@testable import M5BladeApp

/// The sparkline is 64 points wide. Everything that can go wrong in it — a
/// divide by zero, a NaN, a line drawn over the text beside it — is invisible at
/// that size, so it is checked arithmetically instead.
final class SparklineGeometryTests: XCTestCase {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let size = CGSize(width: 64, height: 14)

    private func points(_ values: [Double], step: TimeInterval = 1) -> [SeriesPoint] {
        values.enumerated().map { offset, value in
            SeriesPoint(date: base.addingTimeInterval(Double(offset) * step), value: value)
        }
    }

    // MARK: - Nothing to draw

    func testNothingToDrawReturnsNil() {
        XCTAssertNil(SparklineGeometry.path(for: [], in: size))
        XCTAssertNil(SparklineGeometry.path(for: points([50]), in: size),
                     "one sample is a dot, not a trace")
        XCTAssertNil(SparklineGeometry.path(for: points([50, 51]), in: .zero))
        XCTAssertNil(SparklineGeometry.path(for: points([50, 51]),
                                            in: CGSize(width: 64, height: 0)))
    }

    func testSamplesSharingAnInstantDoNotDivideByZero() {
        let same = [SeriesPoint(date: base, value: 50), SeriesPoint(date: base, value: 60)]
        let path = SparklineGeometry.path(for: same, in: size) ?? []
        XCTAssertEqual(path.count, 2)
        for point in path {
            XCTAssertTrue(point.x.isFinite)
            XCTAssertTrue(point.y.isFinite)
        }
    }

    func testNonFiniteValuesAreDropped() {
        let path = SparklineGeometry.path(for: points([50, .nan, 55, .infinity, 60]), in: size)
        XCTAssertEqual(path?.count, 3)
    }

    // MARK: - Scale

    /// Half a degree of drift must not be drawn as a mountain range.
    func testAFlatSensorDrawsAFlatLineThroughTheMiddle() {
        let path = SparklineGeometry.path(for: points([60, 60, 60, 60]), in: size)
        let ys = Set((path ?? []).map { ($0.y * 1_000).rounded() })
        XCTAssertEqual(ys.count, 1, "a still sensor must not wobble")
        XCTAssertEqual(path?.first?.y ?? 0, size.height / 2, accuracy: 0.001)
    }

    func testTinyDriftStaysNearTheMiddleRatherThanFillingTheBox() throws {
        let path = try XCTUnwrap(SparklineGeometry.path(for: points([60, 60.5, 60.2, 60.4]),
                                                        in: size))
        let ys = path.map(\.y)
        let spread = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertLessThan(spread, size.height * 0.1,
                          "half a degree used the whole 10-degree scale")
    }

    func testAFullRangeUsesTheWholeBox() throws {
        let path = try XCTUnwrap(SparklineGeometry.path(for: points([40, 90]), in: size))
        let ys = path.map(\.y)
        XCTAssertEqual(ys.min() ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(ys.max() ?? -1, size.height, accuracy: 0.001)
    }

    /// Higher temperature is higher on screen, which is the one thing a reader
    /// assumes without being told.
    func testHotterSamplesSitHigher() throws {
        let path = try XCTUnwrap(SparklineGeometry.path(for: points([40, 90]), in: size))
        XCTAssertGreaterThan(path[0].y, path[1].y)
    }

    // MARK: - Window

    func testOnlyTheLastMinuteIsDrawn() {
        // Five minutes of samples; only the last sixty seconds belong on screen.
        let path = SparklineGeometry.path(for: points(Array(repeating: 50, count: 300)), in: size)
        XCTAssertEqual(path?.count, 61)
    }

    func testWideSpacingStillProducesATrace() {
        let path = SparklineGeometry.path(for: points([50, 60, 70], step: 20), in: size)
        XCTAssertEqual(path?.count, 3)
        XCTAssertEqual(path?.first?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(path?.last?.x ?? -1, size.width, accuracy: 0.001)
    }

    // MARK: - Fuzz

    /// Whatever the samples, the trace stays inside its box and contains no
    /// number a drawing routine cannot use.
    func testRandomInputAlwaysStaysInsideTheBoxAndFinite() {
        var random = Seeded(seed: 0x5EED)
        for iteration in 0..<3_000 {
            let count = Int.random(in: 0...80, using: &random)
            let box = CGSize(width: Double.random(in: 1...400, using: &random),
                             height: Double.random(in: 1...80, using: &random))
            let samples = (0..<count).map { index -> SeriesPoint in
                let value: Double = switch Int.random(in: 0..<10, using: &random) {
                case 0: .nan
                case 1: .infinity
                case 2: Double.random(in: -1e6...1e6, using: &random)
                default: Double.random(in: -50...150, using: &random)
                }
                // Deliberately unordered spacing, including repeats.
                return SeriesPoint(date: base.addingTimeInterval(
                    Double(index) * Double.random(in: 0...4, using: &random)), value: value)
            }

            guard let path = SparklineGeometry.path(for: samples, in: box) else { continue }
            for point in path {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite,
                              "non-finite coordinate at iteration \(iteration)")
                XCTAssertTrue((0...box.width).contains(point.x),
                              "x escaped the box at iteration \(iteration)")
                XCTAssertTrue((0...box.height).contains(point.y),
                              "y escaped the box at iteration \(iteration)")
            }
        }
    }

    /// One absurd sample — a sensor that reports 300° for a single tick — must
    /// not drag the line outside the box and over the reading beside it.
    func testASingleOutlierIsClampedRatherThanDrawnOutside() throws {
        let path = try XCTUnwrap(SparklineGeometry.path(for: points([60, 61, 3_000, 62]),
                                                        in: size))
        for point in path {
            XCTAssertTrue((0...size.height).contains(point.y))
            XCTAssertTrue((0...size.width).contains(point.x))
        }
    }
}
