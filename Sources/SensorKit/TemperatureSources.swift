import Foundation
import SMCKit

/// Both temperature sources, merged into the one list the app reads.
///
/// The HID sensor hub and the SMC are genuinely different sets, not one nested
/// in the other. Measured on this Mac: the hub reports 22 physical sensors, the
/// SMC 270 more, and the intersection is six — the `TG*` battery-gauge keys,
/// which read identically down to the last digit through either path (33.30 and
/// 33.30, then 33.20 and 33.20, sampled at the same instants). Everything else
/// is unique to one side. The hub's 14 `PMU tdie*` zones have no SMC key; the
/// SMC's `Tp*`/`Tm*`/`Tg*` families have no hub entry.
///
/// So the merge is a union with one de-duplication rule, not a choice of source.
public actor TemperatureSources {

    private let hid: TemperatureSensors
    private let smc: SMCTemperatureSensors
    private var includeSMC: Bool

    /// - Parameter includeSMC: off by default. Adding the SMC takes this Mac
    ///   from 22 sensors to 292, which is a change to what the app shows and to
    ///   what the history store records, so it is the caller's decision rather
    ///   than a silent consequence of updating.
    public init(includeSMC: Bool = false) {
        self.hid = TemperatureSensors()
        self.smc = SMCTemperatureSensors()
        self.includeSMC = includeSMC
    }

    /// Turn the SMC source on or off between polls.
    ///
    /// The catalogue the SMC source discovered is kept either way, so toggling
    /// back on does not pay the ~12 ms enumeration again. Turning it off stops
    /// the reads, which is where the cost actually is.
    public func setIncludeSMC(_ enabled: Bool) {
        includeSMC = enabled
    }

    public nonisolated var isHIDAvailable: Bool { hid.isAvailable }

    /// Every sensor from every enabled source, de-duplicated.
    public func readAll() async -> [TemperatureSensors.Reading] {
        let hidReadings = hid.readAll()
        let smcReadings = includeSMC ? await smc.readAll() : []
        return Self.merge(hid: hidReadings, smc: smcReadings)
    }

    /// Highest temperature among the sensors whose subsystem is established.
    ///
    /// With `includeSMC` off this is exactly `TemperatureSensors.maxTemperature()`
    /// — the behaviour the curve has today, unchanged.
    public func maxTemperature() async -> Double? {
        Self.attributed(await readAll()).map(\.celsius).max()
    }

    /// The readings this app is willing to act on: the ones it can say what they
    /// measure.
    ///
    /// Two callers, one question. A fan curve may only be driven from a reading
    /// whose subsystem is known, and the history store only spends two years of
    /// disk on the same — a key nobody can attribute is worth showing live and
    /// worth neither of those.
    ///
    /// Named sensors keep the existing rule: everything except a calibration
    /// reference. Bare SMC keys have to clear a higher bar, and the bar is
    /// evidence about what the key measures — only the two families whose
    /// behaviour was established by load testing, `Tp` (processor) and `Tg`
    /// (graphics), qualify.
    ///
    /// A whitelist rather than a blacklist, because the failure modes are not
    /// symmetric. Among the 270 SMC-only keys on this Mac are `TR0Z`, which holds
    /// 51.82 °C forever and would pin the curve input above every real reading on
    /// a cool machine; `TVMX`/`TVmS`/`TVms`, which sit at exactly 61.00 and look
    /// like configured limits; and nine `Tz1*` keys reading 0.00. None of those
    /// can be told from a live sensor by its readings alone — the attempt is
    /// documented in `TemperatureSensors.Reading.isReference` — but all of them
    /// are excluded for free by requiring positive evidence instead.
    ///
    /// The cost of the whitelist is that a genuinely hot sensor in an
    /// unclassified family cannot raise the fans. That is acceptable here because
    /// the HID hub already covers the peak independently: sampled at the same
    /// instants under load, its hottest `tdie` read 102.07 °C against the SMC's
    /// hottest 101.41 °C.
    public static func attributed(_ readings: [TemperatureSensors.Reading])
    -> [TemperatureSensors.Reading] {
        readings.filter { reading in
            guard !reading.isReference else { return false }
            guard let key = SMCKeyName(reading.name) else { return true }
            return eligibleFamilies.contains(key.family)
        }
    }

    /// Established by load testing on this Mac — see
    /// `SensorCategory.classify(smcKey:)` for the measurements. `Tm` is left out
    /// on purpose: it rose under both CPU-only and GPU-only load, so what it
    /// measures is not settled, and an unsettled sensor does not get to drive a
    /// fan while the HID hub is already reporting the same peak.
    public static let eligibleFamilies: Set<String> = ["Tp", "Tg"]

    /// Union the two sources, preferring the HID reading wherever both describe
    /// the same key.
    ///
    /// The hub wins because it carries a `Product` name — "gas gauge battery"
    /// against a bare `TG0B` — and that name is what drives both the friendly
    /// label and the category. Nothing is lost by dropping the SMC copy: they are
    /// the same sensor reporting the same number.
    ///
    /// Readings with no key cannot be proven duplicate and are always kept, the
    /// same call `TemperatureSensors.consolidate` makes.
    static func merge(hid: [TemperatureSensors.Reading],
                      smc: [TemperatureSensors.Reading]) -> [TemperatureSensors.Reading] {
        let claimed = Set(hid.lazy.filter { !$0.smcKey.isEmpty }.map(\.smcKey))
        // Key comparison is case-sensitive, and has to be: on this Mac `TG0B` is
        // a battery gauge and `Tg08` is a GPU sensor. Case-folding the two
        // together would merge unrelated hardware.
        let additions = smc.filter { $0.smcKey.isEmpty || !claimed.contains($0.smcKey) }

        return (hid + additions).sorted {
            (TemperatureSensors.naturalKey($0.name), $0.smcKey)
                < (TemperatureSensors.naturalKey($1.name), $1.smcKey)
        }
    }
}
