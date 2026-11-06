//! Shell state and the immediate mode UI drawn on every surface.

mod bar;
mod details;
mod lock;
mod menu;
mod notes;
mod polkit;
pub mod w;

use crate::config::{self, Act, SUSPEND_TIMEOUT_MS};
use crate::svc::{
    Msg, apps, audio::Audio, bt, bt::Bt, exec, hypr::Hypr, mpris::Player, net, net::Net,
    notifd, notifd::Note, pam, polkit::Flow, power::Battery, power::Profiles, stats::Stats,
};
use egui::{TextureHandle, TextureId, Ui, Vec2};
use std::{
    collections::{HashMap, HashSet},
    time::{Duration, Instant},
};
use zbus::OwnedObjectPath;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Role {
    Bar,
    Wall,
    Menu,
    Details,
    Notes,
    Polkit,
    Lock,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Section {
    Wifi,
    Output,
    Profiles,
}

/// What a surface tells its UI, and what the UI asks back.
pub struct Frame<'a> {
    pub role: Role,
    pub out: &'a str,
    pub size: Vec2,
    pub wall: Option<TextureId>,
    /// Height the surface should take to fit its content.
    pub want_h: Option<f32>,
}

#[derive(Default)]
pub struct Menu {
    pub open: bool,
    pub out: String,
    pub query: String,
    pub current: usize,
    pub power: bool,
    pub pending: Option<usize>,
    pub apps: Vec<apps::App>,
    stamp: Vec<Option<std::time::SystemTime>>,
    pub focus: bool,
}

#[derive(Default)]
pub struct Details {
    pub section: Option<Section>,
    pub out: String,
    pub anchor: f32,
    pub pending: Option<String>,
    pub password_for: Option<String>,
    pub password: String,
    pub pin: String,
    pub error: String,
    pub scanning: bool,
    pub settle: Option<Instant>,
    pub focus_password: bool,
    pub focus: bool,
}

#[derive(Default)]
pub struct Notes {
    pub list: Vec<Note>,
    pub out: String,
    pub to_top: bool,
}

#[derive(Default)]
pub struct Lock {
    pub locked: bool,
    pub secure: bool,
    pub password: String,
    pub authenticating: bool,
    pub failed: bool,
    pub awaiting: bool,
    pub message: String,
    pub visible: bool,
    pub suspend_by: Option<Instant>,
    answers: Option<std::sync::mpsc::Sender<Option<String>>>,
    pub focus: bool,
}

#[derive(Default)]
pub struct Polkit {
    pub flow: Option<Flow>,
    pub text: String,
    pub focus: bool,
}

#[derive(Default)]
pub struct Pairing {
    pub busy: Option<OwnedObjectPath>,
    pub status: String,
    pub prompt: String,
    pub confirm: bool,
}

#[derive(Default)]
pub struct Shell {
    pub outputs: Vec<String>,
    pub hypr: Hypr,
    pub stats: Stats,
    pub battery: Battery,
    pub profiles: Profiles,
    pub net: Net,
    pub bt: Bt,
    pub bt_busy: HashSet<OwnedObjectPath>,
    pub pair: Pairing,
    pub audio: Audio,
    pub players: Vec<Player>,
    pub player: Option<String>,
    pub menu: Menu,
    pub details: Details,
    pub notes: Notes,
    pub lock: Lock,
    pub polkit: Polkit,
    pub dates: HashSet<String>,
    pub wall_size: Option<Vec2>,
    pub time: Option<libc::tm>,
    textures: HashMap<(Role, String), Option<TextureHandle>>,
    icons: Option<HashMap<String, String>>,
    discovering: Option<OwnedObjectPath>,
    scanning_for: bool,
}

impl Shell {
    pub fn new(wall_size: Option<Vec2>) -> Self {
        Shell { wall_size, time: Some(crate::clock::now()), ..Default::default() }
    }

