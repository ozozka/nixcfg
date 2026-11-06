//! MPRIS media players on the session bus.

use super::{Msg, Props, Watch, get, get_all, send, session, set_prop, spawn};
use std::time::Instant;
use zbus::{MatchRule, OwnedObjectPath};

const PREFIX: &str = "org.mpris.MediaPlayer2.";
const PATH: &str = "/org/mpris/MediaPlayer2";
const PLAYER: &str = "org.mpris.MediaPlayer2.Player";

#[derive(Clone, PartialEq)]
pub struct Player {
    pub bus: String,
    pub identity: String,
    pub playing: bool,
    pub title: String,
    pub track: Option<OwnedObjectPath>,
    /// Seconds; `None` when the player does not report it.
    pub length: Option<f64>,
    pub position: Option<f64>,
    pub at: Instant,
    pub loop_status: Option<String>,
    pub can_control: bool,
    pub can_next: bool,
    pub can_previous: bool,
    pub can_play: bool,
    pub can_pause: bool,
    pub can_seek: bool,
}

impl Player {
    pub fn name(&self) -> &str {
        if self.identity.is_empty() { &self.bus } else { &self.identity }
    }

    /// MPRIS does not notify elapsed time, so extrapolate it like Quickshell does.
    pub fn position(&self) -> f64 {
        let p = self.position.unwrap_or(0.0)
            + if self.playing { self.at.elapsed().as_secs_f64() } else { 0.0 };
        p.min(self.length.filter(|l| *l > 0.0).unwrap_or(f64::INFINITY)).max(0.0)
    }

    pub fn can_toggle(&self) -> bool {
        if self.playing { self.can_pause } else { self.can_play }
    }
}

fn micros(p: &Props, key: &str) -> Option<f64> {
    get::<i64>(p, key).or_else(|| get::<u64>(p, key).map(|v| v as i64)).map(|v| v as f64 / 1e6)
}

async fn player(c: &zbus::Connection, bus: String) -> Option<Player> {
    let root = get_all(c, &bus, PATH, "org.mpris.MediaPlayer2").await.unwrap_or_default();
    let p = get_all(c, &bus, PATH, PLAYER).await.ok()?;
    let meta: Props = get(&p, "Metadata").unwrap_or_default();
    Some(Player {
        identity: get(&root, "Identity").unwrap_or_default(),
        playing: get::<String>(&p, "PlaybackStatus").as_deref() == Some("Playing"),
        title: get(&meta, "xesam:title").unwrap_or_default(),
        track: get(&meta, "mpris:trackid"),
        length: micros(&meta, "mpris:length"),
        position: micros(&p, "Position"),
        at: Instant::now(),
        loop_status: get(&p, "LoopStatus"),
        can_control: get(&p, "CanControl").unwrap_or(false),
        can_next: get(&p, "CanGoNext").unwrap_or(false),
        can_previous: get(&p, "CanGoPrevious").unwrap_or(false),
        can_play: get(&p, "CanPlay").unwrap_or(false),
        can_pause: get(&p, "CanPause").unwrap_or(false),
        can_seek: get(&p, "CanSeek").unwrap_or(false),
        bus,
    })
}

pub async fn run() {
    let Ok(c) = session().await else { return };
    let signal = || MatchRule::builder().msg_type(zbus::message::Type::Signal);
    let rules = vec![
        signal().path(PATH).build().expect("valid match rule"),
        signal()
            .member("NameOwnerChanged")
            .arg0ns("org.mpris.MediaPlayer2")
            .build()
            .expect("valid match rule"),
    ];
    let mut w = Watch::new(c, rules).await;
    while w.next().await {
        let Ok(reply) = c
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "ListNames",
                &(),
            )
            .await
        else {
            continue;
        };
        let mut names: Vec<String> = reply.body().deserialize().unwrap_or_default();
        // playerctld mirrors the active real player.
        names.retain(|n| n.starts_with(PREFIX) && n != "org.mpris.MediaPlayer2.playerctld");
        names.sort();
        let mut players = Vec::new();
        for name in names {
            players.extend(player(c, name).await);
        }
        send(Msg::Media(players));
    }
}

fn call<B>(bus: &str, method: &'static str, body: B)
where
    B: serde::ser::Serialize + zbus::zvariant::DynamicType + Send + Sync + 'static,
{
    let bus = bus.to_owned();
    spawn(async move {
        if let Ok(c) = session().await {
            let _ = c.call_method(Some(bus.as_str()), PATH, Some(PLAYER), method, &body).await;
        }
    });
}

pub fn toggle(p: &Player) {
    call(&p.bus, "PlayPause", ());
}

pub fn next(p: &Player) {
    call(&p.bus, "Next", ());
}

pub fn previous(p: &Player) {
    call(&p.bus, "Previous", ());
}

pub fn seek(p: &Player, secs: f64) {
    if let Some(track) = p.track.clone() {
        call(&p.bus, "SetPosition", (track, (secs * 1e6) as i64));
    }
}

pub fn set_loop(p: &Player, status: &'static str) {
    let bus = p.bus.clone();
    spawn(async move {
        if let Ok(c) = session().await {
            let _ = set_prop(c, &bus, PATH, PLAYER, "LoopStatus", status).await;
        }
    });
}
