use crate::{PinStore, Secret, request::Request};
use std::{
    ffi::OsString,
    fmt,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, Command, Stdio},
};

// Assuan's limit includes the newline. All buffers that can contain secret
// bytes are preallocated and zeroized, including encoded transport frames.
const LINE_LIMIT: usize = 1000;
const SECRET_LIMIT: usize = 4096;
const RESPONSE_LIMIT: usize = 65536;
const FAILURE: &[u8] = b"ERR 83886081 Pinentry request failed\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyError {
    Protocol,
    Io,
    Store,
    Frontend,
}
impl fmt::Display for ProxyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Protocol => "invalid pinentry protocol",
            Self::Io => "pinentry transport failed",
            Self::Store => "native PIN store failed",
            Self::Frontend => "pinentry frontend unavailable",
        })
    }
}
impl std::error::Error for ProxyError {}

fn read_line(reader: &mut impl BufRead) -> Result<Option<Secret>, ProxyError> {
    let mut line = Secret::new(Vec::with_capacity(LINE_LIMIT));
    loop {
        let available = reader.fill_buf().map_err(|_| ProxyError::Io)?;
        if available.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                Err(ProxyError::Protocol)
            };
        }
        let count = available
            .iter()
            .position(|b| *b == b'\n')
            .map_or(available.len(), |p| p + 1);
        if line.len() + count > LINE_LIMIT {
            return Err(ProxyError::Protocol);
        }
        let finished = available[count - 1] == b'\n';
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if finished {
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            if line.contains(&0) || line.contains(&b'\r') {
                return Err(ProxyError::Protocol);
            }
            return Ok(Some(line));
        }
    }
}

fn send(writer: &mut impl Write, line: &[u8]) -> Result<(), ProxyError> {
    writer
        .write_all(line)
        .and_then(|_| writer.write_all(b"\n"))
        .and_then(|_| writer.flush())
        .map_err(|_| ProxyError::Io)
}

pub(crate) fn decode(encoded: &[u8]) -> Result<Secret, ProxyError> {
    let mut decoded = Secret::new(Vec::with_capacity(encoded.len()));
    let mut pos = 0;
    while pos < encoded.len() {
        if encoded[pos] == b'%' {
            let hex = encoded.get(pos + 1..pos + 3).ok_or(ProxyError::Protocol)?;
            let digit = |b: u8| match b {
                b'0'..=b'9' => Some(b - b'0'),
                b'a'..=b'f' => Some(b - b'a' + 10),
                b'A'..=b'F' => Some(b - b'A' + 10),
                _ => None,
            };
            decoded.push(
                digit(hex[0]).ok_or(ProxyError::Protocol)? * 16
                    + digit(hex[1]).ok_or(ProxyError::Protocol)?,
            );
            pos += 3;
        } else {
            decoded.push(encoded[pos]);
            pos += 1;
        }
    }
    Ok(decoded)
}

fn command(line: &[u8]) -> (&[u8], &[u8]) {
    line.iter()
        .position(|b| *b == b' ')
        .map_or((line, &[][..]), |p| (&line[..p], &line[p + 1..]))
}
fn terminal(line: &[u8]) -> Option<bool> {
    match command(line).0 {
        b"OK" => Some(true),
        b"ERR" => Some(false),
        _ => None,
    }
}

fn inquiry(
    upstream: &mut impl BufRead,
    output: &mut impl Write,
    frontend_input: &mut impl Write,
    line: &[u8],
) -> Result<(), ProxyError> {
    send(output, line)?;
    let mut total = 0;
    loop {
        let response = read_line(upstream)?.ok_or(ProxyError::Protocol)?;
        match command(&response).0 {
            b"D" => {
                total += decode(command(&response).1)?.len();
                if total > SECRET_LIMIT {
                    return Err(ProxyError::Protocol);
                }
                send(frontend_input, &response)?;
            }
            b"END" | b"CAN" => {
                send(frontend_input, &response)?;
                return Ok(());
            }
            _ => return Err(ProxyError::Protocol),
        }
    }
}

