import Foundation
import IOKit
import OSLog

/// Watches the virtual HID "channel" devices that the 3Dconnexion driver creates for each navlib
/// connection, so a document can tell when the 3Dconnexion daemon has dropped its connection.
///
/// Why this is needed: 3DconnexionClient (loaded in-process under navlib) builds every report it sends
/// to the daemon in a single unlocked static buffer. With one connection per document, the connections'
/// threads race on that buffer when the daemon pings all channels at once; the driver rejects the
/// corrupted reply, and about five minutes later the daemon removes that connection and terminates its
/// channel. navlib never reconnects, so the document's SpaceMouse would stay dead until relaunch.
///
/// Each connection's channel is an IORegistry service named `TDxVirtualHIDData_ID<16 hex digits>`.
/// Its termination is the signal to recreate the session. The daemon also owns a per-user base channel
/// (`TDxVirtualHIDData_Base…`) that exists only while it's running, which tells when a new connection can
/// succeed. If the driver ever names channels differently, nothing is identified and nothing is watched,
/// which is the same as not having this.
///
/// Main thread only.
final class NavLibChannelMonitor {
    static let shared = NavLibChannelMonitor()

    private static let channelNamePrefix = "TDxVirtualHIDData_ID"
    private static let baseChannelNamePrefix = "TDxVirtualHIDData_Base"
    /// How long to let a freshly started daemon settle before connecting to it.
    private static let daemonSettleDelay: TimeInterval = 1

    private var notificationPort: IONotificationPortRef?
    private var terminationIterator: io_iterator_t = 0
    private var publicationIterator: io_iterator_t = 0
    /// Termination handlers keyed by the channel service's registry entry ID.
    private var terminationHandlers: [UInt64: () -> Void] = [:]
    /// Handlers waiting for the daemon to (re)appear.
    private var daemonAvailableHandlers: [() -> Void] = []

    private init() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Logger.navLib.error("Couldn't create an IOKit notification port; SpaceMouse connections won't be recovered")
            return
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let terminated: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<NavLibChannelMonitor>.fromOpaque(refcon).takeUnretainedValue().servicesTerminated(iterator)
        }
        let terminationResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"), terminated, refcon, &terminationIterator
        )
        if terminationResult == KERN_SUCCESS {
            // Draining the iterator arms the notification.
            servicesTerminated(terminationIterator)
        } else {
            Logger.navLib.error("Couldn't observe HID device termination (\(terminationResult)); SpaceMouse connections won't be recovered")
        }

        let published: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<NavLibChannelMonitor>.fromOpaque(refcon).takeUnretainedValue().servicesPublished(iterator)
        }
        let publicationResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), published, refcon, &publicationIterator
        )
        if publicationResult == KERN_SUCCESS {
            // Arm without treating devices that already exist as newly published.
            while case let service = IOIteratorNext(publicationIterator), service != 0 {
                IOObjectRelease(service)
            }
        } else {
            Logger.navLib.error("Couldn't observe HID device publication (\(publicationResult)); SpaceMouse connections won't be recovered after a 3Dconnexion restart")
        }
    }

    /// Whether the 3Dconnexion daemon is running, judged by its per-user base channel existing.
    var isDaemonAvailable: Bool {
        !matchingServices(namePrefix: Self.baseChannelNamePrefix).isEmpty
    }

    /// Calls `handler` once the daemon is running and has had a moment to settle: right away if it already
    /// is, otherwise when its base channel next appears.
    func whenDaemonAvailable(_ handler: @escaping () -> Void) {
        if isDaemonAvailable {
            handler()
        } else {
            daemonAvailableHandlers.append(handler)
        }
    }

    /// Runs `connect`, which creates a navlib connection, and reports the registry ID of the channel that
    /// connection created, or nil if it can't be told apart from other channels.
    func identifyChannel(createdBy connect: () throws -> Void, completion: @escaping (UInt64?) -> Void) rethrows {
        let before = matchingServices(namePrefix: Self.channelNamePrefix)
        try connect()
        if let channel = newChannel(since: before) {
            completion(channel)
            return
        }
        // The channel device can be published a moment after the connection call returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            completion(newChannel(since: before))
        }
    }

    /// Calls `handler` once, when the channel service terminates.
    func watchChannel(_ channel: UInt64, onTermination handler: @escaping () -> Void) {
        terminationHandlers[channel] = handler
    }

    func stopWatchingChannel(_ channel: UInt64) {
        terminationHandlers[channel] = nil
    }

    private func newChannel(since before: Set<UInt64>) -> UInt64? {
        let candidates = matchingServices(namePrefix: Self.channelNamePrefix)
            .subtracting(before)
            .subtracting(terminationHandlers.keys)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Registry entry IDs of the HID devices whose names start with `namePrefix`.
    private func matchingServices(namePrefix: String) -> Set<UInt64> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var entries: Set<UInt64> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if Self.name(of: service)?.hasPrefix(namePrefix) == true, let entryID = Self.registryEntryID(of: service) {
                entries.insert(entryID)
            }
        }
        return entries
    }

    private func servicesTerminated(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard Self.name(of: service)?.hasPrefix(Self.channelNamePrefix) == true,
                  let channel = Self.registryEntryID(of: service),
                  let handler = terminationHandlers.removeValue(forKey: channel)
            else { continue }
            handler()
        }
    }

    private func servicesPublished(_ iterator: io_iterator_t) {
        var baseChannelAppeared = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if Self.name(of: service)?.hasPrefix(Self.baseChannelNamePrefix) == true {
                baseChannelAppeared = true
            }
        }
        guard baseChannelAppeared, !daemonAvailableHandlers.isEmpty else { return }

        Logger.navLib.notice("3Dconnexion daemon is available again")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.daemonSettleDelay) { [self] in
            let handlers = daemonAvailableHandlers
            daemonAvailableHandlers.removeAll()
            handlers.forEach { $0() }
        }
    }

    private static func name(of service: io_service_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS else { return nil }
        return nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func registryEntryID(of service: io_service_t) -> UInt64? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        return entryID
    }
}

extension Logger {
    /// SpaceMouse connection diagnostics. Stream with:
    /// `log stream --predicate 'subsystem BEGINSWITH "se.tomasf" AND category == "navlib"'`
    static let navLib = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CadovaViewer", category: "navlib")
}
