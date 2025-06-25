import Foundation
import SwiftUI
import CoreFoundation


struct PreferencesView: View {
    @AppStorage("navLibActivationBehavior") var navLibActivationBehavior: Preferences.NavLibAppActivationBehavior = .foregroundOnly
    @AppStorage("navLibWhitelistedApps") var navLibWhitelistedAppsData: Data?

    @State private var addingApp = false
    @State private var selectedAppBundleIDs: Set<String> = []

    var navLibWhitelistedApps: [Preferences.NavLibForegroundApplication] {
        get {
            guard let data = navLibWhitelistedAppsData else { return [] }
            return (try? JSONDecoder().decode([Preferences.NavLibForegroundApplication].self, from: data)) ?? []
        }
        nonmutating set {
            navLibWhitelistedAppsData = try? JSONEncoder().encode(newValue)
        }
    }

    private func deleteSelection() {
        guard navLibActivationBehavior == .specificApplicationsInForeground else { return }
        navLibWhitelistedApps.removeAll(where: { selectedAppBundleIDs.contains($0.bundleIdentifier) })
        selectedAppBundleIDs = []
    }

    var body: some View {
        Form {
            Picker("SpaceMouse controls Cadova Viewer", selection: $navLibActivationBehavior) {
                Text("In Foreground Only")
                    .tag(Preferences.NavLibAppActivationBehavior.foregroundOnly)
                Text("Regardless of Frostmost Application")
                    .tag(Preferences.NavLibAppActivationBehavior.always)
                Text("When it or Specific Applications are in the Foreground:")
                    .tag(Preferences.NavLibAppActivationBehavior.specificApplicationsInForeground)
            }
            .pickerStyle(.radioGroup)

            List(.init(get: { navLibWhitelistedApps }, set: { navLibWhitelistedApps = $0 }), id: \.bundleIdentifier, selection: $selectedAppBundleIDs) { app in
                HStack {
                    let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.wrappedValue.bundleIdentifier)
                    let icon: NSImage = if let appURL {
                        NSWorkspace.shared.icon(forFile: appURL.path)
                    } else {
                        NSWorkspace.shared.icon(for: .application)
                    }

                    Image(nsImage: icon)
                    Text(app.wrappedValue.displayName)
                }
                .opacity(navLibActivationBehavior == .specificApplicationsInForeground ? 1 : 0.5)
                .disabled(navLibActivationBehavior != .specificApplicationsInForeground)
                //.selectionDisabled(navLibActivationBehavior != .specificApplicationsInForeground)
                .focusable(navLibActivationBehavior == .specificApplicationsInForeground)
            }
            .disabled(navLibActivationBehavior != .specificApplicationsInForeground)
            .scrollDisabled(navLibActivationBehavior != .specificApplicationsInForeground)
            .listStyle(.bordered)
            .onDeleteCommand { deleteSelection() }
            HStack {
                Button("Add Application…") {
                    addingApp = true
                }
                .disabled(navLibActivationBehavior != .specificApplicationsInForeground)

                Button("Remove") { deleteSelection() }
                    .disabled(selectedAppBundleIDs.isEmpty || navLibActivationBehavior != .specificApplicationsInForeground)
            }
        }
        .padding()
        .frame(width: 650)
        .frame(minHeight: 200)
        .fileImporter(isPresented: $addingApp, allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }

            let newApps = urls.compactMap { url -> Preferences.NavLibForegroundApplication? in
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      !navLibWhitelistedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }),
                      let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? bundle.infoDictionary?[kCFBundleNameKey as String] as? String
                else {
                    return nil
                }

                return .init(bundleIdentifier: bundleIdentifier, displayName: displayName)
            }
            navLibWhitelistedApps.append(contentsOf: newApps)
        }
        .onChange(of: navLibActivationBehavior) { oldValue, newValue in
            if oldValue == .specificApplicationsInForeground {
                selectedAppBundleIDs = []
            }
        }
        .onChange(of: selectedAppBundleIDs) { _, newValue in
            if navLibActivationBehavior != .specificApplicationsInForeground && !newValue.isEmpty {
                selectedAppBundleIDs = []
            }
        }
    }

    
}
