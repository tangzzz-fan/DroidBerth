mod adb;
mod diag;
mod json;
mod proc;

use std::path::{Path, PathBuf};
use std::process::Command as SysCommand;

use json::J;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const SIZE_BUDGET_MB: f64 = 40.0;
const MAX_NESTED_INSPECT: usize = 80;

const USAGE: &str = "\
droidock-adb — ADB sidecar + macOS bundle risk validator

USAGE:
    droidock-adb <COMMAND> [ARGS]

COMMANDS:
    version                 Print sidecar version and build info
    doctor [--compact]      Full bundle/signature/ADB risk report (JSON)
    resolve                 Show ADB binary resolution order (JSON)
    exec [--timeout SECS]   Run the resolved adb with the given args (JSON)
    raw <adb args...>       Run the resolved adb with stdio inherited
    help                    Show this message
";

struct Check {
    id: u32,
    key: &'static str,
    module: &'static str,
    name: &'static str,
    level: &'static str,
    status: &'static str,
    detail: String,
    evidence: String,
}

impl Check {
    fn to_json(&self) -> J {
        J::obj([
            ("id", J::N(self.id as i64)),
            ("key", J::s(self.key)),
            ("module", J::s(self.module)),
            ("name", J::s(self.name)),
            ("level", J::s(self.level)),
            ("status", J::s(self.status)),
            ("detail", J::s(&self.detail)),
            ("evidence", J::s(&self.evidence)),
        ])
    }
}

fn yes_no(v: bool) -> &'static str {
    if v {
        "yes"
    } else {
        "no"
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(|s| s.as_str()).unwrap_or("help");

    match command {
        "version" | "--version" | "-V" => {
            println!(
                "droidock-adb {VERSION} ({} {})",
                std::env::consts::ARCH,
                std::env::consts::OS
            );
            println!("exe: {}", current_exe().display());
            std::process::exit(0);
        }
        "help" | "--help" | "-h" => {
            print!("{USAGE}");
            std::process::exit(0);
        }
        "doctor" => {
            let compact = args.iter().any(|a| a == "--compact");
            let table = args.iter().any(|a| a == "--table");
            let report = doctor_report(table);
            if !table {
                println!(
                    "{}",
                    if compact {
                        report.render()
                    } else {
                        report.render_pretty()
                    }
                );
            }
            std::process::exit(0);
        }
        "resolve" => {
            println!("{}", adb::resolve().to_json().render_pretty());
            std::process::exit(0);
        }
        "exec" => {
            let mut timeout = 30u64;
            let mut rest: Vec<String> = Vec::new();
            let mut i = 1;
            while i < args.len() {
                if args[i] == "--timeout" {
                    i += 1;
                    timeout = args.get(i).and_then(|v| v.parse().ok()).unwrap_or(30);
                } else {
                    rest.push(args[i].clone());
                }
                i += 1;
            }
            println!("{}", adb::exec(&rest, timeout).render_pretty());
            std::process::exit(0);
        }
        "raw" => {
            let rest: Vec<String> = args[1..].to_vec();
            let resolution = adb::resolve();
            let Some(adb) = resolution.path else {
                eprintln!("droidock-adb: adb binary not found");
                std::process::exit(127);
            };
            let status = SysCommand::new(&adb).args(&rest).status();
            std::process::exit(match status {
                Ok(s) => s.code().unwrap_or(1),
                Err(e) => {
                    eprintln!("droidock-adb: failed to run {}: {e}", adb.display());
                    126
                }
            });
        }
        other => {
            eprintln!("droidock-adb: unknown command `{other}`\n");
            print!("{USAGE}");
            std::process::exit(1);
        }
    }
}

fn current_exe() -> PathBuf {
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("droidock-adb"));
    std::fs::canonicalize(&exe).unwrap_or(exe)
}

