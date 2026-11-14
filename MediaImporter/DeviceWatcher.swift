import Foundation
import Combine
import ImageCaptureCore

/// 监听通过数据线连接的 iPhone / iPad（ImageCaptureCore 设备浏览器）
final class DeviceWatcher: NSObject, ObservableObject, ICDeviceBrowserDelegate {

    struct Info: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published private(set) var devices: [Info] = []

    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var started = false

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        browser.start()
    }

    func stop() {
        guard started else { return }
        started = false
        browser.stop()
    }

    func refresh() {
        devices = cameras.values.compactMap { camera in
            guard let id = camera.uuidString ?? camera.name else { return nil }
            return Info(id: id, name: camera.name ?? "iOS 设备")
        }
            .sorted { $0.name < $1.name }
    }

    func camera(for id: String) -> ICCameraDevice? {
        cameras[id]
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = camera.uuidString ?? camera.name ?? UUID().uuidString
        cameras[id] = camera
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0.id == id }) {
                self.devices.append(Info(id: id, name: camera.name ?? "iOS 设备"))
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = camera.uuidString ?? camera.name ?? ""
        cameras.removeValue(forKey: id)
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == id }
        }
    }
}
