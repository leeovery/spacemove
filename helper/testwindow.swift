// A 2×2 transparent, click-through window owned by its own process: a stand-in for another
// app's window, so spacemove's routes can be tried without touching a real one.
// Prints its window number, then exits after the given number of seconds (default 20).
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.isOpaque = false
window.backgroundColor = .clear
window.ignoresMouseEvents = true
window.orderFrontRegardless()
print(window.windowNumber)
fflush(stdout)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 20
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
