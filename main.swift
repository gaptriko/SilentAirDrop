import AppKit
import Foundation
import CoreGraphics
import ServiceManagement

private struct RecentDownloadCandidate {
    let file: FileCandidate
    let detectedAt: Date
}

private enum SilentAirDropSettingsError: LocalizedError {
    case launchAtLoginUnavailable
    case launchAtLoginChangeFailed

    var errorDescription: String? {
        switch self {
        case .launchAtLoginUnavailable:
            return "Launch at login is unavailable. Build and run SilentAirDrop as a signed app bundle, then try again."
        case .launchAtLoginChangeFailed:
            return "macOS did not apply the Launch at Login change. Please try again in System Settings."
        }
    }
}

class SilentAirDropApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var isEnabled = true
    private var lastValidApp: NSRunningApplication?
    private let downloadsPath: URL
    private var lastFileChangeTime: Date = Date.distantPast
    private var recentDownloadCandidates: [String: RecentDownloadCandidate] = [:]
    private var knownDownloadPaths = Set<String>()
    private var hasInitializedDownloadSnapshot = false
    private var eventStream: FSEventStreamRef?
    private var fileBehaviorPolicy: FileBehaviorPolicy
    private var settingsWindowController: SettingsWindowController?
    private var finderEvaluationGeneration = 0
    private let fileChangeWindow: TimeInterval = 5.0
    private let transferBatchQuietPeriod: TimeInterval = 0.5
    
    // Settings keys
    private let kEnabledKey = "SilentAirDropEnabled"
    private let kHideIconKey = "SilentAirDropHideIcon"
    
    override init() {
        downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        fileBehaviorPolicy = FileBehaviorPolicy.load()
        super.init()
        
        isEnabled = UserDefaults.standard.object(forKey: kEnabledKey) as? Bool ?? true
        
        applySystemTweaks()
        setupNotificationObservers()
    }

    deinit {
        tearDownFSEvents()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showWelcomeAndRequestPermissions()
        initializeDownloadSnapshot()
        setupFSEvents()
        // Close the snapshot-to-stream gap: anything created while the stream
        // was being installed is recovered here and later event callbacks dedupe it.
        rescanDownloadsForNewCandidates(detectedAt: Date())
        
        // Hiding the icon lasts until the next launch, which guarantees a
        // recovery path without requiring Terminal or deleting preferences.
        if UserDefaults.standard.bool(forKey: kHideIconKey) {
            UserDefaults.standard.set(false, forKey: kHideIconKey)
        }
        setupMenuBar()
    }
    
    private func applySystemTweaks() {
        if !UserDefaults.standard.bool(forKey: "SystemTweaksV2") {
            let script = "defaults write com.apple.spaces \"app-bindings\" -dict-add \"com.apple.finder\" \"All\" && killall Dock"
            let task = Process()
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", script]
            do {
                try task.run()
            } catch {
                print("Failed to run system tweaks: \(error)")
            }
            UserDefaults.standard.set(true, forKey: "SystemTweaksV2")
        }
    }

    private func showWelcomeAndRequestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        let welcomeKey = "WelcomeShownV3"
        
        if !isTrusted && !UserDefaults.standard.bool(forKey: welcomeKey) {
            _ = try? FileManager.default.contentsOfDirectory(at: downloadsPath, includingPropertiesForKeys: nil)
            
            let alert = NSAlert()
            alert.messageText = "Welcome to SilentAirDrop! 🚀"
            alert.informativeText = """
            To keep your workflow uninterrupted, SilentAirDrop needs two simple permissions:
            
            1. Access to the Downloads folder (to detect new files).
            2. Accessibility permissions (to prevent Finder from stealing focus).
            
            Click 'Let's Go!' and follow the system prompts.
            """
            alert.addButton(withTitle: "Let's Go!")
            
            if let icon = NSApp.applicationIconImage {
                alert.icon = icon
            }
            
            alert.runModal()
            UserDefaults.standard.set(true, forKey: welcomeKey)
        }
    }
    
    private func setupMenuBar() {
        if UserDefaults.standard.bool(forKey: kHideIconKey) {
            // Icon is hidden. We don't create statusItem.
            return
        }
        
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "SilentAirDrop")
            image?.isTemplate = true
            button.image = image
        }
        
        updateMenu()
    }
    
    private func updateMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
        menu.addItem(NSMenuItem(title: "SilentAirDrop v\(version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Status toggle
        let toggleItem = NSMenuItem(title: isEnabled ? "Status: ENABLED" : "Status: DISABLED", action: #selector(toggleStatus), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        statusItem?.button?.alphaValue = isEnabled ? 1.0 : 0.4
    }
    
    @objc private func toggleStatus() {
        setEnabled(!isEnabled)
    }

    @objc private func showSettings() {
        let generalSettings = currentGeneralSettings()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                policy: fileBehaviorPolicy,
                generalSettings: generalSettings
            ) { [weak self] policy, settings in
                try self?.apply(policy: policy, generalSettings: settings)
            }
        } else {
            settingsWindowController?.update(policy: fileBehaviorPolicy, generalSettings: generalSettings)
        }
        settingsWindowController?.showWindow(self)
    }

    // This allows showing the icon again when user opens the .app
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setMenuBarIconVisible(true)
        showSettings()
        return true
    }

    private func currentGeneralSettings() -> GeneralSettings {
        let serviceStatus = SMAppService.mainApp.status
        let launchAtLogin: Bool
        let launchAtLoginRequiresApproval: Bool
        switch serviceStatus {
        case .enabled:
            launchAtLogin = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLogin = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLogin = false
            launchAtLoginRequiresApproval = false
        }

        return GeneralSettings(
            isEnabled: isEnabled,
            launchAtLogin: launchAtLogin,
            launchAtLoginRequiresApproval: launchAtLoginRequiresApproval,
            launchAtLoginAvailability: launchAtLoginAvailability(for: serviceStatus),
            showMenuBarIcon: statusItem != nil
        )
    }

    private func launchAtLoginAvailability(
        for status: SMAppService.Status
    ) -> LaunchAtLoginAvailability {
        let bundleURL = Bundle.main.bundleURL
        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let packageType = Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        let isApplicationBundle = resolvedBundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && packageType == "APPL"
        let isInApplications = isApplicationBundle && isInstalledInApplications(resolvedBundleURL)

        // Keep registered services removable even if this copy was moved or
        // launched from somewhere temporary.
        if status == .enabled || status == .requiresApproval {
            if isInApplications {
                return .available
            }
            return .removableOnly(
                reason: "SilentAirDrop is outside Applications. You can turn Launch at Login off here; move and reopen the app before enabling it again."
            )
        }

        guard isApplicationBundle else {
            return .unavailable(reason: "Build and open SilentAirDrop.app to enable Launch at Login.")
        }

        guard isInApplications else {
            return .unavailable(
                reason: "Move SilentAirDrop.app to your Applications folder, then reopen it to enable Launch at Login."
            )
        }

        switch status {
        case .notRegistered:
            return .available
        case .notFound:
            return .unavailable(
                reason: "macOS could not find a Launch at Login service for this copy of SilentAirDrop."
            )
        case .enabled, .requiresApproval:
            return .available
        @unknown default:
            return .unavailable(
                reason: "Launch at Login is unavailable because macOS returned an unknown service status."
            )
        }
    }

    private func isInstalledInApplications(_ bundleURL: URL) -> Bool {
        let fileManager = FileManager.default
        let applicationDirectories = fileManager.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask]
        )

        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return applicationDirectories.contains { directoryURL in
            var relationship = FileManager.URLRelationship.other
            do {
                try fileManager.getRelationship(
                    &relationship,
                    ofDirectoryAt: directoryURL.resolvingSymlinksInPath().standardizedFileURL,
                    toItemAt: resolvedBundleURL
                )
                return relationship == .contains
            } catch {
                return false
            }
        }
    }

    private func apply(policy: FileBehaviorPolicy, generalSettings: GeneralSettings) throws {
        let currentSettings = currentGeneralSettings()
        if currentSettings.launchAtLogin != generalSettings.launchAtLogin {
            if generalSettings.launchAtLogin,
               !currentSettings.launchAtLoginAvailability.allowsEnabling {
                throw SilentAirDropSettingsError.launchAtLoginUnavailable
            }
            try setLaunchAtLogin(generalSettings.launchAtLogin)
        }

        policy.save()
        fileBehaviorPolicy = policy
        setEnabled(generalSettings.isEnabled)
        setMenuBarIconVisible(generalSettings.showMenuBarIcon)
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: kEnabledKey)
        updateMenu()
    }

    private func setLaunchAtLogin(_ shouldLaunch: Bool) throws {
        let service = SMAppService.mainApp

        if shouldLaunch {
            switch service.status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            case .notRegistered:
                try service.register()
            case .notFound:
                throw SilentAirDropSettingsError.launchAtLoginUnavailable
            @unknown default:
                throw SilentAirDropSettingsError.launchAtLoginUnavailable
            }

            switch service.status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            case .notRegistered, .notFound:
                throw SilentAirDropSettingsError.launchAtLoginUnavailable
            @unknown default:
                throw SilentAirDropSettingsError.launchAtLoginUnavailable
            }
        }

        switch service.status {
        case .enabled, .requiresApproval:
            try service.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            return
        }

        switch service.status {
        case .notRegistered, .notFound:
            return
        case .enabled, .requiresApproval:
            throw SilentAirDropSettingsError.launchAtLoginChangeFailed
        @unknown default:
            throw SilentAirDropSettingsError.launchAtLoginChangeFailed
        }
    }

    private func setMenuBarIconVisible(_ visible: Bool) {
        UserDefaults.standard.set(!visible, forKey: kHideIconKey)

        if visible {
            setupMenuBar()
            return
        }

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func initializeDownloadSnapshot() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: downloadsPath,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        knownDownloadPaths = Set(urls.map { $0.standardizedFileURL.path })
        hasInitializedDownloadSnapshot = true
    }

    private func setupFSEvents() {
        let pathString = downloadsPath.path
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventContext = FSEventStreamContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        let paths = [pathString] as CFArray

        let streamFlags = UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(nil, { (_, clientCallBackInfo, numEvents, eventPaths, eventFlags, _) in
            guard let clientCallBackInfo else {
                return
            }

            let watcher = Unmanaged<SilentAirDropApp>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = (cfPaths as NSArray) as? [String] else {
                return
            }

            let eventCount = min(Int(numEvents), paths.count)
            var flags: [FSEventStreamEventFlags] = []
            flags.reserveCapacity(eventCount)
            for index in 0..<eventCount {
                flags.append(eventFlags[index])
            }

            watcher.handleFileSystemEvents(
                paths: Array(paths.prefix(eventCount)),
                flags: flags,
                detectedAt: Date()
            )
        }, &eventContext, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, streamFlags) else {
            print("Failed to create FSEventStream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            print("Failed to start FSEventStream")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        eventStream = stream
    }

    private func tearDownFSEvents() {
        guard let eventStream else {
            return
        }

        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)
        self.eventStream = nil
    }

    private func handleFileSystemEvents(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        detectedAt: Date
    ) {
        lastFileChangeTime = detectedAt
        pruneRecentDownloadCandidates(at: detectedAt)

        let eventCount = min(paths.count, flags.count)
        let relevantChangeFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let droppedEventFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        var needsRescan = false

        for index in 0..<eventCount {
            let eventFlags = flags[index]
            if eventFlags & droppedEventFlags != 0 {
                needsRescan = true
                continue
            }

            let url = URL(fileURLWithPath: paths[index]).standardizedFileURL
            guard url.deletingLastPathComponent().standardizedFileURL.path == downloadsPath.standardizedFileURL.path else {
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !exists || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                // Rename events can include the old name as well as the final one.
                knownDownloadPaths.remove(url.path)
                recentDownloadCandidates.removeValue(forKey: url.path)
                continue
            }

            knownDownloadPaths.insert(url.path)
            guard eventFlags & relevantChangeFlags != 0,
                  !shouldIgnoreDownloadEvent(for: url) else {
                continue
            }

            recordDownloadCandidate(url: url, isDirectory: isDirectory.boolValue, detectedAt: detectedAt)
        }

        if needsRescan {
            rescanDownloadsForNewCandidates(detectedAt: detectedAt)
        }
    }

    private func recordDownloadCandidate(url: URL, isDirectory: Bool, detectedAt: Date) {
        if lastFileChangeTime != .distantPast,
           detectedAt.timeIntervalSince(lastFileChangeTime) > transferBatchQuietPeriod {
            recentDownloadCandidates.removeAll()
        }

        let file = FileCandidate(url: url, isDirectory: isDirectory)
        recentDownloadCandidates[url.path] = RecentDownloadCandidate(file: file, detectedAt: detectedAt)
        lastFileChangeTime = detectedAt
    }

    private func rescanDownloadsForNewCandidates(detectedAt: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: downloadsPath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        let standardizedURLs = urls.map(\.standardizedFileURL)
        let currentPaths = Set(standardizedURLs.map(\.path))
        guard hasInitializedDownloadSnapshot else {
            knownDownloadPaths = currentPaths
            hasInitializedDownloadSnapshot = true
            return
        }

        let newURLs = standardizedURLs.filter { !knownDownloadPaths.contains($0.path) }
        knownDownloadPaths = currentPaths

        for url in newURLs where !shouldIgnoreDownloadEvent(for: url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            recordDownloadCandidate(url: url, isDirectory: isDirectory.boolValue, detectedAt: detectedAt)
        }
    }

    private func shouldIgnoreDownloadEvent(for url: URL) -> Bool {
        let fileName = url.lastPathComponent.lowercased()
        if fileName == ".ds_store" || fileName == ".localized" {
            return true
        }

        let temporarySuffixes = [".crdownload", ".download", ".part"]
        return temporarySuffixes.contains(where: fileName.hasSuffix)
    }

    private func pruneRecentDownloadCandidates(at date: Date) {
        recentDownloadCandidates = recentDownloadCandidates.filter {
            date.timeIntervalSince($0.value.detectedAt) < fileChangeWindow
                && FileManager.default.fileExists(atPath: $0.value.file.url.path)
        }
    }

    private func recentFiles(at date: Date) -> [FileCandidate] {
        pruneRecentDownloadCandidates(at: date)
        return recentDownloadCandidates.values.map(\.file)
    }

    private func consumeRecentDownloadCandidates() {
        recentDownloadCandidates.removeAll()
        lastFileChangeTime = .distantPast
    }

    private func setupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidActivate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc func appDidActivate(notification: NSNotification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        if app.bundleIdentifier == "com.apple.finder" {
            let now = Date()
            let timeSinceFileChange = now.timeIntervalSince(lastFileChangeTime)
            let idleAtActivation = min(
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            )

            let files = recentFiles(at: now)
            let fileBehavior = files.isEmpty ? fileBehaviorPolicy.defaultBehavior : fileBehaviorPolicy.behavior(for: files)

            if isEnabled && timeSinceFileChange < fileChangeWindow && idleAtActivation > 0.4 && fileBehavior == .keepFinderClosed {
                if let lastApp = lastValidApp,
                   let bid = lastApp.bundleIdentifier,
                   bid != "com.apple.finder",
                   bid != Bundle.main.bundleIdentifier {
                    lastApp.activate(options: [.activateIgnoringOtherApps])
                } else {
                    app.hide()
                }
                self.closeDownloadsWindow(finder: app)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.closeDownloadsWindow(finder: app)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.closeDownloadsWindow(finder: app)
                }
                consumeRecentDownloadCandidates()
            } else {
                lastValidApp = app
            }
        } else {
            finderEvaluationGeneration += 1
            lastValidApp = app
        }
    }

    private func closeDownloadsWindow(finder: NSRunningApplication) {
        let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(finderElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        let localizedDownloads = FileManager.default.displayName(atPath: downloadsPath.path)
        var closedAny = false
        
        if let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                let title = titleValue as? String ?? ""
                if title == localizedDownloads || title == "Downloads" || title == "Загрузки" {
                    var closeButtonVal: AnyObject?
                    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonVal) == .success,
                       let closeButton = closeButtonVal {
                        let res = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                        if res == .success {
                            closedAny = true
                        }
                    }
                }
            }
        }

        if !closedAny {
            let script = "tell application \"Finder\" to close (every window whose name is \"\(localizedDownloads)\" or name is \"Downloads\" or name is \"Загрузки\")"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = SilentAirDropApp()
app.delegate = delegate
app.run()
