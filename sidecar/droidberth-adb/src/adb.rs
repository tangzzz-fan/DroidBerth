use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::diag;
use crate::json::J;
use crate::proc;

#[derive(Debug, Clone)]
pub struct Resolution {
    pub found: bool,
    pub path: Option<PathBuf>,
    pub source: &'static str,
    pub probes: Vec<(String, &'static str, bool)>,
}

impl Resolution {
    pub fn to_json(&self) -> J {
        J::obj([
            ("found", J::B(self.found)),
            (
                "path",
                match &self.path {
                    Some(p) => J::s(p.to_string_lossy().to_string()),
                    None => J::Null,
                },
            ),
            ("source", J::s(self.source)),
            (
                "probes",
                J::arr(
                    self.probes
                        .iter()
                        .map(|(p, src, exists)| {
                            J::obj([
                                ("path", J::s(p)),
                                ("source", J::s(*src)),
                                ("exists", J::B(*exists)),
                            ])
                        })
                        .collect::<Vec<_>>(),
                ),
            ),
        ])
    }
}

fn sidecar_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
    exe.parent().map(|p| p.to_path_buf())
}

pub fn resolve() -> Resolution {
    let mut probes: Vec<(String, &'static str, bool)> = Vec::new();
    let push = |path: PathBuf, source: &'static str, probes: &mut Vec<(String, &'static str, bool)>| {
        let exists = path.is_file();
        probes.push((path.to_string_lossy().into_owned(), source, exists));
        if exists {
            Some(path)
        } else {
            None
        }
    };

    let mut hit: Option<(PathBuf, &'static str)> = None;

    if let Some(env_path) = std::env::var_os("DROIDBERTH_ADB") {
        let p = PathBuf::from(env_path);
        if let Some(found) = push(p, "env:DROIDBERTH_ADB", &mut probes) {
            hit = Some((found, "env:DROIDBERTH_ADB"));
        }
    }

    if hit.is_none() {
        if let Some(dir) = sidecar_dir() {
            let candidates: [(PathBuf, &'static str); 4] = [
                (dir.join("adb"), "bundled:Contents/MacOS/adb"),
                (
                    dir.join("../Resources/adb"),
                    "bundled:Contents/Resources/adb",
                ),
                (
                    dir.join("../Resources/binaries/adb"),
                    "bundled:Contents/Resources/binaries/adb",
                ),
                (
                    dir.join("../Resources/platform-tools/adb"),
                    "bundled:Contents/Resources/platform-tools/adb",
                ),
            ];
            for (path, source) in candidates {
                if let Some(found) = push(path, source, &mut probes) {
                    hit = Some((found, source));
                    break;
                }
            }
        }
    }

    if hit.is_none() {
        if let Some(path) = proc::which("adb") {
            let p = PathBuf::from(path);
            if let Some(found) = push(p, "path:PATH", &mut probes) {
                hit = Some((found, "path:PATH"));
            }
        } else {
            probes.push(("adb (via PATH lookup)".into(), "path:PATH", false));
        }
    }

    if hit.is_none() {
        let mut sdk_roots: Vec<(PathBuf, &'static str)> = Vec::new();
        for var in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let Some(v) = std::env::var_os(var) {
                sdk_roots.push((PathBuf::from(v).join("platform-tools/adb"), "android-sdk:env"));
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            sdk_roots.push((
                PathBuf::from(home).join("Library/Android/sdk/platform-tools/adb"),
                "android-sdk:default-location",
            ));
        }
        for (path, source) in sdk_roots {
            if let Some(found) = push(path, source, &mut probes) {
                hit = Some((found, source));
                break;
            }
        }
    }

    match hit {
        Some((path, source)) => Resolution {
            found: true,
            path: Some(path),
            source,
            probes,
        },
        None => Resolution {
            found: false,
            path: None,
            source: "none",
            probes,
        },
    }
}

pub fn adb_json(path: &Path) -> J {
    let (deps, foreign) = diag::otool_dependencies(path);
    let version = proc::run_simple(
        &path.to_string_lossy(),
        &["version"],
        15,
    );
    let archs = diag::lipo_archs(path);
    let sig = diag::inspect_signature(path);
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    J::obj([
        ("path", J::s(path.to_string_lossy().to_string())),
        ("sizeBytes", J::N(size as i64)),
        ("fileType", J::s(diag::file_type(path))),
        (
            "archs",
            J::arr(archs.iter().map(J::s).collect::<Vec<_>>()),
        ),
        ("universal", J::B(archs.len() > 1)),
        (
            "dependencies",
            J::arr(deps.iter().map(J::s).collect::<Vec<_>>()),
        ),
        (
            "foreignDependencies",
            J::arr(foreign.iter().map(J::s).collect::<Vec<_>>()),
        ),
        (
            "systemOnlyDependencies",
            J::B(foreign.is_empty()),
        ),
        ("signature", sig.to_json()),
        ("versionOutput", J::s(version.combined().trim())),
        ("versionOk", J::B(version.ok())),
    ])
}

pub fn exec(args: &[String], timeout_secs: u64) -> J {
    let resolution = resolve();
    let Some(adb) = resolution.path else {
        return J::obj([
            ("ok", J::B(false)),
            ("error", J::s("adb binary not found")),
            ("resolution", resolution.to_json()),
        ]);
    };
    let out = proc::run(
        &adb.to_string_lossy(),
        args,
        Duration::from_secs(timeout_secs),
    );
    J::obj([
        ("ok", J::B(out.ok())),
        (
            "code",
            match out.code {
                Some(c) => J::N(c as i64),
                None => J::Null,
            },
        ),
        ("stdout", J::s(&out.stdout)),
        ("stderr", J::s(&out.stderr)),
        ("timedOut", J::B(out.timed_out)),
        ("durationMs", J::N(out.duration_ms as i64)),
        ("adbPath", J::s(adb.to_string_lossy().to_string())),
        ("source", J::s(resolution.source)),
        (
            "error",
            match &out.spawn_error {
                Some(e) => J::s(e),
                None => J::Null,
            },
        ),
    ])
}
