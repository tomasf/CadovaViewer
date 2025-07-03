import Cocoa

enum MenuType: Hashable {
    case file
    case view
    case window
}

class MenuController: NSObject, NSMenuDelegate {
    @IBOutlet var viewMenuStartMarker: NSMenuItem!
    @IBOutlet var viewMenuEndMarker: NSMenuItem!

    @IBOutlet var windowMenuStartMarker: NSMenuItem!
    @IBOutlet var windowMenuEndMarker: NSMenuItem!

    @IBOutlet var fileMenuStartMarker: NSMenuItem!
    @IBOutlet var fileMenuEndMarker: NSMenuItem!

    private var menuBuilders: [MenuType: MenuBuilder] = [:]

    func type(for menu: NSMenu) -> MenuType? {
        switch menu {
        case viewMenuStartMarker.menu: .view
        case windowMenuStartMarker.menu: .window
        case fileMenuStartMarker.menu: .file
        default: nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menuType = type(for: menu) else {
            return
        }

        let startMarker, endMarker: NSMenuItem
        switch menuType {
        case .view:
            startMarker = viewMenuStartMarker
            endMarker = viewMenuEndMarker
        case .window:
            startMarker = windowMenuStartMarker
            endMarker = windowMenuEndMarker
        case .file:
            startMarker = fileMenuStartMarker
            endMarker = fileMenuEndMarker
        }

        guard let startIndex = menu.items.firstIndex(of: startMarker),
              let endIndex = menu.items.firstIndex(of: endMarker)
        else { return }

        for _ in (startIndex+1)..<endIndex {
            menu.removeItem(at: startIndex + 1)
        }

        guard let document = NSDocumentController.shared.currentDocument as? Document,
              let controller = document.documentHostingController
        else { return }

        let menuBuilder = MenuBuilder()
        controller.buildMenu(menuType, with: menuBuilder)
        menuBuilders[menuType] = menuBuilder
        menuBuilder.insert(into: menu, after: startMarker)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let menuType = type(for: menu),
              let builder = menuBuilders[menuType]
        else { return }
        builder.menuDidClose(menu)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let menuType = type(for: menu),
              let builder = menuBuilders[menuType]
        else { return }
        builder.menu(menu, willHighlight: item)
    }
}
