//! `ozshell msg TARGET FUNCTION` over a unix socket in the runtime directory.

use super::{Msg, send};
use std::{io::Write, path::PathBuf};
use tokio::io::AsyncReadExt;

fn path() -> PathBuf {
    PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()))
        .join("ozshell.sock")
}

pub async fn serve() {
    let _ = std::fs::remove_file(path());
    let listener = match tokio::net::UnixListener::bind(path()) {
        Ok(l) => l,
        Err(e) => return eprintln!("ozshell: cannot bind {}: {e}", path().display()),
    };
    while let Ok((mut stream, _)) = listener.accept().await {
        let mut cmd = String::new();
        if stream.read_to_string(&mut cmd).await.is_ok() {
            send(Msg::Ipc(cmd.trim().to_owned()));
        }
    }
}

pub fn client(args: &[String]) {
    let sent = std::os::unix::net::UnixStream::connect(path())
        .and_then(|mut s| s.write_all(args.join(" ").as_bytes()));
    if let Err(e) = sent {
        eprintln!("ozshell: {e}");
        std::process::exit(1);
    }
}
