import Foundation

/// Tracks how long each key has been *continuously* active.
///
/// "Sustained" conditions are the difference between useful automation and a
/// profile that flaps every time a beachball spins. Pure and value-typed, so the
/// timing rules are testable without waiting in real time.
public struct SustainTracker: Sendable, Equatable {
    private var activeSince: [String: Date] = [:]

    public init() {}

    /// Any key absent from `activeKeys` has its clock reset — that is what makes
    /// this *continuously* active rather than a cumulative total.
    public mutating func update(activeKeys: Set<String>, now: Date) {
        for key in activeKeys where activeSince[key] == nil {
            activeSince[key] = now
        }
        activeSince = activeSince.filter { activeKeys.contains($0.key) }
    }

    public func duration(_ key: String, now: Date) -> TimeInterval {
        guard let since = activeSince[key] else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    public var trackedKeys: Set<String> { Set(activeSince.keys) }

    public mutating func reset() { activeSince.removeAll() }
}
