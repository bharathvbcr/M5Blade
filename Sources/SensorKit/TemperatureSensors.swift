import Foundation
import FanKit
#if canImport(IOKit)
import IOKit

/// Temperature sensors on Apple Silicon, read through the HID sensor hub.
///
/// These are private APIs. Every symbol is resolved with `dlsym`, so a removed
/// or renamed function degrades to "no sensors" instead of a launch failure
/// (AUDIT, private API exposure).
public final class TemperatureSensors: @unchecked Sendable {

    public struct Reading: Sendable, Equatable, Identifiable {
        public let name: String
        public let celsius: Double

        /// The hardware channel behind this reading — the SMC FourCC that the
        /// HID service carries in its `LocationID` ("TP1b", "TG0B", "TN0n").
        ///
        /// This is the only stable identity Apple gives us, and it is the one
        /// thing that tells duplicates from namesakes. On this Mac the hub
        /// enumerates each die sensor three times: all three copies of
        /// "PMU tdie1" report `TP1b`, so they are one sensor, not three. The six
        /// entries called "gas gauge battery" report six *different* keys, so
        /// they are six sensors sharing one unhelpful name.
        ///
        /// Empty when the property is missing, which is the only case where the
        /// name has to serve as identity again.
        public let smcKey: String

        /// Index among the sensors that share `name`, assigned in `smcKey`
        /// order so a given sensor keeps its number between reads. Scan order
        /// would not: the services array is not ordered.
        public let ordinal: Int

        public var id: String { smcKey.isEmpty ? "\(name)#\(ordinal)" : smcKey }

        /// A calibration reference, not a temperature. `PMU tcal` reads exactly
        /// 51.8 °C on this Mac at idle and under full load alike — charting it
        /// implies a measurement, and feeding it to a fan curve pins the input
        /// to a constant that happens to sit above the real idle readings.
        ///
        /// Name-based, and deliberately still name-based after the SMC source was
        /// added. The SMC surfaces what is almost certainly this same reference
        /// as the bare key `TR0Z` — measured at 51.82 °C through a 32 °C swing —
        /// with no name to match on, and there is no way to recognise it from its
        /// readings: across 200 samples spanning that swing, 34 keys held a span
        /// of exactly 0.00 °C, and nine of them were the battery sensors, which
        /// are real and merely thermally decoupled from the SoC. Flatness finds
        /// decoupled sensors, not references.
        ///
        /// So keyed sensors are kept out of the fan curve by
        /// `TemperatureSources.curveInput`, on evidence of what they measure,
        /// rather than by guessing which of them are references.
        public var isReference: Bool { SensorNaming.isCalibrationReference(name) }

        /// What a person should read. `name` stays the raw hardware shorthand;
        /// this is the plain-English rendering of it.
        public var friendlyName: String { SensorNaming.friendlyName(for: name) }

        /// Friendly name plus a disambiguating index, but only where one is
        /// needed — the six battery sensors, not the de-duplicated die zones.
        public func displayName(isAmbiguous: Bool) -> String {
            isAmbiguous ? "\(friendlyName) \(ordinal + 1)" : friendlyName
        }

        public init(name: String, celsius: Double, ordinal: Int = 0, smcKey: String = "") {
            self.name = name
            self.celsius = celsius
            self.ordinal = ordinal
            self.smcKey = smcKey
        }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (AnyObject?, Int32) -> Double

    private let create: CreateFn?
    private let setMatching: SetMatchingFn?
    private let copyServices: CopyServicesFn?
    private let copyEvent: CopyEventFn?
    private let copyProperty: CopyPropertyFn?
    private let getFloat: GetFloatFn?

    private var client: AnyObject?
    private let lock = NSLock()

    private static let eventTypeTemperature: Int64 = 15
    private static let appleVendorPage = 0xff00
    private static let temperatureSensorUsage = 0x0005

    public private(set) var isAvailable = false

