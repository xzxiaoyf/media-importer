import SwiftUI
import AppKit

struct ContentView: View {

    enum SourceKind: String, CaseIterable, Identifiable {
        case device
        case folder

        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: return "iPhone / iPad 设备"
            case .folder: return "本地文件夹 / DCIM"
            }
        }
    }

    @StateObject private var engine = ImportEngine()
    @StateObject private var watcher = DeviceWatcher()

    @State private var sourceKind: SourceKind = .device
    @State private var selectedDeviceID: String?
    @State private var sourceFolder: URL?
    @State private var targetFolder: URL?
    @State private var mode: OrganizeMode = .byDate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourceSection
            targetSection
            modeSection
            actionSection
            progressSection
            logSection
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 640)
        .onAppear {
            watcher.start()
            if selectedDeviceID == nil {
                selectedDeviceID = watcher.devices.first?.id
            }
        }
        .onDisappear { watcher.stop() }
    }

    // MARK: - 各区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("📷 iPhone / iPad 媒体导入工具")
                .font(.title2)
                .bold()
            Text("把设备中的照片、视频原文件拷贝到 Mac 指定目录，可按拍摄日期自动分文件夹。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceSection: some View {
        GroupBox("1. 选择来源") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $sourceKind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if sourceKind == .device {
                    HStack(spacing: 8) {
                        Text("设备")
                            .frame(width: 64, alignment: .leading)
                            .foregroundStyle(.secondary)

                        Picker("", selection: $selectedDeviceID) {
                            if watcher.devices.isEmpty {
                                Text("未检测到设备").tag(String?.none)
                            } else {
                                ForEach(watcher.devices) { device in
                                    Text(device.name).tag(String?.some(device.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)

                        Button("刷新") { refreshDevices() }
                            .disabled(engine.running)

                        Spacer()

                        if watcher.devices.isEmpty {
                            Text("请用数据线连接，并在设备上点「信任」")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("源目录")
                            .frame(width: 64, alignment: .leading)
                            .foregroundStyle(.secondary)

                        Text(sourceFolder?.path ?? "未选择")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(sourceFolder == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("选择…") { pickSourceFolder() }
                            .disabled(engine.running)
                    }
                }
            }
            .padding(6)
        }
    }

    private var targetSection: some View {
        GroupBox("2. 选择保存目录") {
            HStack(spacing: 8) {
                Text("目标目录")
                    .frame(width: 64, alignment: .leading)
                    .foregroundStyle(.secondary)

                Text(targetFolder?.path ?? "未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(targetFolder == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("选择…") { pickTargetFolder() }
                    .disabled(engine.running)
            }
            .padding(6)
        }
    }

    private var modeSection: some View {
        GroupBox("3. 拷贝方式") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $mode) {
                    ForEach(OrganizeMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(engine.running)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            if engine.running {
                Button("取消处理") { engine.cancel() }
            } else {
                Button("开始处理") { beginProcessing() }
                    .keyboardShortcut(.defaultAction)
            }

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }

            Spacer()

            Text(engine.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .opacity(engine.running ? 1 : 0.35)
            if !engine.logFilePath.isEmpty {
                Text("日志文件：\(engine.logFilePath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var logSection: some View {
        GroupBox("运行日志") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(engine.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("log-bottom")
                    }
                    .padding(6)
                }
                .frame(minHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .task(id: engine.logLines.count) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 交互

    private func beginProcessing() {
        guard let target = targetFolder else {
            engine.log("⚠️ 请先选择保存目录")
            return
        }

        switch sourceKind {
        case .device:
            guard let id = selectedDeviceID, let camera = watcher.camera(for: id) else {
                engine.log("⚠️ 请先选择已连接的 iPhone / iPad 设备")
                return
            }
            engine.startDeviceImport(camera: camera, target: target, mode: mode)

        case .folder:
            guard let source = sourceFolder else {
                engine.log("⚠️ 请先选择源文件夹")
                return
            }
            guard source.path != target.path else {
                engine.log("⚠️ 源目录与目标目录不能相同")
                return
            }
            engine.startFolderImport(source: source, target: target, mode: mode)
        }
    }

    private func refreshDevices() {
        watcher.refresh()
        if selectedDeviceID == nil || watcher.camera(for: selectedDeviceID ?? "") == nil {
            selectedDeviceID = watcher.devices.first?.id
        }
    }

    private func pickSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择要导入的源文件夹（例如 iPhone 的 DCIM 拷贝，或照片 App 导出的目录）"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK {
            sourceFolder = panel.url
        }
    }

    private func pickTargetFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择照片 / 视频要保存到的目录"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK {
            targetFolder = panel.url
        }
    }
}
