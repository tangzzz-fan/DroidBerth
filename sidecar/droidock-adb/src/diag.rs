use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::json::J;
use crate::proc::{self, Out};

pub const HARDENED_RUNTIME_BIT: u64 = 0x10000;

#[derive(Debug, Clone, Default)]
pub struct Signature {
    pub path: String,
    pub signed: bool,
    pub adhoc: bool,
    pub identifier: String,
    pub team_id: String,
    pub authorities: Vec<String>,
    pub flags_hex: String,
    pub flags_names: Vec<String>,
    pub flags_value: u64,
    pub timestamp: String,
    pub verify_ok: bool,
    pub verify_output: String,
    pub note: Option<String>,
}

impl Signature {
    pub fn hardened_runtime(&self) -> bool {
        self.flags_value & HARDENED_RUNTIME_BIT != 0
    }

    pub fn has_timestamp(&self) -> bool {
        !self.timestamp.is_empty()
    }

    pub fn is_developer_id(&self) -> bool {
        self.authorities
            .iter()
            .any(|a| a.starts_with("Developer ID Application"))
    }

    pub fn is_apple_development(&self) -> bool {
        self.authorities
            .iter()
            .any(|a| a.starts_with("Apple Development") || a.starts_with("Mac Developer"))
    }

    pub fn cert_kind(&self) -> &'static str {
        if self.is_developer_id() {
            "developer-id"
        } else if self.is_apple_development() {
            "apple-development"
        } else if self.adhoc {
            "adhoc"
        } else if self.authorities.is_empty() {
            "unsigned-or-unknown"
        } else {
            "other"
        }
    }

    pub fn notarizable(&self) -> bool {
        self.is_developer_id() && self.has_timestamp() && self.hardened_runtime()
    }

    pub fn to_json(&self) -> J {
        J::obj([
            ("path", J::s(&self.path)),
            ("signed", J::B(self.signed)),
            ("adhoc", J::B(self.adhoc)),
            ("identifier", J::s(&self.identifier)),
            ("teamId", J::s(&self.team_id)),
            (
                "authorities",
                J::arr(self.authorities.iter().map(J::s).collect::<Vec<_>>()),
            ),
            ("certKind", J::s(self.cert_kind())),
            ("flagsHex", J::s(&self.flags_hex)),
            (
                "flagsNames",
                J::arr(self.flags_names.iter().map(J::s).collect::<Vec<_>>()),
            ),
            ("hardenedRuntime", J::B(self.hardened_runtime())),
            ("timestamp", J::s(&self.timestamp)),
            ("hasTimestamp", J::B(self.has_timestamp())),
            ("verifyOk", J::B(self.verify_ok)),
            ("verifyOutput", J::s(self.verify_output.trim())),
            (
                "note",
                match &self.note {
                    Some(n) => J::s(n),
                    None => J::Null,
                },
            ),
        ])
    }
}