    pub fn focused(&self) -> String {
        if self.outputs.contains(&self.hypr.monitor) {
            self.hypr.monitor.clone()
        } else {
            self.outputs.first().cloned().unwrap_or_default()
        }
    }

    pub fn sync_outputs(&mut self) {
        let outs = self.outputs.clone();
        for o in [&mut self.menu.out, &mut self.details.out, &mut self.notes.out] {
            if !outs.contains(o) {
                o.clear();
            }
        }
        if !outs.contains(&self.menu.out) {
            self.menu.open = false;
        }
        if !outs.contains(&self.details.out) {
            self.details.section = None;
        }
        if !outs.contains(&self.notes.out) {
            self.notes.out = self.focused();
        }
    }

    pub fn player(&self) -> Option<&Player> {
        self.players.iter().find(|p| Some(&p.bus) == self.player.as_ref())
    }

    /// Media timing as `length-position`, empty when the player cannot tell.
    pub fn timing(&self) -> String {
        let fmt = |s: f64| {
            let t = s.max(0.0) as u64;
            format!("{}:{:02}", t / 60, t % 60)
        };
        match self.player() {
            Some(p)
                if p.position.is_some()
                    && p.length.is_some_and(|l| l.is_finite() && l > 0.0) =>
            {
                format!("{}-{}", fmt(p.length.unwrap()), fmt(p.position()))
            }
            _ => String::new(),
        }
    }

    /// Lazily loaded image texture per surface role.
    pub fn texture(
        &mut self,
        ui: &Ui,
        role: Role,
        key: &str,
        load: impl FnOnce() -> Option<egui::ColorImage>,
    ) -> Option<TextureHandle> {
        self.textures
            .entry((role, key.to_owned()))
            .or_insert_with(|| {
                load().map(|img| ui.ctx().load_texture(key, img, egui::TextureOptions::LINEAR))
            })
            .clone()
    }

    /// Icon theme file for an icon name, or the name itself when it is a path.
    pub fn icon_path(&mut self, name: &str) -> Option<String> {
        if name.starts_with('/') || name.starts_with("file://") {
            return Some(name.to_owned());
        }
        self.icons.get_or_insert_with(apps::icons).get(name).cloned()
    }

    pub fn tick(&mut self) {
        self.time = Some(crate::clock::now());
        if self.lock.suspend_by.is_some_and(|t| t <= Instant::now()) {
            eprintln!("ozshell: session lock was not secured; refusing to suspend");
            self.lock.suspend_by = None;
        }
        if self.details.settle.is_some_and(|t| t <= Instant::now()) {
            self.details.settle = None;
        }
    }

    pub fn scanning(&self) -> bool {
        self.details.scanning || self.details.settle.is_some()
    }

