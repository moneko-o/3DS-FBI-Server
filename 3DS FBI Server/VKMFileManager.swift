//
//  VKMFileManager.swift
//  3DS FBI Server
//

import Foundation
import Combine

@MainActor
protocol VKMLoggingDelegate: AnyObject {
    func logStatus(_ status: String)
}

/// Live HTTP send progress for a queue row (local files only).
struct QueueItemTransferMetrics: Equatable {
    var sentBytes: Int64
    var totalBytes: Int64
    var speedBytesPerSecond: Double

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(sentBytes) / Double(totalBytes))
    }
}

/// HTTP listener callbacks are `@Sendable`; all observable state is updated on the main actor (`applyHTTPTransferProgress`, path resolution, index HTML).
@MainActor
final class VKMFileManager: NSObject, ObservableObject {
    @Published var dataArray: [VKMFileManagerItem] = []
    /// Populated while FBI downloads a local queue file over this Mac’s HTTP server.
    @Published private(set) var transferMetricsByQueueID: [UUID: QueueItemTransferMetrics] = [:]
    weak var loggingDelegate: VKMLoggingDelegate?

    private var httpServer: LocalHTTPServer?
    private var transferSpeedSample: [UUID: (t: TimeInterval, sent: Int64)] = [:]
    /// Coalesces high-frequency `bytesSent` callbacks so SwiftUI is not flooded (~60+ publishes/sec).
    private var metricsPublishTask: Task<Void, Never>?
    private(set) var serverURL: URL?

    /// Whether the HTTP server is listening (replaces `GCDWebServer.isRunning`).
    var isHTTPServerRunning: Bool {
        httpServer?.isRunning ?? false
    }

    private func emitLog(_ status: String) {
        loggingDelegate?.logStatus(status)
    }

    /// Builds the index page on the main actor (queue snapshot reads `dataArray`).
    private func buildIndexHTML() -> String {
        var responseHTML = "<html><body><p><table cellspacing=\"2\" cellpadding=\"0\"><tr><th>File</th><th>Size</th></tr>"
        for fileItem in dataArray {
            // Use absoluteString (percent-encoded path), not .path — otherwise spaces/Unicode break the browser’s GET vs queue matching.
            let href = fileItem.clientURL?.absoluteString ?? "#"
            let escapedName = fileItem.fileName
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            responseHTML.append("<tr><td><a href=\"\(href)\">\(escapedName)</a></td><td>\(fileItem.size)</td></tr>")
        }
        responseHTML.append("</table></p></body></html>")
        return responseHTML
    }

