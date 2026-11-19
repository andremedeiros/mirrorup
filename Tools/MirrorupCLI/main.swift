import Foundation
import MirrorupDevices
import MirrorupCapture
import MirrorupDiagnostics
import MirrorupPTP
import MirrorupUSB

let usage = """
    usage: mirrorup <command> [options]

    commands:
      devices                         list attached cameras and which driver supports each
      inspect                         USB descriptors, endpoints, interface ownership, claim test
      camera info [--json F]          everything the camera reports, decoded: identity, lens,
                                      exposure, image, power, capabilities (--json writes all of it,
                                      including codes no public source documents)
      ptp info                        open a PTP session and print parsed GetDeviceInfo
      ptp operations                  list operations, events, properties and formats by name
      ptp dump --body NAME --output-dir D [--keep-serial]
                                      start live view once and save the raw data phases the
                                      driver's tests use as fixtures (deviceinfo-NAME.bin, plus
                                      the driver's own, e.g. getevent-initial-NAME.bin and
                                      evf-NAME.bin); the serial number is zeroed unless
                                      --keep-serial
      liveview snapshot --output F    save one live-view JPEG frame to F and its metadata to F.json
      liveview benchmark [--duration S] [--no-decode] [--enhance] [--json F]
                                      stream live view for S seconds (default 60) and report
                                      measured throughput and timing distributions; --enhance
                                      adds the super-resolution scaler to the decode stage

    options:
      --transport imagecapture|usb    PTP transport (default imagecapture; usb needs the PTP
                                      interface to be unclaimed, see docs/usb-feasibility.md)
    """

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if ["no-decode", "enhance", "keep-serial", "help"].contains(name) {
                    flags.insert(name)
                } else {
                    guard i + 1 < args.count else { throw CLIError("missing value for \(a)") }
                    options[name] = args[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func transport() throws -> CameraTransport {
        guard let raw = options["transport"] else { return .imageCapture }
        guard let t = CameraTransport(rawValue: raw == "imagecapture" ? "imageCapture" : raw) else {
            throw CLIError("unknown transport '\(raw)' (expected imagecapture or usb)")
        }
        return t
    }
}

enum MirrorupCLI {
    static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if args.flags.contains("help") || args.positional.isEmpty {
                print(usage)
                exit(args.positional.isEmpty && !args.flags.contains("help") ? 64 : 0)
            }
            switch (args.positional.first, args.positional.dropFirst().first) {
            case ("devices", _): await Commands.devices()
            case ("inspect", _): Commands.inspect()
            case ("camera", "info"): try await Commands.cameraInfo(jsonPath: args.options["json"], transport: args.transport())
            case ("ptp", "info"): try await Commands.ptpInfo(transport: args.transport())
            case ("ptp", "operations"): try await Commands.ptpOperations(transport: args.transport())
            case ("ptp", "dump"):
                guard let body = args.options["body"], let dir = args.options["output-dir"] else {
                    throw CLIError("dump needs --body <name> and --output-dir <dir>")
                }
                try await Commands.ptpDump(body: body, outputDir: dir, keepSerial: args.flags.contains("keep-serial"),
                                           transport: args.transport())
            case ("liveview", "snapshot"):
                guard let output = args.options["output"] else { throw CLIError("snapshot needs --output <file.jpg>") }
                try await Commands.snapshot(output: output, transport: args.transport())
            case ("liveview", "benchmark"):
                let duration = Double(args.options["duration"] ?? "60") ?? 60
                try await Benchmark.run(
                    duration: .milliseconds(Int(duration * 1000)), decode: !args.flags.contains("no-decode"),
                    enhance: args.flags.contains("enhance"), jsonPath: args.options["json"], transport: args.transport())
            default:
                throw CLIError("unknown command '\(args.positional.joined(separator: " "))'\n\n\(usage)")
            }
            exit(0)
        } catch let error as CameraError {
            FileHandle.standardError.write(Data("error: \(error.message)\n  detail: \(error.detail ?? "none")\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}

await MirrorupCLI.main()