fn main_executable(app: &Path) -> Option<PathBuf> {
    let name = app.file_stem()?.to_string_lossy().into_owned();
    let candidate = app.join("Contents/MacOS").join(&name);
    if candidate.is_file() {
        return Some(candidate);
    }
    let dir = app.join("Contents/MacOS");
    let entries = std::fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

fn doctor_report(table: bool) -> J {
    let exe = current_exe();
    let app = diag::app_bundle_of(&exe);
    let sidecar_sig = diag::inspect_signature(&exe);

    let (app_sig, nested, main_exe) = match &app {
        Some(app_path) => {
            let sig = diag::inspect_signature(app_path);
            let main_exe = main_executable(app_path);
            let all = diag::collect_macho_files(app_path);
            let mut nested: Vec<diag::Signature> = Vec::new();
            let mut count = 0usize;
            for path in all.iter() {
                if Some(path) == main_exe.as_ref() {
                    continue;
                }
                if count >= MAX_NESTED_INSPECT {
                    break;
                }
                count += 1;
                nested.push(diag::inspect_signature(path));
            }
            (Some(sig), nested, main_exe)
        }
        None => (None, Vec::new(), None),
    };

    let resolution = adb::resolve();
    let adb_report = resolution.path.as_ref().map(|p| adb::adb_json(p));

    let main_sig = main_exe.as_ref().map(|p| diag::inspect_signature(p));
    let app_archs = main_exe
        .as_ref()
        .map(|p| diag::lipo_archs(p))
        .unwrap_or_default();
    let sidecar_archs = diag::lipo_archs(&exe);

    let app_dir_mb = app
        .as_ref()
        .map(|p| diag::dir_size_bytes(p) as f64 / 1_048_576.0)
        .unwrap_or(0.0);
    let dmg_mb = diag::dmg_size_mb();

    let installed_in_applications = app
        .as_ref()
        .map(|p| p.starts_with("/Applications"))
        .unwrap_or(false);

    let host = diag::host_environment();

    let spctl = app
        .as_ref()
        .map(|p| diag::spctl_assess(p))
        .map(|out| (out.ok(), out.combined().trim().to_string()));

    let port = diag::adb_port_status(resolution.path.as_deref());

    let mut checks: Vec<Check> = Vec::new();

    let mut check = |id: u32,
                     key: &'static str,
                     module: &'static str,
                     name: &'static str,
                     level: &'static str,
                     status: &'static str,
                     detail: String,
                     evidence: String| {
        checks.push(Check {
            id,
            key,
            module,
            name,
            level,
            status,
            detail,
            evidence,
        });
    };

    let spctl_status = match &spctl {
        Some((true, _)) => "pass",
        Some((false, _)) => "fail",
        None => "skip",
    };
    check(
        1,
        "sidecar.notarization",
        "module-1",
        "Gatekeeper accepts the signed bundle (spctl --assess -t open)",
        "blocker",
        spctl_status,
        match &spctl {
            Some((true, _)) => "spctl accepted. Only meaningful when the app sits in /Applications on a machine that has never seen it.".into(),
            Some((false, _)) => "spctl rejected. Inspect every nested Mach-O signature below; on macOS 15 nested ad-hoc or foreign-TeamID signatures fail the whole bundle.".into(),
            None => "No .app bundle found (running the raw sidecar binary from target/). Re-run from the bundled app.".into(),
        },
        spctl.as_ref().map(|(_, t)| t.clone()).unwrap_or_default(),
    );

    check(
        2,
        "sidecar.hardened_runtime",
        "module-1",
        "Sidecar signature carries hardened runtime",
        "blocker",
        if sidecar_sig.hardened_runtime() { "pass" } else { "fail" },
        format!(
            "flags={} names=[{}]",
            if sidecar_sig.flags_hex.is_empty() {
                "none"
            } else {
                &sidecar_sig.flags_hex
            },
            sidecar_sig.flags_names.join(", ")
        ),
        format!(
            "expected bit 0x10000; present={}",
            yes_no(sidecar_sig.hardened_runtime())
        ),
    );

    check(
        3,
        "sidecar.secure_timestamp",
        "module-1",
        "Sidecar signature carries a secure timestamp",
        "high",
        if sidecar_sig.has_timestamp() { "pass" } else { "fail" },
        format!(
            "Timestamp={}",
            if sidecar_sig.has_timestamp() {
                &sidecar_sig.timestamp
            } else {
                "(absent)"
            }
        ),
        "macOS 15 rejects hardened-runtime signatures without a secure timestamp; macOS 14 accepts them.".into(),
    );

    let adb_foreign: Vec<String> = adb_report
        .as_ref()
        .and_then(|j| match j {
            J::O(items) => items
                .iter()
                .find(|(k, _)| k == "foreignDependencies")
                .map(|(_, v)| v),
            _ => None,
        })
        .and_then(|v| match v {
            J::A(items) => Some(
                items
                    .iter()
                    .filter_map(|i| match i {
                        J::S(s) => Some(s.clone()),
                        _ => None,
                    })
                    .collect(),
            ),
            _ => None,
        })
        .unwrap_or_default();

    check(
        4,
        "adb.no_foreign_deps",
        "module-3",
        "ADB links only against system libraries",
        "high",
        if adb_report.is_none() {
            "skip"
        } else if adb_foreign.is_empty() {
            "pass"
        } else {
            "fail"
        },
        match &adb_report {
            None => "No adb binary resolved. Bundle one, or set DROIDDOCK_ADB to a build worth inspecting.".into(),
            Some(_) if adb_foreign.is_empty() => {
                "otool -L shows only /usr/lib and /System/Library entries.".into()
            }
            Some(_) => format!(
                "{} non-system dependenc{}: {}",
                adb_foreign.len(),
                if adb_foreign.len() == 1 { "y" } else { "ies" },
                adb_foreign.join(", ")
            ),
        },
        adb_report
            .as_ref()
            .map(|j| match j {
                J::O(items) => items
                    .iter()
                    .find(|(k, _)| k == "dependencies")
                    .map(|(_, v)| v.render())
                    .unwrap_or_default(),
                _ => String::new(),
            })
            .unwrap_or_default(),
    );

    check(
        5,
        "wifi.tcpip_5555_reconnect",
        "module-4",
        "adb tcpip 5555 survives screen-off / network change",
        "medium",
        "manual",
        "Needs a physical device. Use the Wireless tab: enable tcpip 5555, unplug USB, then run the reconnect matrix.".into(),
        String::new(),
    );

    check(
        6,
        "wifi.after_reboot",
        "module-4",
        "adb tcpip 5555 after phone reboot",
        "medium",
        "manual",
        "Known limitation: the port is lost on reboot and the device must be re-attached over USB. The app must guide the user through this.".into(),
        String::new(),
    );

    let universal_ok = app_archs.len() > 1 && sidecar_archs.len() > 1;
    check(
        7,
        "bundle.universal",
        "module-1",
        "Universal binary covers arm64 and x86_64",
        "medium",
        if main_exe.is_none() {
            "skip"
        } else if universal_ok {
            "pass"
        } else {
            "fail"
        },
        format!(
            "main=[{}] sidecar=[{}]",
            app_archs.join(" "),
            sidecar_archs.join(" ")
        ),
        "Tauri looks for binaries/<name>-<target-triple>; ship both aarch64-apple-darwin and x86_64-apple-darwin.".into(),
    );

    let size_measured = dmg_mb.unwrap_or(app_dir_mb);
    let size_label = if dmg_mb.is_some() { "DMG" } else { "app bundle" };
    check(
        8,
        "bundle.size",
        "module-3",
        "Distributable stays within the 40 MB budget",
        "low",
        if size_measured == 0.0 {
            "skip"
        } else if size_measured <= SIZE_BUDGET_MB {
            "pass"
        } else {
            "fail"
        },
        format!("{size_label} = {size_measured:.1} MB"),
        format!(
            "budget {SIZE_BUDGET_MB:.0} MB; app bundle = {app_dir_mb:.1} MB; dmg = {}",
            dmg_mb
                .map(|v| format!("{v:.1} MB"))
                .unwrap_or_else(|| "not built".into())
        ),
    );

    let port_status = if !port.busy || port.is_our_adb {
        "pass"
    } else if port.is_adb {
        "manual"
    } else {
        "fail"
    };
    check(
        9,
        "adb.port_5037",
        "module-3",
        "ADB server port 5037 is free, ours, or a foreign adb we can see",
        "low",
        port_status,
        if !port.busy {
            "Nothing is listening on 127.0.0.1:5037; the bundled adb will start its own server.".into()
        } else if port.is_our_adb {
            format!(
                "Held by our own adb server (pid {}). Expected.",
                port.pid.unwrap_or(0)
            )
        } else if port.is_adb {
            format!(
                "Held by a different adb server (pid {}, {}). An adb client reuses whatever is on 5037, so a version mismatch would silently change behaviour — kill it or point the app at that same binary.",
                port.pid.unwrap_or(0),
                if port.full_path.is_empty() { port.command.clone() } else { port.full_path.clone() }
            )
        } else {
            format!(
                "Held by a non-adb process (pid {}, {}). The bundled adb cannot bind 5037 and device commands will fail.",
                port.pid.unwrap_or(0),
                if port.full_path.is_empty() { port.command.clone() } else { port.full_path.clone() }
            )
        },
        if port.busy {
            format!(
                "127.0.0.1:5037 <- pid {} {}",
                port.pid.unwrap_or(0),
                if port.full_path.is_empty() { port.command.clone() } else { port.full_path.clone() }
            )
        } else {
            "127.0.0.1:5037 <- nothing listening".into()
        },
    );

    let team_ids: Vec<String> = nested
        .iter()
        .map(|s| {
            if s.team_id.is_empty() {
                s.cert_kind().to_string()
            } else {
                s.team_id.clone()
            }
        })
        .collect();
    let distinct = diag::unique_sorted(team_ids.clone());
    let inconsistent = distinct.len() > 1;
    check(
        10,
        "bundle.nested_team_consistency",
        "module-2",
        "Every nested Mach-O shares one signing identity",
        "blocker",
        if nested.is_empty() {
            "skip"
        } else if inconsistent {
            "fail"
        } else {
            "pass"
        },
        if nested.is_empty() {
            "No nested Mach-O files found.".into()
        } else if inconsistent {
            format!(
                "{} distinct identities across {} nested binaries: {}",
                distinct.len(),
                nested.len(),
                distinct.join(", ")
            )
        } else {
            format!(
                "{} nested binaries, all `{}`",
                nested.len(),
                distinct.first().cloned().unwrap_or_default()
            )
        },
        "macOS 15 deep-validates nested Mach-O; one ad-hoc or foreign-TeamID helper rejects the entire bundle.".into(),
    );

    let missing_runtime: Vec<String> = nested
        .iter()
        .filter(|s| !s.hardened_runtime())
        .map(|s| {
            s.path
                .rsplit('/')
                .next()
                .unwrap_or(&s.path)
                .to_string()
        })
        .collect();
    check(
        11,
        "bundle.nested_hardened_runtime",
        "module-2",
        "Hardened runtime is set on every nested executable",
        "blocker",
        if nested.is_empty() {
            "skip"
        } else if missing_runtime.is_empty() {
            "pass"
        } else {
            "fail"
        },
        if nested.is_empty() {
            "No nested Mach-O files found.".into()
        } else if missing_runtime.is_empty() {
            format!("All {} nested binaries carry flags=0x10000(runtime).", nested.len())
        } else {
            format!(
                "{} of {} nested binaries lack the runtime flag: {}",
                missing_runtime.len(),
                nested.len(),
                missing_runtime.join(", ")
            )
        },
        "Entitlements declared on the outer app do not propagate down to nested executables.".into(),
    );

    check(
        12,
        "bundle.notarizable_identity",
        "module-1",
        "Signing identity is eligible for notarization",
        "blocker",
        match app_sig.as_ref() {
            None => "skip",
            Some(s) if s.notarizable() => "pass",
            Some(_) => "fail",
        },
        match app_sig.as_ref() {
            None => "No bundle to inspect.".into(),
            Some(s) => format!(
                "cert={} hardenedRuntime={} timestamp={}",
                s.cert_kind(),
                yes_no(s.hardened_runtime()),
                yes_no(s.has_timestamp())
            ),
        },
        "notarytool only accepts `Developer ID Application` with hardened runtime and a secure timestamp. Apple Development certificates cannot be notarized.".into(),
    );

    let sequoia = host.is_sequoia_or_later();
    check(
        13,
        "host.sequoia_or_later",
        "module-2",
        "Running on macOS 15+ so the deep-validation path is exercised",
        "high",
        if sequoia { "pass" } else { "fail" },
        format!("macOS {} ({})", host.version, host.build),
        "A macOS 14 pass does not imply a macOS 15 pass; the doc requires the clean-environment check on Sequoia.".into(),
    );

    check(
        14,
        "host.installed_in_applications",
        "module-2",
        "Bundle is installed at /Applications for a meaningful Gatekeeper result",
        "high",
        if installed_in_applications { "pass" } else { "fail" },
        app.as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| "(no bundle)".into()),
        "spctl is only conclusive on an installed copy on a machine that has never run the app.".into(),
    );

    let failures = checks.iter().filter(|c| c.status == "fail").count();
    let passes = checks.iter().filter(|c| c.status == "pass").count();
    let manual = checks.iter().filter(|c| c.status == "manual").count();
    let skipped = checks.iter().filter(|c| c.status == "skip").count();

    let verdict = if failures == 0 && manual == 0 {
        "pass"
    } else if failures == 0 {
        "pass-with-manual"
    } else {
        "fail"
    };

    if table {
        print_table(
            &checks,
            verdict,
            passes,
            failures,
            manual,
            skipped,
            &host,
            &app,
            &exe,
            &sidecar_sig,
            spctl.as_ref().map(|(ok, _)| *ok),
        );
    }

    J::obj([
        ("tool", J::s(format!("droidock-adb {VERSION}"))),
        ("host", host.to_json()),
        ("bundle", J::obj([
            (
                "appPath",
                match &app {
                    Some(p) => J::s(p.to_string_lossy().to_string()),
                    None => J::Null,
                },
            ),
            ("installedInApplications", J::B(installed_in_applications)),
            (
                "mainExecutable",
                match &main_exe {
                    Some(p) => J::s(p.to_string_lossy().to_string()),
                    None => J::Null,
                },
            ),
            (
                "archs",
                J::arr(app_archs.iter().map(J::s).collect::<Vec<_>>()),
            ),
            ("appSizeMb", J::F(app_dir_mb)),
            (
                "dmgSizeMb",
                match dmg_mb {
                    Some(v) => J::F(v),
                    None => J::Null,
                },
            ),
            (
                "quarantineAttributes",
                match &app {
                    Some(p) => J::arr(diag::xattr_names(p).iter().map(J::s).collect::<Vec<_>>()),
                    None => J::A(Vec::new()),
                },
            ),
        ])),
        ("sidecar", J::obj([
            ("path", J::s(exe.to_string_lossy().to_string())),
            ("version", J::s(VERSION)),
            (
                "archs",
                J::arr(sidecar_archs.iter().map(J::s).collect::<Vec<_>>()),
            ),
            ("signature", sidecar_sig.to_json()),
        ])),
        (
            "appSignature",
            match &app_sig {
                Some(s) => s.to_json(),
                None => J::Null,
            },
        ),
        (
            "mainExecutableSignature",
            match &main_sig {
                Some(s) => s.to_json(),
                None => J::Null,
            },
        ),
        (
            "nestedMachO",
            J::obj([
                ("count", J::N(nested.len() as i64)),
                (
                    "items",
                    J::arr(nested.iter().map(|s| s.to_json()).collect::<Vec<_>>()),
                ),
            ]),
        ),
        ("adb", J::obj([
            ("resolution", resolution.to_json()),
            (
                "binary",
                match &adb_report {
                    Some(j) => j.clone(),
                    None => J::Null,
                },
            ),
        ])),
        ("gatekeeper", J::obj([
            (
                "spctlAccepted",
                match &spctl {
                    Some((ok, _)) => J::B(*ok),
                    None => J::Null,
                },
            ),
            (
                "spctlOutput",
                match &spctl {
                    Some((_, t)) => J::s(t),
                    None => J::Null,
                },
            ),
        ])),
        ("summary", J::obj([
            ("verdict", J::s(verdict)),
            ("pass", J::N(passes as i64)),
            ("fail", J::N(failures as i64)),
            ("manual", J::N(manual as i64)),
            ("skip", J::N(skipped as i64)),
            ("total", J::N(checks.len() as i64)),
        ])),
        (
            "checks",
            J::arr(checks.iter().map(|c| c.to_json()).collect::<Vec<_>>()),
        ),
    ])
}

