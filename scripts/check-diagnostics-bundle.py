#!/usr/bin/env python3
r"""诊断包的回归守卫。

## 为什么需要它

第一版导出器产出的 zip **只有一个根目录条目** —— 一个「能解压但空」的包，
不报错、不警告。这类缺陷不会被编译器、也不会被任何单测发现，**只有把产物打开来数条目**
才会露出来。所以把「打开来数」这件事自动化掉。

四个判据（任一条不满足即 exit 1）：

1. **条目数** —— 至少 8 项（9 类内容里目录会各占一项，实际约 11 项）。
   这条专抓「空包」。
2. **中文名的 UTF-8 标志位**（`0x0800`）—— 没有它，Windows / Linux / 7-Zip 会按
   `cp437` 解释而得到乱码名（macOS 自家工具假定 UTF-8，看不出问题，所以本地很容易漏）。
3. **没有 `__MACOSX/` 垃圾项** —— 那是 `ditto --sequesterRsrc` 的副产品，不是我们的内容。
4. **没有真实用户名 / 家目录路径泄露** —— 注意系统 `.ips` 自己会把用户名匿成字面量
   `USER`、把中间层匿成 `*`（`\/Users\/USER\/*\/…`），那是**已脱敏**的内容，必须放行；
   判据只看**真实**的家目录路径与用户名（详见判据 4 处的长注释）。

用法：

    /usr/bin/python3 scripts/check-diagnostics-bundle.py [app 可执行文件路径]

不给路径时用 Release 产物的默认位置。**需要先构建**。
"""

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

DEFAULT_APP = "macos/build/dd/Build/Products/Release/DroidBerth.app/Contents/MacOS/DroidBerth"
MIN_ENTRIES = 8

passed: list[str] = []
failed: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        passed.append(label)
    else:
        failed.append(f"{label}{'  —— ' + detail if detail else ''}")


def main() -> int:
    app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_APP)
    if not app.exists():
        print(f"找不到 app：{app}\n先跑 ./scripts/build.sh 或 xcodebuild。")
        return 2

    work = tempfile.mkdtemp(prefix="droidberth-diagnostic-check-")
    try:
        result = subprocess.run(
            [str(app), f"--export-diagnostics={work}"],
            capture_output=True, text=True, timeout=180,
        )
        check("导出命令退出码为 0", result.returncode == 0, f"实际 {result.returncode}")

        zips = sorted(pathlib.Path(work).glob("*.zip"))
        check("产出了 zip", len(zips) == 1, f"找到 {len(zips)} 个")
        if not zips:
            return report()
        zpath = zips[0]

        with zipfile.ZipFile(zpath) as archive:
            infos = archive.infolist()
            names = [i.filename for i in infos]

            check(f"条目数 ≥ {MIN_ENTRIES}", len(infos) >= MIN_ENTRIES, f"实际 {len(infos)} —— 疑似空包")

            # 判据 2：每个含非 ASCII 的名字都必须带 EFS 标志
            non_ascii = [i for i in infos if any(ord(c) > 127 for c in i.filename)]
            check("存在中文名条目", len(non_ascii) > 0, "一个都没有，说明包的内容不对")
            missing_flag = [i.filename for i in non_ascii if not (i.flag_bits & 0x800)]
            check("所有中文名都带 UTF-8 标志位 (0x0800)", not missing_flag,
                  f"缺标志的条目：{missing_flag[:3]}")

            # 判据 3：没有 __MACOSX
            junk = [n for n in names if "__MACOSX" in n or "/._" in n]
            check("没有 __MACOSX / ._ 垃圾项", not junk, f"多出：{junk[:3]}")

            # 判据 4：不泄露**真实**家目录路径 / **真实**用户名
            #
            # ⚠️ 两条都是「把判据写宽了就等于没有判据」的例子，都真的误报过：
            #
            # ① bundle 标识符本身就含用户名（`dev.<用户名>.droidberth`）。那是**产品标识**、
            #    公开且排障时有用，不该被当成隐私。所以先把标识符替掉再找。
            #
            # ② **不能拿 `/Users/` 前缀当隐私判据**。系统崩溃报告（`.ips`）自己就会做匿名化 ——
            #    实测里面的形态是 `\/Users\/USER\/*\/DroidBerth.app\/…`：用户名被换成了字面量
            #    `USER`、中间层被换成了 `*`。那是**已经脱敏过**的内容，看到它是正常的。
            #    按 `/Users/` 判，会让「用户机器上崩过一次」这个再普通不过的情况永远 FAIL ——
            #    而**持续误报等于没有判据**（仓库里同一句话已经因为 bundle id 那件事写过一遍）。
            #
            # 所以这里判两件**具体**的事：真实家目录路径（含 JSON 转义形态）与真实用户名，
            # 占位符 `USER` / `Shared` / `*` 放行。
            username = pathlib.Path.home().name
            bundle_id = f"dev.{username}.droidberth"
            home = str(pathlib.Path.home())
            home_escaped = home.replace("/", "\\/")
            placeholder_users = {"USER", "Shared", "*"}
            leaked: list[str] = []
            for info in infos:
                if info.is_dir():
                    continue
                try:
                    blob = archive.read(info).decode("utf-8", "replace")
                except Exception:
                    continue
                probe = blob.replace(bundle_id, "<bundle-id>")
                reasons = []
                if home in probe or home_escaped in probe:
                    reasons.append("出现真实家目录路径")
                # `/Users/<名字>` 里凡是**不是**系统占位符的名字，都算泄露（含别的用户名）。
                outsiders = {
                    name for name in re.findall(r"/Users/([^/\s\"\\]+)", probe)
                    if name not in placeholder_users
                }
                if outsiders:
                    reasons.append("出现 /Users/ 下的真实用户名：" + "、".join(sorted(outsiders)))
                if re.search(rf"(?<![\w.]){re.escape(username)}(?![\w])", probe):
                    reasons.append("出现用户名")
                if reasons:
                    leaked.append(f"{info.filename}（{'、'.join(reasons)}）")
            check(f"包里不出现真实家目录路径或用户名「{username}」",
                  not leaked, f"命中：{leaked}")

            print(f"\n（包内 {len(infos)} 项）")
            for name in names:
                print("   ", name)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    return report()


def report() -> int:
    print()
    for item in passed:
        print(f"  ✓ {item}")
    for item in failed:
        print(f"  ✗ {item}")
    print()
    if failed:
        print(f"FAILURES ({len(failed)})")
        return 1
    print(f"ALL OK（{len(passed)} 项）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
