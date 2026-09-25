import Foundation

struct SpikeRow: Identifiable, Sendable {
    enum Status: String, Sendable {
        case pass
        case fail
        case manual
        case skip
    }

    let id: String
    let title: String
    let status: Status
    let evidence: String
}

enum SpikeChecks {
    static func runAll() -> [SpikeRow] {
        let location = SidecarLocator.locate()
        var rows: [SpikeRow] = [checkLocator(location)]

        if let executable = location.executable {
            let client = SidecarClient(executable: executable)
            rows.append(checkSignatureChain(client))
        } else {
            rows.append(SpikeRow(
                id: "V2",
                title: "签名链（doctor）",
                status: .skip,
                evidence: "sidecar 未定位到，跳过"
            ))
        }

        rows.append(checkProcessWrapper())

        if let executable = location.executable {
            rows.append(checkDevice(SidecarClient(executable: executable)))
        } else {
            rows.append(SpikeRow(
                id: "V4",
                title: "端到端（真实设备）",
                status: .skip,
                evidence: "sidecar 未定位到，跳过"
            ))
        }

        return rows
    }

    private static func checkLocator(_ location: SidecarLocation) -> SpikeRow {
        let id = "V1"
        let title = "sidecar 定位与执行"

        guard let executable = location.executable else {
            return SpikeRow(
                id: id,
                title: title,
                status: .fail,
                evidence: "未找到 sidecar。已尝试：\n\(SidecarLocator.describe(location))"
            )
        }

        let result = SidecarClient(executable: executable).version()
        var lines = [
            "路径: \(executable.path)",
            "App Translocation: \(executable.path.contains("AppTranslocation") ? "是" : "否")",
            "退出码: \(result.exitCode.map(String.init) ?? "nil")",
            "耗时: \(result.durationMs) ms",
            "输出: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))",
        ]
        if !result.stderr.isEmpty {
            lines.append("stderr: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let spawnError = result.spawnError {
            lines.append("spawn error: \(spawnError)")
        }

        let passed = result.ok && result.stdout.contains("droidberth-adb")
        return SpikeRow(id: id, title: title, status: passed ? .pass : .fail,
                        evidence: lines.joined(separator: "\n"))
    }

    private static func checkSignatureChain(_ client: SidecarClient) -> SpikeRow {
        let id = "V2"
        let title = "签名链（doctor）"

        guard let report = client.doctor() else {
            return SpikeRow(id: id, title: title, status: .fail,
                            evidence: "doctor 未返回可解析的 JSON")
        }

        let summary = report.summary
        var lines = [
            "tool: \(report.tool)",
            "verdict: \(summary.verdict)  (\(summary.pass) pass / \(summary.fail) fail / \(summary.manual) manual / \(summary.skip) skip of \(summary.total))",
        ]

        let nonPassing = report.checks.filter { $0.status != "pass" }
        if nonPassing.isEmpty {
            lines.append("全部 \(summary.total) 项 pass")
        } else {
            lines.append("")
            for check in nonPassing {
                lines.append("[\(check.status)] #\(check.id) \(check.key)")
                lines.append("        \(check.name)")
                if !check.detail.isEmpty {
                    lines.append("        detail: \(check.detail)")
                }
                if !check.evidence.isEmpty {
                    lines.append("        evidence: \(check.evidence)")
                }
            }
        }

        let status: SpikeRow.Status
        if summary.fail > 0 {
            status = .fail
        } else if summary.manual > 0 || summary.skip > 0 {
            status = .manual
        } else {
            status = .pass
        }

        return SpikeRow(id: id, title: title, status: status,
                        evidence: lines.joined(separator: "\n"))
    }

    private static func checkProcessWrapper() -> SpikeRow {
        let id = "V3"
        let title = "进程封装（双路抽干 + 超时）"
        let shell = URL(fileURLWithPath: "/bin/sh")
        var lines: [String] = []
        var allPassed = true

        let stdoutCase = ProcessRunner.run(
            shell,
            ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i; i=$((i+1)); done"],
            timeout: 30
        )
        let stdoutLines = stdoutCase.stdout.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        let stdoutPassed = stdoutCase.ok && stdoutLines == 20000
        lines.append("大 stdout: \(stdoutLines)/20000 行, 退出码 \(stdoutCase.exitCode.map(String.init) ?? "nil") -> \(stdoutPassed ? "pass" : "FAIL")")
        allPassed = allPassed && stdoutPassed

        let stderrCase = ProcessRunner.run(
            shell,
            ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i >&2; i=$((i+1)); done"],
            timeout: 30
        )
        let stderrLines = stderrCase.stderr.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        let stderrPassed = stderrCase.ok && stderrLines == 20000
        lines.append("大 stderr: \(stderrLines)/20000 行, 退出码 \(stderrCase.exitCode.map(String.init) ?? "nil") -> \(stderrPassed ? "pass" : "FAIL")")
        allPassed = allPassed && stderrPassed

        let timeoutCase = ProcessRunner.run(shell, ["-c", "sleep 30"], timeout: 2)
        let timeoutPassed = timeoutCase.timedOut && timeoutCase.durationMs < 5000
        lines.append("超时: timedOut=\(timeoutCase.timedOut), 耗时 \(timeoutCase.durationMs) ms, 退出码 \(timeoutCase.exitCode.map(String.init) ?? "nil") -> \(timeoutPassed ? "pass" : "FAIL")")
        allPassed = allPassed && timeoutPassed

        return SpikeRow(id: id, title: title, status: allPassed ? .pass : .fail,
                        evidence: lines.joined(separator: "\n"))
    }

    private static func checkDevice(_ client: SidecarClient) -> SpikeRow {
        let id = "V4"
        let title = "端到端（真实设备）"

        guard let devices = client.exec(["devices", "-l"], timeout: 20) else {
            return SpikeRow(id: id, title: title, status: .manual,
                            evidence: "exec 未返回可解析的 JSON")
        }

        guard devices.ok else {
            var lines = ["adb 未就绪：\(devices.error ?? "未知原因")"]
            if let resolution = devices.resolution {
                lines.append("解析来源: \(resolution.source)")
                for probe in resolution.probes {
                    lines.append("  \(probe.exists ? "+" : "-") [\(probe.source)] \(probe.path)")
                }
            }
            return SpikeRow(id: id, title: title, status: .manual,
                            evidence: lines.joined(separator: "\n"))
        }

        let deviceLines = (devices.stdout ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var lines = [
            "adb: \(devices.adbPath ?? "?")",
            "来源: \(devices.source ?? "?")",
            "devices -l:",
        ]
        lines.append(contentsOf: deviceLines.map { "  \($0)" })

        let serials = deviceLines.compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            return parts[0]
        }

        guard let serial = serials.first else {
            lines.append("")
            lines.append("未检测到已授权设备。本项标 manual，不阻塞 V1–V3 的结论。")
            return SpikeRow(id: id, title: title, status: .manual,
                            evidence: lines.joined(separator: "\n"))
        }

        if serials.count > 1 {
            lines.append("")
            lines.append("同时有 \(serials.count) 个 transport 在线：\(serials.joined(separator: ", "))")
            lines.append("裸 adb 会报 \"more than one device/emulator\"，本项显式用 -s \(serial)。")
        }

        let target = ["-s", serial]

        guard let model = client.exec(target + ["shell", "getprop", "ro.product.model"], timeout: 20), model.ok else {
            lines.append("getprop ro.product.model 失败")
            return SpikeRow(id: id, title: title, status: .fail,
                            evidence: lines.joined(separator: "\n"))
        }
        lines.append("serial: \(serial)")
        lines.append("model: \((model.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines))")

        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidberth-spike-\(UUID().uuidString).txt")
        let payload = String(repeating: "droidberth spike payload\n", count: 128)
        try? payload.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }

        let remote = "/sdcard/Download/\(local.lastPathComponent)"
        guard let pushed = client.exec(target + ["push", local.path, remote], timeout: 60) else {
            lines.append("push 未返回可解析的 JSON")
            return SpikeRow(id: id, title: title, status: .fail,
                            evidence: lines.joined(separator: "\n"))
        }
        lines.append("push 退出码: \(pushed.code.map(String.init) ?? "nil"), ok=\(pushed.ok)")
        lines.append("push 输出: \((pushed.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines))")

        guard let verified = client.exec(target + ["shell", "ls", "-l", remote], timeout: 20) else {
            lines.append("复核 ls -l 未返回可解析的 JSON")
            return SpikeRow(id: id, title: title, status: .fail,
                            evidence: lines.joined(separator: "\n"))
        }
        let listing = (verified.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("复核 ls -l: \(listing)")

        _ = client.exec(target + ["shell", "rm", "-f", remote], timeout: 20)

        let passed = pushed.ok && verified.ok && listing.contains(local.lastPathComponent)
        return SpikeRow(id: id, title: title, status: passed ? .pass : .fail,
                        evidence: lines.joined(separator: "\n"))
    }
}