    public init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }
        create = sym("IOHIDEventSystemClientCreate", CreateFn.self)
        setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)

        isAvailable = create != nil && copyServices != nil
                   && copyEvent != nil && getFloat != nil
        if isAvailable { start() }
    }

    private func start() {
        guard let create, let setMatching else { isAvailable = false; return }
        guard let created = create(kCFAllocatorDefault) else { isAvailable = false; return }
        let c = created.takeRetainedValue()
        let matching: [String: Int] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureSensorUsage,
        ]
        _ = setMatching(c, matching as CFDictionary)
        client = c
    }

    /// Snapshot every temperature sensor. Returns an empty array rather than
    /// throwing when the private API is unavailable.
    public func readAll() -> [Reading] {
        lock.lock()
        defer { lock.unlock() }

        guard isAvailable,
              let client,
              let copyServices, let copyEvent, let getFloat,
              let servicesRef = copyServices(client) else { return [] }

        let services = servicesRef.takeRetainedValue() as [AnyObject]
        var results: [Reading] = []

        for service in services {
            var name = "sensor"
            var smcKey = ""
            if let copyProperty {
                if let prop = copyProperty(service, "Product" as CFString),
                   let str = prop.takeRetainedValue() as? String {
                    name = str
                }
                if let prop = copyProperty(service, "LocationID" as CFString),
                   let number = prop.takeRetainedValue() as? NSNumber {
                    smcKey = Self.fourCC(number.uint32Value)
                }
            }
            guard let eventRef = copyEvent(service, Self.eventTypeTemperature, 0, 0) else {
                continue
            }
            let event = eventRef.takeRetainedValue()
            let field = Int32(Self.eventTypeTemperature << 16)
            let value = getFloat(event, field)
            // The same window the SMC source and the history detectors apply.
            // `FanKit.PlausibleTemperature` is the one definition of it — see
            // there for why it is not local to either sensor source.
            guard PlausibleTemperature.admits(value) else { continue }
            results.append(Reading(name: name, celsius: value, ordinal: 0, smcKey: smcKey))
        }

        return Self.consolidate(results)
    }

    /// Collapse the hub's duplicate enumerations, then number what remains.
    ///
    /// This Mac's 52 entries are 22 physical sensors: the hub lists every die
    /// sensor three times under one SMC key. Averaging the copies rather than
    /// picking one keeps the sampling jitter between them (up to ~0.7 °C, since
    /// they are read at slightly different instants) out of the chart.
    ///
    /// Entries with no SMC key can't be proven duplicate, so they are kept
    /// separate and fall back to name-and-ordinal identity.
    static func consolidate(_ raw: [Reading]) -> [Reading] {
        // A key that turns up under two different names is not the identity we
        // thought it was. Merging on it would silently swallow a sensor and
        // would hand two rows the same `id`, so those keys are distrusted and
        // their readings fall back to name-and-ordinal — noisier, never lossy.
        var namesPerKey: [String: Set<String>] = [:]
        for reading in raw where !reading.smcKey.isEmpty {
            namesPerKey[reading.smcKey, default: []].insert(reading.name)
        }
        let conflicted = Set(namesPerKey.lazy.filter { $0.value.count > 1 }.map(\.key))

        var order: [String] = []
        var groups: [String: (name: String, smcKey: String, values: [Double])] = [:]

        for (index, reading) in raw.enumerated() {
            let trusted = !reading.smcKey.isEmpty && !conflicted.contains(reading.smcKey)
            // Un-keyed and distrusted sensors get a per-entry bucket so they
            // never merge with anything.
            let bucket = trusted ? reading.smcKey : "\(reading.name)##\(index)"
            if groups[bucket] == nil {
                order.append(bucket)
                groups[bucket] = (reading.name, trusted ? reading.smcKey : "", [])
            }
            groups[bucket]?.values.append(reading.celsius)
        }

        // Sort by name, then by key, so the ordinal a sensor gets depends only
        // on the hardware and not on the order the services came back in.
        // Digit runs compare numerically, or "tdie10" would sort above "tdie2".
        let sorted = order.compactMap { groups[$0] }
            .sorted { (Self.naturalKey($0.name), $0.smcKey)
                    < (Self.naturalKey($1.name), $1.smcKey) }

        var seen: [String: Int] = [:]
        return sorted.map { group in
            let ordinal = seen[group.name, default: 0]
            seen[group.name] = ordinal + 1
            let mean = group.values.reduce(0, +) / Double(group.values.count)
            return Reading(name: group.name, celsius: mean,
                           ordinal: ordinal, smcKey: group.smcKey)
        }
    }

    /// Zero-pads every digit run so a plain string comparison orders names the
    /// way a reader expects: `tdie2` before `tdie10`, not after it.
    ///
    /// The pad width covers any number a sensor name could plausibly carry;
    /// past it, ordering degrades to lexicographic rather than breaking.
    private static let digitPadWidth = 18

    static func naturalKey(_ name: String) -> String {
        var out = ""
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            out += String(repeating: "0", count: max(0, digitPadWidth - digits.count)) + digits
            digits = ""
        }
        for character in name {
            if character.isNumber { digits.append(character) } else { flush(); out.append(character) }
        }
        flush()
        return out
    }

    /// `LocationID` holds a packed SMC key: 0x54503162 spells "TP1b".
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        // Anything that isn't printable ASCII isn't a key we can trust as an
        // identity, so it degrades to "no key" rather than to mojibake.
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Highest real temperature across all sensors — the input to every fan curve.
    ///
    /// Calibration references are excluded. `PMU tcal` reads a constant 51.8 °C
    /// on this Mac, which is *above* every real sensor at idle, so including it
    /// pinned the curve input to a number that never moved.
    public func maxTemperature() -> Double? {
        readAll().lazy.filter { !$0.isReference }.map(\.celsius).max()
    }

    /// Raw names shared by more than one physical sensor, so callers know which
    /// readings need `displayName(isAmbiguous: true)`. Lives here rather than in
    /// each view because two views showing the same sensor under two different
    /// labels is worse than either label alone.
    public static func ambiguousNames(in readings: [Reading]) -> Set<String> {
        var counts: [String: Int] = [:]
        for reading in readings { counts[reading.name, default: 0] += 1 }
        return Set(counts.lazy.filter { $0.value > 1 }.map(\.key))
    }
}
#endif
