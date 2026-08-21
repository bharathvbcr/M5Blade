import Foundation
import FanKit
import SMCKit

/// Temperature sensors read straight from the SMC.
///
/// A second source alongside `TemperatureSensors`, not a replacement. The two
/// overlap far less than the shared `T`-prefixed key spelling suggests: of the
/// 22 sensors the HID hub reports on this Mac, only the six `TG*` battery-gauge
/// keys also appear in the SMC's own key space. The 14 `PMU tdie*` zones do not
/// — HID `TP1b` has no SMC counterpart, and SMC `TPD0` has no HID one.
///
/// What it adds here is subsystem separation the HID hub does not give at all.
/// The hub's 14 die zones are undifferentiated; the SMC exposes 285 `T*` keys,
/// including 23 `Tp*`, 40 `Tm*` and 42 `Tg*`, and those families are separable
/// by measurement — see `SensorCategory.classify(smcKey:)`.
///
/// Discovery is by enumeration, never by a table of keys per Mac model. The keys
/// a machine has are a fact it will tell you; which sensor each key *is* is not,
/// and this type does not pretend otherwise.
public actor SMCTemperatureSensors {

    /// A key that survived discovery, with the metadata needed to read it.
    private struct Candidate {
        let key: SMCKey
        let info: SMCKeyInfo
        let name: String
    }

    private let connection: SMCConnection
    private var catalog: [Candidate]?

    /// Whether discovery has run and found anything. False until the first
    /// `readAll()`, so callers should treat it as "nothing yet", not "no SMC".
    public private(set) var isAvailable = false

    public init(connection: SMCConnection = SMCConnection()) {
        self.connection = connection
    }

    /// Temperature keys, by convention, are the ones beginning with `T`.
    ///
    /// This bounds the sweep: without it every poll would read all 3603 keys
    /// instead of 285, and would touch keys this app has no business reading.
    /// The prefix is a filter on *work*, not the correctness gate — type and
    /// range are, and they are what actually rejects `TV*` (`si32`, not a
    /// temperature) and `TTPD`.
    private static let temperaturePrefix: Character = "T"

    /// Enumerate once and keep the result.
    ///
    /// The key set is fixed for the life of the machine, and enumeration costs
    /// ~12 ms against ~57 ms for a full read of the catalog, so re-discovering
    /// per poll would be a fifth of the budget spent re-learning a constant.
    private func discover() async -> [Candidate] {
        if let catalog { return catalog }

        do {
            try await connection.open()
        } catch {
            catalog = []
            return []
        }

        guard let keys = try? await connection.allKeys() else {
            catalog = []
            return []
        }

        var found: [Candidate] = []
        for key in keys {
            let name = key.description
            guard name.first == Self.temperaturePrefix else { continue }
            guard let info = try? await connection.keyInfo(key), info.isReadable else { continue }
            // An unrecognised type is not a temperature we can decode. This is
            // what excludes the 31 `TV*` keys: they report `si32`, which
            // `SMCValue.doubleValue` has no case for and never will.
            guard info.type != nil else { continue }
            found.append(Candidate(key: key, info: info, name: name))
        }

        catalog = found
        isAvailable = !found.isEmpty
        return found
    }

    /// Snapshot every SMC temperature sensor.
    ///
    /// Returns an empty array when the SMC cannot be opened, matching
    /// `TemperatureSensors.readAll()` — a missing source degrades to no readings,
    /// never to a throw on the polling path.
    public func readAll() async -> [TemperatureSensors.Reading] {
        let candidates = await discover()
        var readings: [TemperatureSensors.Reading] = []
        readings.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let value = try? await connection.read(candidate.key),
                  let celsius = value.doubleValue,
                  PlausibleTemperature.admits(celsius) else { continue }
            // The key is both the name and the identity. There is no friendlier
            // name to be had: unlike the HID hub, the SMC reports no `Product`
            // string, and inventing one from the key is the guess this project
            // exists to avoid.
            readings.append(TemperatureSensors.Reading(name: candidate.name,
                                                       celsius: celsius,
                                                       ordinal: 0,
                                                       smcKey: candidate.name))
        }
        return readings
    }

    /// Close the underlying connection. Not required — `SMCConnection` closes on
    /// deinit — but the app's teardown path is explicit about its IOKit handles.
    public func close() async {
        await connection.close()
    }
}
