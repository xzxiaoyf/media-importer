import Foundation
import AppKit
import ImageIO
import ImageCaptureCore

// MARK: - 处理方式

enum OrganizeMode: String, CaseIterable, Identifiable {
    case flat
    case byDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat:   return "全部拷贝到同一目录"
        case .byDate: return "按拍摄日期建立子目录（YYYY-MM-DD）"
        }
    }
}

// MARK: - 统计

struct ImportSummary {
    var copied = 0
    var skipped = 0
    var failed = 0
    var bytes: Int64 = 0

    var description: String {
        "成功 \(copied) 个，跳过 \(skipped) 个，失败 \(failed) 个，共 \(ByteFormatter.human(bytes))"
    }
}

enum ByteFormatter {
    static func human(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var index = 0
        while size >= 1024, index < units.count - 1 {
            size /= 1024
            index += 1
        }
        return String(format: "%.1f %@", size, units[index])
    }
}

// MARK: - 媒体类型识别

enum MediaKind {
    case image
    case video
}

enum MediaType {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "webp"
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp", "mpg", "mpeg"
    ]

    static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }
}

// MARK: - 拍摄日期读取

enum MediaDate {
    static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 优先读取照片 EXIF 的拍摄时间，取不到则退回文件创建时间 / 修改时间
    static func captureDate(for url: URL) -> Date? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let date = exifFormatter.date(from: text) {
                return date
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let text = tiff[kCGImagePropertyTIFFDateTime] as? String,
               let date = exifFormatter.date(from: text) {
                return date
            }
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}

// MARK: - 日志文件写入

final class LogFileWriter {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

// MARK: - 导入引擎

final class ImportEngine: ObservableObject {
    @Published private(set) var logLines: [String] = []
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = "就绪"
    @Published private(set) var logFilePath = ""

    private var cancelledFlag = false
    private var writer: LogFileWriter?
    private var deviceImporter: DeviceImporter?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    var isCancelled: Bool { cancelledFlag }

    // MARK: 对外入口

    func cancel() {
        guard running else { return }
        cancelledFlag = true
        log("收到取消请求，正在停止…")
        updateStatus("正在取消…")
    }

    /// 本地文件夹模式（iPhone 的 DCIM 拷贝、照片 App 导出的文件夹、SD 卡等）
    func startFolderImport(source: URL, target: URL, mode: OrganizeMode) {
        guard begin(target: target) else {
            DispatchQueue.main.async {
                self.running = false
                self.statusText = "无法在目标目录创建日志文件"
            }
            return
        }
        log("=== 开始处理（本地文件夹模式） ===")
        log("源目录：\(source.path)")
        log("目标目录：\(target.path)")
        log("处理方式：\(mode.title)")

        DispatchQueue.global(qos: .userInitiated).async {
            let files = self.collectMedia(in: source)
            self.log("共发现 \(files.count) 个照片 / 视频文件")
            guard !files.isEmpty else {
                self.finish(ImportSummary())
                return
            }

            let fm = FileManager.default
            var summary = ImportSummary()

            for (index, file) in files.enumerated() {
                if self.cancelledFlag {
                    self.log("用户取消，已停止")
                    break
                }

                let dir = self.destinationDirectory(for: file, target: target, mode: mode)
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if let dest = self.uniqueDestination(for: file.lastPathComponent, in: dir, sourceSize: size) {
                        try fm.copyItem(at: file, to: dest)
                        summary.copied += 1
                        summary.bytes += size
                        self.log("[\(index + 1)/\(files.count)] ✅ \(file.lastPathComponent) → \(dest.path)")
                    } else {
                        summary.skipped += 1
                        self.log("[\(index + 1)/\(files.count)] ⏭ 已存在，跳过：\(file.lastPathComponent)")
                    }
                } catch {
                    summary.failed += 1
                    self.log("[\(index + 1)/\(files.count)] ❌ 失败：\(file.lastPathComponent)（\(error.localizedDescription)）")
                }

                self.report(progress: Double(index + 1) / Double(files.count),
                            text: "\(index + 1)/\(files.count)")
            }

            self.finish(summary)
        }
    }

