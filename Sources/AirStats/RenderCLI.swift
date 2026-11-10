import AppKit
import AirStatKit
import AirStatUI

/// `AirStats --render` writes PNGs of every surface without needing a screen or a
/// Screen Recording grant, using deterministic fixture data.
enum RenderCLI {

    static func run(_ arguments: [String]) {
        var surfaces: [OffscreenRenderer.Surface] = []
        var scenarios: [OffscreenRenderer.Scenario] = []
        var scales: [CGFloat] = []
        var appearances: [Bool] = []
        var outputDirectory = URL(fileURLWithPath: "render", isDirectory: true)
        var collectedMinutes: Int?
        var withoutHistory = false
        var differentiatesWithoutColor = false
        var settings = AirStatKit.Settings()

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                index += 1
                guard let path = arguments[safe: index], !path.isEmpty else {
                    FileHandle.standardError.write(Data("--out wants a directory\n".utf8))
                    exit(2)
                }
                outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            case "--scale":
                index += 1
                // Bounded, not just parsed. `Double("1e400")` is `+infinity`, and the
                // pixel count it produces is an `Int(_:)` conversion that traps rather
                // than saturating — a typo in a flag should not be a crash.
                guard let value = Double(arguments[safe: index] ?? ""),
                      value.isFinite, value > 0, value <= 8 else {
                    FileHandle.standardError.write(Data("--scale wants a number in 0...8\n".utf8))
                    exit(2)
                }
                scales.append(CGFloat(value))
            case "--light": appearances.append(false)
            case "--dark": appearances.append(true)
            // The colour a user picks is already carried on Request.settings and read
            // by MenuBarRenderModel and the desktop widget; only a way to say so was missing.
            // The panel ignores it on purpose, it is monochrome by design.
            case "--tint":
                index += 1
                guard let color = themeColor(from: arguments[safe: index] ?? "") else {
                    FileHandle.standardError.write(Data("--tint wants #RRGGBB or r,g,b in 0...1\n".utf8))
                    exit(2)
                }
                settings.theme.setAllColors(color)
            // The desktop widget's shape is decided by two settings a reviewer cannot reach
            // from the command line otherwise, and its worst case (nine modules,
            // expanded) is exactly the one worth looking at.
            case "--expanded":
                settings.desktopWidget.isCompact = false
            // Off by default, and the day silhouette is the tallest thing a widget
            // module can grow.
            case "--history":
                settings.desktopWidget.showsHistoryChart = true
            // A day still being collected is the state every launch starts in.
            case "--collected":
                index += 1
                guard let minutes = Int(arguments[safe: index] ?? ""), minutes >= 0 else {
                    FileHandle.standardError.write(Data("--collected wants a number of minutes\n".utf8))
                    exit(2)
                }
                collectedMinutes = minutes
            // Every chart's first state, and the one a reviewer never sees by accident
            // because the fixtures come with a day of history.
            case "--no-history":
                withoutHistory = true
            // The system setting changes the menu bar's shapes, and a render process cannot
            // read it from System Settings, so it is asked for here.
            case "--without-color":
                differentiatesWithoutColor = true
            case "--modules":
                index += 1
                let names = (arguments[safe: index] ?? "").split(separator: ",")
                let parsed = names.compactMap { PanelModule(rawValue: String($0)) }
                guard parsed.count == names.count, !parsed.isEmpty else {
                    FileHandle.standardError.write(Data("--modules wants a comma-separated list of module names\n".utf8))
                    exit(2)
                }
                var seen: Set<PanelModule> = []
                settings.desktopWidget.modules = parsed.filter { seen.insert($0).inserted }
            // Every panel module starts collapsed, so a change to a module's detail
            // cannot be reviewed without a way to open it.
            case "--open":
                index += 1
                let names = (arguments[safe: index] ?? "").split(separator: ",")
                let parsed = names.compactMap { PanelModule(rawValue: String($0)) }
                guard parsed.count == names.count, !parsed.isEmpty else {
                    FileHandle.standardError.write(Data("--open wants a comma-separated list of module names\n".utf8))
                    exit(2)
                }
                settings.panel.collapsedModules.subtract(parsed)
            // The menu bar renders the shipped readouts unless told otherwise, and a
            // readout nobody ships by default could not be reviewed at all without this.
            // Each entry is a metric, optionally with a style: `connectivity:text`.
            case "--readouts":
                index += 1
                guard let items = readouts(from: arguments[safe: index] ?? "") else {
                    FileHandle.standardError.write(Data(
                        "--readouts wants metric[:style],… with styles the metric supports\n".utf8))
                    exit(2)
                }
                settings.menuBar.items = items
                // Asking for the internet readout is asking to see it working: with the
                // check off it would render as the dash, whatever the scenario says.
                if items.contains(where: { $0.metric == .connectivity }) {
                    settings.general.checksConnectivity = true
                }
            case "--scenario":
                index += 1
                guard let scenario = OffscreenRenderer.Scenario(rawValue: arguments[safe: index] ?? "") else {
                    let known = OffscreenRenderer.Scenario.allCases.map(\.rawValue).joined(separator: ", ")
                    FileHandle.standardError.write(Data("--scenario wants one of: \(known)\n".utf8))
                    exit(2)
                }
                scenarios.append(scenario)
            default:
                if let surface = OffscreenRenderer.Surface(rawValue: arguments[index]) {
                    surfaces.append(surface)
                } else {
                    FileHandle.standardError.write(Data("unknown argument '\(arguments[index])'\n".utf8))
                    exit(2)
                }
            }
            index += 1
        }

        // Default to the full matrix: every surface, every state, both appearances,
        // both backing scales. That is what a visual reviewer needs to see at once.
        if surfaces.isEmpty { surfaces = OffscreenRenderer.Surface.allCases }
        if scenarios.isEmpty { scenarios = OffscreenRenderer.Scenario.allCases }
        if appearances.isEmpty { appearances = [false, true] }
        if scales.isEmpty { scales = [1, 2] }

        // Rendering AppKit and SwiftUI views needs a running NSApplication even
        // though nothing is ever shown, so the app is brought up as an accessory
        // and torn down as soon as the images are written.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        MainActor.assumeIsolated {
            var written = 0
            var failures: [String] = []
            for surface in surfaces {
                for scenario in scenarios {
                    for isDark in appearances {
                        for scale in scales {
                            let request = OffscreenRenderer.Request(
                                surface: surface, scenario: scenario,
                                isDark: isDark, scale: scale, settings: settings,
                                collectedMinutes: collectedMinutes, withoutHistory: withoutHistory,
                                differentiatesWithoutColor: differentiatesWithoutColor)
                            do {
                                let url = try OffscreenRenderer.render(request, to: outputDirectory)
                                print(url.path)
                                written += 1
                            } catch {
                                failures.append("\(request.fileName): \(error)")
                            }
                        }
                    }
                }
            }
            print("\nwrote \(written) image(s) to \(outputDirectory.path)")
            for failure in failures {
                FileHandle.standardError.write(Data("FAILED \(failure)\n".utf8))
            }
            if !failures.isEmpty { exit(1) }
        }
    }
}

