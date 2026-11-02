import AppKit
import IOKit.ps
import Metal

// Clicks land here and stop, so they can't reach the windows hidden underneath, and the panel
// never becomes key, so typing stays in the app being studied in.
final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PassiveView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let movingWaterKey = "movingWater"
    private static let skySeconds = 3.0

    private let panel = QuietPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var statusItem: NSStatusItem?
    private var movingItem: NSMenuItem?
    private var skyTimer: Timer?
    private var chosenScreen: NSScreen?
    private var renderer: SceneRenderer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.movingWaterKey: true])

        // Above the menu bar, so whatever is already open on that display disappears
        // without being rearranged.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice(), let renderer = SceneRenderer(device: device) else {
            let alert = NSAlert()
            alert.messageText = "Slow Horizon can't start"
            alert.informativeText = "This Mac could not load the app's Metal shaders."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.renderer = renderer
        let content = PassiveView()
        content.addSubview(renderer.skyView)
        content.addSubview(renderer.seaView)
        panel.contentView = content

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Slow Horizon")
        let menu = NSMenu()
        let moving = menu.addItem(withTitle: "Moving Water", action: #selector(toggleMovingWater), keyEquivalent: "")
        moving.target = self
        moving.state = UserDefaults.standard.bool(forKey: Self.movingWaterKey) ? .on : .off
        movingItem = moving
        let next = menu.addItem(withTitle: "Move to Next Display", action: #selector(moveToNextDisplay), keyEquivalent: "")
        next.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "End Slow Horizon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(placePanel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(refreshAnimation), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        center.addObserver(self, selector: #selector(refreshAnimation), name: .NSProcessInfoPowerStateDidChange, object: nil)

        placePanel()

        let timer = Timer(timeInterval: Self.skySeconds, repeats: true) { [weak self] _ in self?.tick() }
        // The tolerance lets macOS bundle this wake-up with others.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        skyTimer = timer

        runShortcut("Slow Horizon On")
    }

    // Opening the app a second time is the off switch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runShortcut("Slow Horizon Off")
    }

    private var isShowing: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    private func tick() {
        guard isShowing else { return }
        refreshAnimation()
        renderer?.update()
    }

    @objc private func toggleMovingWater() {
        let moving = !UserDefaults.standard.bool(forKey: Self.movingWaterKey)
        UserDefaults.standard.set(moving, forKey: Self.movingWaterKey)
        movingItem?.state = moving ? .on : .off
        refreshAnimation()
    }

    // The water stops on battery and in Low Power Mode, and whenever nothing can see it.
    @objc private func refreshAnimation() {
        let onMains = IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
        let moving = UserDefaults.standard.bool(forKey: Self.movingWaterKey)
        let allowed = moving && onMains && !ProcessInfo.processInfo.isLowPowerModeEnabled
        renderer?.setSeaAnimating(allowed && isShowing)
    }

    @objc private func moveToNextDisplay() {
        let screens = NSScreen.screens
        guard let current = panel.screen, let index = screens.firstIndex(of: current) else { return }
        chosenScreen = screens[(index + 1) % screens.count]
        placePanel()
    }

    @objc private func placePanel() {
        let work = screenHoldingClaude() ?? NSScreen.main
        let chosen = chosenScreen.flatMap { NSScreen.screens.contains($0) ? $0 : nil }
        guard let target = chosen ?? NSScreen.screens.first(where: { $0.frame != work?.frame }) else {
            // One display means that display is the study screen, so wait for a second one.
            panel.orderOut(nil)
            refreshAnimation()
            return
        }
        panel.setFrame(target.frame, display: false)
        panel.contentView?.frame = CGRect(origin: .zero, size: target.frame.size)
        renderer?.layout(sceneSize: target.frame.size, scale: target.backingScaleFactor)
        panel.orderFrontRegardless()
        refreshAnimation()
    }

    private func screenHoldingClaude() -> NSScreen? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
            let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }

        var best: (screen: NSScreen, area: CGFloat)?
        for window in windows {
            guard
                window[kCGWindowOwnerName as String] as? String == "Claude",
                window[kCGWindowLayer as String] as? Int == 0,
                let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { continue }

            // Window bounds count from the top of the primary display, screen frames from the bottom.
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            for screen in NSScreen.screens {
                let overlap = frame.intersection(screen.frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (screen, area) }
            }
        }
        return best?.screen
    }

    // macOS has no public API for Focus, so it goes through two optional user-made shortcuts.
    // A missing shortcut only makes this process exit with an error, which is fine to ignore.
    private func runShortcut(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
