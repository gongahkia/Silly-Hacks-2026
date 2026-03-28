import AppKit
import AngyCore
import Foundation

@MainActor
final class AngyHiveCoordinator: NSObject, NSMenuDelegate {
    private let config: AppConfig
    private let debugMonitor = DebugMonitor.shared
    private let windowCatalogService = WindowCatalogService()
    private let hateMailWriter = HateMailWriter()
    private let primaryController: AngyInstanceController

    private var spawnedControllers: [AngyInstanceID: AngyInstanceController] = [:]
    private var spawnedOrder: [AngyInstanceID] = []
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var controlPlaneServer: AngyControlPlaneServer?
    private var globalPauseAll = false
    private var hateMailEnabled = false
    private var statusMessage: String?
    private var isStatusMenuOpen = false
    private var needsStatusMenuRebuild = false

    init(config: AppConfig) {
        self.config = config
        self.primaryController = AngyInstanceController(
            id: AngyInstanceID(rawValue: "primary"),
            role: .primary,
            config: config,
            trackingSource: WindowTracker(config: config),
            managesPermissions: true,
            warmStickersOnStart: true,
            allowsDisplayLinkedRefresh: true,
            autoRemoveWhenTargetLost: false
        )
        super.init()
    }

    func start() {
        debugMonitor.announceIfEnabled()
        bindCallbacks(for: primaryController)
        primaryController.start()
        configureStatusItem()
        requestStatusMenuRebuild()
        startControlPlaneServer()
    }

    func stop() {
        controlPlaneServer?.stop()
        controlPlaneServer = nil

        primaryController.stop()
        for controller in spawnedControllers.values {
            controller.stop()
        }
        spawnedControllers.removeAll()
        spawnedOrder.removeAll()
        statusItem?.menu = nil
        statusItem = nil
        statusMenu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        isStatusMenuOpen = true
        rebuildStatusMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isStatusMenuOpen = false

        guard needsStatusMenuRebuild else {
            return
        }

        needsStatusMenuRebuild = false
        rebuildStatusMenu()
    }

