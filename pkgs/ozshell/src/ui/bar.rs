//! Bottom bar: workspaces, clock, controls on the left and system stats on the right.

use super::{Frame, Section, Shell, w};
use crate::{
    clock,
    config::WORKSPACES,
    theme::{Fam, font, t},
};
use egui::{Align, Color32, Layout, Response, Sense, Ui, UiBuilder, vec2};

struct Item<'a> {
    text: &'a str,
    suffix: &'a str,
    fg: Color32,
    suffix_fg: Option<Color32>,
    selected: bool,
    bold: bool,
    enabled: bool,
}

impl<'a> Item<'a> {
    fn new(text: &'a str) -> Self {
        Item {
            text,
            suffix: "",
            fg: t().col.f,
            suffix_fg: None,
            selected: false,
            bold: false,
            enabled: true,
        }
    }

    /// Hidden while empty, like a QML item bound to `text.length > 0`.
    fn show(self, ui: &mut Ui) -> Option<Response> {
        if self.text.is_empty() {
            return None;
        }
        let (c, d) = (&t().col, &t().dim);
        let f = font(Fam::Mono, t().fs.m, self.bold);
        let left = format!(" {}{}", self.text, if self.suffix.is_empty() { " " } else { "" });
        let right =
            if self.suffix.is_empty() { String::new() } else { format!(" {} ", self.suffix) };
        let gl = w::galley(ui, &left, f.clone(), self.fg, f32::INFINITY, 0, Align::Min);
        let gr = w::galley(
            ui,
            &right,
            f,
            self.suffix_fg.unwrap_or(self.fg),
            f32::INFINITY,
            0,
            Align::Min,
        );
        let sense = if self.enabled { Sense::click() } else { Sense::hover() };
        let (rect, resp) = ui.allocate_exact_size(vec2(gl.size().x + gr.size().x, d.m), sense);
        if self.selected
            || (self.enabled && (resp.hovered() || resp.is_pointer_button_down_on()))
        {
            ui.painter().rect_filled(rect, 0.0, c.o);
        }
        let split = rect.left() + gl.size().x;
        w::paint(ui, gl, rect.with_max_x(split), Align::Min);
        w::paint(ui, gr, rect.with_min_x(split), Align::Min);
        Some(resp)
    }
}

/// Why Wi-Fi is unusable, or empty when it is ready.
pub fn wifi_state(sh: &Shell) -> &'static str {
    match (&sh.net.wifi, sh.net.hardware, sh.net.enabled) {
        (None, _, _) => "unavailable",
        (_, false, _) => "blocked",
        (_, _, false) => "off",
        _ => "",
    }
}

pub fn wifi_status(sh: &Shell) -> String {
    let state = wifi_state(sh);
    if !state.is_empty() {
        return state.into();
    }
    sh.net
        .wifi
        .as_ref()
        .and_then(|w| w.connected())
        .map_or("Not connected".into(), |n| n.ssid.clone())
}

fn rate(b: f64) -> String {
    match b {
        b if b < 1024.0 => format!("{}B/s", b.round()),
        b if b < 1024.0 * 1024.0 => format!("{:.1}K/s", b / 1024.0),
        b => format!("{:.1}M/s", b / (1024.0 * 1024.0)),
    }
}

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    let (c, out) = (&t().col, f.out.to_owned());
    let full = ui.max_rect();
    let mut left = ui.new_child(
        UiBuilder::new().max_rect(full).layout(Layout::left_to_right(Align::Center)),
    );
    left.spacing_mut().item_spacing = vec2(0.0, 0.0);
    let ui = &mut left;

    for id in 1..=WORKSPACES as i64 {
        let occupied = sh.hypr.workspaces.iter().any(|(w, n)| *w == id && *n > 0);
        Item {
            selected: sh.hypr.focused_ws == id,
            fg: if occupied { c.f } else { c.m },
            bold: true,
            ..Item::new("🞄")
        }
        .show(ui);
    }

    let tm = sh.time.unwrap_or_else(clock::now);
    let date = sh.dates.contains(&out);
    let text = clock::format(&tm, if date { "%Y-%m-%d" } else { "%H:%M:%S" });
    if let Some(r) = Item::new(&text).show(ui) {
        if r.clicked() {
            if sh.menu.open { sh.close_menu() } else { sh.open_menu() }
        }
        if r.secondary_clicked() && !sh.dates.remove(&out) {
            sh.dates.insert(out.clone());
        }
    }

    let selected = |sh: &Shell, s| sh.details.section == Some(s) && sh.details.out == out;
    let off = !sh.net.enabled || !sh.net.hardware;
    let disconnected = !off && sh.net.wifi.as_ref().is_some_and(|w| w.connected().is_none());
    let enabled = sh.net.wifi.is_some() || sh.bt.adapter.is_some();
    let status = wifi_status(sh);
    let text = if off {
        "-"
    } else if disconnected {
        "~"
    } else {
        &status
    };
    let item = Item {
        selected: selected(sh, Section::Wifi),
        fg: if !enabled || off || disconnected { c.m } else { c.f },
        bold: disconnected,
        enabled,
        ..Item::new(text)
    };
    if let Some(r) = item.show(ui)
        && r.clicked()
    {
        sh.toggle_details(Section::Wifi, &out, r.rect.center().x);
    }

    let output = sh.audio.default_node(true).filter(|n| n.ready);
    let muted = output.is_some_and(|n| n.muted);
    let text = output.map_or("—".into(), |n| format!("%{}", (n.volume * 100.0).round()));
    let timing = sh.timing();
    let playing = sh.player().is_some_and(|p| p.playing);
    let item = Item {
        selected: selected(sh, Section::Output),
        fg: if muted { c.m } else { c.f },
        suffix: &timing,
        suffix_fg: Some(if playing { c.f } else { c.m }),
        enabled: sh.audio.devices().next().is_some() || sh.player().is_some(),
        ..Item::new(&text)
    };
    if let Some(r) = item.show(ui)
        && r.clicked()
    {
        sh.toggle_details(Section::Output, &out, r.rect.center().x);
    }

    let b = &sh.battery;
    let text = match b.status() {
        "Full" => "🞄".into(),
        s => format!("{}{}", if s == "Discharging" { "-%" } else { "%" }, b.percentage.round()),
    };
    if let Some(r) =
        (Item { selected: selected(sh, Section::Profiles), ..Item::new(&text) }).show(ui)
        && r.clicked()
    {
        sh.toggle_details(Section::Profiles, &out, r.rect.center().x);
    }

    Item::new(&sh.hypr.layout).show(ui);
    if sh.hypr.submap != "default" {
        Item::new(&sh.hypr.submap).show(ui);
    }

    let mut right = left.new_child(
        UiBuilder::new().max_rect(full).layout(Layout::right_to_left(Align::Center)),
    );
    right.spacing_mut().item_spacing = vec2(0.0, 0.0);
    let s = &sh.stats;
    let stats = [
        if sh.net.iface_up { rate(s.rate) } else { String::new() },
        format!("{}°C", (s.temp / 1000.0).round()),
        s.procs.to_string(),
        format!("%{:.2}", s.cpu),
        format!("{:.2}", s.mem / (1024.0 * 1024.0 * 1024.0)),
    ];
    for text in stats.iter().rev() {
        Item::new(text).show(&mut right);
    }
}
