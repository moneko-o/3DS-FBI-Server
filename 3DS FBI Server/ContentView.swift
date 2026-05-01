//
//  ContentView.swift
//  3DS FBI Server
//

import SwiftUI
import UniformTypeIdentifiers

private let importContentTypes: [UTType] = {
    let t = ["cia", "tik"].compactMap { UTType(filenameExtension: $0) }
    return t.isEmpty ? [.data] : t
}()

private let queueRowXferFont = Font.system(size: 8)
private let queueNameProgressFill = LinearGradient(
    colors: [Color.accentColor.opacity(0.42), Color.accentColor.opacity(0.14)],
    startPoint: .leading,
    endPoint: .trailing
)

private enum SidebarIPPortField: Hashable {
    case ip, port
}

private enum ActivityScroll {
    static let logEnd = "activityLogEnd"
}

private func secondaryFootnote(_ title: String) -> some View {
    Text(title).font(.footnote).foregroundStyle(.secondary)
}

private enum AppBundleInfo {
    static var footerText: String {
        let b = Bundle.main
        let s = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let n = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let v = n.isEmpty ? String(format: String(localized: "Version %@"), s) : String(format: String(localized: "Version %@ (%@)"), s, n)
        let c = (b.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String) ?? ""
        return c.isEmpty ? v : "\(v)\n\(c)"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var showFileImporter = false
    @State private var showURLField = false
    @State private var urlString = "https://"
    @State private var manualIP = ""
    @State private var manualPort = "5000"
    @State private var selectedConsoleId: UUID?
    @State private var editingConsoleId: UUID?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var ipPortFocus: SidebarIPPortField?

    var body: some View {
        ZStack {
            WindowBackdropBlurView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            NavigationSplitView(columnVisibility: $splitVisibility) {
                ConsoleSidebarPane(
                    consoleManager: model.consoleManager,
                    appModel: model,
                    isServing: model.isServing,
                    manualIP: $manualIP,
                    manualPort: $manualPort,
                    selectedConsoleId: $selectedConsoleId,
                    editingConsoleId: $editingConsoleId,
                    ipPortFocus: $ipPortFocus,
                    onSubmitConsole: submitConsoleEntry
                )
            } detail: {
                QueueDetailPane(
                    fileManager: model.fileManager,
                    appModel: model,
                    activityLog: model.activityLog,
                    selectedConsoleId: $selectedConsoleId,
                    editingConsoleId: $editingConsoleId,
                    showFileImporter: $showFileImporter,
                    showURLField: $showURLField,
                    urlString: $urlString,
                    ipPortFocus: $ipPortFocus
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewStyle(.balanced)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importContentTypes, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.addDroppedFileURLs(urls) }
        }
        .alert(String(localized: "Add URL"), isPresented: $showURLField) {
            TextField(String(localized: "https://…"), text: $urlString)
            Button { model.addCIAURLString(urlString) } label: {
                Label(String(localized: "Add"), systemImage: "plus")
            }
            Button(role: .cancel) {} label: {
                Label(String(localized: "Cancel"), systemImage: "xmark")
            }
        } message: {
            Text(String(localized: "Enter a link to a CIA file."))
        }
    }

    private func submitConsoleEntry() {
        ipPortFocus = nil
        let port = UInt16(manualPort.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5000
        let trimmed = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id = editingConsoleId {
            model.updateConsole(id: id, ipAddress: trimmed, port: port)
            editingConsoleId = nil
        } else if let id = model.addConsole(ipAddress: trimmed, port: port) {
            selectedConsoleId = id
        }
    }
}

// MARK: - Sidebar (observes console list only)

private struct ConsoleSidebarPane: View {
    @ObservedObject var consoleManager: VKMConsoleManager
    let appModel: AppViewModel
    var isServing: Bool
    @Binding var manualIP: String
    @Binding var manualPort: String
    @Binding var selectedConsoleId: UUID?
    @Binding var editingConsoleId: UUID?
    @FocusState.Binding var ipPortFocus: SidebarIPPortField?
    var onSubmitConsole: () -> Void

    private var servingDimOpacity: Double { isServing ? 0.55 : 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    secondaryFootnote(String(localized: "Use the IP and port from FBI → Remote install. This Mac can discover consoles on the LAN."))
                        .fixedSize(horizontal: false, vertical: true)
                    SidebarFusedIPPortFields(
                        manualIP: $manualIP,
                        manualPort: $manualPort,
                        isDisabled: isServing,
                        focusedField: $ipPortFocus
                    ) {
                        Button(action: onSubmitConsole) {
                            Image(systemName: editingConsoleId == nil ? "plus" : "checkmark")
                                .frame(width: 24, height: 24, alignment: .center)
                        }
                        .buttonBorderShape(.circle)
                        .buttonStyle(.glass)
                        .opacity(servingDimOpacity)
                        .disabled(isServing)
                    }
                    if consoleManager.dataArray.isEmpty {
                        secondaryFootnote(String(localized: "No consoles yet. Fill IP and port, then click Add."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(consoleManager.dataArray) { consoleEntryRow($0) }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
            .scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize).background(Color.clear)
            .navigationTitle(String(localized: "Consoles"))
            .onExitCommand { ipPortFocus = nil }
        }
        .background(Color.clear)
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        .onChange(of: isServing) { _, serving in
            if serving { ipPortFocus = nil }
        }
    }

    private func consoleEntryRow(_ item: ConsoleManagerItem) -> some View {
        let selected = selectedConsoleId == item.id

        return Button {
            ipPortFocus = nil
            selectedConsoleId = item.id
        } label: {
            HStack(spacing: 2) {
                Text(item.ipAddress)
                    .font(.callout.monospaced())
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(":")
                    .font(.callout)
                    .foregroundStyle(selected ? Color.accentColor.opacity(0.75) : Color.secondary)
                Text(String(item.port))
                    .font(.callout.monospaced())
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .consoleRowGlass(selected: selected)
        .contextMenu {
            if !isServing {
                Button { beginEditing(item) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
                Button(role: .destructive) {
                    appModel.removeConsole(id: item.id)
                    if editingConsoleId == item.id { editingConsoleId = nil }
                    if selectedConsoleId == item.id { selectedConsoleId = nil }
                } label: { Label(String(localized: "Delete"), systemImage: "trash") }
            }
        }
    }

    private func beginEditing(_ item: ConsoleManagerItem) {
        manualIP = item.ipAddress
        manualPort = String(item.port)
        editingConsoleId = item.id
        selectedConsoleId = item.id
    }
}

// MARK: - Activity log only (high-frequency updates isolated from queue/toolbar)

private struct ActivityLogSection: View {
    @ObservedObject var activityLog: ActivityLogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Activity").font(.headline.weight(.semibold))
            Text(String(localized: "Server status and transfer messages."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(activityLog.text)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                        Color.clear.frame(height: 1).id(ActivityScroll.logEnd)
                    }
                }
                .frame(height: 100)
                .scrollBounceBehavior(.basedOnSize)
                .liquidGlassRoundedRect()
                .onChange(of: activityLog.text) { _, _ in
                    scrollActivityLogToEnd(proxy, duration: 0.2)
                }
                .onAppear {
                    Task { scrollActivityLogToEnd(proxy, duration: 0.1) }
                }
            }
        }
    }

    private func scrollActivityLogToEnd(_ proxy: ScrollViewProxy, duration: Double) {
        withAnimation(.easeOut(duration: duration)) {
            proxy.scrollTo(ActivityScroll.logEnd, anchor: .bottom)
        }
    }
}

// MARK: - Detail (observes queue + serving chrome; activity log is separate)

private struct QueueDetailPane: View {
    @ObservedObject var fileManager: VKMFileManager
    @ObservedObject var appModel: AppViewModel
    let activityLog: ActivityLogStore
    @Binding var selectedConsoleId: UUID?
    @Binding var editingConsoleId: UUID?
    @Binding var showFileImporter: Bool
    @Binding var showURLField: Bool
    @Binding var urlString: String
    @FocusState.Binding var ipPortFocus: SidebarIPPortField?

    private var servingDimOpacity: Double { appModel.isServing ? 0.55 : 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(String(localized: "Host files locally and push the queue to your 3DS running FBI."))
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    queueSection
                    ActivityLogSection(activityLog: activityLog)
                    Text(AppBundleInfo.footerText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize).background(Color.clear)
            .navigationTitle(String(localized: "3DS FBI Server"))
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 500, minHeight: 300)
        .simultaneousGesture(TapGesture().onEnded { ipPortFocus = nil })
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Queue").font(.headline.weight(.semibold))
                HStack(spacing: 8) {
                    Circle()
                        .fill(appModel.isServing ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(appModel.isServing ? String(localized: "Serving") : String(localized: "Idle"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                Spacer()
                queueHeaderTrailingControls
            }
            VStack(alignment: .leading, spacing: 0) {
                if fileManager.dataArray.isEmpty {
                    secondaryFootnote(String(localized: "Drop files here, or use File / URL beside the title."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(fileManager.dataArray.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index)
                            if index < fileManager.dataArray.count - 1 {
                                Divider().padding(.vertical, 7)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlassRoundedRect()
        }
    }

    private var queueHeaderTrailingControls: some View {
        HStack(spacing: 8) {
            Button(String(localized: "File"), systemImage: "doc.badge.plus") {
                showFileImporter = true
            }
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .opacity(servingDimOpacity)
            .disabled(appModel.isServing)

            Button(String(localized: "URL"), systemImage: "link") {
                urlString = "https://"
                showURLField = true
            }
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .opacity(servingDimOpacity)
            .disabled(appModel.isServing)

            Button {
                appModel.resetAll()
                selectedConsoleId = nil
                editingConsoleId = nil
            } label: {
                Label(String(localized: "Reset"), systemImage: "arrow.counterclockwise").foregroundStyle(.white)
            }
            .tint(.orange.opacity(0.8))
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .opacity(servingDimOpacity)
            .disabled(appModel.isServing)

            Button {
                appModel.toggleServing()
            } label: {
                Label(appModel.startStopTitle, systemImage: appModel.isServing ? "stop.fill" : "play.fill")
                    .foregroundStyle(.white)
            }
            .tint(appModel.isServing ? .red.opacity(0.8) : .green.opacity(0.85))
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .opacity(!appModel.isServing && !appModel.hasAtLeastOneConsole ? 0.55 : 1)
            .disabled(!appModel.isServing && !appModel.hasAtLeastOneConsole)
            .keyboardShortcut(.defaultAction)
        }
        .accessibilityElement(children: .contain)
    }

    private func queueRowByteCount(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func queueRow(_ item: VKMFileManagerItem, index: Int) -> some View {
        let metrics = fileManager.transferMetricsByQueueID[item.id]
        let transferring = !item.isUrl && metrics != nil
        let frac = transferring ? (metrics?.fractionComplete ?? 0) : 0
        let namePadH: CGFloat = transferring ? 6 : 0
        let corner: CGFloat = 6
        return HStack(alignment: .center, spacing: 8) {
            Text("\(index + 1)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 20, alignment: .center)
                .padding(.vertical, 2)
                .padding(.horizontal, 5)
                .background { Capsule(style: .continuous).fill(Color.primary.opacity(0.08)) }
            ZStack(alignment: .leading) {
                if transferring {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .allowsHitTesting(false)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(queueNameProgressFill)
                            .frame(width: max(0, g.size.width * CGFloat(frac)))
                    }
                    .allowsHitTesting(false)
                }
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.vertical, 9)
                    .padding(.horizontal, namePadH)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: transferring ? corner : 0, style: .continuous))
            HStack(alignment: .center, spacing: 6) {
                queueRowTrailing(item: item, metrics: metrics, transferring: transferring)
                queueRowDeleteButton(itemId: item.id)
            }
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    private func queueRowDeleteButton(itemId: UUID) -> some View {
        Button {
            appModel.removeQueueItem(id: itemId)
        } label: {
            Image(systemName: "trash").foregroundStyle(.red)
        }
        .buttonBorderShape(.circle)
        .buttonStyle(.glass)
        .disabled(appModel.isServing)
        .opacity(appModel.isServing ? 0.55 : 1)
        .accessibilityLabel(String(localized: "Remove from queue"))
    }

    @ViewBuilder
    private func queueRowTrailing(item: VKMFileManagerItem, metrics: QueueItemTransferMetrics?, transferring: Bool) -> some View {
        if item.isUrl {
            Text(QueueRowFmt.urlScheme(item))
                .font(.caption.weight(.bold))
                .tracking(0.3)
                .foregroundStyle(Color.green.opacity(0.8))
                .lineLimit(1)
                .frame(minWidth: 48, alignment: .trailing)
        } else if transferring, let m = metrics {
            VStack(alignment: .trailing, spacing: 2) {
                Text(queueRowByteCount(item.size))
                    .font(queueRowXferFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(QueueRowFmt.throughput(m.speedBytesPerSecond))
                    .font(queueRowXferFont)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(minWidth: 64, alignment: .trailing)
        } else {
            Text(queueRowByteCount(item.size))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 64, alignment: .trailing)
        }
    }
}

private enum QueueRowFmt {
    static func urlScheme(_ item: VKMFileManagerItem) -> String {
        guard let u = item.clientURL else { return String(localized: "HTTP") }
        let s = (u.scheme ?? "http").uppercased()
        return s.isEmpty ? "HTTP" : s
    }
    static func throughput(_ bps: Double) -> String {
        guard bps >= 8 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + String(localized: "/s")
    }
}

private struct SidebarFusedIPPortFields<Trailing: View>: View {
    @Binding var manualIP: String
    @Binding var manualPort: String
    var isDisabled: Bool
    @FocusState.Binding var focusedField: SidebarIPPortField?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 0) {
                TextField(String(localized: "IP address"), text: $manualIP)
                    .textFieldStyle(.plain)
                    .textContentType(.none)
                    .font(.body)
                    .focused($focusedField, equals: .ip)
                    .padding(.leading, 12)
                    .padding(.trailing, 2)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(":").opacity(0.5).padding(.vertical, 8)
                TextField(String(localized: "Port"), text: $manualPort)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($focusedField, equals: .port)
                    .padding(.leading, 2)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
                    .frame(width: 52.0, alignment: .leading)
            }
            .liquidGlassRoundedRect()
            .clipShape(Capsule(style: .continuous))
            .opacity(isDisabled ? 0.55 : 1)
            .disabled(isDisabled)
            trailing()
        }
    }
}

#Preview {
    ContentView().environmentObject(AppViewModel())
}
