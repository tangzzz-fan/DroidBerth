import Foundation

// 沙盒版「固定位置」过滤的回归核对（docs/1011_04_appstore-plan.md §4.1）。
//
// 它挡的是**第四种形态**的缺陷：
//
//   ① `check-icon-mapping`       挡「同一份事实写两遍之后分叉」；
//   ② `check-transfer-semantics` 挡「同一个概念在两端语义不同，代码只按一端写」；
//   ③ `check-grid-navigation`    挡「同一个列表在视图里排一次、在键盘逻辑里再排一次」；
//   ④ 这一份挡「**只对某一种运行环境生效的分支**」。
//
// 第 ④ 种最阴：`LocalPlacePolicy` 的两条判据**只在沙盒里才有区别**。侧载版跑一百遍
// 也只会走到「都放行」那一路 —— 手跑、肉眼、编译都不会有任何反馈，而它错了的后果是
// **用户在沙盒版里点开「文稿」，看到一个空文件夹，然后以为文件丢了**。
//
// 所以这份清单必须把**沙盒那一侧**的输入直接喂进去（容器路径是构造出来的字符串，
// 不需要真的在沙盒里跑）。判据与 `scripts/spike-sandbox-adb/` 量到的三类一致：
//
//   容器外 + 能列   → 留        （`Downloads`，有 `files.downloads.read-write`）
//   容器外 + 列不了 → 剔        （`Desktop`/`Movies`/`Pictures`/`Music`，`errno 257`）
//   容器里 + 能列   → 剔        （`Documents`，容器里的**空真目录**，最危险的那一类）
//
// 跑法（不需要 Rust / adb，约 3 秒）：
//
//     mkdir -p /tmp/placecheck && cp scripts/check-local-place-policy.swift /tmp/placecheck/main.swift
//     swiftc -O -o /tmp/placecheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       macos/Sources/DroidBerth/Support/LocalPlacePolicy.swift \
//       /tmp/placecheck/main.swift && /tmp/placecheck/run
//
// 注意 **必须叫 `main.swift`**（顶层代码只允许在这个文件名里），
// 且 helper 要标 `@MainActor`（Swift 6 下顶层代码是 MainActor 隔离的）。

var failures: [String] = []

@MainActor
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { failures.append("\(label)  期望 \(want)，实际 \(got)") }
}

let container = "/Users/a/Library/Containers/dev.tango.droidberth/Data"

func usable(_ resolved: String, container containerPath: String?, canList: Bool) -> Bool {
    LocalPlacePolicy.isUsable(resolvedPath: resolved, containerPath: containerPath, canList: canList)
}

// ── ① 不在沙盒里：两条判据都放行，侧载版行为必须与从前一模一样 ──────────────
check("非沙盒：容器外 + 能列 ⇒ 留", usable("/Users/a/Desktop", container: nil, canList: true), true)
check("非沙盒：空字符串与 nil 等价", usable("/Users/a/Desktop", container: "", canList: true), true)
check("非沙盒：真的列不出来还是要剔", usable("/Users/a/Desktop", container: nil, canList: false), false)

// ── ② 沙盒下：容器外的符号链接 + 有权限 ⇒ 留（对应 `Downloads`）──────────────
check("沙盒：容器外 + 能列 ⇒ 留", usable("/Users/a/Downloads", container: container, canList: true), true)

// ── ③ 沙盒下：容器外的符号链接但读不了 ⇒ 剔（对应 `Desktop`/`Movies`/`Pictures`/`Music`）──
// 只有 `canList` 这条拦得住 —— 它们的 `resolvedPath` 是真实目录，跟容器没关系。
check("沙盒：容器外但列不出来 ⇒ 剔", usable("/Users/a/Desktop", container: container, canList: false), false)
check("沙盒：四个读不了的一视同仁", usable("/Users/a/Movies", container: container, canList: false), false)
check("沙盒：四个读不了的一视同仁", usable("/Users/a/Pictures", container: container, canList: false), false)
check("沙盒：四个读不了的一视同仁", usable("/Users/a/Music", container: container, canList: false), false)

// ── ④ 沙盒下：解析后仍在容器里 ⇒ 剔，**哪怕它列得出来**（对应 `Documents`）──────
// 这一条是本缺陷的核心：容器里的空真目录**能列、不报错**，只有「必须在容器外」拦得住。
check("沙盒：解析后落在容器里 ⇒ 剔（能列也没用）", usable(container + "/Documents", container: container, canList: true), false)
check("沙盒：路径恰好是容器根 ⇒ 剔", usable(container, container: container, canList: true), false)
check("沙盒：容器里的深层目录同样剔", usable(container + "/Library/Logs/DroidBerth/x.log", container: container, canList: true), false)
check("沙盒：`..` 折掉之后再比", usable(container + "/Documents/../Desktop", container: container, canList: true), false)

// ── ⑤ 边界：**按路径分量比，不按字符串前缀** ────────────────────────────────
// 前缀比较会把 `…/DroidBerth/Database` 判成在 `…/DroidBerth/Data` 之内。
check("分量边界：同前缀但不同目录 ⇒ 留", usable("/Users/a/Library/Containers/dev.tango.droidberth/Database/x", container: container, canList: true), true)
check("分量边界：容器末尾带 `/` 结论不变", usable(container + "/Documents", container: container + "/", canList: true), false)
check("分量边界：isInside 对兄弟目录为假", LocalPlacePolicy.isInside("/a/bc", "/a/b"), false)
check("分量边界：isInside 对子目录为真", LocalPlacePolicy.isInside("/a/b/c", "/a/b"), true)
check("分量边界：isInside 对超短路径为假", LocalPlacePolicy.isInside("/a", "/a/b"), false)

// ── ⑥ 反向：不能因为路径里出现 `Containers` 就一律判成「在里面」 ───────────────
check("反向：别的 app 的容器不算我的", usable("/Users/a/Library/Containers/com.example.other/Data", container: container, canList: true), true)
check("反向：真实家目录不在容器里", usable("/Users/a/Documents", container: container, canList: true), true)

// ─────────────────────────────────────────────────────────────

print("覆盖：非沙盒放行 · 容器外能列 / 列不了 · 容器内（含容器根、深层、`..`）· "
      + "路径分量边界 · `isInside` 的三个方向 · 别的 app 的容器不算数")
if failures.isEmpty {
    print("ALL OK")
} else {
    print("FAILURES (\(failures.count)):")
    for item in failures { print("  - \(item)") }
    exit(1)
}
