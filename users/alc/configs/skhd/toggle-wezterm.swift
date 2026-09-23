import Cocoa

let bundleID = "com.github.wez.wezterm"

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/WezTerm.app"))
    exit(0)
}

if app.isActive {
    app.hide()
} else {
    app.unhide()
    app.activate()
}
