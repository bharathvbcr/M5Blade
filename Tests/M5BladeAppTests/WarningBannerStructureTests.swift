import XCTest
@testable import M5BladeApp

/// The banner's action button must stay outside the combined accessibility
/// element. The pre-fix code `.combine`d the whole row, which made "Set Up…"
/// part of the announcement *text* with no separately focusable control —
/// a VoiceOver user could hear about the problem but not act on it.
///
/// What these tests can and cannot verify is stated plainly:
/// - They verify the view still lays out and draws after the restructure
///   (a combine-scope change can silently break layout; this pins it).
/// - They cannot verify the materialized VoiceOver tree headlessly: SwiftUI
///   builds its AX elements lazily, only when a real assistive client
///   attaches — measured: `accessibilityChildren` is empty and the system AX
///   API returns cannotComplete (-25208) from an untrusted xctest runner.
///   Manual verification steps live in ISSUES.md (§Hardening audit).
@MainActor
final class WarningBannerStructureTests: XCTestCase {

    func testABannerWithAnActionStillRenders() {
        RenderHarness.assertDraws(
            WarningBanner(message: "Helper not running", shape: .card,
                          actionTitle: "Set Up…") { },
            "banner with action")
    }

    func testABannerWithoutAnActionStillRenders() {
        RenderHarness.assertDraws(
            WarningBanner(message: "Two fan controllers detected"),
            "banner without action")
    }
}
