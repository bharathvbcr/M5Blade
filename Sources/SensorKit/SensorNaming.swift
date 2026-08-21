import Foundation

/// Plain-English labels for the sensors Apple's HID hub reports.
///
/// The hub hands back internal hardware shorthand. This Mac's 52 sensors carry
/// 16 distinct names, and every one of them is jargon: `PMU tdie1`, `PMU tcal`,
/// `NAND CH0 temp`, `gas gauge battery`. Accurate, and unreadable.
///
/// The mapping never adds detail Apple didn't give us. A die sensor becomes
/// "Chip zone 3", not "GPU core 3", because nothing in the sensor says which
/// block of the die it sits on — the same reason `SensorCategory` leaves those
/// sensors in `soc`. A name with no rule keeps its own text rather than being
/// guessed at.
///
/// This is display only. `TemperatureSensors.Reading.name` stays the raw name
/// and remains the sensor's identity, so relabelling can never break history
/// keys or chart series.
public enum SensorNaming {

    /// - Parameter rawName: the name exactly as the HID hub reported it.
    /// - Returns: wording for a person, never an empty string.
    public static func friendlyName(for rawName: String) -> String {
        // A raw SMC key stays exactly as it is. There is no plain-English
        // rendering of `Tp04` that is also true — the key says which family the
        // sensor belongs to and nothing more, and the group heading already says
        // that. Running the rules over it would be worse than useless: they match
        // case-insensitively on substrings, so a four-character key can collide
        // with a needle by coincidence and come back confidently mislabelled.
        //
        // The calibration rule is the one exception, and it has to be: "Tcal" is
        // four characters beginning with T, so it fits the key shape exactly
        // while also being a spelling of the reference. `isCalibrationReference`
        // claims that name, and if the label did not agree, a sensor would be cut
        // from the fan curve while still being labelled a measurement. No key on
        // this Mac collides — this keeps the two in step if one ever does.
        if SMCKeyName(rawName) != nil, !isCalibrationReference(rawName) { return rawName }

        let lowered = rawName.lowercased()
        let index = firstNumber(in: rawName)
        for rule in rules where lowered.contains(rule.needle) {
            return rule.label(index)
        }
        return tidied(rawName)
    }

    /// Whether a sensor is a fixed calibration reference rather than a live
    /// temperature. Measured, not assumed: `PMU tcal` reported exactly 51.8 °C
    /// at idle and under sustained all-core load, while every real die sensor
    /// moved by 14–24 °C between those two states.
    public static func isCalibrationReference(_ rawName: String) -> Bool {
        rawName.lowercased().contains("tcal")
    }

    /// A rule matches a lowercased raw name and builds a label from the first
    /// number in that name, so `PMU tdie2` and `PMU tdie10` stay distinct.
    private typealias Rule = (needle: String, label: (Int?) -> String)

    /// First match wins, so the specific sits above the general: `tdie` before
    /// `pmu` (otherwise all 42 die sensors read as "Power controller"), `ecpu`
    /// before `cpu`, `gas gauge battery` before `battery`.
    private static let rules: [Rule] = [
        // Battery and charging
        // Six distinct sensors share this one name on this Mac, so the label has
        // to be something six of can truthfully sit beside each other: there is
        // one battery, measured in six places.
        ("gas gauge battery", { _ in "Battery sensor" }),
        ("gas gauge",         { _ in "Battery gauge" }),
        ("battery",           { numbered("Battery", $0) }),
        ("charger",           { _ in "Charger" }),

        // Storage
        ("nand",  { $0.map { "SSD flash channel \($0)" } ?? "SSD flash" }),
        ("flash", { $0.map { "SSD flash channel \($0)" } ?? "SSD flash" }),
        ("nvme",  { _ in "SSD controller" }),
        ("ssd",   { _ in "SSD" }),

        // On-die sensors. Apple reports these without saying which block of the
        // die each one covers, so the label stays deliberately vague.
        ("tcal", { _ in "Chip calibration reference" }),
        ("tdie", { $0.map { "Chip zone \($0)" } ?? "Chip die" }),

        // Processor. pACC / eACC are the performance and efficiency core
        // clusters on Apple Silicon.
        ("ecpu",        { $0.map { "Efficiency core \($0)" } ?? "Efficiency cores" }),
        ("pcpu",        { $0.map { "Performance core \($0)" } ?? "Performance cores" }),
        ("eacc",        { numbered("Efficiency core cluster", $0) }),
        ("pacc",        { numbered("Performance core cluster", $0) }),
        ("efficiency",  { numbered("Efficiency cores", $0) }),
        ("performance", { numbered("Performance cores", $0) }),
        ("cpu",         { $0.map { "Processor core \($0)" } ?? "Processor" }),
        ("core",        { numbered("Processor core", $0) }),

        // Graphics and Neural Engine
        ("neural", { _ in "Neural Engine" }),
        ("ane",    { _ in "Neural Engine" }),
        ("gpu",    { $0.map { "Graphics zone \($0)" } ?? "Graphics" }),
        ("agx",    { $0.map { "Graphics zone \($0)" } ?? "Graphics" }),

        // Memory
        ("lpddr",  { numbered("Memory", $0) }),
        ("dram",   { numbered("Memory", $0) }),
        ("memory", { numbered("Memory", $0) }),

        // Display
        ("backlight", { _ in "Display backlight" }),
        ("display",   { numbered("Display", $0) }),
        ("lcd",       { numbered("Display", $0) }),

        // Enclosure and surroundings
        ("ambient",   { _ in "Ambient air" }),
        ("tamb",      { _ in "Ambient air" }),
        ("palm",      { _ in "Palm rest" }),
        ("enclosure", { _ in "Enclosure" }),

        // Power delivery. `pmu` is last of these so it only catches sensors
        // that are genuinely about the controller itself.
        ("pmic", { _ in "Power regulator" }),
        ("vrm",  { _ in "Power regulator" }),
        ("watt", { _ in "Power draw" }),
        ("soc",  { _ in "Main chip" }),
        ("pmu",  { _ in "Power controller" }),
    ]

    /// Words that carry no meaning once the reading is already labelled "°C".
    private static let filler: Set<String> = [
        "temp", "temps", "temperature", "sensor", "sensors", "mtr",
    ]

    /// Fallback for names with no rule: drop the filler words, keep the rest
    /// verbatim. An unrecognised name is left recognisable rather than renamed
    /// into something we can't stand behind.
    private static func tidied(_ rawName: String) -> String {
        let kept = rawName.split(separator: " ").filter { !filler.contains($0.lowercased()) }
        guard !kept.isEmpty else { return "Unnamed sensor" }
        return kept.joined(separator: " ")
    }

    private static func numbered(_ base: String, _ index: Int?) -> String {
        index.map { "\(base) \($0)" } ?? base
    }

    /// First run of digits anywhere in the name — `NAND CH0 temp` numbers in the
    /// middle, `PMU tdie10` at the end, and both must come back as one integer.
    private static func firstNumber(in name: String) -> Int? {
        var digits = ""
        for character in name {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}
