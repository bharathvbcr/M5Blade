import Foundation
import SensorKit
import HistoryKit

/// Every series this app records, named in exactly one place.
///
/// The live window and the database share a key space, and the charts look
/// series up by key. If the writer and a reader spelled a key independently,
/// they would agree right up until someone changed one of them — and the
/// failure would be an empty plot, not a build error.
enum HistorySensors {

    /// Display groups a chart can aggregate by. Temperature groups come from
    /// `SensorCategory`; these are the ones that don't.
    static let fan = "Fan"
    static let fanRPM = "Fan rpm"
    static let load = "Load"

    /// Recorded for export and for episode records, but never charted: rpm
    /// shares no axis with temperature or percent, and duty is what people
    /// actually read off a fan.
    static let ungroupedInCharts: Set<String> = [fanRPM]

    static func temperature(_ reading: TemperatureSensors.Reading,
                            isAmbiguous: Bool) -> SensorDescriptor {
        SensorDescriptor(key: temperatureKey(reading),
                         name: reading.displayName(isAmbiguous: isAmbiguous),
                         kind: .temperature,
                         group: SensorCategory.classify(reading.name).rawValue)
    }

    /// `Reading.id` is the sensor's SMC key ("TP1b") where the HID hub exposes
    /// one, falling back to "name#ordinal" where it doesn't. Keys recorded
    /// before that change used the fallback form for every sensor, so those
    /// series stop receiving samples and age out under the normal retention
    /// window rather than merging into the new ones.
    static func temperatureKey(_ reading: TemperatureSensors.Reading) -> String {
        "temp:\(reading.id)"
    }

    static func fanRPM(_ index: Int) -> SensorDescriptor {
        SensorDescriptor(key: "fan:\(index):rpm", name: fanName(index),
                         kind: .rpm, group: fanRPM)
    }

    static func fanDuty(_ index: Int) -> SensorDescriptor {
        SensorDescriptor(key: "fan:\(index):duty", name: fanName(index),
                         kind: .percent, group: fan)
    }

    static let cpuLoad = SensorDescriptor(key: "system:cpu", name: "CPU load",
                                          kind: .percent, group: load)

    /// Fans are numbered from 1 for a reader, everywhere.
    private static func fanName(_ index: Int) -> String { "Fan \(index + 1)" }
}