fn wrap(text: &str, indent: usize, width: usize) -> String {
    let mut out = String::new();
    let mut line_len = indent;
    out.push_str(&" ".repeat(indent));
    for word in text.split_whitespace() {
        if line_len + word.len() + 1 > width && line_len > indent {
            out.push('\n');
            out.push_str(&" ".repeat(indent));
            line_len = indent;
        }
        if line_len > indent {
            out.push(' ');
            line_len += 1;
        }
        out.push_str(word);
        line_len += word.len();
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn print_table(
    checks: &[Check],
    verdict: &str,
    passes: usize,
    failures: usize,
    manual: usize,
    skipped: usize,
    host: &diag::HostInfo,
    app: &Option<PathBuf>,
    exe: &Path,
    sidecar_sig: &diag::Signature,
    spctl_accepted: Option<bool>,
) {
    let width = 100usize;
    let rule = "-".repeat(width);
    println!("DroidDock bundle risk report");
    println!("{rule}");
    println!(
        "  host      macOS {} ({}) {}",
        host.version, host.build, host.arch
    );
    println!(
        "  bundle    {}",
        app.as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| "(not running from an app bundle)".into())
    );
    println!("  sidecar   {}", exe.display());
    println!(
        "  identity  {} [{}]",
        sidecar_sig
            .authorities
            .first()
            .cloned()
            .unwrap_or_else(|| "(unsigned or ad-hoc)".into()),
        sidecar_sig.cert_kind()
    );
    println!(
        "  spctl     {}",
        match spctl_accepted {
            Some(true) => "accepted",
            Some(false) => "rejected",
            None => "not applicable",
        }
    );
    println!("{rule}");
    println!("  {:<3} {:<8} {:<7} {}", "#", "LEVEL", "STATUS", "CHECK");
    println!("{rule}");
    for c in checks {
        println!(
            "  {:<3} {:<8} {:<7} {}",
            c.id,
            c.level,
            c.status.to_uppercase(),
            c.name
        );
        if !c.detail.is_empty() {
            println!("{}", wrap(&c.detail, 6, width));
        }
        if !c.evidence.is_empty() {
            println!("{}", wrap(&format!("evidence: {}", c.evidence), 6, width));
        }
    }
    println!("{rule}");
    println!(
        "  verdict   {}   ({} pass / {} fail / {} manual / {} skip of {})",
        verdict.to_uppercase(),
        passes,
        failures,
        manual,
        skipped,
        checks.len()
    );
}
