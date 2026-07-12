import AppKit

// Fresh-process voice enumeration for the running app (the speech voice
// registry is cached per process, so a helper spawn is the only way to see
// voices downloaded after launch).
if CommandLine.arguments.contains("--print-voices") {
    for option in CompanionVoiceCatalog.options() {
        print("\(option.id)\t\(option.name)\t\(option.gender)\t\(option.localeIdentifier)")
    }
    exit(0)
}

// Design renders for the pet pose catalog (INF-269): exports the spec poses
// as PNGs and proves the neutral pose still matches the locked mark, then
// exits without starting the app.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-poses") {
    let outputPath = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1]
        : "design/pet"
    Task { @MainActor in
        do {
            try PetPoseRenderer.renderAll(to: URL(fileURLWithPath: outputPath))
            exit(0)
        } catch {
            fputs("pose render failed: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// Brand pose exports (INF-274): the marketing pose set at 2048 px plus the
// idle hero loop frames, same geometry lock.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-brand-poses") {
    let outputPath = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1]
        : "design/poses"
    Task { @MainActor in
        do {
            try PetPoseRenderer.renderBrand(to: URL(fileURLWithPath: outputPath))
            exit(0)
        } catch {
            fputs("brand pose render failed: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
