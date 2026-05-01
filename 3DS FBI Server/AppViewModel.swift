//
//  AppViewModel.swift
//  3DS FBI Server
//

import Foundation
import SwiftUI

/// Isolated from `AppViewModel` so high-frequency log appends do not invalidate the whole UI tree via `@EnvironmentObject`.
@MainActor
final class ActivityLogStore: ObservableObject {
    private static let maxLogCharacters = 350_000

    @Published private(set) var text: String = ""

    func append(_ chunk: String) {
        text.append(chunk)
        if text.count > Self.maxLogCharacters {
            text = String(text.suffix(Self.maxLogCharacters))
        }
    }

    func reset(to placeholder: String) {
        text = placeholder
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isServing = false
    @Published var startStopTitle = String(localized: "Start")

    let activityLog = ActivityLogStore()
    let fileManager = VKMFileManager()
    let consoleManager = VKMConsoleManager()

    /// Start is allowed whenever at least one console exists (selection not required; all are contacted).
    var hasAtLeastOneConsole: Bool {
        !consoleManager.dataArray.isEmpty
    }

    init() {
        fileManager.loggingDelegate = self
        consoleManager.delegate = self
    }

    /// Re-assign so `@Published` fires on each logical edit (same pattern as before).
    private func mutateConsoles(_ body: (inout [ConsoleManagerItem]) -> Void) {
        body(&consoleManager.dataArray)
        consoleManager.dataArray = Array(consoleManager.dataArray)
    }

    func appendLog(_ text: String) {
        activityLog.append(text)
    }

    func toggleServing() {
        if fileManager.isHTTPServerRunning {
            stopServing()
        } else {
            startServing()
        }
    }

    func startServing() {
        appendLog(String(localized: "Starting up.\n"))
        Task {
            guard await fileManager.startServing() else { return }
            isServing = true
            startStopTitle = String(localized: "Stop")
            guard let hostURL = fileManager.serverURL else { return }
            consoleManager.sendData(fileList: fileManager.dataArray, hostURL: hostURL)
        }
    }

    func stopServing() {
        appendLog(String(localized: "Shutting down.\n"))
        fileManager.stopServing()
        isServing = false
        startStopTitle = String(localized: "Start")
    }

    func resetAll() {
        stopServing()
        fileManager.clearQueue()
        consoleManager.dataArray = []
        consoleManager.enqueueLANARPScan()
        activityLog.reset(to: String(localized: "<reset>\n"))
    }

    func addDroppedFileURLs(_ urls: [URL]) {
        fileManager.received(fileURLs: urls)
    }

    func addCIAURLString(_ string: String) {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let candidates = [t, t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)].compactMap { $0 }
        for s in candidates {
            guard let u = URL(string: s), let sch = u.scheme?.lowercased(), ["http", "https"].contains(sch) else { continue }
            fileManager.received(url: u)
            return
        }
    }

    func removeQueueItem(id: UUID) {
        fileManager.removeQueueItem(id: id)
    }

    /// Adds a console, or returns the existing row’s id when IP:port already exists (IPv4 octets normalized).
    @discardableResult
    func addConsole(ipAddress: String, port: UInt16) -> UUID? {
        let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = consoleManager.dataArray.first(where: { $0.isSameAddress(ip: trimmed, port: port) }) {
            return existing.id
        }
        let item = ConsoleManagerItem(ipAddress: trimmed, port: port)
        mutateConsoles { $0.append(item) }
        return item.id
    }

    func removeConsole(id: UUID?) {
        guard let id else { return }
        mutateConsoles { $0.removeAll { $0.id == id } }
    }

    func updateConsole(id: UUID, ipAddress: String, port: UInt16) {
        let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if consoleManager.dataArray.contains(where: { $0.id != id && $0.isSameAddress(ip: trimmed, port: port) }) {
            return
        }
        guard let index = consoleManager.dataArray.firstIndex(where: { $0.id == id }) else { return }
        mutateConsoles { rows in
            rows[index].ipAddress = trimmed
            rows[index].port = port
        }
    }
}

extension AppViewModel: VKMLoggingDelegate {
    func logStatus(_ status: String) {
        appendLog(status)
    }
}

extension AppViewModel: ConsoleManagementDelegate {
    func socketsDisconnected() {
        appendLog(String(localized: "All consoles finished downloading.\n"))
        stopServing()
    }

    func foundConsoleWith(consoleManagerItem: ConsoleManagerItem) {
        appendLog(String(localized: "Autodetected 3DS at \(consoleManagerItem.ipAddress), guessing port 5000.\n"))
    }

    func connectedToConsole(_ console: ConsoleManagerItem) {
        appendLog(String(localized: "Connected to 3DS at \(console.ipAddress).\n"))
    }
}
