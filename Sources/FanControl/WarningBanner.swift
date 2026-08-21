import SwiftUI

/// The app's one way of saying "something is wrong, here is what".
///
/// There were four of these, written out separately in the popover, the
/// settings window, the History window, and the General tab — and they had
/// already drifted: two icons, two paddings, one rounded and three square. A
/// warning that looks different every time it appears reads as four unrelated
/// glitches rather than one consistent signal.
struct WarningBanner: View {

    enum Shape {
        /// Edge to edge, directly under a window's header.
        case strip
        /// Inset and rounded, for use inside a form.
        case card
    }

    let message: String
    var shape: Shape = .strip
    /// An optional way out of the problem — "Show File", "Open Login Items".
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, shape == .strip ? 12 : 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: shape == .card ? 6 : 0))
        // One element, read as one sentence: VoiceOver announced the icon, the
        // text, and the button as three unrelated things.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. \(message)")
    }
}