fn parse_flags(line: &str) -> (String, Vec<String>, u64) {
    let Some(start) = line.find("flags=0x") else {
        return (String::new(), Vec::new(), 0);
    };
    let rest = &line[start + "flags=".len()..];
    let hex_token: String = rest
        .chars()
        .take_while(|c| c.is_ascii_hexdigit() || *c == 'x' || *c == 'X')
        .collect();
    let value = u64::from_str_radix(hex_token.trim_start_matches("0x"), 16).unwrap_or(0);
    let mut names = Vec::new();
    if let Some(open) = rest.find('(') {
        if let Some(close) = rest[open..].find(')') {
            names = rest[open + 1..open + close]
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
    }
    (hex_token, names, value)
}

pub fn inspect_signature(path: &Path) -> Signature {
    let mut sig = Signature {
        path: path.to_string_lossy().into_owned(),
        ..Default::default()
    };

    if !path.exists() {
        sig.note = Some("path does not exist".into());
        return sig;
    }

    let dump = proc::run_simple(
        "/usr/bin/codesign",
        &["-dvvv", &sig.path],
        20,
    );
    let text = dump.combined();
    if text.contains("code object is not signed at all") {
        sig.note = Some("not signed at all".into());
    } else if dump.spawn_error.is_some() {
        sig.note = dump.spawn_error.clone();
    }

    for line in text.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("Identifier=") {
            sig.identifier = v.trim().to_string();
            sig.signed = true;
        } else if let Some(v) = line.strip_prefix("TeamIdentifier=") {
            sig.team_id = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("Authority=") {
            sig.authorities.push(v.trim().to_string());
        } else if let Some(v) = line.strip_prefix("Timestamp=") {
            sig.timestamp = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("Signature=") {
            if v.trim() == "adhoc" {
                sig.adhoc = true;
                sig.signed = true;
            }
        } else if line.contains("flags=0x") {
            let (hex, names, value) = parse_flags(line);
            sig.flags_hex = hex;
            sig.flags_names = names;
            sig.flags_value = value;
        }
    }

    let verify = proc::run_simple(
        "/usr/bin/codesign",
        &["--verify", "--strict", "--verbose=2", &sig.path],
        20,
    );
    sig.verify_ok = verify.ok();
    sig.verify_output = if sig.verify_ok {
        String::new()
    } else {
        verify.combined()
    };
    if sig.verify_ok {
        sig.signed = true;
    }

    sig
}

pub fn otool_dependencies(path: &Path) -> (Vec<String>, Vec<String>) {
    let out = proc::run_simple("/usr/bin/otool", &["-L", &path.to_string_lossy()], 20);
    let mut all: Vec<String> = Vec::new();
    let mut foreign: Vec<String> = Vec::new();
    for line in out.stdout.lines() {
        if !line.starts_with('\t') && !line.starts_with(' ') {
            continue;
        }
        let dep = line
            .trim()
            .split(" (")
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        if dep.is_empty() || all.contains(&dep) {
            continue;
        }
        let system = dep.starts_with("/usr/lib/")
            || dep.starts_with("/System/Library/")
            || dep.starts_with("/System/iOSSupport/");
        if !system {
            foreign.push(dep.clone());
        }
        all.push(dep);
    }
    (all, foreign)
}

pub fn lipo_archs(path: &Path) -> Vec<String> {
    let out = proc::run_simple("/usr/bin/lipo", &["-archs", &path.to_string_lossy()], 20);
    out.stdout.split_whitespace().map(|s| s.to_string()).collect()
}

pub fn file_type(path: &Path) -> String {
    let out = proc::run_simple("/usr/bin/file", &["-b", &path.to_string_lossy()], 20);
    out.stdout.trim().to_string()
}

pub fn spctl_assess(path: &Path) -> Out {
    proc::run_simple(
        "/usr/sbin/spctl",
        &[
            "--assess",
            "-t",
            "open",
            "--context",
            "context:primary-signature",
            "-vv",
            &path.to_string_lossy(),
        ],
        30,
    )
}

fn is_macho(path: &Path) -> bool {
    let Ok(bytes) = read_magic(path) else {
        return false;
    };
    matches!(
        bytes,
        0xfeed_face | 0xcefa_edfe | 0xfeed_facf | 0xcffa_edfe | 0xcafe_babe | 0xbeba_feca
            | 0xcafe_babf | 0xbfba_feca
    )
}

fn read_magic(path: &Path) -> std::io::Result<u32> {
    use std::io::Read;
    let mut f = fs::File::open(path)?;
    let mut buf = [0u8; 4];
    f.read_exact(&mut buf)?;
    Ok(u32::from_be_bytes(buf))
}

pub fn collect_macho_files(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() {
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                if name == "_CodeSignature" || name == "SC_Info" {
                    continue;
                }
                stack.push(path);
            } else if meta.is_file() && is_macho(&path) {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

pub fn app_bundle_of(exe: &Path) -> Option<PathBuf> {
    let mut cur = Some(exe.to_path_buf());
    while let Some(p) = cur {
        if p.extension().and_then(|e| e.to_str()) == Some("app") {
            return Some(p);
        }
        cur = p.parent().map(|x| x.to_path_buf());
    }
    None
}

pub fn dmg_size_mb() -> Option<f64> {
    let exe = std::env::current_exe().ok()?;
    let app = app_bundle_of(&exe)?;
    let dmg_dir = app.parent()?.parent()?.join("dmg");
    let entries = fs::read_dir(dmg_dir).ok()?;
    let mut best: Option<(u64, String)> = None;
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) != Some("dmg") {
            continue;
        }
        let size = e.metadata().ok()?.len();
        if best.as_ref().map(|(s, _)| size > *s).unwrap_or(true) {
            best = Some((size, p.to_string_lossy().into_owned()));
        }
    }
    best.map(|(s, _)| s as f64 / 1_048_576.0)
}

pub fn dir_size_bytes(root: &Path) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                total += meta.len();
            }
        }
    }
    total
}

