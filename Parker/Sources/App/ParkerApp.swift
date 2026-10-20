import Cocoa
import SwiftUI

@main
struct ParkerApp {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { SettingsSnapshot.render(to: args[i + 1]) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate is weak: keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var captureEngine: ScreenCaptureEngine!
    private var thumbnailController: FloatingThumbnailController!
    private var editorController: AnnotationEditorController!
    private var hotkeyManager: HotkeyManager!
    private var screenRecorder: ScreenRecorder!
    private var ocrTool: OCRTool!
    private var colorPicker: ColorPickerTool!
    private var preferencesController: PreferencesWindowController!
    private var scrollCapture: ScrollCapture!
    private var onboardingController: OnboardingWindowController!
    private var captureToolbar: CaptureToolbarController!
    private var captureHistory: CaptureHistoryController!
    private var pinnedWindows: [PinnedImageWindow] = []
    private var shortcutSettingsObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastActiveExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Parker's history folder keeps only the files still in the history (20 at most)
        Defaults.shared.pruneHistoryDirectory()

        captureEngine = ScreenCaptureEngine()
        thumbnailController = FloatingThumbnailController()
        editorController = AnnotationEditorController()
        screenRecorder = ScreenRecorder()
        ocrTool = OCRTool()
        colorPicker = ColorPickerTool()
        preferencesController = PreferencesWindowController()
        scrollCapture = ScrollCapture()
        hotkeyManager = HotkeyManager()
        onboardingController = OnboardingWindowController()
        captureToolbar = CaptureToolbarController()
        captureHistory = CaptureHistoryController()

        thumbnailController.onEdit = { [weak self] url in
            self?.editorController.open(imageURL: url)
        }
        thumbnailController.onPin = { [weak self] url in
            self?.pinImage(url: url)
        }

        screenRecorder.onRecordingFinished = { [weak self] url in
            Defaults.shared.addRecentCapture(url)
            self?.thumbnailController.show(for: url)
            self?.menuBarController.rebuildMenu()
        }

        menuBarController = MenuBarController(
            captureEngine: captureEngine,
            thumbnailController: thumbnailController,
            screenRecorder: screenRecorder,
            ocrTool: ocrTool,
            colorPicker: colorPicker,
            scrollCapture: scrollCapture,
            preferencesController: preferencesController
        )
        menuBarController.prepareForCapture = { [weak self] preferredApp, action in
            self?.prepareForCapture(preferredApp: preferredApp, action: action) ?? action()
        }

        setupCaptureToolbar()
        setupHotkeys()
        observeShortcutSettings()
        observeWorkspaceActivation()

        menuBarController.onShowAllInOne = { [weak self] in
            self?.captureToolbar.toggle()
        }
        menuBarController.onShowHistory = { [weak self] in
            self?.captureHistory.toggle()
        }
        captureHistory.onEdit = { [weak self] url in
            self?.editorController.open(imageURL: url)
        }
        captureHistory.onHistoryChanged = { [weak self] in
            self?.menuBarController.rebuildMenu()
        }

        // Show onboarding on first launch
        // Permissions assistant (drag Parker into System Settings) when something is missing
        PermissionAssistant.shared.showIfNeeded()

        // Look for a newer version on GitHub (silent, at most every 6 h)
        UpdateChecker.shared.checkInBackgroundIfNeeded()
    }

    private func setupCaptureToolbar() {
        captureToolbar.onCaptureFullscreen = { [weak self] in
            self?.menuBarController.triggerCaptureFullscreen()
        }
        captureToolbar.onCaptureArea = { [weak self] in
            self?.menuBarController.triggerCaptureArea()
        }
        captureToolbar.onCaptureWindow = { [weak self] in
            self?.menuBarController.triggerCaptureWindow()
        }
        captureToolbar.onCaptureScrolling = { [weak self] in
            self?.menuBarController.triggerCaptureScrolling()
        }
        captureToolbar.onRecordScreen = { [weak self] in
            self?.menuBarController.triggerRecordScreen()
        }
        captureToolbar.onRecordArea = { [weak self] in
            self?.menuBarController.triggerRecordArea()
        }
        captureToolbar.onOCR = { [weak self] in
            self?.menuBarController.triggerOCR()
        }
        captureToolbar.onColorPicker = { [weak self] in
            self?.menuBarController.triggerColorPicker()
        }
    }

    private func setupHotkeys() {
        hotkeyManager.onCaptureFullscreen = { [weak self] in
            self?.menuBarController.triggerCaptureFullscreen()
        }
        hotkeyManager.onCaptureArea = { [weak self] in
            self?.menuBarController.triggerCaptureArea()
        }
        hotkeyManager.onCaptureWindow = { [weak self] in
            self?.menuBarController.triggerCaptureWindow()
        }
        hotkeyManager.onCaptureScrolling = { [weak self] in
            self?.menuBarController.triggerCaptureScrolling()
        }
        hotkeyManager.onOCR = { [weak self] in
            self?.menuBarController.triggerOCR()
        }
        hotkeyManager.onColorPicker = { [weak self] in
            self?.menuBarController.triggerColorPicker()
        }
        hotkeyManager.onRecordScreen = { [weak self] in
            self?.menuBarController.triggerRecordScreen()
        }
        hotkeyManager.onRecordArea = { [weak self] in
            self?.menuBarController.triggerRecordArea()
        }
        hotkeyManager.onAllInOne = { [weak self] in
            self?.captureToolbar.toggle()
        }
        hotkeyManager.onHistory = { [weak self] in
            self?.captureHistory.toggle()
        }
        hotkeyManager.registerAll()
        SystemScreenshotShortcuts.sync(with: ShortcutCatalog.currentProfile())
    }

    private func observeShortcutSettings() {
        shortcutSettingsObserver = NotificationCenter.default.addObserver(
            forName: .shortcutConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyManager.registerAll()
            SystemScreenshotShortcuts.sync(with: ShortcutCatalog.currentProfile())
            self?.menuBarController.rebuildMenu()
        }
    }

    private func observeWorkspaceActivation() {
        updateLastActiveExternalApp(NSWorkspace.shared.frontmostApplication)

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateLastActiveExternalApp(app)
        }
    }

    private func updateLastActiveExternalApp(_ app: NSRunningApplication?) {
        guard let app else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastActiveExternalApp = app
        CaptureSource.lastExternalApp = app
    }

    private func prepareForCapture(preferredApp: NSRunningApplication?, action: @escaping () -> Void) {
        let app = preferredApp?.isTerminated == false ? preferredApp : lastActiveExternalApp
        let parkerInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier

        // Another app is already in front (the usual case): capture right away, without
        // activating anything (activating an app can switch desktop).
        guard parkerInFront else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: action)
            return
        }
        // Parker is in front (settings, menu…): give the focus back without leaving this desktop
        SpaceSafeFocus.restoreFocus(to: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
    }

    private func pinImage(url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pinned = PinnedImageWindow(image: image, imageURL: url)
        pinned.show()
        pinnedWindows.append(pinned)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemScreenshotShortcuts.restore()
        if let shortcutSettingsObserver {
            NotificationCenter.default.removeObserver(shortcutSettingsObserver)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }
}
