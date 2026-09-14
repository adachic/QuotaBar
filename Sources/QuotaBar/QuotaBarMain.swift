import AppKit
import SwiftUI
import Combine
import QuotaCore

@main
struct QuotaBarMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--check") {
            Task {
                var failed = false
                let providers = Provider.allCases.filter { !arguments.contains("--codex-only") || $0 == .codex }
                    .filter { !arguments.contains("--claude-only") || $0 == .claude }
                for provider in providers {
                    do {
                        let snapshot: UsageSnapshot
                        if provider == .codex {
                            guard let executable = CodexClient.findExecutable() else { throw UsageError.missingCodex }
                            snapshot = try await CodexClient.fetch(executable: executable)
                        } else {
                            snapshot = try await ClaudeClient.fetch(allowInteraction: arguments.contains("--allow-keychain"))
                        }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
                    } catch { print("\(provider.title): \(error.localizedDescription)"); failed = true }
                }
                exit(failed ? 1 : 0)
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = AppDelegate(demo: arguments.contains("--demo"))
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: UsageStore
    private var items: [Provider: NSStatusItem] = [:]
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private weak var anchorButton: NSStatusBarButton?

    init(demo: Bool) { store = UsageStore(demo: demo); super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid duplicate menu items when Finder launches a second copy.
        if !store.demo, let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApplication.shared.terminate(nil)
            return
        }
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: PopoverView(store: store, onResize: { [weak self] size in
            // Applying a native size during a SwiftUI layout transaction can stall UI updates.
            DispatchQueue.main.async {
                guard let self, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            }
        }))
        // The screen bounds govern the popover size. Usage updates must not grow it offscreen.
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 430)
        for provider in Provider.allCases.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "QuotaBar.\(provider.rawValue)"
            if let button = item.button {
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.tag = provider == .codex ? 0 : 1
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            items[provider] = item
        }
        store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItems() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown, let button = self.anchorButton else { return }
                self.fitPopover(to: button)
            }.store(in: &subscriptions)
        updateStatusItems()
        store.start()
        if CommandLine.arguments.contains("--show") || store.demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let button = self.items[.codex]?.button else { return }
                self.showPopover(button)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { store.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let button = items[.codex]?.button { showPopover(button) }
        return true
    }
    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { store.settingsVisible = true }
        if popover.isShown { popover.performClose(sender) } else { showPopover(sender) }
    }
    private func showPopover(_ button: NSStatusBarButton) {
        store.now = Date()
        anchorButton = button
        fitPopover(to: button)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    private func fitPopover(to button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        // The view measures its compact content and scales only if a very small screen requires it.
        // Leave room for the arrow, shadow, menu bar and Dock. AppKit handles horizontal positioning.
        var height = min(620, max(160, visible.height - 32))
        #if DEBUG
        if let previewHeight = Bundle.main.object(forInfoDictionaryKey: "QuotaBarPreviewHeight") as? Double {
            height = min(height, max(160, previewHeight))
        }
        #endif
        let size = NSSize(width: min(370, max(240, visible.width - 32)), height: height)
        if store.panelSize != size { store.panelSize = size }
    }
    private func updateStatusItems() {
        for provider in Provider.allCases {
            guard let button = items[provider]?.button else { continue }
            let window = store.selected(provider)
            let stale = store.isStale(provider)
            button.image = MenuBarImage.make(provider: provider, window: window, showPercent: store.showPercent, stale: stale, demo: store.demo)
            button.imagePosition = .imageOnly
            let value = window.map { "\($0.displayPercent)%" } ?? "未取得"
            let label = "\(provider.title) \(window?.title ?? store.selection.title) 残り\(value)\(stale ? "（前回の値）" : "")\(store.demo ? "（デモ）" : "")"
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
    }

}

@MainActor
enum MenuBarImage {
    static func make(provider: Provider, window: UsageWindow?, showPercent: Bool, stale: Bool, demo: Bool) -> NSImage {
        let label = window.map { "\($0.displayPercent)%" } ?? "—%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let labelWidth: CGFloat = showPercent ? 36 : 0
        let width: CGFloat = 48 + labelWidth + (stale || demo ? 7 : 0)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let color = NSColor.labelColor
            color.setFill()
            // Distinct silhouettes remain legible in monochrome next to macOS system icons.
            if let symbol = NSImage(systemSymbolName: provider.symbol, accessibilityDescription: provider.title)?
                .withSymbolConfiguration(.init(pointSize: provider == .codex ? 10 : 12, weight: .semibold)) {
                symbol.draw(in: NSRect(x: 2, y: 5, width: 14, height: 12))
            }
            let body = NSRect(x: 21, y: 5, width: 22, height: 12)
            color.withAlphaComponent(0.62).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.4, yRadius: 2.4)
            outline.lineWidth = 1; outline.stroke()
            color.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 44, y: 8.5, width: 1.5, height: 5), xRadius: 0.6, yRadius: 0.6).fill()
            if let window {
                color.withAlphaComponent(stale ? 0.4 : 1).setFill()
                let fill = NSRect(x: 23, y: 7, width: 18 * window.remainingPercent / 100, height: 8)
                NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            } else {
                color.withAlphaComponent(0.45).setFill()
                NSRect(x: 29, y: 10, width: 6, height: 1.5).fill()
            }
            if showPercent {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                (label as NSString).draw(at: NSPoint(x: 50, y: 3.5), withAttributes: attributes)
            }
            if stale || demo {
                ("·" as NSString).draw(at: NSPoint(x: width - 6, y: 3.5), withAttributes: [.font: font, .foregroundColor: color])
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
