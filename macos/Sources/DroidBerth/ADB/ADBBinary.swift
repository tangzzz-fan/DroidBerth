import Foundation

final class ADBBinary: @unchecked Sendable {
    static let shared = ADBBinary()

    private let lock = NSLock()
    private var cached: SidecarResolution?
    private var sidecarMissing = false

    @discardableResult
    func resolve(force: Bool = false) -> SidecarResolution? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, !force { return cached }
        guard let sidecar = SidecarLocator.locate().executable else {
            sidecarMissing = true
            return nil
        }
        sidecarMissing = false
        let value = SidecarClient(executable: sidecar).resolve()
        cached = value
        return value
    }

    var path: URL? {
        guard let resolution = resolve(), resolution.found, let path = resolution.path else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isSidecarMissing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sidecarMissing
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