    /// Returns false when only the bars need a redraw.
    pub fn on_msg(&mut self, msg: Msg) -> bool {
        match msg {
            Msg::Stats(s) => {
                self.stats = s;
                return false;
            }
            Msg::Hypr(h) => {
                self.hypr = h;
                return false;
            }
            Msg::Battery(b) => self.battery = b,
            Msg::Profiles(p) => self.profiles = p,
            Msg::Net(n) => {
                if let (Some(p), Some(dev)) = (&self.details.pending, &n.wifi)
                    && dev.connected().is_some_and(|c| &c.ssid == p)
                {
                    self.details.pending = None;
                }
                self.net = n;
                self.sync_scanning();
            }
            Msg::NetError(e) => {
                self.details.pending = None;
                self.details.error = e;
            }
            Msg::NetFailed(reason) => self.network_failed(reason),
            Msg::Scan(r) => {
                self.details.scanning = false;
                match r {
                    Ok(()) if self.details.section == Some(Section::Wifi) => {
                        self.details.settle = Some(
                            Instant::now() + Duration::from_millis(config::SCAN_SETTLE_MS),
                        );
                    }
                    Err(e) if self.details.section == Some(Section::Wifi) => {
                        self.details.error = e
                    }
                    _ => {}
                }
            }
            Msg::Bt(b) => {
                self.bt = b;
                self.sync_scanning();
            }
            Msg::BtDone(p) => {
                self.bt_busy.remove(&p);
            }
            Msg::Pair(e) => match e {
                bt::Pair::Status(s) => self.pair.status = s,
                bt::Pair::Prompt { text, confirm } => {
                    self.pair.prompt = text;
                    self.pair.confirm = confirm;
                }
                bt::Pair::Done => {
                    self.pair.busy = None;
                    self.pair.prompt.clear();
                }
            },
            Msg::Audio(a) => self.audio = a,
            Msg::Media(players) => self.set_players(players),
            Msg::Note(n) => {
                self.notes.list.retain(|o| o.id != n.id);
                self.notes.list.insert(0, n);
                self.notes.out = self.focused();
                self.notes.to_top = true;
            }
            Msg::NoteClosed(id) => {
                self.notes.list.retain(|n| n.id != id);
                self.drop_note_textures();
            }
            Msg::Polkit(f) => {
                let reset = match (&self.polkit.flow, &f) {
                    (Some(old), Some(new)) => old.required != new.required,
                    (old, new) => old.is_some() != new.is_some(),
                };
                if reset {
                    self.polkit.text.clear();
                    self.polkit.focus = f.as_ref().is_some_and(|f| f.required);
                }
                self.polkit.flow = f;
            }
            Msg::Pam(p) => self.pam(p),
            Msg::Ipc(cmd) => self.ipc(&cmd),
        }
        true
    }

    fn network_failed(&mut self, reason: u32) {
        let Some(ssid) = self.details.pending.take() else { return };
        let psk = self
            .net
            .wifi
            .as_ref()
            .and_then(|w| w.networks.iter().find(|n| n.ssid == ssid))
            .is_some_and(|n| matches!(n.security, net::Security::Psk | net::Security::Sae));
        if reason == 7 && psk {
            self.ask_password(ssid);
        } else if reason == 7 {
            self.details.error =
                "This network requires credentials in a NetworkManager connection profile."
                    .into();
        } else {
            self.details.error = net::reason(reason).into();
        }
    }

    fn ask_password(&mut self, ssid: String) {
        self.details.password_for = Some(ssid);
        self.details.error = "Enter the Wi-Fi password.".into();
        self.details.focus_password = true;
    }

    /// New playback activity takes precedence over a manual selection.
    fn set_players(&mut self, players: Vec<Player>) {
        for p in &players {
            let was = self.players.iter().find(|o| o.bus == p.bus).is_some_and(|o| o.playing);
            if p.playing && !was {
                self.player = Some(p.bus.clone());
            }
        }
        self.players = players;
        let first_playing = self.players.iter().find(|p| p.playing).map(|p| p.bus.clone());
        match self.player() {
            None => {
                self.player =
                    first_playing.or_else(|| self.players.first().map(|p| p.bus.clone()))
            }
            Some(p) if !p.playing => self.player = first_playing.or(self.player.take()),
            _ => {}
        }
    }

    fn ipc(&mut self, cmd: &str) {
        match cmd {
            "menu open" => self.open_menu(),
            "menu hide" => self.close_menu(),
            "menu toggle" if self.menu.open => self.close_menu(),
            "menu toggle" => self.open_menu(),
            "lock lock" => self.engage_lock(),
            "lock suspend" => self.suspend(),
            "notifications dismissAll" => {
                for id in self.notes.list.iter().map(|n| n.id).collect::<Vec<_>>() {
                    self.dismiss(id);
                }
            }
            _ => eprintln!("ozshell: unknown command: {cmd}"),
        }
    }

    pub fn open_menu(&mut self) {
        self.close_details();
        let stamp = apps::stamp();
        if self.menu.stamp != stamp || self.menu.apps.is_empty() {
            self.menu.apps = apps::load();
            self.menu.stamp = stamp;
            self.icons = None;
            self.textures.retain(|(r, _), _| *r != Role::Menu);
        }
        let out = self.focused();
        let m = &mut self.menu;
        m.power = false;
        m.pending = None;
        m.query.clear();
        m.current = 0;
        m.focus = true;
        m.out = out;
        m.open = true;
    }

