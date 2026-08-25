import Foundation
import SMCKit

/// Reads and writes the firmware charge limit through the SMC.
///
/// Reads are unprivileged. Writes require root, which is why this type lives
/// on the daemon side of the XPC boundary; the app reaches it only through
/// `DaemonProtocol`. Every write is followed by a read-back, because "the SMC
/// accepted the command" and "the firmware changed its behaviour" are
/// different facts — on macOS ≥ 15 the kernel can refuse the write to a
/// process without Apple's own entitlement, and only the read-back knows.
public actor ChargeLimitController {

    /// Why a write did not take. Carries its own text because every reason
    /// here is one a person may need to act on.
    public struct WriteError: Error, Sendable, Equatable {
        public let message: String
    }

    private let connection: SMCConnection

    public init(connection: SMCConnection = SMCConnection()) {
        self.connection = connection
    }

    /// Probes for both keys and reads whichever answers.
    public func status() async -> (state: ChargeLimitState, support: ChargeLimitSupport) {
        do {
            try await connection.open()
        } catch {
            return (.unsupported, ChargeLimitSupport())
        }

        let chwaKey = SMCKey("CHWA")
        let bclmKey = SMCKey("BCLM")
        let hasCHWA = await connection.exists(chwaKey)
        let hasBCLM = await connection.exists(bclmKey)
        let support = ChargeLimitSupport(hasAppleSiliconKey: hasCHWA,
                                         hasIntelKey: hasBCLM)

        if hasCHWA {
            if let byte = try? await connection.readUInt8(chwaKey) {
                return (ChargeLimit.state(fromAppleSiliconByte: byte), support)
            }
            return (.unknown(raw: 0), support)
        }
        if hasBCLM {
            if let byte = try? await connection.readUInt8(bclmKey) {
                return (ChargeLimit.state(fromIntelByte: byte), support)
            }
            return (.unknown(raw: 0), support)
        }
        return (.unsupported, support)
    }

    /// Just the capability probe, for callers that only need to know whether
    /// a request can possibly apply here.
    public func support() async -> ChargeLimitSupport {
        await status().support
    }

    /// Writes one percent and verifies by reading back.
    ///
    /// - Returns: `.success` only when the read-back shows the requested
    ///   state. Anything else carries the reason the write did not take —
    ///   including "refused by macOS", which is the expected outcome for a
    ///   non-entitled process on modern releases.
    public func set(percent: Int) async -> Result<Void, WriteError> {
        do {
            try await connection.open()
        } catch {
            return .failure(WriteError(message:
                "the SMC could not be opened: \(error.localizedDescription)"))
        }

        let appleSiliconKey = await connection.exists(SMCKey("CHWA"))
        guard let byte = ChargeLimit.byte(forPercent: percent,
                                          appleSiliconKey: appleSiliconKey) else {
            return .failure(WriteError(message: "only 80 or 100 may be written"))
        }
        let key = appleSiliconKey ? SMCKey("CHWA") : SMCKey("BCLM")

        do {
            try await connection.writeUInt8(key, byte)
        } catch {
            let why = error.localizedDescription
            if why.contains("not writable") || why.contains("0x84") {
                return .failure(WriteError(message:
                    "this firmware refuses charge-limit writes "
                    + "(macOS restricts them to Apple's own components)"))
            }
            return .failure(WriteError(message: "the write was refused: \(why)"))
        }

        // The verification read. A silent no-op write was the classic failure
        // of every tool in this category; this is what turns it into an
        // honest report instead.
        let after: ChargeLimitState?
        if let raw = try? await connection.readUInt8(key) {
            after = appleSiliconKey ? ChargeLimit.state(fromAppleSiliconByte: raw)
                                    : ChargeLimit.state(fromIntelByte: raw)
        } else {
            after = nil
        }
        if after?.percent == percent {
            return .success(())
        }
        let reported = after.flatMap(\.percent).map { "\($0)" } ?? "nothing readable"
        return .failure(WriteError(message:
            "the firmware still reports \(reported) after writing \(percent)"))
    }
}
