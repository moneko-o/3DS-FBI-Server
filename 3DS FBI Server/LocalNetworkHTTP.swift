//
//  LocalNetworkHTTP.swift
//  LAN IPv4 helper + minimal HTTP/1.1 server using Network.framework (no GCDWebServer).
//

import Darwin
import Foundation
import Network

/// Per–queue-item HTTP body streaming progress (local CIA/TIK files only).
enum LocalHTTPFileTransferProgress: Sendable {
    case began(queueItemID: UUID, totalBytes: Int64)
    case bytesSent(queueItemID: UUID, count: Int)
    case finished(queueItemID: UUID)
}

typealias LocalHTTPIndexHTML = @Sendable () -> String
typealias LocalHTTPFileForPath = @Sendable (String) -> (url: URL, fileName: String, queueItemID: UUID)?
typealias LocalHTTPTransferProgress = @Sendable (LocalHTTPFileTransferProgress) -> Void

/// Ensures a continuation is resumed at most once from concurrent listener callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return }
        consumed = true
        body()
    }
}

/// Best-effort IPv4 for URLs announced to the 3DS.
enum LocalIPv4 {
    static func primaryForServing() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = ptr?.pointee {
            defer { ptr = addr.ifa_next }

            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let namePtr = addr.ifa_name else { continue }
            let nameLen = strlen(namePtr)
            let nameBytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(namePtr), count: nameLen).bindMemory(to: UInt8.self)
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            if getnameinfo(addr.ifa_addr, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) != 0 {
                continue
            }
            let hostEnd = hostname.firstIndex(of: 0) ?? hostname.endIndex
            let ip = String(decoding: hostname[..<hostEnd].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if ip != "127.0.0.1", !ip.hasPrefix("169.254.") {
                return ip
            }
        }
        return "127.0.0.1"
    }
}

