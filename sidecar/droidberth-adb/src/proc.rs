use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Out {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
    pub spawn_error: Option<String>,
    pub duration_ms: u128,
}

impl Out {
    pub fn ok(&self) -> bool {
        !self.timed_out && self.spawn_error.is_none() && self.code == Some(0)
    }

    pub fn combined(&self) -> String {
        let mut s = self.stdout.clone();
        if !self.stderr.is_empty() {
            if !s.is_empty() && !s.ends_with('\n') {
                s.push('\n');
            }
            s.push_str(&self.stderr);
        }
        s
    }

    pub fn error(message: impl Into<String>) -> Out {
        Out {
            code: None,
            stdout: String::new(),
            stderr: String::new(),
            timed_out: false,
            spawn_error: Some(message.into()),
            duration_ms: 0,
        }
    }
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

pub fn run(program: &str, args: &[String], timeout: Duration) -> Out {
    let started = Instant::now();
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let mut out = Out::error(format!("spawn {program} failed: {e}"));
            out.duration_ms = started.elapsed().as_millis();
            return out;
        }
    };

    let rx_out = child.stdout.take().map(pump);
    let rx_err = child.stderr.take().map(pump);

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
                let mut out = Out::error(format!("wait {program} failed: {e}"));
                out.duration_ms = started.elapsed().as_millis();
                return out;
            }
        }
        if started.elapsed() >= timeout {
            timed_out = true;
            let _ = child.kill();
            let _ = child.wait();
            break;
        }
        thread::sleep(Duration::from_millis(15));
    }

    let stdout = rx_out
        .and_then(|rx| rx.recv_timeout(Duration::from_millis(500)).ok())
        .unwrap_or_default();
    let stderr = rx_err
        .and_then(|rx| rx.recv_timeout(Duration::from_millis(500)).ok())
        .unwrap_or_default();

    Out {
        code,
        stdout,
        stderr,
        timed_out,
        spawn_error: None,
        duration_ms: started.elapsed().as_millis(),
    }
}

pub fn run_simple(program: &str, args: &[&str], timeout_secs: u64) -> Out {
    let owned: Vec<String> = args.iter().map(|a| a.to_string()).collect();
    run(program, &owned, Duration::from_secs(timeout_secs))
}

pub fn which(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}