#[derive(Debug, Clone, Default)]
pub struct PortStatus {
    pub busy: bool,
    pub pid: Option<u32>,
    pub command: String,
    pub full_path: String,
    pub is_adb: bool,
    pub is_our_adb: bool,
}

pub fn adb_port_status(our_adb: Option<&Path>) -> PortStatus {
    let out = proc::run_simple(
        "/usr/sbin/lsof",
        &["-nP", "-iTCP:5037", "-sTCP:LISTEN", "-t"],
        10,
    );
    let Some(pid) = out
        .stdout
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .and_then(|l| l.parse::<u32>().ok())
    else {
        return PortStatus::default();
    };

    let ps = proc::run_simple("/bin/ps", &["-p", &pid.to_string(), "-o", "comm="], 10);
    let command = ps.stdout.trim().to_string();

    let fd = proc::run_simple("/usr/sbin/lsof", &["-p", &pid.to_string(), "-Fn"], 10);
    let want = our_adb.map(|p| fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()));

    let mut full_path = String::new();
    let mut is_our_adb = false;
    for line in fd.stdout.lines() {
        let Some(path) = line.strip_prefix('n') else {
            continue;
        };
        if !path.starts_with('/') {
            continue;
        }
        let canon = fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
        if let Some(w) = &want {
            if &canon == w {
                is_our_adb = true;
                full_path = path.to_string();
                break;
            }
        }
        if full_path.is_empty() && canon.file_name().and_then(|n| n.to_str()) == Some("adb") {
            full_path = path.to_string();
        }
    }

    let is_adb = is_our_adb
        || command == "adb"
        || command.ends_with("/adb")
        || full_path.ends_with("/adb");

    PortStatus {
        busy: true,
        pid: Some(pid),
        command,
        full_path,
        is_adb,
        is_our_adb,
    }
}

pub fn xattr_names(path: &Path) -> Vec<String> {
    let out = proc::run_simple("/usr/bin/xattr", &[&path.to_string_lossy()], 15);
    out.stdout
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

#[derive(Debug, Clone, Default)]
pub struct HostInfo {
    pub version: String,
    pub build: String,
    pub major: i64,
    pub arch: String,
}

impl HostInfo {
    pub fn is_sequoia_or_later(&self) -> bool {
        self.major >= 15
    }

    pub fn to_json(&self) -> J {
        J::obj([
            ("macOSVersion", J::s(&self.version)),
            ("macOSBuild", J::s(&self.build)),
            ("macOSMajor", J::N(self.major)),
            ("arch", J::s(&self.arch)),
            ("isSequoiaOrLater", J::B(self.is_sequoia_or_later())),
        ])
    }
}

pub fn host_environment() -> HostInfo {
    let sw = proc::run_simple("/usr/bin/sw_vers", &["-productVersion"], 10);
    let build = proc::run_simple("/usr/bin/sw_vers", &["-buildVersion"], 10);
    let arch = proc::run_simple("/usr/bin/uname", &["-m"], 10);
    let version = sw.stdout.trim().to_string();
    let major: i64 = version
        .split('.')
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    HostInfo {
        version,
        build: build.stdout.trim().to_string(),
        major,
        arch: arch.stdout.trim().to_string(),
    }
}

pub fn unique_sorted(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let set: BTreeSet<String> = values.into_iter().collect();
    set.into_iter().collect()
}
