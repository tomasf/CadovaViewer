import Cocoa
import ObjectiveC

class MenuBuilder: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private var menuItems: [NSMenuItem] = []
    private var actions: [UUID: () -> Void] = [:]
    private var highlightActions: [UUID: (Bool, Bool) -> Void] = [:]
    private var enabledStates: [UUID: Bool] = [:]
    private var asyncIcons: [(item: NSMenuItem, provider: AsyncIconProvider)] = []
    private var previousHighlight: UUID?

    /// Produces an item's icon asynchronously. Lets a menu open immediately and fill in icons that are
    /// expensive to render — updating an item's `image` while its menu is open refreshes the row in
    /// place.
    typealias AsyncIconProvider = () async -> NSImage?

    func addItem(
        label: String,
        icon: NSImage? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        isAlternate: Bool = false,
        action: (() -> Void)? = nil,
        onHighlight: ((_ highlighted: Bool, _ isClosing: Bool) -> Void)? = nil,
        submenu: ((_ builder: MenuBuilder) -> ())? = nil,
        // Declared last so it doesn't sit ahead of `action` in the trailing-closure forward scan,
        // which would steal the bare `{ … }` action closures callers pass.
        asyncIcon: AsyncIconProvider? = nil
    ) {
        let item = NSMenuItem(title: label, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        let uuid = UUID()
        item.representedObject = uuid
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.keyEquivalent = keyEquivalent
        item.image = icon
        item.isAlternate = isAlternate

        if modifiers != [] {
            item.keyEquivalentModifierMask = modifiers
        }

        if let submenu {
            let subbuilder = MenuBuilder()
            submenu(subbuilder)
            item.submenu = subbuilder.makeMenu()
        }

        actions[uuid] = action
        highlightActions[uuid] = onHighlight
        enabledStates[uuid] = enabled
        if let asyncIcon {
            asyncIcons.append((item, asyncIcon))
        }
        menuItems.append(item)
    }

    // The host menus auto-enable items (they re-enable anything whose target responds to the
    // action), which would ignore our `enabled:` flag — so honour it here instead.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let uuid = menuItem.representedObject as? UUID else { return true }
        return enabledStates[uuid] ?? true
    }

    func addSeparator() {
        menuItems.append(.separator())
    }

    func addHeader(_ title: String) {
        menuItems.append(.sectionHeader(title: title))
    }

    private static let associationKey = "MenuBuilder"
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        objc_setAssociatedObject(menu, Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN)
        menu.delegate = self
        for item in menuItems {
            menu.addItem(item)
        }
        // Kick off async icon rendering now that the menu exists; each result is set on its item in
        // place, so icons appear whether the render lands before or after the menu is on screen.
        //
        // Deliberately off the main actor: a context menu spins the run loop in
        // `NSEventTrackingRunLoopMode`, which doesn't service the main-queue (main-actor) executor, so
        // a `Task { @MainActor }` continuation can't resume until the menu closes. Instead render off
        // the main actor (the provider must too) and assign `item.image` via a run-loop perform in
        // tracking-live modes, which NSMenu picks up and redraws while the menu is open.
        for (item, provider) in asyncIcons {
            // Only ever assigned on the main thread inside the perform block below.
            nonisolated(unsafe) let item = item
            Task.detached {
                guard let image = await provider() else { return }
                RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
                    item.image = image
                }
            }
        }
        return menu
    }

    func insert(into menu: NSMenu, after item: NSMenuItem) {
        guard var index: Int = menu.items.firstIndex(where: { $0 === item }) else {
            return
        }
        for item in menuItems {
            index += 1
            menu.insertItem(item, at: index)
        }
    }

    @objc func performAction(_ sender: NSMenuItem) {
        if let uuid = sender.representedObject as? UUID, let action = actions[uuid] {
            action()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let uuid = previousHighlight, let highlightAction = highlightActions[uuid] {
            highlightAction(false, true)
            previousHighlight = nil
        }
    }

    @objc func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let uuid = previousHighlight, let highlightAction = highlightActions[uuid] {
            highlightAction(false, false)
            previousHighlight = nil
        }
        if let item, let uuid = item.representedObject as? UUID, let highlightAction = highlightActions[uuid] {
            previousHighlight = uuid
            highlightAction(true, false)
        }
    }
}