    /// Called from `LocalHTTPServer` worker threads; hops to the main actor for queue/HTML state.
    private nonisolated func indexHTMLForHTTP() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { buildIndexHTML() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.buildIndexHTML() }
        }
    }

    /// Resolves queue item + file URL on the main thread; the HTTP server streams bytes from that URL on its queue (no full-file copy or `Data` buffer).
    private nonisolated func fileURLForHTTP(path: String) -> (url: URL, fileName: String, queueItemID: UUID)? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                self.fileURLForHTTPOnMainActor(path: path)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.fileURLForHTTPOnMainActor(path: path)
            }
        }
    }

    @MainActor
    private func fileURLForHTTPOnMainActor(path: String) -> (url: URL, fileName: String, queueItemID: UUID)? {
        let matchPath = Self.canonicalPathForHTTPComparison(path)
        if Self.isBenignHTTPProbe(path: matchPath) {
            return nil
        }
        guard let i = Self.firstMatchingQueueIndex(in: dataArray, httpPath: matchPath) else {
            emitLog("Error: GET path did not match any queue item (HTTP path: \(matchPath)). Check encoding vs list URL.\n")
            return nil
        }
        let foundItem = dataArray[i]
        guard !foundItem.isUrl else { return nil }
        let refURL = URL(fileURLWithPath: foundItem.path)
        return (refURL, foundItem.fileName, foundItem.id)
    }

    /// Decodes all `%xx` layers, ensures leading `/`, NFC-normalizes (browser vs filesystem may differ).
    nonisolated private static func canonicalPathForHTTPComparison(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var prev = ""
        while s != prev {
            prev = s
            if let d = s.removingPercentEncoding { s = d }
        }
        if !s.hasPrefix("/") { s = "/" + s }
        return s.precomposedStringWithCanonicalMapping
    }

    /// Picks the queue row for an HTTP path (FBI may use different leading segments or encoding than `clientURL`).
    nonisolated private static func firstMatchingQueueIndex(in items: [VKMFileManagerItem], httpPath matchPath: String) -> Int? {
        if let i = items.firstIndex(where: { queueItemMatchesHTTPPath($0, httpPath: matchPath) }) {
            return i
        }
        let req = canonicalPathForHTTPComparison(matchPath)
        guard let reqKey = lastTwoSegmentKeyFromHTTPPath(req) else { return nil }
        if let i = items.firstIndex(where: { !$0.isUrl && lastTwoSegmentKeyFromFilePath($0.path) == reqKey }) {
            return i
        }
        // Same tail but parent folder may differ in case (`Downloads` vs `downloads`) between FBI and Foundation.
        if let nReq = normalizedLastTwoKeyFromHTTPPath(req),
           let i = items.firstIndex(where: { !$0.isUrl && normalizedLastTwoKeyFromFilePath($0.path) == nReq }) {
            return i
        }
        let reqFile = (req as NSString).lastPathComponent
        guard !reqFile.isEmpty else { return nil }
        let named = items.enumerated().filter { !$0.element.isUrl && fileNameMatchesPathComponent($0.element.fileName, reqFile) }
        if named.count == 1 {
            return named[0].offset
        }
        return nil
    }

    nonisolated private static func fileNameMatchesPathComponent(_ fileName: String, _ pathComponent: String) -> Bool {
        let a = fileName.precomposedStringWithCanonicalMapping
        let b = pathComponent.precomposedStringWithCanonicalMapping
        return a == b
    }

    nonisolated private static func lastTwoSegmentKeyFromHTTPPath(_ canonicalReq: String) -> String? {
        let parts = canonicalReq.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        guard parts.count >= 2 else { return nil }
        let dir = parts[parts.count - 2].precomposedStringWithCanonicalMapping
        let name = parts[parts.count - 1].precomposedStringWithCanonicalMapping
        return dir + "/" + name
    }

    nonisolated private static func lastTwoSegmentKeyFromFilePath(_ posixPath: String) -> String? {
        let parts = URL(fileURLWithPath: posixPath).pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let dir = parts[parts.count - 2].precomposedStringWithCanonicalMapping
        let name = parts[parts.count - 1].precomposedStringWithCanonicalMapping
        return dir + "/" + name
    }

    nonisolated private static func normalizedLastTwoKeyFromHTTPPath(_ canonical: String) -> String? {
        let parts = canonical.split(separator: "/").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let dir = String(parts[parts.count - 2]).lowercased()
        let name = String(parts[parts.count - 1]).precomposedStringWithCanonicalMapping
        return dir + "/" + name
    }

    nonisolated private static func normalizedLastTwoKeyFromFilePath(_ posixPath: String) -> String? {
        let parts = URL(fileURLWithPath: posixPath).pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let dir = parts[parts.count - 2].lowercased()
        let name = parts[parts.count - 1].precomposedStringWithCanonicalMapping
        return dir + "/" + name
    }

    nonisolated private static func queueItemMatchesHTTPPath(_ item: VKMFileManagerItem, httpPath: String) -> Bool {
        if item.isUrl { return false }
        let req = canonicalPathForHTTPComparison(httpPath)
        if let p = item.clientURL?.path, canonicalPathForHTTPComparison(p) == req {
            return true
        }
        // Match using the same path we recorded at drop time (`path` → last two folders + file).
        let fs = URL(fileURLWithPath: item.path)
        let tail = fs.pathComponents.suffix(2)
        guard tail.count == 2 else { return false }
        let expected = "/" + tail.joined(separator: "/")
        return canonicalPathForHTTPComparison(expected) == req
    }

    /// True for common automatic requests when something opens the index `http://IP:port/` in a web view or browser.
    nonisolated private static func isBenignHTTPProbe(path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = p.lowercased()
        if lower.hasPrefix("/.well-known/") { return true }
        let file = (lower as NSString).lastPathComponent
        if file == "favicon.ico" || file == "robots.txt" { return true }
        if file.hasPrefix("apple-touch-icon") { return true }
        if file == "icon.png" || file == "icon.svg" { return true }
        // Windows / PWA tiles often probed from the page origin
        if file.hasPrefix("mstile-") || file == "browserconfig.xml" { return true }
        return false
    }

    private func applyHTTPTransferProgress(_ e: LocalHTTPFileTransferProgress) {
        var next = transferMetricsByQueueID
        switch e {
        case .began(let id, let total):
            transferSpeedSample[id] = (Date().timeIntervalSinceReferenceDate, 0)
            let t = max(total, 1)
            next[id] = QueueItemTransferMetrics(sentBytes: 0, totalBytes: t, speedBytesPerSecond: 0)
        case .bytesSent(let id, let count):
            guard var cur = next[id] else { return }
            let now = Date().timeIntervalSinceReferenceDate
            let delta = Int64(count)
            cur.sentBytes = min(cur.sentBytes + delta, cur.totalBytes)
            if let prev = transferSpeedSample[id] {
                let dt = max(now - prev.t, 0.000_5)
                let inst = Double(count) / dt
                cur.speedBytesPerSecond = cur.speedBytesPerSecond <= 0
                    ? inst
                    : (0.22 * inst + 0.78 * cur.speedBytesPerSecond)
                transferSpeedSample[id] = (now, cur.sentBytes)
            }
            next[id] = cur
        case .finished(let id):
            transferSpeedSample[id] = nil
            next.removeValue(forKey: id)
        }

        switch e {
        case .began, .finished:
            metricsPublishTask?.cancel()
            metricsPublishTask = nil
            transferMetricsByQueueID = next
        case .bytesSent:
            metricsPublishTask?.cancel()
            let snapshot = next
            metricsPublishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 48_000_000)
                guard let self, !Task.isCancelled else { return }
                self.transferMetricsByQueueID = snapshot
                self.metricsPublishTask = nil
            }
        }
    }

    @discardableResult
    func startServing() async -> Bool {
        stopServing()
        let server = LocalHTTPServer()
        do {
            let url = try await server.start(
                indexHTML: { [weak self] in
                    self?.indexHTMLForHTTP() ?? ""
                },
                fileForPath: { [weak self] path in
                    self?.fileURLForHTTP(path: path)
                },
                onFileTransferProgress: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.applyHTTPTransferProgress(event)
                    }
                }
            )
            httpServer = server
            serverURL = url
            emitLog("You can inspect the files list at \(url)\n")
            return true
        } catch {
            httpServer = nil
            serverURL = nil
            emitLog("Failed to start HTTP server: \(error.localizedDescription)\n")
            return false
        }
    }

    func stopServing() {
        metricsPublishTask?.cancel()
        metricsPublishTask = nil
        httpServer?.stop()
        httpServer = nil
        serverURL = nil
        transferMetricsByQueueID = [:]
        transferSpeedSample = [:]
    }

    func removeQueueItem(id: UUID) {
        dataArray.removeAll { $0.id == id }
        dataArray = Array(dataArray)
        var next = transferMetricsByQueueID
        next.removeValue(forKey: id)
        transferMetricsByQueueID = next
        transferSpeedSample.removeValue(forKey: id)
    }

    func clearQueue() {
        dataArray.removeAll()
        transferMetricsByQueueID = [:]
        transferSpeedSample = [:]
    }

    /// Build child file URLs under an enumerated folder (`URL(fileURLWithPath:relativeTo:)` is unreliable for Unicode names).
    nonisolated private static func fileURLInEnumeratedDirectory(_ directory: URL, relativeEnumeratorPath: String) -> URL {
        let parts = relativeEnumeratorPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return directory }
        var result = directory
        for i in 0..<parts.count {
            let isDirectory = i < parts.count - 1
            result = result.appendingPathComponent(parts[i], isDirectory: isDirectory)
        }
        return result
    }

    /// Records POSIX paths only; HTTP reads open `URL(fileURLWithPath:)` when FBI requests (non–sandboxed target — same idea as the old Pods setup).
    func received(fileURLs: [URL]) {
        let fd = FileManager.default
        for url in fileURLs {
            var isDir: ObjCBool = false
            guard fd.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fd.enumerator(atPath: url.path) else { continue }
                for case let subFile as String in enumerator {
                    let subURL = Self.fileURLInEnumeratedDirectory(url, relativeEnumeratorPath: subFile)
                    let ext = subURL.pathExtension.lowercased()
                    guard ext == "cia" || ext == "tik" else { continue }
                    dataArray.append(VKMFileManagerItem(isUrl: false, path: subURL.path))
                }
            } else {
                let fileRef = url.isFileURL ? url : URL(fileURLWithPath: url.path)
                dataArray.append(VKMFileManagerItem(isUrl: false, path: fileRef.path))
            }
        }
        dataArray = Array(dataArray)
    }

    func received(url: URL) {
        dataArray.append(VKMFileManagerItem(isUrl: true, path: url.absoluteString))
        dataArray = Array(dataArray)
    }
}

