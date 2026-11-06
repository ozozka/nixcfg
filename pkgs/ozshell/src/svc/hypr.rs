//! Hyprland workspaces, focused monitor, keyboard layout and submap over its sockets.

use super::{Msg, send};
use serde_json::Value;
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[derive(Clone, Default, PartialEq)]
pub struct Hypr {
    /// Workspace id and window count.
    pub workspaces: Vec<(i64, i64)>,
    pub focused_ws: i64,
    pub monitor: String,
    pub layout: String,
    pub submap: String,
}

fn socket(name: &str) -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
    PathBuf::from(dir).join("hypr").join(sig).join(name)
}

async fn request(cmd: &str) -> Option<String> {
    let mut s = UnixStream::connect(socket(".socket.sock")).await.ok()?;
    s.write_all(cmd.as_bytes()).await.ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).await.ok()?;
    Some(out)
}

async fn json(cmd: &str) -> Value {
    request(cmd).await.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

async fn workspaces(h: &mut Hypr) {
    let ws = json("j/workspaces").await;
    h.workspaces = ws
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| Some((w["id"].as_i64()?, w["windows"].as_i64().unwrap_or(0))))
        .collect();
    let monitors = json("j/monitors").await;
    if let Some(m) = monitors.as_array().into_iter().flatten().find(|m| m["focused"] == true) {
        h.monitor = m["name"].as_str().unwrap_or_default().to_owned();
        h.focused_ws = m["activeWorkspace"]["id"].as_i64().unwrap_or(0);
    }
}

async fn layout(h: &mut Hypr) {
    let devices = json("j/devices").await;
    let Some(main) =
        devices["keyboards"].as_array().into_iter().flatten().find(|k| k["main"] == true)
    else {
        return;
    };
    let layouts: Vec<&str> = main["layout"].as_str().unwrap_or_default().split(',').collect();
    let active = main["active_layout_index"].as_u64().unwrap_or(0) as usize;
    h.layout = match layouts.get(active) {
        Some(l) if !l.is_empty() => (*l).to_owned(),
        _ => main["active_keymap"].as_str().unwrap_or_default().to_owned(),
    };
}

fn affects_workspaces(event: &str) -> bool {
    ["workspace", "focusedmon", "createworkspace", "destroyworkspace", "moveworkspace"]
        .iter()
        .chain(&["openwindow", "closewindow", "movewindow", "monitor", "renameworkspace"])
        .any(|p| event.starts_with(p))
}

pub async fn run() {
    let mut h = Hypr::default();
    workspaces(&mut h).await;
    layout(&mut h).await;
    h.submap = request("submap").await.unwrap_or_default().trim().to_owned();
    send(Msg::Hypr(h.clone()));

    let Ok(events) = UnixStream::connect(socket(".socket2.sock")).await else {
        eprintln!("ozshell: Hyprland event socket unavailable");
        return;
    };
    let mut lines = BufReader::new(events).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Some((event, data)) = line.split_once(">>") else { continue };
        let old = h.clone();
        match event {
            "activelayout" => layout(&mut h).await,
            "submap" => h.submap = if data.is_empty() { "default".into() } else { data.into() },
            e if affects_workspaces(e) => workspaces(&mut h).await,
            _ => continue,
        }
        if h != old {
            send(Msg::Hypr(h.clone()));
        }
    }
}