/// `cpuUsage,connectivity:text` into menu bar items, or nil when any entry names a
/// metric that does not exist or a style that metric cannot draw. Refused rather than
/// sanitised: a render of a different style than the one asked for would be reviewed as
/// if it were the one asked for.
private func readouts(from text: String) -> [MenuBarItemConfig]? {
    let entries = text.split(separator: ",")
    guard !entries.isEmpty else { return nil }
    var items: [MenuBarItemConfig] = []
    for entry in entries {
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let metric = MenuBarMetric(rawValue: String(parts[0])) else { return nil }
        let style: MenuBarDisplayStyle
        if parts.count == 2 {
            guard let named = MenuBarDisplayStyle(rawValue: String(parts[1])),
                  metric.supportedStyles.contains(named) else { return nil }
            style = named
        } else {
            style = metric.supportedStyles.first ?? .text
        }
        items.append(MenuBarItemConfig(metric: metric, style: style, showsCaption: style.supportsCaption))
    }
    return items
}

/// Accepts `#4C8DFF`, `4C8DFF` or `0.3,0.55,1`, so a colour can be pasted from either
/// a design tool or the settings file without conversion.
private func themeColor(from text: String) -> ThemeColor? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)

    if trimmed.contains(",") {
        let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return ThemeColor(red: parts[0], green: parts[1], blue: parts[2])
    }

    return ThemeColor(hex: trimmed)
}
