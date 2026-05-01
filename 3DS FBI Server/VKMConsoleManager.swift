//
//  VKMConsoleManager.swift
//  3DS FBI Server
//

import Foundation
import Combine
import Network

@MainActor
protocol ConsoleManagementDelegate: AnyObject {
    func socketsDisconnected()
    func foundConsoleWith(consoleManagerItem: ConsoleManagerItem)
    func connectedToConsole(_ console: ConsoleManagerItem)
}

struct ConsoleManagerItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var ipAddress: String
    var port: UInt16

    init(id: UUID = UUID(), ipAddress: String = "0.0.0.0", port: UInt16 = 5000) {
        self.id = id
        self.ipAddress = ipAddress
        self.port = port
    }

    /// Normalizes dotted IPv4 so `192.168.01.1` and `192.168.1.1` compare equal; non‑IPv4 strings are trim + lowercased.
    static func normalizedIPAddress(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return t.lowercased() }
        var octets: [UInt8] = []
        for p in parts {
            guard let n = UInt8(p.trimmingCharacters(in: .whitespaces)) else {
                return t.lowercased()
            }
            octets.append(n)
        }
        return octets.map(String.init).joined(separator: ".")
    }

    func isSameAddress(ip: String, port: UInt16) -> Bool {
        Self.normalizedIPAddress(ipAddress) == Self.normalizedIPAddress(ip) && self.port == port
    }
}

@MainActor
final class VKMConsoleManager: NSObject, ObservableObject {
    private final class SocketBatchFinish: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private weak var delegate: ConsoleManagementDelegate?
        init(remaining: Int, delegate: ConsoleManagementDelegate?) {
            self.remaining = remaining
            self.delegate = delegate
        }
        func connectionFinished() {
            lock.lock()
            remaining -= 1
            let done = remaining <= 0
            lock.unlock()
            if done {
                Task { @MainActor [weak delegate] in
                    delegate?.socketsDisconnected()
                }
            }
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false
        private let batch: SocketBatchFinish
        init(batch: SocketBatchFinish) {
            self.batch = batch
        }
        func run() {
            lock.lock()
            defer { lock.unlock() }
            guard !consumed else { return }
            consumed = true
            batch.connectionFinished()
        }
    }

    /// Bridges NW `stateUpdateHandler` (@Sendable) to `@MainActor` delegate calls without capturing non-Sendable delegate existentials.
    private final class TCPReadyNotifier: @unchecked Sendable {
        weak var delegate: ConsoleManagementDelegate?
        let item: ConsoleManagerItem
        init(delegate: ConsoleManagementDelegate?, item: ConsoleManagerItem) {
            self.delegate = delegate
            self.item = item
        }
        func notifyReady() {
            Task { @MainActor [weak delegate, item] in
                delegate?.connectedToConsole(item)
            }
        }
    }

    weak var delegate: ConsoleManagementDelegate?
    @Published var dataArray: [ConsoleManagerItem] = []

    private let socketQueue = DispatchQueue(label: "com.3dsfbi.tcp")

    override init() {
        super.init()
        enqueueLANARPScan()
    }

    /// Runs `/usr/sbin/arp` off the main actor; results merge on `MainActor`.
    func enqueueLANARPScan() {
        DispatchQueue.global(qos: .utility).async {
            let ips = Self.collectNintendoLANIPs()
            Task { @MainActor [weak self] in
                self?.ingestLANARPCandidates(ips)
            }
        }
    }

    private func ingestLANARPCandidates(_ ips: [String]) {
        guard !ips.isEmpty else { return }
        var next = dataArray
        for ip in ips {
            if next.contains(where: { $0.isSameAddress(ip: ip, port: 5000) }) { continue }
            let item = ConsoleManagerItem(ipAddress: ip, port: 5000)
            next.append(item)
            delegate?.foundConsoleWith(consoleManagerItem: item)
        }
        if next != dataArray {
            dataArray = next
        }
    }

