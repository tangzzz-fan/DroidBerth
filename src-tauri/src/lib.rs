mod sidecar;

use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Serialize)]
struct InvocationView {
    program: String,
    code: Option<i32>,
    stdout: String,
    stderr: String,
    timed_out: bool,
    duration_ms: u64,
    spawn_error: Option<String>,
    parsed: Option<Value>,
}

impl From<sidecar::Invocation> for InvocationView {
    fn from(v: sidecar::Invocation) -> Self {
        let parsed = serde_json::from_str::<Value>(v.stdout.trim()).ok();
        InvocationView {
            program: v.program,
            code: v.code,
            stdout: v.stdout,
            stderr: v.stderr,
            timed_out: v.timed_out,
            duration_ms: v.duration_ms as u64,
            spawn_error: v.spawn_error,
            parsed,
        }
    }
}

#[tauri::command]
fn sidecar_probe() -> Value {
    json!({
        "resolved": sidecar::resolve().map(|p| p.to_string_lossy().into_owned()),
        "candidates": sidecar::candidates()
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect::<Vec<_>>(),
    })
}

#[tauri::command]
fn doctor() -> InvocationView {
    sidecar::invoke(&["doctor".into(), "--compact".into()], 120).into()
}

#[tauri::command]
fn sidecar_run(args: Vec<String>, timeout_secs: Option<u64>) -> InvocationView {
    sidecar::invoke(&args, timeout_secs.unwrap_or(60)).into()
}

#[tauri::command]
fn adb_run(args: Vec<String>, timeout_secs: Option<u64>) -> InvocationView {
    let timeout = timeout_secs.unwrap_or(30);
    let mut full: Vec<String> = vec![
        "exec".into(),
        "--timeout".into(),
        timeout.to_string(),
        "--".into(),
    ];
    full.extend(args);
    sidecar::invoke(&full, timeout + 10).into()
}

#[tauri::command]
fn adb_devices() -> InvocationView {
    sidecar::invoke(
        &[
            "exec".into(),
            "--timeout".into(),
            "20".into(),
            "--".into(),
            "devices".into(),
            "-l".into(),
        ],
        30,
    )
    .into()
}

#[tauri::command]
fn read_text(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))
}

#[tauri::command]
fn save_report(contents: String) -> Result<String, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    let dir: PathBuf = PathBuf::from(home).join("DroidDock-reports");
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = dir.join(format!("droidock-report-{stamp}.json"));
    std::fs::write(&path, contents).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path.to_string_lossy().into_owned())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            sidecar_probe,
            doctor,
            sidecar_run,
            adb_run,
            adb_devices,
            read_text,
            save_report
        ])
        .run(tauri::generate_context!())
        .expect("error while running DroidDock");
}