    pub fn close_menu(&mut self) {
        let m = &mut self.menu;
        m.open = false;
        m.query.clear();
        m.power = false;
        m.pending = None;
    }

    pub fn power(&mut self, i: usize) {
        let entry = &config::POWER[i];
        if entry.destructive && self.menu.pending != Some(i) {
            self.menu.pending = Some(i);
            return;
        }
        match entry.act {
            Act::Lock => self.engage_lock(),
            Act::Suspend => self.suspend(),
            Act::Run(cmd) => exec(cmd),
        }
        self.close_menu();
    }

    pub fn toggle_details(&mut self, section: Section, out: &str, anchor: f32) {
        let same = self.details.section == Some(section) && self.details.out == out;
        self.close_details();
        if !same {
            self.close_menu();
            self.details.section = Some(section);
            self.details.out = out.to_owned();
            self.details.anchor = anchor;
            self.details.focus = true;
        }
        self.sync_scanning();
    }

    pub fn close_details(&mut self) {
        if let Some(dev) = self.pair.busy.take() {
            bt::cancel_pair(&dev);
            self.pair.prompt.clear();
            self.pair.status = "Pairing cancelled.".into();
        }
        let d = &mut self.details;
        (d.section, d.pending, d.password_for, d.settle) = (None, None, None, None);
        d.password.clear();
        d.pin.clear();
        d.error.clear();
        d.scanning = false;
        self.sync_scanning();
    }

    /// Scanning and Bluetooth discovery follow the open Wi-Fi section.
    pub fn sync_scanning(&mut self) {
        let wifi = self.details.section == Some(Section::Wifi);
        let discover = self.bt.adapter.clone().filter(|_| wifi && self.bt.powered);
        if discover != self.discovering {
            if let Some(a) = self.discovering.take() {
                bt::discover(&a, false);
            }
            if let Some(a) = &discover {
                bt::discover(a, true);
            }
            self.discovering = discover;
        }
        let scan = wifi && self.net.enabled && self.net.wifi.is_some();
        if scan && !self.scanning_for {
            net::request_scan(self.net.wifi.as_ref().unwrap());
        }
        self.scanning_for = scan;
    }

    pub fn connect(&mut self, ssid: &str) {
        let Some(dev) = self.net.wifi.clone() else { return };
        let Some(n) = dev.networks.iter().find(|n| n.ssid == ssid) else { return };
        let d = &mut self.details;
        d.error.clear();
        d.password_for = None;
        d.pending = Some(ssid.to_owned());
        if n.connected {
            net::disconnect(&dev);
        } else if n.saved.is_some() || n.security == net::Security::Open {
            net::activate(&dev, n);
        } else if matches!(n.security, net::Security::Psk | net::Security::Sae) {
            d.pending = None;
            self.ask_password(ssid.to_owned());
        } else {
            d.pending = None;
            d.error =
                "This network requires credentials in a NetworkManager connection profile."
                    .into();
        }
    }

    pub fn submit_password(&mut self) {
        let d = &mut self.details;
        let (Some(ssid), Some(dev)) = (d.password_for.clone(), self.net.wifi.as_ref()) else {
            return;
        };
        if d.password.is_empty() {
            return;
        }
        if let Some(n) = dev.networks.iter().find(|n| n.ssid == ssid) {
            net::connect_psk(dev, n, &d.password);
            d.pending = Some(ssid);
        }
        d.password.clear();
        d.password_for = None;
    }

    pub fn rescan(&mut self) {
        if let Some(dev) = &self.net.wifi
            && !self.scanning()
        {
            self.details.error.clear();
            self.details.scanning = true;
            net::rescan(dev);
        }
    }