    /// iPhone / iPad 设备模式
    func startDeviceImport(camera: ICCameraDevice, target: URL, mode: OrganizeMode) {
        guard begin(target: target) else {
            DispatchQueue.main.async {
                self.running = false
                self.statusText = "无法在目标目录创建日志文件"
            }
            return
        }
        log("=== 开始处理（设备模式） ===")
        log("设备：\(camera.name ?? "iOS 设备")")
        log("目标目录：\(target.path)")
        log("处理方式：\(mode.title)")

        let importer = DeviceImporter(
            camera: camera,
            target: target,
            mode: mode,
            log: { [weak self] message in self?.log(message) },
            progress: { [weak self] value, text in self?.report(progress: value, text: text) },
            isCancelled: { [weak self] in self?.cancelledFlag ?? true },
            finished: { [weak self] summary, error in
                self?.finish(summary, error: error)
                self?.deviceImporter = nil
            }
        )
        deviceImporter = importer
        importer.start()
    }

    // MARK: 日志

    func log(_ message: String) {
        let line = "[\(timeFormatter.string(from: Date()))] \(message)"
        writer?.write(line)
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 20000 {
                self.logLines.removeFirst(self.logLines.count - 20000)
            }
        }
    }

    // MARK: 内部实现

    private func begin(target: URL) -> Bool {
        cancelledFlag = false
        progress = 0
        logLines.removeAll()
        running = true
        statusText = "正在处理…"

        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let name = Self.fileStampFormatter.string(from: Date()) + "_log.txt"
            let url = target.appendingPathComponent(name)
            writer = try LogFileWriter(url: url)
            logFilePath = url.path
            log("日志文件：\(url.path)")
            return true
        } catch {
            writer = nil
            logFilePath = ""
            return false
        }
    }

    private func finish(_ summary: ImportSummary? = nil, error: Error? = nil) {
        if let summary {
            log("处理结束：\(summary.description)")
        }
        if let error {
            log("错误：\(error.localizedDescription)")
        }
        if !logFilePath.isEmpty {
            log("日志已保存：\(logFilePath)")
        }
        writer?.close()
        writer = nil

        let wasCancelled = cancelledFlag
        DispatchQueue.main.async {
            self.running = false
            if wasCancelled {
                self.statusText = "已取消（部分完成）"
            } else {
                self.progress = 1
                self.statusText = "完成"
            }
        }
    }

    private func report(progress value: Double, text: String) {
        DispatchQueue.main.async {
            self.progress = min(max(value, 0), 1)
            self.statusText = text
        }
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    private func collectMedia(in root: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: keys) else {
            return []
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }          // 跳过隐藏文件与 ._AppleDouble
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            if MediaType.kind(of: url) != nil {
                result.append(url)
            }
        }
        result.sort { $0.lastPathComponent < $1.lastPathComponent }
        return result
    }

    private func destinationDirectory(for file: URL, target: URL, mode: OrganizeMode) -> URL {
        guard mode == .byDate else { return target }
        let folder = MediaDate.captureDate(for: file).map { MediaDate.dayFormatter.string(from: $0) } ?? "未知日期"
        return target.appendingPathComponent(folder, isDirectory: true)
    }

    /// 返回可用的目标 URL；若同名且大小相同（视为同一文件）返回 nil 表示跳过
    private func uniqueDestination(for name: String, in dir: URL, sourceSize: Int64) -> URL? {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)

        if !fm.fileExists(atPath: candidate.path) { return candidate }

        if let attrs = try? fm.attributesOfItem(atPath: candidate.path),
           let size = attrs[.size] as? Int64, size == sourceSize {
            return nil
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while index < 10000 {
            let newName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        return nil
    }
}