    nonisolated private static func collectNintendoLANIPs() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-a"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let ipPattern = "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"
        let macPattern = " ([0-9a-fA-F]{1,2}:){2}([0-9a-fA-F]{1,2})"
        let nintendoMACs = ["e8:4e:ce", "e0:e7:51", "e0:c:7f", "d8:6b:f7", "cc:fb:65", "cc:9e:0", "b8:ae:6e", "a4:c0:e1", "a4:5c:27", "9c:e6:35", "98:b6:e9", "8c:cd:e8", "8c:56:c5", "7c:bb:8a", "78:a2:a0", "58:bd:a3", "40:f4:7", "40:d2:8a", "34:af:2c", "2c:10:c1", "18:2a:7b", "0:27:9", "0:26:59", "0:25:a0", "0:24:f3", "0:24:44", "0:24:1e", "0:23:cc", "0:23:31", "0:22:d7", "0:22:aa", "0:22:4c", "0:21:bd", "0:21:47", "0:1f:c5", "0:1f:32", "0:1e:a9", "0:1e:35", "0:1d:bc", "0:1c:be", "0:1b:ea", "0:1b:7a", "0:1a:e9", "0:19:fd", "0:19:1d", "0:17:ab", "0:16:56", "0:9:bf"]

        let ipMatches = Self.regexMatches(for: ipPattern, in: output)
        let macMatches = Self.regexMatches(for: macPattern, in: output)
        var ips: [String] = []
        for (index, macMatch) in macMatches.enumerated() {
            var cleanedMAC = macMatch
            cleanedMAC.remove(at: cleanedMAC.startIndex)
            if nintendoMACs.contains(cleanedMAC), index < ipMatches.count {
                ips.append(ipMatches[index])
            }
        }
        return ips
    }

    nonisolated private static func regexMatches(for pattern: String, in text: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let nsString = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            return results.map { nsString.substring(with: $0.range) }
        } catch {
            print("invalid regex: \(error.localizedDescription)")
            return []
        }
    }

    func sendData(fileList: [VKMFileManagerItem], hostURL: URL) {
        var urlData = Data()
        for fileItem in fileList {
            let singleURL: URL?
            if fileItem.isUrl {
                singleURL = fileItem.clientURL
            } else {
                // Must use URLComponents + decoded `path`. appendingPathComponent on a %-segment re-encodes
                // `%` → `%25` (e.g. `%20` → `%2520`), so FBI GET paths no longer match queue entries → 404.
                guard let hostParts = URLComponents(url: hostURL, resolvingAgainstBaseURL: false),
                      let itemPath = fileItem.clientURL?.path,
                      itemPath.hasPrefix("/") else {
                    continue
                }
                var merged = hostParts
                merged.path = itemPath
                singleURL = merged.url
            }
            guard let url = singleURL,
                  let line = (url.absoluteString + "\n").data(using: .utf8) else { continue }
            urlData.append(line)
        }
        let countBE = UInt32(urlData.count).bigEndian
        var dataPayload = Swift.withUnsafeBytes(of: countBE) { Data($0) }
        dataPayload.append(urlData)

        let targets = dataArray
        guard !targets.isEmpty else { return }

        let sendPayload = dataPayload
        let batch = SocketBatchFinish(remaining: targets.count, delegate: delegate)

        for item in targets {
            guard let port = NWEndpoint.Port(rawValue: item.port) else {
                batch.connectionFinished()
                continue
            }
            let host = NWEndpoint.Host(item.ipAddress)
            let conn = NWConnection(host: host, port: port, using: .tcp)

            let gate = OnceGate(batch: batch)
            let completeOnce: @Sendable () -> Void = { gate.run() }
            let readyNotifier = TCPReadyNotifier(delegate: delegate, item: item)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    readyNotifier.notifyReady()
                    conn.send(content: sendPayload, completion: .contentProcessed { error in
                        if error != nil {
                            conn.cancel()
                            completeOnce()
                            return
                        }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                            conn.cancel()
                            completeOnce()
                        }
                    })
                case .failed, .cancelled:
                    completeOnce()
                default:
                    break
                }
            }
            conn.start(queue: socketQueue)
        }
    }
}