struct Response {
    frames: Secret,
    data: Secret,
    success: bool,
    cached: bool,
    has_data: bool,
}

fn response(
    upstream: &mut impl BufRead,
    output: &mut impl Write,
    frontend: &mut impl BufRead,
    frontend_input: &mut impl Write,
    capture: bool,
) -> Result<Response, ProxyError> {
    let mut reply = Response {
        frames: Secret::new(Vec::with_capacity(RESPONSE_LIMIT)),
        data: Secret::new(Vec::with_capacity(SECRET_LIMIT)),
        success: false,
        cached: false,
        has_data: false,
    };
    loop {
        let line = read_line(frontend)?.ok_or(ProxyError::Protocol)?;
        let (cmd, argument) = command(&line);
        if cmd == b"INQUIRE" {
            if capture && !reply.has_data {
                // Status preceding an inquiry must reach the caller before
                // the inquiry. PIN data remains held until the store commits.
                output
                    .write_all(&reply.frames)
                    .and_then(|_| output.flush())
                    .map_err(|_| ProxyError::Io)?;
                reply.frames.clear();
            }
            inquiry(upstream, output, frontend_input, &line)?;
            continue;
        }
        if cmd == b"D" {
            let data = decode(argument)?;
            if reply.data.len() + data.len() > SECRET_LIMIT {
                return Err(ProxyError::Protocol);
            }
            // Even delegated streams are bounded, without retaining their PIN.
            if capture {
                reply.data.extend_from_slice(&data);
            } else {
                let size = reply.data.len() + data.len();
                reply.data.resize(size, 0);
            }
            reply.has_data = true;
        } else if cmd == b"S" {
            if command(argument).0 == b"PASSWORD_FROM_CACHE" {
                reply.cached = true;
            }
        } else if terminal(&line).is_none() && !line.starts_with(b"#") && !line.is_empty() {
            return Err(ProxyError::Protocol);
        }
        if capture {
            if reply.frames.len() + line.len() + 1 > RESPONSE_LIMIT {
                return Err(ProxyError::Protocol);
            }
            reply.frames.extend_from_slice(&line);
            reply.frames.push(b'\n');
        } else {
            send(output, &line)?;
        }
        if let Some(success) = terminal(&line) {
            reply.success = success;
            return Ok(reply);
        }
    }
}

fn send_secret(output: &mut impl Write, secret: &[u8]) -> Result<(), ProxyError> {
    if secret.len() > SECRET_LIMIT {
        return Err(ProxyError::Protocol);
    }
    let mut line = Secret::new(Vec::with_capacity(LINE_LIMIT));
    line.extend_from_slice(b"D ");
    for &byte in secret {
        let width = if matches!(byte, b'%' | b'\r' | b'\n' | 0) {
            3
        } else {
            1
        };
        if line.len() + width + 1 > LINE_LIMIT {
            send(output, &line)?;
            line.truncate(2);
        }
        if width == 3 {
            const HEX: &[u8] = b"0123456789ABCDEF";
            line.extend_from_slice(&[b'%', HEX[(byte >> 4) as usize], HEX[(byte & 15) as usize]]);
        } else {
            line.push(byte);
        }
    }
    send(output, &line)
}

/// Serve one session using an already connected trusted frontend. This seam
/// permits deterministic tests without selecting a native store or dialog.
/// The frontend's greeting is consumed and forwarded before client commands.
pub fn serve(
    upstream: &mut impl BufRead,
    output: &mut impl Write,
    frontend: &mut impl BufRead,
    frontend_input: &mut impl Write,
    store: &mut impl PinStore,
) -> Result<(), ProxyError> {
    let result = session(upstream, output, frontend, frontend_input, store);
    if result.is_err() {
        let _ = output.write_all(FAILURE).and_then(|_| output.flush());
    }
    result
}