    fn drop_note_textures(&mut self) {
        if self.notes.list.is_empty() {
            self.textures.retain(|(r, _), _| *r != Role::Notes);
        }
    }

    pub fn dismiss(&mut self, id: u32) {
        self.notes.list.retain(|n| n.id != id);
        self.drop_note_textures();
        notifd::closed(id, 2);
    }

    /// Invokes the default or first action, else dismisses.
    pub fn activate_note(&mut self, id: u32) {
        let Some(n) = self.notes.list.iter().find(|n| n.id == id) else { return };
        if let Some((key, _)) =
            n.actions.iter().find(|(k, _)| k == "default").or(n.actions.first())
        {
            notifd::invoke(id, key);
        }
        self.dismiss(id);
    }

    pub fn engage_lock(&mut self) {
        if let Some(tx) = self.lock.answers.take() {
            let _ = tx.send(None);
        }
        let l = &mut self.lock;
        l.password.clear();
        (l.authenticating, l.failed, l.awaiting) = (false, false, false);
        l.focus = true;
        if !l.locked {
            l.locked = true;
            l.secure = false;
        }
        self.close_menu();
        self.close_details();
    }

    pub fn suspend(&mut self) {
        self.engage_lock();
        if self.lock.secure {
            exec(config::SUSPEND);
        } else {
            self.lock.suspend_by =
                Some(Instant::now() + Duration::from_millis(SUSPEND_TIMEOUT_MS));
        }
    }

    pub fn lock_secured(&mut self) {
        self.lock.secure = true;
        if self.lock.suspend_by.take().is_some() {
            exec(config::SUSPEND);
        }
    }

    pub fn submit_lock(&mut self, response: String) {
        let l = &mut self.lock;
        if !l.locked || response.is_empty() {
            return;
        }
        l.failed = false;
        if l.authenticating {
            if l.awaiting
                && let Some(tx) = &l.answers
            {
                l.awaiting = false;
                let _ = tx.send(Some(response));
            }
            return;
        }
        let user =
            std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_default();
        l.authenticating = true;
        l.awaiting = false;
        l.answers = Some(pam::start(&user, response));
    }

    fn pam(&mut self, p: pam::Pam) {
        let l = &mut self.lock;
        match p {
            pam::Pam::Prompt(text, visible) => {
                (l.awaiting, l.message, l.visible) = (true, text, visible);
                l.focus = true;
            }
            pam::Pam::Done(ok) => {
                (l.authenticating, l.awaiting, l.visible) = (false, false, false);
                l.answers = None;
                l.password.clear();
                l.focus = true;
                if ok {
                    (l.locked, l.secure, l.failed) = (false, false, false);
                } else {
                    l.failed = true;
                }
            }
        }
    }

    pub fn polkit_cancel(&mut self) {
        crate::svc::polkit::respond(None);
    }
}

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    match f.role {
        Role::Bar => bar::draw(ui, sh, f),
        Role::Wall => wallpaper(ui, sh, f, false),
        Role::Menu => menu::draw(ui, sh, f),
        Role::Details => details::draw(ui, sh, f),
        Role::Notes => notes::draw(ui, sh, f),
        Role::Polkit => polkit::draw(ui, sh, f),
        Role::Lock => {
            wallpaper(ui, sh, f, true);
            lock::draw(ui, sh, f);
        }
    }
}

/// Fits the wallpaper on the desktop and crops it on the lock screen.
fn wallpaper(ui: &mut Ui, sh: &Shell, f: &Frame, crop: bool) {
    let (Some(id), Some(img)) = (f.wall, sh.wall_size) else { return };
    let scale = if crop {
        (f.size.x / img.x).max(f.size.y / img.y)
    } else {
        (f.size.x / img.x).min(f.size.y / img.y)
    };
    let rect = egui::Rect::from_center_size((f.size / 2.0).to_pos2(), img * scale);
    let uv = egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0));
    ui.painter().image(id, rect, uv, egui::Color32::WHITE);
}
