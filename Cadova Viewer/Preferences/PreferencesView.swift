import Foundation
import SwiftUI
import CoreFoundation


struct PreferencesView: View {
    @ObservedObject var preferences = Preferences()
    @State private var addingApp = false
    @State private var selectedAppBundleIDs: Set<String> = []

    var body: some View {
        Form {
            Picker("Slicer", selection: $preferences.slicerBundleIdentifier) {
                Text("None").tag(String?.none)
                ForEach(slicerApps, id: \.bundleIdentifier) { app in
                    HStack {
                        Image(nsImage: app.icon)
                        Text(app.name)
                    }
                    .tag(String?.some(app.bundleIdentifier))
                }
            }

            Toggle("Remove non-solid parts when slicing", isOn: $preferences.removeNonSolidPartsWhenSlicing)
                .help("When slicing the whole model, only solid (printable) parts are sent to the slicer. Parts marked as context or visual — used for visual reference and not meant to be printed — are left out.")

            Divider()
                .padding(.vertical, 12)

            Picker("Precise Scrolling", selection: $preferences.preciseScrollAction) {
                VStack(alignment: .leading) {
                    Text("Pan")
                    Text("Best for trackpads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .tag(Preferences.PreciseScrollAction.pan)
                VStack(alignment: .leading) {
                    Text("Zoom")
                    Text("Best for Magic Mouse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .tag(Preferences.PreciseScrollAction.zoom)
            }
            .pickerStyle(.radioGroup)

            Divider()
                .padding(.vertical, 12)

            Picker("Activate SpaceMouse", selection: $preferences.navLibActivationBehavior) {
                Text("In Foreground Only")
                    .tag(Preferences.NavLibAppActivationBehavior.foregroundOnly)
                Text("Regardless of Foremost Application")
                    .tag(Preferences.NavLibAppActivationBehavior.always)
                Text("When Specific Applications are in the Foreground:")
                    .tag(Preferences.NavLibAppActivationBehavior.specificApplicationsInForeground)
                Text("Except When Specific Applications are in the Foreground:")
                    .tag(Preferences.NavLibAppActivationBehavior.allExceptSpecificApplications)
            }
            .pickerStyle(.radioGroup)

            List(activeAppList, id: \.bundleIdentifier, selection: $selectedAppBundleIDs) { app in
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
                .opacity(usesAppList ? 1 : 0.5)
                .disabled(!usesAppList)
                .focusable(usesAppList)
            }
            .disabled(!usesAppList)
            .scrollDisabled(!usesAppList)
            .listStyle(.bordered)
            .onDeleteCommand { deleteSelection() }
            HStack {
                Button("Add Application…") {
                    addingApp = true
                }
                .disabled(!usesAppList)

                Button("Remove", action: deleteSelection)
                    .disabled(selectedAppBundleIDs.isEmpty || !usesAppList)
            }
        }
        .padding()
        .frame(width: 650)
        .frame(minHeight: 420)
        .fileImporter(isPresented: $addingApp, allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }

            let existing = activeAppList.wrappedValue
            let newApps = urls.compactMap { url -> Preferences.NavLibForegroundApplication? in
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      !existing.contains(where: { $0.bundleIdentifier == bundleIdentifier }),
                      let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? bundle.infoDictionary?[kCFBundleNameKey as String] as? String
                else {
                    return nil
                }

                return .init(bundleIdentifier: bundleIdentifier, displayName: displayName)
            }
            activeAppList.wrappedValue.append(contentsOf: newApps)
        }
        // The two list modes have independent lists, so a selection from one is meaningless in the
        // other — clear it whenever the mode changes.
        .onChange(of: preferences.navLibActivationBehavior) { _, _ in
            selectedAppBundleIDs = []
        }
        .onChange(of: selectedAppBundleIDs) { _, newValue in
            if !usesAppList && !newValue.isEmpty {
                selectedAppBundleIDs = []
            }
        }
    }

    /// Whether the currently selected behavior is driven by an editable application list.
    private var usesAppList: Bool {
        preferences.navLibActivationBehavior.usesApplicationList
    }

    /// The application list the UI edits for the current mode: the block-list in
    /// `.allExceptSpecificApplications`, otherwise the allow-list.
    private var activeAppList: Binding<[Preferences.NavLibForegroundApplication]> {
        preferences.navLibActivationBehavior == .allExceptSpecificApplications
            ? $preferences.navLibExcludedApps
            : $preferences.navLibWhitelistedApps
    }

    /// Apps registered to open 3MF files, used to populate the slicer picker.
    private var slicerApps: [ExternalApplication] {
        ExternalApplication.appsAbleToOpen(contentType: ExternalApplication.threeMFContentType)
    }

    private func deleteSelection() {
        guard usesAppList else { return }
        activeAppList.wrappedValue.removeAll {
            selectedAppBundleIDs.contains($0.bundleIdentifier)
        }
        selectedAppBundleIDs = []
    }
}
