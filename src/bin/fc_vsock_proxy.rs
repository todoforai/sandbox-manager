//! `fc-vsock-proxy` — SSH ProxyCommand for Firecracker vsock UDS.
//!
//! Usage: `ssh -o ProxyCommand="fc-vsock-proxy <uds_path> <port>" user@whatever`
//!
//! Connects to the Firecracker vsock host endpoint, performs the
//! `CONNECT <port>\n` / `OK <peer_port>\n` handshake, then bidirectionally
//! pipes stdin/stdout against the Unix socket.
//!
//! Sync std-only; no tokio. Each invocation handles exactly one SSH session
//! (FC vsock muxes per-connection).

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::thread;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let (uds, port) = match (args.next(), args.next()) {
        (Some(u), Some(p)) => (u, p),
        _ => {
            eprintln!("usage: fc-vsock-proxy <uds_path> <port>");
            return ExitCode::from(2);
        }
    };

    let mut sock = match UnixStream::connect(&uds) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("fc-vsock-proxy: connect {uds}: {e}");
            return ExitCode::from(1);
        }
    };

    // Firecracker host-initiated handshake: write `CONNECT <port>\n`,
    // read one line back. Success starts with `OK `; anything else is failure.
    if let Err(e) = sock.write_all(format!("CONNECT {port}\n").as_bytes()) {
        eprintln!("fc-vsock-proxy: write CONNECT: {e}");
        return ExitCode::from(1);
    }
    // Read handshake one byte at a time — must NOT use BufReader, which would
    // consume bytes past the newline and silently drop the SSH banner that
    // the guest sends immediately after `OK`.
    let mut line = Vec::with_capacity(32);
    loop {
        let mut b = [0u8; 1];
        match sock.read(&mut b) {
            Ok(0) => { eprintln!("fc-vsock-proxy: EOF before handshake"); return ExitCode::from(1); }
            Ok(_) => { line.push(b[0]); if b[0] == b'\n' { break; } }
            Err(e) => { eprintln!("fc-vsock-proxy: read handshake: {e}"); return ExitCode::from(1); }
        }
        if line.len() > 256 { eprintln!("fc-vsock-proxy: handshake line too long"); return ExitCode::from(1); }
    }
    if !line.starts_with(b"OK ") {
        eprintln!("fc-vsock-proxy: handshake failed: {}", String::from_utf8_lossy(&line).trim_end());
        return ExitCode::from(1);
    }

    // Bidirectional copy. Two threads, exit when either direction EOFs.
    let mut sock_to_stdout = sock.try_clone().expect("clone uds");
    let t = thread::spawn(move || {
        let mut buf = [0u8; 8192];
        let mut out = io::stdout().lock();
        loop {
            match sock_to_stdout.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.write_all(&buf[..n]).is_err() { break; }
                    if out.flush().is_err() { break; }
                }
            }
        }
    });

    let mut buf = [0u8; 8192];
    let mut stdin = io::stdin().lock();
    loop {
        match stdin.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if sock.write_all(&buf[..n]).is_err() { break; }
            }
        }
    }
    // Half-close so the peer thread sees EOF.
    let _ = sock.shutdown(std::net::Shutdown::Write);
    let _ = t.join();
    ExitCode::SUCCESS
}