    func handle(request: AngyControlRequest) async -> AngyControlResponse {
        switch request.action {
        case .listWindows:
            return AngyControlResponse(ok: true, windows: availableWindows().map(AngyWindowRef.init(window:)))
        case .listInstances:
            return AngyControlResponse(ok: true, instances: instanceSnapshots())
        case .spawnFrontmost:
            guard let window = windowCatalogService.frontmostWindow() else {
                return failure("No eligible frontmost window is available.")
            }
            return spawn(on: window)
        case .spawnWindow:
            guard let windowID = request.windowID,
                  let window = windowCatalogService.window(windowID: windowID) else {
                return failure("That window is no longer available.")
            }
            return spawn(on: window)
        case .removeInstance:
            guard let controller = resolveController(request: request), controller.role == .spawned else {
                return failure("Only spawned Angys can be removed.")
            }
            removeSpawned(id: controller.id)
            return AngyControlResponse(ok: true, message: "Removed \(controller.snapshot().tag ?? controller.id.rawValue).", instances: instanceSnapshots())
        case .pauseInstance:
            guard let controller = resolveController(request: request) else {
                return failure("That Angy could not be found.")
            }
            controller.pause()
            return AngyControlResponse(ok: true, message: "Paused \(displayName(for: controller.snapshot())).", instances: instanceSnapshots())
        case .resumeInstance:
            guard let controller = resolveController(request: request) else {
                return failure("That Angy could not be found.")
            }
            controller.resume()
            return AngyControlResponse(ok: true, message: "Resumed \(displayName(for: controller.snapshot())).", instances: instanceSnapshots())
        case .pauseAll:
            globalPauseAll = true
            primaryController.pause()
            for controller in spawnedControllers.values {
                controller.pause()
            }
            requestStatusMenuRebuild()
            return AngyControlResponse(ok: true, message: "Paused all Angys.", instances: instanceSnapshots(), settings: settingsSnapshot())
        case .resumeAll:
            globalPauseAll = false
            primaryController.resume()
            for controller in spawnedControllers.values {
                controller.resume()
            }
            requestStatusMenuRebuild()
            return AngyControlResponse(ok: true, message: "Resumed all Angys.", instances: instanceSnapshots(), settings: settingsSnapshot())
        case .retargetInstance:
            guard let controller = resolveController(request: request), controller.role == .spawned else {
                return failure("Only spawned Angys can be retargeted.")
            }
            guard let windowID = request.windowID,
                  let window = windowCatalogService.window(windowID: windowID) else {
                return failure("That window is no longer available.")
            }
            guard !isWindowAttached(window.windowID, excluding: controller.id) else {
                return failure("An Angy is already attached to that window.")
            }
            controller.setTrackingSource(
                PinnedWindowTracker(
                    windowID: window.windowID,
                    refreshInterval: config.spawnedWindowRefreshInterval
                )
            )
            return AngyControlResponse(ok: true, message: "Retargeted \(displayName(for: controller.snapshot())).", instances: instanceSnapshots())
        case .setOverrideState:
            guard let controller = resolveController(request: request),
                  let overrideState = request.overrideState else {
                return failure("A valid Angy and override state are required.")
            }
            controller.setOverrideState(overrideState)
            return AngyControlResponse(ok: true, message: "Set \(displayName(for: controller.snapshot())) to \(overrideState.rawValue).", instances: instanceSnapshots())
        case .clearOverrideState:
            guard let controller = resolveController(request: request) else {
                return failure("That Angy could not be found.")
            }
            controller.clearOverrideState()
            return AngyControlResponse(ok: true, message: "Returned \(displayName(for: controller.snapshot())) to automatic mode.", instances: instanceSnapshots())
        case .explodeInstance:
            guard let controller = resolveController(request: request) else {
                return failure("That Angy could not be found.")
            }
            guard controller.forceExplosion() else {
                return failure("That Angy cannot explode right now.")
            }
            return AngyControlResponse(ok: true, message: "Triggered explosion for \(displayName(for: controller.snapshot())).", instances: instanceSnapshots())
        case .writeHateMail:
            guard let controller = resolveController(request: request) else {
                return failure("That Angy could not be found.")
            }
            do {
                let url = try await hateMailWriter.writeMail(
                    for: controller.snapshot(),
                    config: config,
                    enabled: hateMailEnabled
                )
                statusMessage = "Wrote hate mail to \(url.lastPathComponent)."
                requestStatusMenuRebuild()
                return AngyControlResponse(ok: true, message: "Wrote hate mail to \(url.path).")
            } catch {
                return failure(error.localizedDescription)
            }
        case .getSettings:
            return AngyControlResponse(ok: true, settings: settingsSnapshot())
        case .setSetting:
            guard let settingKey = request.settingKey,
                  let settingValue = request.settingValue else {
                return failure("Both setting key and value are required.")
            }
            return await setSetting(key: settingKey, value: settingValue)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Angy"

        let menu = NSMenu(title: "Angy")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        statusItem = item
        statusMenu = menu
    }

    private func rebuildStatusMenu() {
        guard let statusMenu else {
            return
        }

        statusMenu.removeAllItems()

        let totalInstances = 1 + spawnedControllers.count
        let header = NSMenuItem(
            title: "Angy • \(totalInstances) total • \(globalPauseAll ? "paused" : "running")",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        statusMenu.addItem(header)

        if let statusMessage, !statusMessage.isEmpty {
            let messageItem = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
            messageItem.isEnabled = false
            statusMenu.addItem(messageItem)
        }

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(menuItem(title: "Spawn on Frontmost Window", request: AngyControlRequest(action: .spawnFrontmost)))

        let attachMenuItem = NSMenuItem(title: "Attach to Window", action: nil, keyEquivalent: "")
        let attachMenu = NSMenu(title: "Attach to Window")
        let attachedWindowIDs = Set(instanceSnapshots().compactMap { $0.target?.windowID })
        let visibleWindows = availableWindows().filter { !attachedWindowIDs.contains($0.windowID) }
        if visibleWindows.isEmpty {
            let emptyItem = NSMenuItem(title: "No eligible windows", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            attachMenu.addItem(emptyItem)
        } else {
            for window in visibleWindows {
                let title = windowMenuTitle(for: window)
                attachMenu.addItem(
                    menuItem(
                        title: title,
                        request: AngyControlRequest(action: .spawnWindow, windowID: window.windowID)
                    )
                )
            }
        }
        attachMenuItem.submenu = attachMenu
        statusMenu.addItem(attachMenuItem)

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(
            menuItem(
                title: globalPauseAll ? "Resume All" : "Pause All",
                request: AngyControlRequest(action: globalPauseAll ? .resumeAll : .pauseAll)
            )
        )
        statusMenu.addItem(
            menuItem(
                title: hateMailEnabled ? "Disable Hate Mail" : "Enable Hate Mail",
                request: AngyControlRequest(
                    action: .setSetting,
                    settingKey: "hateMailEnabled",
                    settingValue: hateMailEnabled ? "false" : "true"
                )
            )
        )

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(instanceMenuItem(for: primaryController.snapshot()))

        for snapshot in spawnedSnapshots() {
            statusMenu.addItem(instanceMenuItem(for: snapshot))
        }

        statusMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(handleQuit(_:)), keyEquivalent: "")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func requestStatusMenuRebuild() {
        if isStatusMenuOpen {
            needsStatusMenuRebuild = true
            return
        }

        rebuildStatusMenu()
    }

    private func instanceMenuItem(for snapshot: AngyInstanceSnapshot) -> NSMenuItem {
        let title = displayName(for: snapshot)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)

        let targetItem = NSMenuItem(title: windowMenuTitle(for: snapshot.target), action: nil, keyEquivalent: "")
        targetItem.isEnabled = false
        submenu.addItem(targetItem)

        submenu.addItem(
            menuItem(
                title: snapshot.paused ? "Resume" : "Pause",
                request: AngyControlRequest(
                    action: snapshot.paused ? .resumeInstance : .pauseInstance,
                    instanceID: snapshot.id
                )
            )
        )
        submenu.addItem(
            menuItem(
                title: "Explode",
                request: AngyControlRequest(action: .explodeInstance, instanceID: snapshot.id)
            )
        )
        submenu.addItem(
            menuItem(
                title: "Write Hate Mail",
                request: AngyControlRequest(action: .writeHateMail, instanceID: snapshot.id)
            )
        )

        let statesSubmenuItem = NSMenuItem(title: "Set State", action: nil, keyEquivalent: "")
        let statesSubmenu = NSMenu(title: "Set State")
        statesSubmenu.addItem(
            menuItem(
                title: "Automatic",
                request: AngyControlRequest(action: .clearOverrideState, instanceID: snapshot.id)
            )
        )
        for state in CompanionState.allCases {
            statesSubmenu.addItem(
                menuItem(
                    title: state.rawValue.capitalized,
                    request: AngyControlRequest(action: .setOverrideState, instanceID: snapshot.id, overrideState: state)
                )
            )
        }
        statesSubmenuItem.submenu = statesSubmenu
        submenu.addItem(statesSubmenuItem)

        if snapshot.role == .spawned {
            submenu.addItem(
                menuItem(
                    title: "Retarget to Frontmost Window",
                    request: AngyControlRequest(action: .retargetInstance, instanceID: snapshot.id, windowID: windowCatalogService.frontmostWindow()?.windowID)
                )
            )
            submenu.addItem(
                menuItem(
                    title: "Remove",
                    request: AngyControlRequest(action: .removeInstance, instanceID: snapshot.id)
                )
            )
        }

        item.submenu = submenu
        return item
    }

    private func bindCallbacks(for controller: AngyInstanceController) {
        controller.onSnapshotChange = { [weak self] _ in
            self?.requestStatusMenuRebuild()
        }
        controller.onExplosion = { [weak self] snapshot in
            guard let self else {
                return
            }

            Task {
                do {
                    _ = try await self.hateMailWriter.writeMail(
                        for: snapshot,
                        config: self.config,
                        enabled: self.hateMailEnabled
                    )
                    await MainActor.run {
                        self.statusMessage = "Angy \(snapshot.tag ?? "Primary") left hate mail."
                        self.requestStatusMenuRebuild()
                    }
                } catch HateMailWriterError.featureDisabled, HateMailWriterError.coolingDown {
                    return
                } catch {
                    await MainActor.run {
                        self.statusMessage = error.localizedDescription
                        self.requestStatusMenuRebuild()
                    }
                }
            }
        }
        controller.onTargetLost = { [weak self] instanceID in
            self?.removeSpawned(id: instanceID)
        }
    }

    private func spawn(on window: TrackedWindow) -> AngyControlResponse {
        guard !isWindowAttached(window.windowID, excluding: nil) else {
            return failure("An Angy is already attached to that window.")
        }

        let instanceID = AngyInstanceID(rawValue: UUID().uuidString.lowercased())
        let controller = AngyInstanceController(
            id: instanceID,
            role: .spawned,
            config: config,
            trackingSource: PinnedWindowTracker(
                windowID: window.windowID,
                refreshInterval: config.spawnedWindowRefreshInterval
            ),
            managesPermissions: false,
            warmStickersOnStart: false,
            allowsDisplayLinkedRefresh: false,
            autoRemoveWhenTargetLost: true
        )
        bindCallbacks(for: controller)
        spawnedControllers[instanceID] = controller
        spawnedOrder.append(instanceID)
        recomputeSpawnedTags()
        if globalPauseAll {
            controller.pause()
        }
        controller.start()

        let snapshot = controller.snapshot()
        statusMessage = "Spawned \(displayName(for: snapshot))."
        requestStatusMenuRebuild()
        return AngyControlResponse(ok: true, message: statusMessage, instances: instanceSnapshots())
    }

    private func removeSpawned(id: AngyInstanceID) {
        guard let controller = spawnedControllers.removeValue(forKey: id) else {
            return
        }

        controller.stop()
        spawnedOrder.removeAll { $0 == id }
        recomputeSpawnedTags()
        statusMessage = "Removed \(controller.snapshot().tag ?? id.rawValue)."
        requestStatusMenuRebuild()
    }

    private func recomputeSpawnedTags() {
        for (index, instanceID) in spawnedOrder.enumerated() {
            spawnedControllers[instanceID]?.setDisplayTag("#\(index + 1)")
        }
    }

    private func resolveController(request: AngyControlRequest) -> AngyInstanceController? {
        if let instanceID = request.instanceID {
            if instanceID == primaryController.id {
                return primaryController
            }
            return spawnedControllers[instanceID]
        }

        if let instanceTag = request.instanceTag {
            return spawnedControllers.values.first(where: { $0.snapshot().tag == instanceTag })
        }

        return nil
    }

    private func instanceSnapshots() -> [AngyInstanceSnapshot] {
        [primaryController.snapshot()] + spawnedSnapshots()
    }

    private func spawnedSnapshots() -> [AngyInstanceSnapshot] {
        spawnedOrder.compactMap { spawnedControllers[$0]?.snapshot() }
    }

    private func availableWindows() -> [TrackedWindow] {
        windowCatalogService.visibleWindows()
    }

    private func settingsSnapshot() -> AngyGlobalSettingsSnapshot {
        AngyGlobalSettingsSnapshot(
            pauseAll: globalPauseAll,
            hateMailEnabled: hateMailEnabled,
            soundEnabled: config.soundEnabled
        )
    }

    private func isWindowAttached(_ windowID: UInt32, excluding instanceID: AngyInstanceID?) -> Bool {
        for snapshot in instanceSnapshots() where snapshot.id != instanceID {
            if snapshot.target?.windowID == windowID {
                return true
            }
        }
        return false
    }

    private func displayName(for snapshot: AngyInstanceSnapshot) -> String {
        switch snapshot.role {
        case .primary:
            return "Primary"
        case .spawned:
            return snapshot.tag ?? snapshot.id.rawValue
        }
    }

    private func windowMenuTitle(for target: AngyWindowRef?) -> String {
        guard let target else {
            return "Detached"
        }

        let title = target.title?.isEmpty == false ? target.title! : "Untitled Window"
        return "\(target.appName) — \(title)"
    }

    private func windowMenuTitle(for window: TrackedWindow) -> String {
        let title = window.title?.isEmpty == false ? window.title! : "Untitled Window"
        return "\(window.appName) — \(title)"
    }

    private func menuItem(title: String, request: AngyControlRequest?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleMenuRequest(_:)), keyEquivalent: "")
        item.target = self
        if let request {
            item.representedObject = MenuRequestBox(request: request)
            item.isEnabled = true
        } else {
            item.isEnabled = false
        }
        return item
    }

