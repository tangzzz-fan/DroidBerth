import Foundation

/// adb server 的自愈。
///
/// 「adb 崩了」在用户那里是一个笼统的说法，实际至少是三类**完全不同**的故障：
///
/// | 现象 | 真因 | 能不能自动修 |
/// | --- | --- | --- |
/// | `cannot connect to daemon` / `server is out of date` / `didn't ACK` | **客户端与 server 之间的连接坏了**，设备侧什么事都没发生 | **能** —— 重启 server 后重发即可 |
/// | 设备离线 / `device unauthorized` | 设备侧状态，需要人去手机上点一下 | 不能（这正是引导卡片存在的理由） |
/// | 权限、文件不存在、路径非法 | 命令本身的问题 | 不能，重发也一样 |
///
/// 这里只处理第一类。判据是 **stderr 里的具体措辞**，不是「失败了就重启」——
/// 后者会把重试浪费在第二、三类上，还会把真实的错误信息冲掉。
///
/// 之所以敢对**写操作**也重试：第一类的共同点是**客户端根本没跟设备说上话**，
/// 命令压根没执行。这是「可以安全重发」的全部依据 —— 换成第二、三类就不成立了。
enum ADBRecovery {
    /// 全部是**客户端 ↔ server** 之间的故障措辞。逐条都有出处：前三条来自
    /// adb 自身的 `client.cpp` / `socket_spec` 报错，后几条来自 `daemon` 启动失败。
    private static let markers = [
        "cannot connect to daemon",
        "adb server is out of date",
        "adb server version",            // "adb server version (41) doesn't match this client (36)"
        "server didn't ack",
        "could not read ok from adb server",
        "failed to start daemon",
        "cannot bind to 127.0.0.1:5037",
        "protocol fault",
    ]

    static func suggestsServerRestart(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// 重启 server。**唯一入口** —— 多个调用点各自 `kill-server` 只会互相打架
    /// （一个刚起、另一个又杀）。
    @discardableResult
    static func restartServer(binary: URL) -> Bool {
        AppLog.warning("adb server 不可达，重启后重试一次", .adb)
        // `kill-server` 在没有 server 时会返回非 0，属正常，所以它的结果不作为判据。
        _ = ProcessRunner.run(binary, ["kill-server"], timeout: 15)
        let started = ProcessRunner.run(binary, ["start-server"], timeout: 30)
        // 我们刚 kill 过又起过 ⇒ 这个 server 从此归我们管、**退出时要收**（E8）。
        // 放在这里而不是「探测到没有监听就标记」，是因为这一步是**无条件**的：
        // 不管之前 5037 上有没有别人的 server，我们的 `kill-server` 都已经把它带走了。
        if started.ok { ADBServerOwnership.shared.markRestarted() }
        AppLog.notice("adb server 重启\(started.ok ? "完成" : "失败")", .adb)
        return started.ok
    }

    /// 应用退出时收掉**我们自己**起的那个 adb server（E8 / Guideline 2.4.5(iii)：退出后不留进程）。
    ///
    /// 判据与执行分家的原因有两个：
    ///   ① 判据（`ADBServerOwnership`）要能被守卫单独测，不能牵进 `ProcessRunner` / `ADBBinary`；
    ///   ② **只收自己的**这件事本身是承重的 —— 5037 上那个很可能是用户 Android Studio 的。
    ///      无脑 `kill-server` 会让他的设备突然掉线，而用户只会觉得「这个 app 有毒」。
    @discardableResult
    static func shutdownServerIfOurs() -> Bool {
        guard ADBServerOwnership.shouldShutdown(ADBServerOwnership.shared.owner) else { return false }
        guard let adb = ADBBinary.shared.path else { return false }
        AppLog.notice("退出：收掉本次启动的 adb server", .adb)
        // 超时要短 —— 本函数跑在 `applicationWillTerminate` 里，系统只给几秒。
        _ = ProcessRunner.run(adb, ["kill-server"], timeout: 3)
        ADBServerOwnership.shared.markReleased()
        return true
    }
}
