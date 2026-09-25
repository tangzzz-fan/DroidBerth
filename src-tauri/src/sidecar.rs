use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Invocation {
    pub program: String,
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
    pub duration_ms: u128,
    pub spawn_error: Option<String>,
}

fn host_triple() -> String {
    format!("{}-apple-darwin", std::env::consts::ARCH)
}

fn exe_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    std::fs::canonicalize(&exe)
        .unwrap_or(exe)
        .parent()
        .map(|p| p.to_path_buf())
}

pub fn candidates() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(v) = std::env::var_os("DROIDBERTH_SIDECAR") {
        out.push(PathBuf::from(v));
    }
    if let Some(dir) = exe_dir() {
        out.push(dir.join("droidberth-adb"));
        out.push(dir.join(format!("droidberth-adb-{}", host_triple())));
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    out.push(
        manifest
            .join("binaries")
            .join(format!("droidberth-adb-{}", host_triple())),
    );
    out.push(
        manifest
            .join("../sidecar/droidberth-adb/target/release/droidberth-adb"),
    );
    out
}

pub fn resolve() -> Option<PathBuf> {
    candidates().into_iter().find(|p| p.is_file())
}

fn pump<R: Read + Send + 'static>(mut reader: R) -> mpsc::Receiver<String> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf);
        let _ = tx.send(String::from_utf8_lossy(&buf).into_owned());
    });
    rx
}

pub fn invoke(args: &[String], timeout_secs: u64) -> Invocation {
    let Some(program) = resolve() else {
        return Invocation {
            program: "(unresolved)".into(),
            code: None,
            stdout: String::new(),
            stderr: String::new(),
            timed_out: false,
            duration_ms: 0,
            spawn_error: Some(format!(
                "sidecar not found; looked at: {}",
                candidates()
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        };
    };

    let started = Instant::now();
    let mut child = match Command::new(&program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return Invocation {
                program: program.to_string_lossy().into_owned(),
                code: None,
                stdout: String::new(),
                stderr: String::new(),
                timed_out: false,
                duration_ms: started.elapsed().as_millis(),
                spawn_error: Some(e.to_string()),
            }
        }
    };

    let rx_out = child.stdout.take().map(pump);
    let rx_err = child.stderr.take().map(pump);

    let deadline = Duration::from_secs(timeout_secs);
    let mut timed_out = false;
    let mut code = None;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                code = status.code();
                break;
            }
            Ok(None) => {}
            Err(e) => {
                return Invocation {
                    program: program.to_string_lossy().into_owned(),
                    code: None,
                    stdout: String::new(),
                    stderr: String::new(),
                    timed_out: false,
                    duration_ms: started.elapsed().as_millis(),
                    spawn_error: Some(e.to_string()),
                }
            }
        }
        if started.elapsed() >= deadline {
            timed_out = true;
            let _ = child.kill();
            let _ = child.wait();
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }

    let stdout = rx_out
        .and_then(|rx| rx.recv_timeout(Duration::from_millis(800)).ok())
        .unwrap_or_default();
    let stderr = rx_err
        .and_then(|rx| rx.recv_timeout(Duration::from_millis(800)).ok())
        .unwrap_or_default();

    Invocation {
        program: program.to_string_lossy().into_owned(),
        code,
        stdout,
        stderr,
        timed_out,
        duration_ms: started.elapsed().as_millis(),
        spawn_error: None,
    }
}