final class VKMFileManagerItem: NSObject, Identifiable {
    let id = UUID()
    var isUrl: Bool = false
    var fileName: String = ""
    var path: String = ""
    var size: Int = 0
    var clientURL: URL?

    /// Where the file lived when added (parent folder + name), e.g. `Downloads/汉化DLC….cia` — for UI.
    var recordedLocationPath: String {
        if isUrl { return "" }
        let u = URL(fileURLWithPath: path)
        let parts = u.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return u.lastPathComponent }
        return parts.suffix(2).joined(separator: "/")
    }

    /// FBI / web index: path uses the **recorded** file location (last path components), e.g. `/Downloads/foo.cia`, percent-encoded per segment.
    static func buildLocalQueueClientURL(forOriginalFilePath path: String) -> URL? {
        let tempURL = URL(fileURLWithPath: path)
        var pathSegmentAllowed = CharacterSet.urlPathAllowed
        pathSegmentAllowed.remove(charactersIn: "/")
        let components = tempURL.pathComponents
        guard components.count >= 2 else {
            let last = tempURL.lastPathComponent
            return URL(string: "/" + (last.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? last))
        }
        let usedPath = "/" + components.suffix(2).map { seg in
            seg.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? seg
        }.joined(separator: "/")
        return URL(string: usedPath)
    }

    init(isUrl: Bool, path: String) {
        self.isUrl = isUrl
        self.path = path
        super.init()
        let fd = FileManager.default
        var fileSize = 0
        if !isUrl {
            do {
                let attr = try fd.attributesOfItem(atPath: path)
                fileSize = attr[.size] as? Int ?? 0
            } catch {
                print(error)
            }
            let tempURL = URL(fileURLWithPath: path)
            self.fileName = tempURL.lastPathComponent
            self.clientURL = Self.buildLocalQueueClientURL(forOriginalFilePath: path)
            self.size = fileSize
        } else {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            self.clientURL = Self.canonicalRemoteURL(from: trimmed)
            self.fileName = Self.displayName(forRemoteString: trimmed, url: self.clientURL)
            self.size = 0
        }
    }

    /// Prefer filename from path; fall back to host + path tail (many pasted URLs lack a clear lastPathComponent).
    private static func displayName(forRemoteString raw: String, url: URL?) -> String {
        guard let url else {
            return raw.isEmpty ? String(localized: "Link") : raw
        }
        var last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if last.isEmpty, url.pathComponents.count > 1 {
            last = url.pathComponents.last ?? ""
            last = last.removingPercentEncoding ?? last
        }
        if !last.isEmpty, last != "/" {
            return last
        }
        let host = url.host ?? ""
        if host.isEmpty {
            return raw
        }
        let pathPart = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pathPart.isEmpty {
            return host
        }
        let tail = pathPart.split(separator: "/").last.map(String.init) ?? pathPart
        return tail.count > 48 ? host + " — …" + String(tail.suffix(24)) : host + " — " + tail
    }

    private static func canonicalRemoteURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        if let c = URLComponents(string: trimmed), let u = c.url { return u }
        let allowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(.urlFragmentAllowed)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return URL(string: encoded)
    }
}
