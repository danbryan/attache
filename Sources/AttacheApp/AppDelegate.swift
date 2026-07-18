import AppKit
import Combine
import SwiftUI
import AttacheCore
import Sparkle

extension Notification.Name {
    static let attacheOpenSettings = Notification.Name("attache.openSettings")
    static let attacheShowOnboarding = Notification.Name("attache.showOnboarding")
    static let attacheOpenVoicemailSurface = Notification.Name("attache.openVoicemailSurface")
    static let attacheOpenHistory = Notification.Name("attache.openHistory")
    static let attacheOpenTalk = Notification.Name("attache.openTalk")
    static let attacheOpenPalette = Notification.Name("attache.openPalette")
    static let attacheOpenCharacterSwitcher = Notification.Name("attache.openCharacterSwitcher")
    static let attacheOpenInbox = Notification.Name("attache.openInbox")
    static let attacheOpenShortcuts = Notification.Name("attache.openShortcuts")
    static let attachePlayCard = Notification.Name("attache.playCard")
    static let attacheFocusSession = Notification.Name("attache.focusSession")
    static let attacheOpenSettingsSection = Notification.Name("attache.openSettingsSection")
    static let attacheOpenPersonalityStudio = Notification.Name("attache.openPersonalityStudio")
    static let attacheOpenActivitySimulator = Notification.Name("attache.openActivitySimulator")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var windowController: AttacheWindowController?
    private var miniWindowController: MiniAttacheWindowController?
    private var cancellables: Set<AnyCancellable> = []
    // Sparkle keeps the app current without pestering: a quiet background check
    // and one prompt only when an update is actually available. Feed URL and the
    // update-signing public key live in Info.plist (set by package-app.sh).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /// Marketing version (CFBundleShortVersionString) shown in the menu and the
    /// About panel so users can see, at a glance, which build they are on.
    private static let shortVersionString: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        AttacheTheme.auditContrastFloor()
        #endif
        AttacheNotifier.shared.configure()
        OptionKeyMonitor.shared.start()
        updateAppIcon()
        setupMainMenu()
        if model.showInMenuBar { setupStatusItem() }
        setupWindow()
        bindModel()
        // The production memory runtime publishes its initial snapshot from a
        // main-actor task. Install deterministic AX fixtures on the following
        // turn so that startup publication cannot erase the smoke state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AttacheContextSmokeFixtures.installIfRequested(model: self.model)
        }
        updateDockBadge()
        requestNotificationPermissionIfUseful()
        model.startEventServer()
        model.mainThreadWatchdog.start()
        windowController?.showAttache()
        NotificationCenter.default.addObserver(forName: .attacheOpenSettings, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.windowController?.showAttache()
            NSApp.activate(ignoringOtherApps: true)
            self.model.showSettingsOverlay()
        }
        NotificationCenter.default.addObserver(forName: .attacheOpenSettingsSection, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.object as? String,
                  let section = SettingsSection(rawValue: raw) else { return }
            self?.model.activeSettingsSection = section
        }
        NotificationCenter.default.addObserver(forName: .attacheOpenPersonalityStudio, object: nil, queue: .main) { [weak self] note in
            guard let self, let request = note.object as? PersonalityStudioRequest else { return }
            self.windowController?.showAttache()
            NSApp.activate(ignoringOtherApps: true)
            self.model.openCharacterStudio(request)
        }
        NotificationCenter.default.addObserver(forName: .attacheShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            self?.windowController?.showAttache()
            self?.model.startOnboarding()
        }
        NotificationCenter.default.addObserver(forName: .attacheShowMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.windowController?.showAttache()
        }
        model.$miniAttacheEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.applyMiniAttache(enabled)
            }
            .store(in: &cancellables)
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateAppIcon() }
    }

    /// The live Dock icon follows both the system appearance and Attaché theme.
    /// The bundled `.icns` stays static so Finder and release assets are stable.
    private func updateAppIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let image = AttacheAppIcon.image(dark: isDark, theme: model.theme)
        NSApp.applicationIconImage = image

        let tileSize = NSApp.dockTile.size
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: tileSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = imageView
        NSApp.dockTile.display()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showAttache()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: AttacheAppSupport.appDisplayName)
        item.button?.imagePosition = .imageLeading
        updateStatusTitle()
        rebuildMenu()
    }

    private func setupWindow() {
        windowController = AttacheWindowController(model: model)
    }

    private func applyMiniAttache(_ enabled: Bool) {
        if enabled {
            if miniWindowController == nil {
                miniWindowController = MiniAttacheWindowController(model: model)
            }
            miniWindowController?.show()
        } else {
            miniWindowController?.hide()
        }
        rebuildMenu()
    }

    @objc private func toggleMiniAttache() {
        model.miniAttacheEnabled.toggle()
    }

    @objc private func toggleMiniClickThrough() {
        model.miniAttacheClickThrough.toggle()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: NSLocalizedString("About Attaché", comment: ""), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(toggleSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let updatesItem = NSMenuItem(
            title: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = updaterController
        appMenu.addItem(updatesItem)
        let inboxItem = NSMenuItem(title: NSLocalizedString("Open Inbox", comment: ""), action: #selector(openInbox), keyEquivalent: "i")
        inboxItem.target = self
        appMenu.addItem(inboxItem)
        let notificationsItem = NSMenuItem(title: NSLocalizedString("Enable Notifications…", comment: ""), action: #selector(enableNotifications), keyEquivalent: "")
        notificationsItem.target = self
        appMenu.addItem(notificationsItem)
        let talkItem = NSMenuItem(title: NSLocalizedString("Call / Hang Up", comment: ""), action: #selector(openTalk), keyEquivalent: "l")
        talkItem.target = self
        appMenu.addItem(talkItem)
        let paletteItem = NSMenuItem(title: NSLocalizedString("Find Session…", comment: ""), action: #selector(openPalette), keyEquivalent: "k")
        paletteItem.target = self
        appMenu.addItem(paletteItem)
        let characterItem = NSMenuItem(title: NSLocalizedString("Switch Attaché…", comment: ""), action: #selector(openCharacterSwitcher), keyEquivalent: "p")
        characterItem.keyEquivalentModifierMask = [.command, .shift]
        characterItem.target = self
        appMenu.addItem(characterItem)
        let historyItem = NSMenuItem(title: NSLocalizedString("History…", comment: ""), action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        appMenu.addItem(historyItem)
        let previousPersonalityItem = NSMenuItem(title: NSLocalizedString("Previous Personality", comment: ""), action: #selector(previousPersonality), keyEquivalent: "[")
        previousPersonalityItem.target = self
        appMenu.addItem(previousPersonalityItem)
        let nextPersonalityItem = NSMenuItem(title: NSLocalizedString("Next Personality", comment: ""), action: #selector(nextPersonality), keyEquivalent: "]")
        nextPersonalityItem.target = self
        appMenu.addItem(nextPersonalityItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(AttacheAppSupport.appDisplayName)", action: #selector(quit), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let welcomeItem = NSMenuItem(title: NSLocalizedString("Welcome to Attaché…", comment: ""), action: #selector(showOnboarding), keyEquivalent: "")
        welcomeItem.target = self
        helpMenu.addItem(welcomeItem)
        let shortcutsItem = NSMenuItem(title: NSLocalizedString("Keyboard Shortcuts", comment: ""), action: #selector(openShortcuts), keyEquivalent: "/")
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func requestNotificationPermissionIfUseful() {
        guard model.unreadCount > 0 || model.voicemailMode else { return }
        AttacheNotifier.shared.requestAuthorizationIfUndetermined { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateDockBadge()
            }
        }
    }

    private func bindModel() {
        model.$cards
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.updateDockBadge()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$voicemailMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$sessionAttention
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$attachedTargets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$showInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.applyMenuBarVisibility(visible)
            }
            .store(in: &cancellables)

        model.$miniAttacheClickThrough
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$globalHotKeySpec
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spec in
                self?.applyGlobalHotKey(spec)
            }
            .store(in: &cancellables)
    }

    /// The state Attaché believes is currently registered with the OS
    /// (INF-365). Driven purely by `GlobalHotKeyStateMachine` so set/replace/
    /// clear all go through the same tested transition logic; this method
    /// only performs the Carbon side effects the transition dictates.
    private var globalHotKeyRegistration: GlobalHotKeyRegistrationState = .unregistered

    private func applyGlobalHotKey(_ spec: GlobalHotKeySpec?) {
        let transition = GlobalHotKeyStateMachine.apply(spec, to: globalHotKeyRegistration)
        if transition.shouldUnregisterPrevious {
            GlobalHotKeyMonitor.shared.unregister()
        }
        if let newSpec = transition.shouldRegister {
            GlobalHotKeyMonitor.shared.register(newSpec) { [weak self] in
                self?.windowController?.showAttache()
            }
        }
        globalHotKeyRegistration = transition.next
    }

    private var cachedBrandTemplate: NSImage?

    /// The Attaché lockup as a monochrome menu bar template, rendered once.
    /// AppDelegate work happens on the main thread; assumeIsolated makes that
    /// explicit for the MainActor-bound SwiftUI renderer.
    private func brandTemplateImage() -> NSImage? {
        if let cachedBrandTemplate { return cachedBrandTemplate }
        let rendered = MainActor.assumeIsolated { () -> NSImage? in
            let renderer = ImageRenderer(content:
                AttacheMascotMark(monochrome: .black, headOnly: true)
                    .frame(width: 18, height: 18)
            )
            renderer.scale = 2
            return renderer.nsImage
        }
        guard let image = rendered else { return nil }
        image.isTemplate = true
        cachedBrandTemplate = image
        return image
    }

    private func updateStatusTitle() {
        let unread = model.unreadCount
        statusItem?.button?.title = unread > 0 ? " \(unread)" : ""
        // The most urgent state wins the icon: an agent waiting on the user
        // shows the alert, otherwise the monochrome Attaché mark.
        if model.anyWatchedSessionNeedsUser {
            statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: AttacheAppSupport.appDisplayName)
        } else if let brand = brandTemplateImage() {
            statusItem?.button?.image = brand
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: AttacheAppSupport.appDisplayName)
        }
    }

    /// One glanceable line at the top of the status menu.
    private var fleetSummary: String {
        let watched = model.attachedTargets.count
        guard watched > 0 else { return "Not watching any sessions" }
        var line = "Watching \(watched)"
        if let state = model.fleetStateSummary {
            line += " · \(state)"
        }
        return line
    }

    private func updateDockBadge() {
        let unread = model.unreadCount
        applyDockBadge(count: unread)
        reapplyDockBadge(count: unread, after: 0.5)
        reapplyDockBadge(count: unread, after: 2.0)
    }

    private func applyDockBadge(count unread: Int) {
        guard unread > 0 else {
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.badgeLabel = nil
            AttacheNotifier.shared.setApplicationBadgeCount(0)
            return
        }

        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        AttacheNotifier.shared.setApplicationBadgeCount(unread)

        AttacheNotifier.shared.canUseNativeApplicationBadge { [weak self] canUseNativeBadge in
            DispatchQueue.main.async {
                guard let self, self.model.unreadCount == unread else { return }
                guard canUseNativeBadge else { return }
                NSApp.dockTile.contentView = nil
                NSApp.dockTile.badgeLabel = nil
                AttacheNotifier.shared.setApplicationBadgeCount(unread)
            }
        }
    }

    private func reapplyDockBadge(count: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.model.unreadCount == count else { return }
            self.applyDockBadge(count: count)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let versionItem = NSMenuItem(title: "\(AttacheAppSupport.appDisplayName) \(Self.shortVersionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        let summaryItem = NSMenuItem(title: fleetSummary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        if !model.attachedTargets.isEmpty {
            let focusMenu = NSMenu()
            let ordered = model.attachedTargets.values.sorted { $0.displayTitle < $1.displayTitle }
            for target in ordered {
                let state = model.sessionAttention[target.id]
                let marker: String
                if state?.needsUser == true { marker = "needs you" }
                else if state == .active { marker = "running" }
                else { marker = "" }
                let unread = model.unreadCount(forSessionID: target.id)
                var title = target.displayTitle
                if unread > 0 { title += "  (\(unread))" }
                if !marker.isEmpty { title += "  · \(marker)" }
                let item = NSMenuItem(title: title, action: #selector(focusSessionFromMenu(_:)), keyEquivalent: "")
                item.representedObject = target.id
                item.state = target.id == model.attachedCodexSessionID ? .on : .off
                item.target = self
                focusMenu.addItem(item)
            }
            let focusItem = NSMenuItem(title: NSLocalizedString("Focus Session", comment: ""), action: nil, keyEquivalent: "")
            focusItem.submenu = focusMenu
            menu.addItem(focusItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Open Attaché", comment: ""), action: #selector(openAttache), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Open Inbox", comment: ""), action: #selector(openInbox), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Find Session…", comment: ""), action: #selector(openPalette), keyEquivalent: "k"))
        let characterItem = NSMenuItem(title: NSLocalizedString("Switch Attaché…", comment: ""), action: #selector(openCharacterSwitcher), keyEquivalent: "p")
        characterItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(characterItem)
        menu.addItem(NSMenuItem(title: NSLocalizedString("Previous Personality", comment: ""), action: #selector(previousPersonality), keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Next Personality", comment: ""), action: #selector(nextPersonality), keyEquivalent: "]"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Keyboard Shortcuts", comment: ""), action: #selector(openShortcuts), keyEquivalent: "/"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Enable Notifications…", comment: ""), action: #selector(enableNotifications), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(toggleSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Add sample voicemail", comment: ""), action: #selector(simulateEvent), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Mark All Heard", comment: ""), action: #selector(markAllHeard), keyEquivalent: "h"))
        menu.addItem(.separator())
        let modeTitle = model.voicemailMode ? "Go Live (narrate updates aloud)" : "Go Quiet (send updates to Inbox)"
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(toggleVoicemailMode), keyEquivalent: "")
        menu.addItem(modeItem)
        menu.addItem(.separator())
        // The mini attache's guaranteed control path: with click-through on,
        // the floating window ignores every event, so the menu bar is how you
        // get it back (INF-272).
        let miniItem = NSMenuItem(
            title: NSLocalizedString(model.miniAttacheEnabled ? "Hide Mini Window" : "Show Mini Window", comment: ""),
            action: #selector(toggleMiniAttache),
            keyEquivalent: ""
        )
        menu.addItem(miniItem)
        if model.miniAttacheEnabled {
            let clickThroughItem = NSMenuItem(
                title: NSLocalizedString("Mini Window Click-Through", comment: ""),
                action: #selector(toggleMiniClickThrough),
                keyEquivalent: ""
            )
            clickThroughItem.state = model.miniAttacheClickThrough ? .on : .off
            menu.addItem(clickThroughItem)
        }
        menu.addItem(.separator())
        let checkUpdatesItem = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""), action: #selector(showUpdates), keyEquivalent: "")
        menu.addItem(checkUpdatesItem)
        menu.addItem(NSMenuItem(title: "Quit \(AttacheAppSupport.appDisplayName)", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    @objc private func openAttache() {
        windowController?.showAttache()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AttacheAppSupport.appDisplayName,
            .applicationVersion: Self.shortVersionString,
            .version: ""
        ])
    }

    @objc private func showUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func focusSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        windowController?.showAttache()
        model.focusCodexSession(id)
    }

    private func applyMenuBarVisibility(_ visible: Bool) {
        if visible {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func showOnboarding() {
        windowController?.showAttache()
        model.startOnboarding()
    }

    /// Command-comma toggles the in-window Settings overlay (INF-377): open when
    /// closed, close when open. Bringing the main window forward first ensures
    /// the overlay is visible when triggered from the menu bar or another app.
    @objc private func toggleSettings() {
        AttacheLog.uiLatency.withIntervalSignpost("toggleSettings") {
            windowController?.showAttache()
            NSApp.activate(ignoringOtherApps: true)
            model.toggleSettingsOverlay()
        }
    }

    @objc private func simulateEvent() {
        model.simulateEvent()
        windowController?.showAttache()
    }

    @objc private func markAllHeard() {
        model.markAllHeard()
    }

    @objc private func toggleVoicemailMode() {
        model.toggleVoicemailMode()
    }

    @objc private func openTalk() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenTalk, object: nil)
    }

    @objc private func openHistory() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenHistory, object: nil)
    }

    @objc private func openPalette() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
    }

    @objc private func openCharacterSwitcher() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenCharacterSwitcher, object: nil)
    }

    @objc private func openShortcuts() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenShortcuts, object: nil)
    }

    @objc private func previousPersonality() {
        model.selectAdjacentPersonality(offset: -1)
        windowController?.showAttache()
    }

    @objc private func nextPersonality() {
        model.selectAdjacentPersonality(offset: 1)
        windowController?.showAttache()
    }

    @objc private func openInbox() {
        windowController?.showAttache()
        NotificationCenter.default.post(name: .attacheOpenInbox, object: nil)
    }

    @objc private func enableNotifications() {
        AttacheNotifier.shared.requestAuthorization { [weak self] state in
            DispatchQueue.main.async {
                self?.updateDockBadge()
                if state.shouldOpenSystemSettings {
                    AttacheNotifier.shared.openSystemNotificationSettings()
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
