import Foundation
import Network
import Observation

/// Whether the server is plausibly reachable.
///
/// Deliberately only a hint. The server is usually on a LAN, so "the device has
/// a network" says little about whether *this* server answers — a phone on
/// cellular is online and cannot see a home server at all. It is used to decide
/// when to retry queued writes and what to tell the reader, never to refuse to
/// try.
@Observable
@MainActor
public final class Reachability {
    public private(set) var isOnline = true
    /// True on cellular or a personal hotspot, so large downloads can be held
    /// back when the reader has asked for Wi-Fi only.
    public private(set) var isExpensive = false

    /// Fired on each transition to online, for draining queued work.
    public var onBecameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "issa.reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !isOnline
                isOnline = online
                isExpensive = expensive
                if online, wasOffline { onBecameOnline?() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
