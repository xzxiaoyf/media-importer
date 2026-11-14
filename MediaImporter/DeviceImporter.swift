import Foundation
import ImageCaptureCore
import CoreGraphics

/// 从 iPhone / iPad 逐文件下载媒体原文件
final class DeviceImporter: NSObject, ICDeviceDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {

    private let camera: ICCameraDevice
    private let target: URL
    private let mode: OrganizeMode

    private let log: (String) -> Void
    private let progressHandler: (Double, String) -> Void
    private let isCancelled: () -> Bool
    private let finished: (ImportSummary, Error?) -> Void

    private var queue: [ICCameraFile] = []
    private var total = 0
    private var processed = 0
    private var summary = ImportSummary()
    private var isDone = false
    private var didStartDownloading = false
    private var wantsFreshEnumeration = false
    private var fallbackTimer: Timer?
    private var currentDestPath = ""

    init(camera: ICCameraDevice,
         target: URL,
         mode: OrganizeMode,
         log: @escaping (String) -> Void,
         progress: @escaping (Double, String) -> Void,
         isCancelled: @escaping () -> Bool,
         finished: @escaping (ImportSummary, Error?) -> Void) {
        self.camera = camera
        self.target = target
        self.mode = mode
        self.log = log
        self.progressHandler = progress
        self.isCancelled = isCancelled
        self.finished = finished
        super.init()
    }

    func start() {
        camera.delegate = self
        log("正在打开设备会话…")
        if camera.hasOpenSession {
            // 会话已开过但内容可能未枚举完整：先关再开，强制重新枚举
            wantsFreshEnumeration = true
            camera.requestCloseSession()
        } else {
            camera.requestOpenSession()
        }
        scheduleFallback()
    }

    /// 兜底：个别设备可能不发完整目录通知，超时后直接尝试读取
    private func scheduleFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, !self.isDone, !self.didStartDownloading else { return }
            self.log("⚠️ 20 秒内未收到设备目录枚举完成通知，尝试直接读取当前内容…")
            self.startDownloadingIfNeeded(self.camera)
        }
    }

    // MARK: - 下载主流程

    private func downloadNext() {
        if isDone { return }

        if isCancelled() {
            log("用户取消，停止导出")
            finishNow(nil)
            return
        }
        guard !queue.isEmpty else {
            finishNow(nil)
            return
        }

        let file = queue.removeFirst()
        let name = file.name ?? "未命名文件"
        let size = Int64(file.fileSize)
        let dir = destinationDirectory(for: file)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            summary.failed += 1
            log("❌ 无法创建目录 \(dir.path)：\(error.localizedDescription)")
            advance()
            DispatchQueue.main.async { self.downloadNext() }
            return
        }

        let dest = dir.appendingPathComponent(name)
        currentDestPath = dest.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let existing = attrs[.size] as? Int64, existing == size {
            summary.skipped += 1
            log("[\(processed + 1)/\(total)] ⏭ 已存在，跳过：\(dest.path)")
            advance()
            DispatchQueue.main.async { self.downloadNext() }
            return
        }

        log("[\(processed + 1)/\(total)] ⬇︎ \(name)（\(ByteFormatter.human(size))）")

        let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: dir]
        camera.requestDownloadFile(file,
                                  options: options,
                                  downloadDelegate: self,
                                  didDownloadSelector: #selector(ICCameraDeviceDownloadDelegate.didDownloadFile(_:error:options:contextInfo:)),
                                  contextInfo: nil)
    }

    private func advance() {
        processed += 1
        let value = total > 0 ? Double(processed) / Double(total) : 0
        progressHandler(value, "\(processed)/\(total)")
    }

    private func finishNow(_ error: Error?) {
        guard !isDone else { return }
        isDone = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if camera.hasOpenSession {
            camera.requestCloseSession()
        }
        finished(summary, error)
    }

    private func destinationDirectory(for file: ICCameraFile) -> URL {
        guard mode == .byDate else { return target }
        let date = file.creationDate ?? file.modificationDate
        let folder = date.map { MediaDate.dayFormatter.string(from: $0) } ?? "未知日期"
        return target.appendingPathComponent(folder, isDirectory: true)
    }

    // MARK: - 下载回调

    func didDownloadFile(_ file: ICCameraFile,
                         error: Error?,
                         options: [String: Any],
                         contextInfo: UnsafeMutableRawPointer?) {
        let name = file.name ?? "未命名文件"
        if let error {
            summary.failed += 1
            log("❌ 下载失败：\(name)（\(error.localizedDescription)）")
        } else {
            summary.copied += 1
            summary.bytes += Int64(file.fileSize)
            log("✅ 完成：\(name) → \(currentDestPath)")
        }
        advance()
        downloadNext()
    }

    func cameraDevice(_ camera: ICCameraDevice,
                      didReceiveDownloadProgressForFile file: ICCameraFile,
                      downloadedBytes: off_t,
                      maxBytes: off_t) {
        guard maxBytes > 0 else { return }
        let fileProgress = Double(downloadedBytes) / Double(maxBytes)
        let value = (Double(processed) + fileProgress) / Double(max(total, 1))
        progressHandler(value, "\(processed)/\(total) · \(file.name ?? "")")
    }

    // MARK: - ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            log("❌ 打开设备会话失败：\(error.localizedDescription)")
            finishNow(error)
            return
        }
        log("设备会话已打开，正在枚举内容目录…")
    }

    /// 关键：只有收到「完整内容目录」通知后才代表枚举结束，此时读取才有文件
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        startDownloadingIfNeeded(device)
    }

    private func startDownloadingIfNeeded(_ device: ICDevice) {
        guard !isDone, !didStartDownloading, let camera = device as? ICCameraDevice else { return }
        didStartDownloading = true

        let files = collectFiles(from: camera)
        queue = files
        total = files.count
        log("设备内可导出文件：\(total) 个")

        if total == 0 {
            log("设备中没有可导出的照片或视频")
            finishNow(nil)
            return
        }
        downloadNext()
    }

    /// 递归遍历 contents 目录树收集文件；取不到再退回 mediaFiles
    private func collectFiles(from camera: ICCameraDevice) -> [ICCameraFile] {
        var result: [ICCameraFile] = []

        func walk(_ items: [ICCameraItem]) {
            for item in items {
                if let folder = item as? ICCameraFolder {
                    walk(folder.contents ?? [])
                } else if let file = item as? ICCameraFile {
                    result.append(file)
                }
            }
        }

        walk(camera.contents ?? [])

        if result.isEmpty {
            result = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        }
        result.sort { ($0.name ?? "") < ($1.name ?? "") }
        return result
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if let error {
            log("关闭设备会话时出错：\(error.localizedDescription)")
        }
        if wantsFreshEnumeration && !isDone {
            wantsFreshEnumeration = false
            log("重新打开设备会话以获取完整内容目录…")
            camera.requestOpenSession()
        }
    }

    func didRemove(_ device: ICDevice) {
        log("设备已断开连接")
        if !isDone {
            summary.failed += queue.count
            queue.removeAll()
            finishNow(nil)
        }
    }

    // MARK: - ICCameraDeviceDelegate 必需方法（本程序不使用，留空实现）

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDevice(_ camera: ICCameraDevice,
                      didReceiveThumbnail thumbnail: CGImage?,
                      for item: ICCameraItem,
                      error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice,
                      didReceiveMetadata metadata: [AnyHashable: Any]?,
                      for item: ICCameraItem,
                      error: Error?) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log("设备已解锁，媒体可访问")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log("⚠️ 设备处于锁定状态，请解锁 iPhone / iPad 后重试")
    }
}
