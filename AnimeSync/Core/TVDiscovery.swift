import Foundation
import Combine
import Darwin

struct TVDiscoveredDevice: Identifiable, Equatable {
    let name: String
    let host: String
    var id: String { host }
}

@MainActor final class TVDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var candidates: [TVDiscoveredDevice] = []
    @Published private(set) var message = ""
    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var resolved: [ObjectIdentifier: [TVDiscoveredDevice]] = [:]
    func start() {
        stop(); let next = NetServiceBrowser(); browser = next; next.delegate = self
        message = "Searching for TVs on your home network…"
        next.searchForServices(ofType: "_animesync._tcp.", inDomain: "local.")
    }
    func stop() {
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll(); resolved.removeAll(); candidates = []
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self, self.browser === browser else { return }
            self.services[ObjectIdentifier(service)] = service; service.delegate = self; service.resolve(withTimeout: 4)
        }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self, self.browser === browser else { return }
            let id = ObjectIdentifier(service); self.services.removeValue(forKey: id)?.stop(); self.resolved.removeValue(forKey: id); self.publish()
        }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor [weak self] in guard let self = self, self.browser === browser else { return }; self.message = "Discovery unavailable. Enter the TV address instead." }
    }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            guard let self = self, self.browser != nil, self.services[ObjectIdentifier(sender)] === sender, sender.port == 8765 else { return }
            var devices: [TVDiscoveredDevice] = []
            for data in sender.addresses ?? [] {
                guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
                let numeric: String? = data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress?.assumingMemoryBound(to: sockaddr.self), Int32(base.pointee.sa_family) == AF_INET else { return nil }
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(base, socklen_t(data.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                    return String(cString: name)
                }
                if let numeric = numeric, let host = try? TVAddress.host(numeric) { devices.append(TVDiscoveredDevice(name: sender.name, host: host)) }
            }
            self.resolved[ObjectIdentifier(sender)] = devices; self.publish()
        }
    }
    private func publish() {
        var found: [String: TVDiscoveredDevice] = [:]
        for list in resolved.values { for device in list { found[device.host] = device } }
        candidates = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        message = candidates.isEmpty ? "Enter the TV address if it does not appear." : "Choose your TV, then enter its pairing code."
    }
}
