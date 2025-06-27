import Cocoa
import ObjectiveC

class MenuBuilder: NSObject, NSMenuDelegate {
    private var menuItems: [NSMenuItem] = []
    private var actions: [UUID: () -> Void] = [:]
    private var highlightActions: [UUID: (Bool) -> Void] = [:]
    private static let associationKey = "MenuBuilder"
    private var previousHighlight: UUID?

    func addItem(
        label: String,
        checked: Bool = false,
        alternateForModifiers: NSEvent.ModifierFlags = [],
        action: @escaping () -> Void,
        onHighlight: ((Bool) -> Void)? = nil,
    ) {
        let item = NSMenuItem(title: label, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        let uuid = UUID()
        item.representedObject = uuid
        item.state = checked ? .on : .off

        if alternateForModifiers != [] {
            item.isAlternate = true
            item.keyEquivalentModifierMask = alternateForModifiers
        }

        actions[uuid] = action
        highlightActions[uuid] = onHighlight
        menuItems.append(item)
    }

    func addSeparator() {
        menuItems.append(.separator())
    }

    func addHeader(_ title: String) {
        menuItems.append(.sectionHeader(title: title))
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        objc_setAssociatedObject(menu, Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN)
        menu.delegate = self
        for item in menuItems {
            menu.addItem(item)
        }
        return menu
    }

    @objc func performAction(_ sender: NSMenuItem) {
        if let uuid = sender.representedObject as? UUID, let action = actions[uuid] {
            action()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let uuid = previousHighlight, let highlightAction = highlightActions[uuid] {
            highlightAction(false)
            previousHighlight = nil
        }
    }

    @objc func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let uuid = previousHighlight, let highlightAction = highlightActions[uuid] {
            highlightAction(false)
            previousHighlight = nil
        }
        if let item, let uuid = item.representedObject as? UUID, let highlightAction = highlightActions[uuid] {
            previousHighlight = uuid
            highlightAction(true)
        }
    }
}
