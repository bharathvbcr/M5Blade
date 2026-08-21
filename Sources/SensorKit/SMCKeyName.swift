import Foundation

/// A sensor name that is really a raw SMC key — `Tp04`, `TG0B`, `TRD7`.
///
/// The SMC gives no `Product` string, so `SMCTemperatureSensors` puts the key in
/// `Reading.name`. That leaves the naming and grouping layers with a value that
/// looks like a name and must not be treated as one: they match substrings
/// case-insensitively, which is correct for "eCPU core 3" and actively wrong for
/// a four-byte FourCC where case carries meaning.
///
/// Recognising the shape once, here, keeps that distinction in a single place
/// instead of repeated in every rule table.
public struct SMCKeyName: Hashable, Sendable, CustomStringConvertible {
    public let description: String

    /// Exactly four ASCII alphanumerics beginning with `T`.
    ///
    /// Narrow on purpose. Every real sensor name from the HID hub on this Mac —
    /// "PMU tdie1", "gas gauge battery", "NAND CH0 temp" — is either longer than
    /// four characters or contains a space, so none can be mistaken for a key.
    /// Temperature keys are the only ones this project reads, hence the `T`.
    public init?(_ candidate: String) {
        guard candidate.count == 4, candidate.first == "T" else { return nil }
        guard candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        self.description = candidate
    }

    /// The two-character family — `Tp`, `Tg`, `TG` — which is the finest
    /// division the measurements in `SensorCategory.classify(smcKey:)` support.
    /// Case-sensitive, because `Tg` and `TG` are different hardware here.
    public var family: String { String(description.prefix(2)) }
}
