import Cocoa

let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.wez.wezterm")
    .first

if let app = app {
    if app.isActive {
        app.hide()
    } else {
        app.unhide()
        app.activate()
    }
} else {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/alc/Applications/Home Manager Apps/WezTerm.app"))
}
