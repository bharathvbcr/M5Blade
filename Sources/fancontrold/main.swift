import Foundation
import FanKit
import DaemonCore
import DaemonProtocol

func writeStderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

// Root-only. Refuse to run otherwise rather than fail confusingly later.
guard getuid() == 0 else {
    writeStderr("fancontrold must run as root\n")
    exit(1)
}

/// Written by install-helper.sh from the installed app's actual cdhash.
/// No requirement means no connections are accepted at all (AUDIT A-2).
let clientRequirement: String? = {
    let path = HelperInstallation.clientRequirementPath
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}()

if clientRequirement == nil {
    NSLog("[fancontrold] no client requirement file — all connections will be refused")
}

let service = DaemonService(backend: SMCFanBackend())
Task { await service.start() }

let delegate = DaemonListenerDelegate(service: service, requirement: clientRequirement)
let listener = NSXPCListener(machServiceName: fanControlMachServiceName)
listener.delegate = delegate
listener.resume()

NSLog("[fancontrold] listening on %@", fanControlMachServiceName)
RunLoop.main.run()