/// Minimal TCP HTTP server: `GET /` index, `GET /path` streams file bytes in chunks (no full-file buffer).
final class LocalHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.3dsfbi.http")
    private let stateLock = NSLock()
    private var stopped = false
    private var liveConnections: [ObjectIdentifier: NWConnection] = [:]

    /// Reads per chunk when streaming file bodies.
    private static let streamChunkSize = 256 * 1024

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener != nil
    }

    func start(
        indexHTML: @escaping LocalHTTPIndexHTML,
        fileForPath: @escaping LocalHTTPFileForPath,
        onFileTransferProgress: LocalHTTPTransferProgress? = nil
    ) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let zero = NWEndpoint.Port(rawValue: 0) else {
            throw NSError(domain: "LocalHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad port"])
        }
        let lst = try NWListener(using: parameters, on: zero)

        lst.newConnectionHandler = { [weak self] connection in
            self?.accept(
                connection: connection,
                indexHTML: indexHTML,
                fileForPath: fileForPath,
                onFileTransferProgress: onFileTransferProgress
            )
        }

        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            let resume: @Sendable (Result<URL, Error>) -> Void = { result in
                once.run {
                    switch result {
                    case .success(let u): continuation.resume(returning: u)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }
            }

            lst.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let port = lst.port?.rawValue ?? 0
                    let host = LocalIPv4.primaryForServing()
                    if let u = URL(string: "http://\(host):\(port)/") {
                        resume(.success(u))
                    } else {
                        resume(.failure(NSError(domain: "LocalHTTPServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
                    }
                case .failed(let err):
                    resume(.failure(err))
                case .cancelled:
                    resume(.failure(NSError(domain: "LocalHTTPServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled"])))
                default:
                    break
                }
            }

            lst.start(queue: queue)
        }

        listener = lst
        return url
    }

    func stop() {
        stateLock.lock()
        stopped = true
        let lst = listener
        listener = nil
        let conns = Array(liveConnections.values)
        liveConnections.removeAll()
        stateLock.unlock()

        lst?.cancel()
        for c in conns { c.cancel() }
    }

    private func accept(
        connection: NWConnection,
        indexHTML: @escaping LocalHTTPIndexHTML,
        fileForPath: @escaping LocalHTTPFileForPath,
        onFileTransferProgress: LocalHTTPTransferProgress?
    ) {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            connection.cancel()
            return
        }
        let oid = ObjectIdentifier(connection)
        liveConnections[oid] = connection
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.removeConn(oid) }
            if case .cancelled = state { self?.removeConn(oid) }
        }
        connection.start(queue: queue)
        receiveRequest(
            connection: connection,
            buffer: Data(),
            indexHTML: indexHTML,
            fileForPath: fileForPath,
            onFileTransferProgress: onFileTransferProgress
        )
    }

    private func removeConn(_ id: ObjectIdentifier) {
        stateLock.lock()
        liveConnections.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func receiveRequest(
        connection: NWConnection,
        buffer: Data,
        indexHTML: @escaping LocalHTTPIndexHTML,
        fileForPath: @escaping LocalHTTPFileForPath,
        onFileTransferProgress: LocalHTTPTransferProgress?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if Self.requestHeadersComplete(buf) || isComplete {
                self.dispatchHTTP(
                    connection: connection,
                    buf: buf,
                    indexHTML: indexHTML,
                    fileForPath: fileForPath,
                    onFileTransferProgress: onFileTransferProgress
                )
                return
            }
            if !isComplete {
                self.receiveRequest(
                    connection: connection,
                    buffer: buf,
                    indexHTML: indexHTML,
                    fileForPath: fileForPath,
                    onFileTransferProgress: onFileTransferProgress
                )
            }
        }
    }

    /// True once header block ends (RFC 7230 allows CRLF or some clients use LF-only).
    private static func requestHeadersComplete(_ buf: Data) -> Bool {
        buf.range(of: Data("\r\n\r\n".utf8)) != nil || buf.range(of: Data("\n\n".utf8)) != nil
    }

    /// Request-target may be origin-form `/path` or absolute-form `http://host/path` (Safari / some stacks).
    private static func pathFromRequestTarget(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://"), let u = URL(string: t) {
            var p = u.path
            if p.isEmpty { p = "/" }
            return p
        }
        return t
    }

    private func dispatchHTTP(
        connection: NWConnection,
        buf: Data,
        indexHTML: @escaping LocalHTTPIndexHTML,
        fileForPath: @escaping LocalHTTPFileForPath,
        onFileTransferProgress: LocalHTTPTransferProgress?
    ) {
        guard let raw = String(data: buf, encoding: .utf8) else {
            respond(connection: connection, status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8))
            return
        }
        let first: String
        if let r = raw.range(of: "\r\n") {
            first = String(raw[..<r.lowerBound])
        } else if let n = raw.firstIndex(of: "\n") {
            first = String(raw[..<n])
        } else {
            respond(connection: connection, status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8))
            return
        }
        // Origin-form: GET /path HTTP/1.x — or absolute-form GET http://host/path HTTP/1.x
        guard first.hasPrefix("GET ") else {
            respond(connection: connection, status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8))
            return
        }
        let afterMethod = first.dropFirst(4)
        guard let httpMarker = afterMethod.range(of: " HTTP/") else {
            respond(connection: connection, status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8))
            return
        }
        let target = String(afterMethod[..<httpMarker.lowerBound])
        var path = Self.pathFromRequestTarget(target)
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }

        if path == "/" || path.isEmpty {
            let html = indexHTML()
            respond(connection: connection, status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
            return
        }

        if let spec = fileForPath(path) {
            streamFile(
                connection: connection,
                fileURL: spec.url,
                downloadFileName: spec.fileName,
                queueItemID: spec.queueItemID,
                onFileTransferProgress: onFileTransferProgress
            )
            return
        }

        respond(connection: connection, status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
    }

    private func streamFile(
        connection: NWConnection,
        fileURL: URL,
        downloadFileName: String,
        queueItemID: UUID,
        onFileTransferProgress: LocalHTTPTransferProgress?
    ) {
        let oid = ObjectIdentifier(connection)

        func fail404() {
            respond(connection: connection, status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let sizeNum = attrs[.size] as? NSNumber
        else {
            fail404()
            return
        }
        let contentLength = sizeNum.int64Value
        guard contentLength >= 0, let fh = try? FileHandle(forReadingFrom: fileURL) else {
            fail404()
            return
        }
        let safe = downloadFileName.replacingOccurrences(of: "\"", with: "_")
        var header = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: \(contentLength)\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Disposition: attachment; filename=\"\(safe)\"\r\n\r\n"

        let headerData = Data(header.utf8)
        connection.send(content: headerData, completion: .contentProcessed { [weak self] err in
            guard let self else {
                try? fh.close()
                return
            }
            if err != nil {
                try? fh.close()
                connection.cancel()
                self.removeConn(oid)
                onFileTransferProgress?(.finished(queueItemID: queueItemID))
                return
            }
            if contentLength == 0 {
                try? fh.close()
                connection.cancel()
                self.removeConn(oid)
                onFileTransferProgress?(.began(queueItemID: queueItemID, totalBytes: 0))
                onFileTransferProgress?(.finished(queueItemID: queueItemID))
                return
            }
            onFileTransferProgress?(.began(queueItemID: queueItemID, totalBytes: contentLength))
            self.sendFileChunks(
                connection: connection,
                fileHandle: fh,
                remaining: Int(contentLength),
                oid: oid,
                queueItemID: queueItemID,
                onFileTransferProgress: onFileTransferProgress
            )
        })
    }

    private func sendFileChunks(
        connection: NWConnection,
        fileHandle: FileHandle,
        remaining: Int,
        oid: ObjectIdentifier,
        queueItemID: UUID,
        onFileTransferProgress: LocalHTTPTransferProgress?
    ) {
        guard remaining > 0 else {
            try? fileHandle.close()
            connection.cancel()
            removeConn(oid)
            onFileTransferProgress?(.finished(queueItemID: queueItemID))
            return
        }

        let chunkSize = min(remaining, Self.streamChunkSize)
        let data = fileHandle.readData(ofLength: chunkSize)
        let n = data.count
        if n == 0 {
            try? fileHandle.close()
            connection.cancel()
            removeConn(oid)
            onFileTransferProgress?(.finished(queueItemID: queueItemID))
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil {
                try? fileHandle.close()
                connection.cancel()
                self.removeConn(oid)
                onFileTransferProgress?(.finished(queueItemID: queueItemID))
                return
            }
            onFileTransferProgress?(.bytesSent(queueItemID: queueItemID, count: n))
            let nextRemaining = remaining - n
            if nextRemaining <= 0 {
                try? fileHandle.close()
                connection.cancel()
                self.removeConn(oid)
                onFileTransferProgress?(.finished(queueItemID: queueItemID))
                return
            }
            self.sendFileChunks(
                connection: connection,
                fileHandle: fileHandle,
                remaining: nextRemaining,
                oid: oid,
                queueItemID: queueItemID,
                onFileTransferProgress: onFileTransferProgress
            )
        })
    }

    private func respond(connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        let oid = ObjectIdentifier(connection)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConn(oid)
        })
    }
}
