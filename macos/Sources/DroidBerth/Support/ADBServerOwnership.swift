import Darwin
import Foundation

/// 「退出时要不要收掉 adb server」的判据 —— PRD 的 E8 / Guideline **2.4.5(iii)**。
///
/// 麻烦不在「怎么收」，在「**能不能收**」：5037 上的 server 不一定是我们拉起来的。
/// 用户自己的 Android Studio、命令行里的 `adb`、别的工具用的是同一个端口，而 adb 的行为是
/// 「**有就复用、没有才自己起**」⇒ 退出时无脑 `kill-server` 会把**别人的** server 一起杀掉，
/// 对用户的表现是「Android Studio 突然说设备掉了」—— 比「残留一个进程」更糟。
///
/// 判据因此只有一条：**这个 server 是不是我们拉起来的**。
///
/// | 我们第一次跑 adb 之前 | 5037 上 | 归属 | 退出时 |
/// | --- | --- | --- | --- |
/// | 没有监听 | 第一条 adb 命令会把它拉起来 ⇒ 是我们起的 | `.ours` | **收掉** |
/// | 已有监听 | 复用别人的 ⇒ 我们什么都没启动 | `.foreign` | **不许动** |
/// | （运行中途）`ADBRecovery.restartServer()` 成功 | 我们 kill 过、又起过 | `.ours` | **收掉** |
///
/// ⚠️ 已知边界（写在这里免得以后被当成 bug）：若**在我们运行期间**用户自己把 server 换掉
/// （他跑一次 `adb kill-server`，再让 Android Studio 起一个），我们退出时仍会按
/// 「这个端口曾归我们」去收一次。对用户是可恢复的（他的工具会自己重启 server），
/// 而要做到完全精确就得记 PID 再比对 —— 收益不抵复杂度，所以停在这里。
///
/// **本文件刻意零项目依赖**（只有 Foundation / Darwin）：它要被守卫单独编译，
/// 而 `check-all.sh` 的依赖清单是手写的 —— 多拉一个文件就多一次「清单过期」的机会。
/// 需要 `ADBBinary` / `ProcessRunner` 的那一半放在 `ADBRecovery` 里。
final class ADBServerOwnership: @unchecked Sendable {
    /// adb 的默认客户端端口（它自己文档里的 `ANDROID_ADB_SERVER_PORT` 默认值）。
    static let fallbackPort: UInt16 = 5037

    /// adb **实际**会用的端口。
    ///
    /// **必须跟着 `ANDROID_ADB_SERVER_PORT` 走**，否则判据与事实不符：adb 客户端认这个环境
    /// 变量，用户（或我们自己，用来把测试与用户的 server 隔开）设了它之后命令走的是那个端口，
    /// 而我们若还去探 5037 —— 探到的多半是**用户的** server，于是判成 `.foreign`、
    /// **永远不收**。那正是「判据错了、但看起来完全正常」的形态。
    static var defaultPort: UInt16 {
        port(fromEnvironment: ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"])
    }

    /// 解析环境变量。**纯函数** —— 守卫直接喂各种取值，不必真去改进程环境。
    ///
    /// 非法取值（空 / 非数字 / 0 / 超出 `UInt16`）一律退回默认端口：宁可去探一个已知的端口，
    /// 也不要因为一个坏环境变量而**放弃探测** —— 放弃探测等于每次退出都误判。
    static func port(fromEnvironment raw: String?) -> UInt16 {
        guard let raw, let value = UInt16(raw), value > 0 else { return fallbackPort }
        return value
    }

    static let shared = ADBServerOwnership()

    enum Owner: Equatable, Sendable {
        /// 还没探测过。**这时候不许动手**。
        case unknown
        /// 我们启动的（或我们重启过的）。
        case ours
        /// 复用了别人的 ⇒ 我们没启动过任何东西。
        case foreign
    }

    private let lock = NSLock()
    private var stored: Owner = .unknown

    var owner: Owner {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// 退出时该不该 `kill-server`。**纯函数**，守卫直接喂三种取值。
    ///
    /// `.unknown` 必须是 false：它表示「还没探测过」，把「不知道」当成「是我们的」
    /// 正是这里要避免的错。
    static func shouldShutdown(_ owner: Owner) -> Bool {
        owner == .ours
    }

    /// 状态迁移。与**探测**分开是为了可测 —— 守卫不需要真 server 就能把三种情况喂进来。
    func record(serverWasListening: Bool) {
        lock.lock()
        stored = serverWasListening ? .foreign : .ours
        lock.unlock()
    }

    /// 在任何 adb 命令**可能隐式拉起 server** 之前调用一次。
    ///
    /// ⚠️ 必须**同步**：`adb` 的第一条命令就会把 server 拉起来，异步探测必然测到
    /// 「已经有了」，于是永远判成 `.foreign` —— 那条错法表现为「**永远不收**」，
    /// 而它看起来完全正常（App Review 之外没有任何反馈）。
    func probeBeforeAdbCommands(port: UInt16 = ADBServerOwnership.defaultPort) {
        record(serverWasListening: Self.isListening(port: port))
    }

    /// `ADBRecovery.restartServer()` 成功之后调用 —— 那个函数 kill 过又起过。
    func markRestarted() {
        lock.lock()
        stored = .ours
        lock.unlock()
    }

    /// 我们收过了（或决定不收）⇒ 回到「不知道」。
    func markReleased() {
        lock.lock()
        stored = .unknown
        lock.unlock()
    }

    /// `127.0.0.1:port` 上有人在监听吗。
    ///
    /// 用一次 **TCP connect** 判，不用 `lsof`、也不看 adb 的措辞：
    /// · `lsof` 要另起进程再解析输出（`DiagnosticsExporter` 里那段解析就是先例），而这是
    ///   退出路径上的判据，越少环节越好；
    /// · adb 的措辞会随版本变，而**这条判据错了没人会发现**。
    ///
    /// 连 localhost 是即时的：端口关着会立刻 RST，开着则握手完成。
    static func isListening(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
