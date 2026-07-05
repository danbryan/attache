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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
