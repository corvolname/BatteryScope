import AppKit

// A menu bar agent: no Dock icon, no main menu, no default window.
//
// The entry point is written explicitly (rather than using SwiftUI's `App` lifecycle) so the
// activation policy is set before the run loop starts — that is what keeps the process out of
// the Dock and the ⌘-Tab switcher.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
