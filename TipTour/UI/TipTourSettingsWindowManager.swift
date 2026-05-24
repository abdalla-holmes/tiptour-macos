import AppKit
import SwiftUI

@MainActor
final class TipTourSettingsWindowManager {
    private weak var companionManager: CompanionManager?
    private var window: NSWindow?
    private let initialWindowSize = NSSize(width: 760, height: 560)
    private let minimumWindowSize = NSSize(width: 700, height: 500)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        guard let companionManager else { return }

        if window == nil {
            createWindow(companionManager: companionManager)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow(companionManager: CompanionManager) {
        let settingsView = TipTourSettingsView(companionManager: companionManager)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(origin: .zero, size: initialWindowSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = [.intrinsicContentSize]

        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "TipTour Settings"
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.isOpaque = false
        settingsWindow.hasShadow = true
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.contentMinSize = minimumWindowSize
        settingsWindow.setFrameAutosaveName("TipTourSettingsWindow")
        settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        settingsWindow.contentView = hostingView

        window = settingsWindow
    }
}
