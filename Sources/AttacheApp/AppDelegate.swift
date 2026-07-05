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
    static let attacheOpenInbox = Notification.Name("attache.openInbox")
    static let attacheOpenShortcuts = Notification.Name("attache.openShortcuts")
    static let attachePlayCard = Notification.Name("attache.playCard")
    static let attacheFocusSession = Notification.Name("attache.focusSession")
    static let attacheOpenSettingsSection = Notification.Name("attache.openSettingsSection")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var windowController: CompanionWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    // Sparkle keeps the app current without pestering: a quiet background check
    // and one prompt only when an update is actually available. Feed URL and the
    // update-signing public key live in Info.plist (set by package-app.sh).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        CompanionTheme.auditContrastFloor()
        #endif
        CompanionNotifier.shared.configure()
        updateAppIcon()
        setupMainMenu()
        if model.showInMenuBar { setupStatusItem() }
        setupWindow()
        bindModel()
        updateDockBadge()
        requestNotificationPermissionIfUseful()
        model.startEventServer()
        windowController?.showCompanion()
        NotificationCenter.default.addObserver(forName: .attacheOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
        NotificationCenter.default.addObserver(forName: .attacheShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            self?.windowController?.showCompanion()
            self?.model.startOnboarding()
        }
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
        windowController?.showCompanion()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: CompanionAppSupport.appDisplayName)
        item.button?.imagePosition = .imageLeading
        updateStatusTitle()
        rebuildMenu()
    }

    private func setupWindow() {
        windowController = CompanionWindowController(model: model)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(showSettings), keyEquivalent: ",")
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
        appMenu.addItem(NSMenuItem(title: "Quit \(CompanionAppSupport.appDisplayName)", action: #selector(quit), keyEquivalent: "q"))
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
        CompanionNotifier.shared.requestAuthorizationIfUndetermined { [weak self] _ in
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
    }

    private var cachedBrandTemplate: NSImage?

    /// The Attaché lockup as a monochrome menu bar template, rendered once.
    /// AppDelegate work happens on the main thread; assumeIsolated makes that
    /// explicit for the MainActor-bound SwiftUI renderer.
    private func brandTemplateImage() -> NSImage? {
        if let cachedBrandTemplate { return cachedBrandTemplate }
        let rendered = MainActor.assumeIsolated { () -> NSImage? in
            let renderer = ImageRenderer(content:
                AttacheBrandMark(letterColor: .black, barColor: { _ in .black }, glow: .clear, glowStrength: 0)
                    .frame(width: 17, height: 18)
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
            statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: CompanionAppSupport.appDisplayName)
        } else if let brand = brandTemplateImage() {
            statusItem?.button?.image = brand
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: CompanionAppSupport.appDisplayName)
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
            CompanionNotifier.shared.setApplicationBadgeCount(0)
            return
        }

        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        CompanionNotifier.shared.setApplicationBadgeCount(unread)

        CompanionNotifier.shared.canUseNativeApplicationBadge { [weak self] canUseNativeBadge in
            DispatchQueue.main.async {
                guard let self, self.model.unreadCount == unread else { return }
                guard canUseNativeBadge else { return }
                NSApp.dockTile.contentView = nil
                NSApp.dockTile.badgeLabel = nil
                CompanionNotifier.shared.setApplicationBadgeCount(unread)
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
        menu.addItem(NSMenuItem(title: NSLocalizedString("Open Attaché", comment: ""), action: #selector(openCompanion), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Open Inbox", comment: ""), action: #selector(openInbox), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Find Session…", comment: ""), action: #selector(openPalette), keyEquivalent: "k"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Previous Personality", comment: ""), action: #selector(previousPersonality), keyEquivalent: "["))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Next Personality", comment: ""), action: #selector(nextPersonality), keyEquivalent: "]"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Keyboard Shortcuts", comment: ""), action: #selector(openShortcuts), keyEquivalent: "/"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Enable Notifications…", comment: ""), action: #selector(enableNotifications), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings…", comment: ""), action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Add sample voicemail", comment: ""), action: #selector(simulateEvent), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Mark All Heard", comment: ""), action: #selector(markAllHeard), keyEquivalent: "h"))
        menu.addItem(.separator())
        let modeTitle = model.voicemailMode ? "Go Live (narrate updates aloud)" : "Go Quiet (send updates to Inbox)"
        let modeItem = NSMenuItem(title: modeTitle, action: #selector(toggleVoicemailMode), keyEquivalent: "")
        menu.addItem(modeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(CompanionAppSupport.appDisplayName)", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    @objc private func openCompanion() {
        windowController?.showCompanion()
    }

    @objc private func focusSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        windowController?.showCompanion()
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
        windowController?.showCompanion()
        model.startOnboarding()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
        }
        settingsWindowController?.show()
    }

    @objc private func simulateEvent() {
        model.simulateEvent()
        windowController?.showCompanion()
    }

    @objc private func markAllHeard() {
        model.markAllHeard()
    }

    @objc private func toggleVoicemailMode() {
        model.toggleVoicemailMode()
    }

    @objc private func openTalk() {
        windowController?.showCompanion()
        NotificationCenter.default.post(name: .attacheOpenTalk, object: nil)
    }

    @objc private func openHistory() {
        windowController?.showCompanion()
        NotificationCenter.default.post(name: .attacheOpenHistory, object: nil)
    }

    @objc private func openPalette() {
        windowController?.showCompanion()
        NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
    }

    @objc private func openShortcuts() {
        windowController?.showCompanion()
        NotificationCenter.default.post(name: .attacheOpenShortcuts, object: nil)
    }

    @objc private func previousPersonality() {
        model.selectAdjacentPersonality(offset: -1)
        windowController?.showCompanion()
    }

    @objc private func nextPersonality() {
        model.selectAdjacentPersonality(offset: 1)
        windowController?.showCompanion()
    }

    @objc private func openInbox() {
        windowController?.showCompanion()
        NotificationCenter.default.post(name: .attacheOpenInbox, object: nil)
    }

    @objc private func enableNotifications() {
        CompanionNotifier.shared.requestAuthorization { [weak self] state in
            DispatchQueue.main.async {
                self?.updateDockBadge()
                if state.shouldOpenSystemSettings {
                    CompanionNotifier.shared.openSystemNotificationSettings()
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
