import AppKit
import Foundation
import CoreGraphics
import ServiceManagement

class SilentAirDropApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var isEnabled = true
    private var lastValidApp: NSRunningApplication?
    private let downloadsPath: URL
    private var lastFileChangeTime: Date = Date.distantPast
    
    // Settings keys
    private let kEnabledKey = "SilentAirDropEnabled"
    private let kHideIconKey = "SilentAirDropHideIcon"
    
    override init() {
        downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        super.init()
        
        isEnabled = UserDefaults.standard.object(forKey: kEnabledKey) as? Bool ?? true
        
        applySystemTweaks()
        setupFSEvents()
        setupNotificationObservers()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showWelcomeAndRequestPermissions()
        
        // If the icon was hidden, we still show it on launch to give user control.
        // The user can hide it again via menu.
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
        menu.addItem(NSMenuItem(title: "SilentAirDrop v1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Status toggle
        let toggleItem = NSMenuItem(title: isEnabled ? "Status: ENABLED" : "Status: DISABLED", action: #selector(toggleStatus), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        // Auto-launch
        let isAutoLaunch = SMAppService.mainApp.status == .enabled
        let launchItem = NSMenuItem(title: isAutoLaunch ? "Launch at Login: ON" : "Launch at Login: OFF", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        
        // Hide Icon
        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(confirmHideIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        statusItem?.button?.alphaValue = isEnabled ? 1.0 : 0.4
    }
    
    @objc private func toggleStatus() {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: kEnabledKey)
        updateMenu()
    }
    
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateMenu()
        } catch {
            print("Failed to toggle Launch at Login: \(error)")
        }
    }
    
    @objc private func confirmHideIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon?"
        alert.informativeText = "The app will keep running in the background. To show the icon again, simply launch the app from your Applications folder."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: kHideIconKey)
            statusItem = nil // This removes it from the menu bar
        }
    }

    // This allows showing the icon again when user opens the .app
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(false, forKey: kHideIconKey)
        setupMenuBar()
        return true
    }

    private func setupFSEvents() {
        let pathString = downloadsPath.path
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventContext = FSEventStreamContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        let paths = [pathString] as CFArray
        
        guard let stream = FSEventStreamCreate(nil, { (stream, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            let watcher = Unmanaged<SilentAirDropApp>.fromOpaque(clientCallBackInfo!).takeUnretainedValue()
            watcher.lastFileChangeTime = Date()
        }, &eventContext, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, UInt32(kFSEventStreamCreateFlagFileEvents)) else {
            print("Failed to create FSEventStream")
            return
        }
        
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func setupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidActivate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc func appDidActivate(notification: NSNotification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        
        if app.bundleIdentifier == "com.apple.finder" {
            let timeSinceFileChange = Date().timeIntervalSince(lastFileChangeTime)
            let idle = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
            
            if isEnabled && timeSinceFileChange < 5.0 && idle > 0.4 {
                if let lastApp = lastValidApp, lastApp.bundleIdentifier != "com.apple.finder" {
                    lastApp.activate(options: [.activateIgnoringOtherApps])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.closeDownloadsWindow(finder: app)
                }
            } else {
                lastValidApp = app
            }
        } else {
            lastValidApp = app
        }
    }

    private func closeDownloadsWindow(finder: NSRunningApplication) {
        let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(finderElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        let localizedDownloads = FileManager.default.displayName(atPath: downloadsPath.path)
        
        if let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                let title = titleValue as? String ?? ""
                if title == localizedDownloads || title == "Downloads" || title == "Загрузки" {
                    AXUIElementPerformAction(window, kAXCancelAction as CFString)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = SilentAirDropApp()
app.delegate = delegate
app.run()
