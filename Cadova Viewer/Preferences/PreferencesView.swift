import Foundation
import SwiftUI
import CoreFoundation


struct PreferencesView: View {
    @ObservedObject var preferences = Preferences()
    @State private var addingApp = false
    @State private var selectedAppBundleIDs: Set<String> = []

    var body: some View {
        Form {
            Picker("Activate SpaceMouse", selection: $preferences.navLibActivationBehavior) {
                Text("In Foreground Only")
                    .tag(Preferences.NavLibAppActivationBehavior.foregroundOnly)
                Text("Regardless of Frostmost Application")
                    .tag(Preferences.NavLibAppActivationBehavior.always)
                Text("When Specific Applications are in the Foreground:")
                    .tag(Preferences.NavLibAppActivationBehavior.specificApplicationsInForeground)
            }
            .pickerStyle(.radioGroup)

            List($preferences.navLibWhitelistedApps, id: \.bundleIdentifier, selection: $selectedAppBundleIDs) { app in
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
                .opacity(preferences.navLibActivationBehavior == .specificApplicationsInForeground ? 1 : 0.5)
                .disabled(preferences.navLibActivationBehavior != .specificApplicationsInForeground)
                .focusable(preferences.navLibActivationBehavior == .specificApplicationsInForeground)
            }
            .disabled(preferences.navLibActivationBehavior != .specificApplicationsInForeground)
            .scrollDisabled(preferences.navLibActivationBehavior != .specificApplicationsInForeground)
            .listStyle(.bordered)
            .onDeleteCommand { deleteSelection() }
            HStack {
                Button("Add Application…") {
                    addingApp = true
                }
                .disabled(preferences.navLibActivationBehavior != .specificApplicationsInForeground)

                Button("Remove", action: deleteSelection)
                    .disabled(selectedAppBundleIDs.isEmpty || preferences.navLibActivationBehavior != .specificApplicationsInForeground)
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
                      !preferences.navLibWhitelistedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }),
                      let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? bundle.infoDictionary?[kCFBundleNameKey as String] as? String
                else {
                    return nil
                }

                return .init(bundleIdentifier: bundleIdentifier, displayName: displayName)
            }
            preferences.navLibWhitelistedApps.append(contentsOf: newApps)
        }
        .onChange(of: preferences.navLibActivationBehavior) { oldValue, newValue in
            if oldValue == .specificApplicationsInForeground {
                selectedAppBundleIDs = []
            }
        }
        .onChange(of: selectedAppBundleIDs) { _, newValue in
            if preferences.navLibActivationBehavior != .specificApplicationsInForeground && !newValue.isEmpty {
                selectedAppBundleIDs = []
            }
        }
    }

    private func deleteSelection() {
        guard preferences.navLibActivationBehavior == .specificApplicationsInForeground else { return }
        preferences.navLibWhitelistedApps.removeAll {
            selectedAppBundleIDs.contains($0.bundleIdentifier)
        }
        selectedAppBundleIDs = []
    }
}
