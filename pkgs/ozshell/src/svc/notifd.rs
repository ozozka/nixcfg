//! `org.freedesktop.Notifications` server. Notifications stay until dismissed.

use super::{Msg, Props, get, send, session, spawn};
use crate::clock;
use egui::ColorImage;
use std::sync::{Arc, atomic::AtomicU32, atomic::Ordering};
use zbus::OwnedVariant;

const PATH: &str = "/org/freedesktop/Notifications";
const IFACE: &str = "org.freedesktop.Notifications";

#[derive(Clone)]
pub enum Image {
    Path(String),
    Raw(Arc<ColorImage>),
}

#[derive(Clone)]
pub struct Note {
    pub id: u32,
    pub app: String,
    pub icon: String,
    pub summary: String,
    pub body: String,
    pub actions: Vec<(String, String)>,
    pub image: Option<Image>,
    pub time: String,
}

struct Server {
    next: AtomicU32,
}

fn image(hints: &Props) -> Option<Image> {
    for key in ["image-data", "image_data", "icon_data"] {
        type Raw = (i32, i32, i32, bool, i32, i32, Vec<u8>);
        if let Some((w, h, stride, alpha, _, ch, data)) = get::<Raw>(hints, key) {
            return crate::img::raw(w, h, stride, alpha, ch, &data)
                .map(|i| Image::Raw(Arc::new(i)));
        }
    }
    ["image-path", "image_path"]
        .iter()
        .find_map(|k| get::<String>(hints, k))
        .filter(|p| !p.is_empty())
        .map(Image::Path)
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Server {
    fn get_capabilities(&self) -> Vec<&'static str> {
        vec!["actions", "body", "persistence", "icon-static"]
    }

    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: std::collections::HashMap<String, OwnedVariant>,
        _expire_timeout: i32,
    ) -> u32 {
        let id = if replaces_id != 0 {
            replaces_id
        } else {
            self.next.fetch_add(1, Ordering::Relaxed)
        };
        send(Msg::Note(Note {
            id,
            app: app_name,
            icon: app_icon,
            summary,
            body,
            actions: actions
                .as_chunks::<2>()
                .0
                .iter()
                .map(|[k, v]| (k.clone(), v.clone()))
                .collect(),
            image: image(&hints),
            time: clock::format(&clock::now(), "%H:%M"),
        }));
        id
    }

    fn close_notification(&self, id: u32) {
        send(Msg::NoteClosed(id));
        closed(id, 3);
    }

    fn get_server_information(
        &self,
    ) -> (&'static str, &'static str, &'static str, &'static str) {
        ("ozshell", "ozozka", env!("CARGO_PKG_VERSION"), "1.2")
    }
}

fn emit<B>(member: &'static str, body: B)
where
    B: serde::ser::Serialize + zbus::zvariant::DynamicType + Send + Sync + 'static,
{
    spawn(async move {
        if let Ok(c) = session().await {
            let _ = c.emit_signal(None::<&str>, PATH, IFACE, member, &body).await;
        }
    });
}

/// Reasons: 2 dismissed by the user, 3 closed by the sender.
pub fn closed(id: u32, reason: u32) {
    emit("NotificationClosed", (id, reason));
}

pub fn invoke(id: u32, action: &str) {
    emit("ActionInvoked", (id, action.to_owned()));
}

pub async fn run() {
    let Ok(c) = session().await else { return };
    let _ = c.object_server().at(PATH, Server { next: AtomicU32::new(1) }).await;
    if let Err(e) = c.request_name(IFACE).await {
        eprintln!("ozshell: cannot own {IFACE}: {e}");
    }
}
