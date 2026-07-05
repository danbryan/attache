import AttacheCore
import Foundation

/// A user-defined theme: the same surface the built-ins expose, as data.
/// Specs are stored one JSON file per theme under Application Support and
/// are the interchange format for import, export, and the theme registry.
struct CompanionThemeSpec: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var stops: [CompanionThemeStop]
    var accentDark: CompanionThemeStop
    var accentLight: CompanionThemeStop
    var wantsSolidPlates: Bool

    init(id: String = UUID().uuidString,
         name: String,
         stops: [CompanionThemeStop],
         accentDark: CompanionThemeStop,
         accentLight: CompanionThemeStop,
         wantsSolidPlates: Bool = false) {
        self.id = id
        self.name = name
        self.stops = stops
        self.accentDark = accentDark
        self.accentLight = accentLight
        self.wantsSolidPlates = wantsSolidPlates
    }

    /// Returns a copy whose accents hold the INF-150 contrast floor: the dark
    /// accent renders on a black plate and the light accent on a white plate,
    /// both at 4.5:1 minimum. Any color a user picks is nudged toward the
    /// plate's opposite until it passes, so a custom theme can never make
    /// selection chrome unreadable.
    func enforcingContrastFloor() -> CompanionThemeSpec {
        var spec = self
        spec.accentDark = Self.enforced(spec.accentDark, onDarkPlate: true)
        spec.accentLight = Self.enforced(spec.accentLight, onDarkPlate: false)
        return spec
    }

    static func contrastRatio(_ stop: CompanionThemeStop, onDarkPlate: Bool) -> Double {
        let plate: Double = onDarkPlate ? 0 : 1
        return WCAGContrast.ratio(red1: stop.red, green1: stop.green, blue1: stop.blue,
                                  red2: plate, green2: plate, blue2: plate)
    }

    static func enforced(_ stop: CompanionThemeStop, onDarkPlate: Bool, floor: Double = 4.5) -> CompanionThemeStop {
        var adjusted = stop
        var iterations = 0
        while contrastRatio(adjusted, onDarkPlate: onDarkPlate) < floor, iterations < 60 {
            let target: Double = onDarkPlate ? 1 : 0
            adjusted.red += (target - adjusted.red) * 0.06
            adjusted.green += (target - adjusted.green) * 0.06
            adjusted.blue += (target - adjusted.blue) * 0.06
            iterations += 1
        }
        return adjusted
    }
}

/// Disk store for custom themes plus the bridge the `CompanionTheme.custom`
/// case reads its colors through. The active spec is set by AppModel whenever
/// the selection or the spec itself changes.
enum CustomThemeStore {
    static var activeSpec: CompanionThemeSpec?

    static func directory() -> URL {
        let dir = CompanionAppSupport.supportDirectory().appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> [CompanionThemeSpec] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CompanionThemeSpec.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ spec: CompanionThemeSpec) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(spec) else { return }
        try? data.write(to: directory().appendingPathComponent("\(spec.id).json"), options: .atomic)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory().appendingPathComponent("\(id).json"))
    }

    static func decode(_ data: Data) throws -> CompanionThemeSpec {
        try JSONDecoder().decode(CompanionThemeSpec.self, from: data)
    }

    static func encode(_ spec: CompanionThemeSpec) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(spec)
    }
}