fn session(
    upstream: &mut impl BufRead,
    output: &mut impl Write,
    frontend: &mut impl BufRead,
    frontend_input: &mut impl Write,
    store: &mut impl PinStore,
) -> Result<(), ProxyError> {
    if !response(upstream, output, frontend, frontend_input, false)?.success {
        return Err(ProxyError::Frontend);
    }
    let mut request = Request::default();
    let mut allow_cache = false;
    while let Some(line) = read_line(upstream)? {
        if line.is_empty() || line.starts_with(b"#") {
            continue;
        }
        let (cmd, argument) = command(&line);
        if cmd == b"GETPIN" && argument.is_empty() {
            let qualified = if allow_cache {
                request.classify()
            } else {
                None
            };
            // A subsequent interaction must receive fresh descriptor and prompt
            // context. In particular a failed dialog cannot reuse an old card.
            request = Request::default();
            if let Some((card, warning)) = qualified {
                if warning {
                    store.delete(&card).map_err(|_| ProxyError::Store)?;
                } else if let Some(secret) = store.get(&card).map_err(|_| ProxyError::Store)? {
                    if secret.is_empty() || secret.len() > SECRET_LIMIT {
                        return Err(ProxyError::Store);
                    }
                    send(output, b"S PASSWORD_FROM_CACHE")?;
                    send_secret(output, &secret)?;
                    send(output, b"OK")?;
                    continue;
                }
                send(frontend_input, &line)?;
                let reply = response(upstream, output, frontend, frontend_input, true)?;
                if reply.success && reply.has_data && !reply.data.is_empty() && !reply.cached {
                    store
                        .set(&card, &reply.data)
                        .map_err(|_| ProxyError::Store)?;
                }
                if reply.success {
                    if !reply.has_data {
                        return Err(ProxyError::Protocol);
                    }
                    output
                        .write_all(&reply.frames)
                        .and_then(|_| output.flush())
                        .map_err(|_| ProxyError::Io)?;
                } else {
                    // Native errors/statuses remain exact; partial PIN data on
                    // a failed transaction is never released or enrolled.
                    for frame in reply
                        .frames
                        .split(|b| *b == b'\n')
                        .filter(|v| !v.is_empty())
                    {
                        if command(frame).0 != b"D" {
                            send(output, frame)?;
                        }
                    }
                }
                continue;
            }
        }
        // Clear before forwarding context changes, even when the frontend
        // rejects one: a failed update must not retain a previous identity.
        request.update(cmd, argument);
        send(frontend_input, &line)?;
        let reply = response(upstream, output, frontend, frontend_input, false)?;
        if !reply.success {
            request = Request::default();
        }
        if cmd == b"OPTION" && argument == b"allow-external-password-cache" && reply.success {
            allow_cache = true;
        }
        if cmd == b"BYE" {
            return Ok(());
        }
    }
    Ok(())
}

struct Frontend(Child);
impl Drop for Frontend {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Spawn the configured absolute executable directly, without a shell or
/// command-line secret. Resolve aliases before preventing wrapper recursion.
pub fn serve_with_fallback(
    upstream: &mut impl BufRead,
    output: &mut impl Write,
    fallback: &Path,
    arguments: &[OsString],
    store: &mut impl PinStore,
) -> Result<(), ProxyError> {
    if !fallback.is_absolute() {
        return Err(ProxyError::Frontend);
    }
    let path = fallback.canonicalize().map_err(|_| ProxyError::Frontend)?;
    let current = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|_| ProxyError::Frontend)?;
    if path == current {
        return Err(ProxyError::Frontend);
    }
    let mut child = Frontend(
        Command::new(path)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| ProxyError::Frontend)?,
    );
    let mut input = child.0.stdin.take().ok_or(ProxyError::Frontend)?;
    let mut reader = BufReader::new(child.0.stdout.take().ok_or(ProxyError::Frontend)?);
    serve(upstream, output, &mut reader, &mut input, store)
}