    @objc
    private func handleMenuRequest(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuRequestBox else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let response = await handle(request: box.request)
            if let message = response.message {
                statusMessage = message
            }
            requestStatusMenuRebuild()
        }
    }

    @objc
    private func handleQuit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func startControlPlaneServer() {
        let server = AngyControlPlaneServer(config: config) { [weak self] request in
            guard let self else {
                return AngyControlResponse(ok: false, message: "Angy is shutting down.")
            }
            return await self.handle(request: request)
        }
        do {
            try server.start()
            controlPlaneServer = server
        } catch {
            statusMessage = error.localizedDescription
            requestStatusMenuRebuild()
        }
    }

    private func setSetting(key: String, value: String) async -> AngyControlResponse {
        switch key {
        case "hateMailEnabled":
            hateMailEnabled = (value as NSString).boolValue
            requestStatusMenuRebuild()
            return AngyControlResponse(ok: true, message: "Updated hateMailEnabled.", settings: settingsSnapshot())
        case "pauseAll":
            if (value as NSString).boolValue {
                return await handle(request: AngyControlRequest(action: .pauseAll))
            }
            return await handle(request: AngyControlRequest(action: .resumeAll))
        default:
            return failure("Unsupported setting key: \(key)")
        }
    }

    private func failure(_ message: String) -> AngyControlResponse {
        statusMessage = message
        requestStatusMenuRebuild()
        return AngyControlResponse(ok: false, message: message)
    }
}

private final class MenuRequestBox {
    let request: AngyControlRequest

    init(request: AngyControlRequest) {
        self.request = request
    }
}
