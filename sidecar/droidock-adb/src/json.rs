use std::fmt::Write;

#[derive(Clone)]
pub enum J {
    S(String),
    N(i64),
    F(f64),
    B(bool),
    Null,
    A(Vec<J>),
    O(Vec<(String, J)>),
}

impl J {
    pub fn s(v: impl Into<String>) -> J {
        J::S(v.into())
    }

    pub fn arr<I: IntoIterator<Item = J>>(v: I) -> J {
        J::A(v.into_iter().collect())
    }

    pub fn obj<I: IntoIterator<Item = (&'static str, J)>>(v: I) -> J {
        J::O(v.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn render(&self) -> String {
        let mut out = String::with_capacity(1024);
        self.write(&mut out, 0, false);
        out
    }

    pub fn render_pretty(&self) -> String {
        let mut out = String::with_capacity(4096);
        self.write(&mut out, 0, true);
        out
    }

    fn pad(out: &mut String, depth: usize) {
        out.push('\n');
        for _ in 0..depth {
            out.push_str("  ");
        }
    }

    fn write(&self, out: &mut String, depth: usize, pretty: bool) {
        match self {
            J::S(v) => J::esc(v, out),
            J::N(v) => {
                let _ = write!(out, "{v}");
            }
            J::F(v) => {
                if v.is_finite() {
                    let _ = write!(out, "{v:.3}");
                } else {
                    out.push_str("null");
                }
            }
            J::B(v) => out.push_str(if *v { "true" } else { "false" }),
            J::Null => out.push_str("null"),
            J::A(items) => {
                if items.is_empty() {
                    out.push_str("[]");
                    return;
                }
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    if pretty {
                        J::pad(out, depth + 1);
                    }
                    item.write(out, depth + 1, pretty);
                }
                if pretty {
                    J::pad(out, depth);
                }
                out.push(']');
            }
            J::O(items) => {
                if items.is_empty() {
                    out.push_str("{}");
                    return;
                }
                out.push('{');
                for (i, (k, v)) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    if pretty {
                        J::pad(out, depth + 1);
                    }
                    J::esc(k, out);
                    out.push(':');
                    if pretty {
                        out.push(' ');
                    }
                    v.write(out, depth + 1, pretty);
                }
                if pretty {
                    J::pad(out, depth);
                }
                out.push('}');
            }
        }
    }

    fn esc(s: &str, out: &mut String) {
        out.push('"');
        for ch in s.chars() {
            match ch {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 => {
                    let _ = write!(out, "\\u{:04x}", c as u32);
                }
                c => out.push(c),
            }
        }
        out.push('"');
    }
}
