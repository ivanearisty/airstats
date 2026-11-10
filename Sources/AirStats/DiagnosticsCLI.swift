import Foundation
import AirStatKit
import AirStatUI

/// Command-line entry points used for verification and debugging.
///
/// `AirStats --probe` samples the collectors and prints what they produced, so any
/// metric can be checked against `top`, `vm_stat`, `netstat -ib`, `ioreg`, `pmset`
/// and `system_profiler` without launching the UI.
enum DiagnosticsCLI {

    /// Returns true when the process handled a command-line request and should exit.
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return false }

        switch command {
        case "--probe":
            runProbe(Array(arguments.dropFirst()))
            return true
        case "--render":
            RenderCLI.run(Array(arguments.dropFirst()))
            return true
        case "--help", "-h":
            print(usage)
            return true
        default:
            return false
        }
    }

    private static let usage = """
    AirStats — macOS system statistics

      AirStats                                launch the menu bar app
      AirStats --probe [collectors…] [flags]  sample collectors and print results
      AirStats --render [surfaces…] [flags]   render UI surfaces to PNG (no screen needed)

    Probe collectors:
      \(CollectorID.allCases.map(\.rawValue).joined(separator: ", "))
      (omit to probe everything)

    Probe flags:
      --repeat N      number of samples (default 2; rate metrics need at least 2)
      --interval S    seconds between samples (default 1)
      --verbose       print every sample, not just the last
      --connectivity A   run the internet check against A (an IPv4 address or an
                         https:// address); off unless given, so the probe contacts nothing

    Render surfaces:  menuBar, panel, desktopWidget, settings   (omit for all)
    Render flags:
      --out DIR       output directory (default ./render)
      --scenario S    \(OffscreenScenarioNames.list)  (omit for all)
      --light / --dark   appearance (omit for both)
      --scale N       backing scale, repeatable (omit for 1 and 2)
      --tint C        metric colour as #RRGGBB or r,g,b; the panel stays monochrome
      --readouts L    menu bar readouts as metric[:style],… e.g. connectivity,networkThroughput:statusDot
      --without-color draw as macOS does with Differentiate Without Color turned on

    Examples:
      AirStats --probe cpu --repeat 5 --interval 1 --verbose
      AirStats --probe network disk
      AirStats --probe network --repeat 5 --connectivity 1.1.1.1
      AirStats --render panel --scenario nominal --dark --scale 2 --out /tmp/shots
      AirStats --render menuBar --scenario offline --readouts connectivity,connectivity:text
    """

    private static func runProbe(_ arguments: [String]) {
        var collectors = Set<CollectorID>()
        var repeatCount = 2
        var interval: TimeInterval = 1
        var verbose = false
        var connectivity: ConnectivityTarget?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--repeat":
                index += 1
                repeatCount = Int(arguments[safe: index] ?? "") ?? repeatCount
            case "--interval":
                index += 1
                interval = Double(arguments[safe: index] ?? "") ?? interval
            case "--verbose":
                verbose = true
            case "--connectivity":
                index += 1
                switch ConnectivityTarget.parse(arguments[safe: index] ?? "") {
                case .success(let target):
                    connectivity = target
                case .failure(let error):
                    FileHandle.standardError.write(Data("--connectivity: \(error.message)\n".utf8))
                    exit(2)
                }
            default:
                if let id = CollectorID(rawValue: argument) {
                    collectors.insert(id)
                } else {
                    FileHandle.standardError.write(
                        Data("unknown collector '\(argument)'. Known: \(CollectorID.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                    exit(2)
                }
            }
            index += 1
        }

        // The check rides the network sample and answers on the one after it sends, so
        // asking for it brings the network collector and a second sample with it.
        if connectivity != nil {
            if !collectors.isEmpty { collectors.insert(.network) }
            repeatCount = max(repeatCount, 2)
        }
        let options = MetricProbe.Options(
            collectors: collectors.isEmpty ? Set(CollectorID.allCases) : collectors,
            repeatCount: repeatCount,
            interval: interval,
            verbose: verbose,
            connectivity: connectivity
        )
        print(MetricProbe.run(options))
    }
}

/// The scenario names for the usage text, read off the renderer so the help can never
/// list one that does not exist, or miss one that does.
enum OffscreenScenarioNames {
    static var list: String {
        OffscreenRenderer.Scenario.allCases.map(\.rawValue).joined(separator: " | ")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
