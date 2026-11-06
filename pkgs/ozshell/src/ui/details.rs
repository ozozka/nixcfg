//! Popup above the bar for battery, audio and network controls.

use super::{Frame, Section, Shell, bar, w, w::Btn};
use crate::{
    config::POPUP_WIDTH,
    svc::{audio, audio::Availability, bt, mpris, net, power},
    theme::{Fam, font, t},
};
use egui::{Align, Align2, Id, Key, Modifiers, Ui, pos2, vec2};

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    let (c, d) = (&t().col, &t().dim);
    let Some(section) = sh.details.section else { return };
    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape)) {
        return sh.close_details();
    }
    let inset = d.s;
    let mw = POPUP_WIDTH.min((f.size.x - inset * 2.0).max(0.0));
    let max_h = (f.size.y - d.m - inset * 2.0).max(0.0);
    let x = (sh.details.anchor - mw / 2.0).min(f.size.x - mw - inset).max(inset);
    let area = egui::Area::new(Id::unique("details"))
        .fixed_pos(pos2(x, f.size.y - d.m - d.s))
        .pivot(Align2::LEFT_BOTTOM)
        .constrain(false)
        .show(ui.ctx(), |ui| {
            egui::Frame::NONE.fill(c.b).inner_margin(inset).show(ui, |ui| {
                ui.set_width(mw - inset * 2.0);
                w::scroll(ui, "details", max_h - inset * 2.0, |ui| match section {
                    Section::Profiles => battery(ui, sh),
                    Section::Output => output(ui, sh),
                    Section::Wifi => wifi(ui, sh),
                });
            });
        });
    let rect = area.response.rect;
    let clicked =
        ui.input(|i| i.pointer.any_click().then(|| i.pointer.interact_pos()).flatten());
    if let Some(p) = clicked
        && !rect.contains(p)
        && p.y < f.size.y - d.m
    {
        sh.close_details();
    }
}

fn battery(ui: &mut Ui, sh: &mut Shell) {
    let b = sh.battery.clone();
    w::heading(ui, "Battery");
    w::label(
        ui,
        w::Txt { text: &format!("Charge: %{}", b.percentage.round()), ..Default::default() },
    );
    w::label(ui, w::Txt { text: &format!("Status: {}", b.status()), ..Default::default() });
    if matches!(b.status(), "Charging" | "Discharging") {
        let prefix =
            if b.status() == "Charging" { "Time until full" } else { "Time remaining" };
        let text = if b.remaining() > 0 {
            format!("{prefix}: {}m", b.remaining() / 60)
        } else {
            "Estimate unavailable".into()
        };
        w::label(ui, w::Txt { text: &text, color: t().col.m, ..Default::default() });
    }
    w::heading(ui, "Power profiles");
    let performance = sh.profiles.available.iter().any(|p| p == "performance");
    for name in
        ["power-saver", "balanced", "performance"].iter().take(if performance { 3 } else { 2 })
    {
        if (Btn {
            text: name,
            wide: true,
            selected: sh.profiles.active == *name,
            ..Default::default()
        })
        .show(ui)
        .clicked()
        {
            power::set_profile(name);
        }
    }
}

fn output(ui: &mut Ui, sh: &mut Shell) {
    playback(ui, sh);
    ui.add_space(t().dim.s);
    audio_options(ui, sh, true);
    ui.add_space(t().dim.s);
    audio_options(ui, sh, false);
}

fn playback(ui: &mut Ui, sh: &mut Shell) {
    let (c, d, fs) = (&t().col, &t().dim, &t().fs);
    w::heading(ui, "Playback");
    let Some(p) = sh.player().cloned() else {
        w::label(
            ui,
            w::Txt { text: "No media player available", color: c.m, ..Default::default() },
        );
        return;
    };
    if sh.players.len() > 1 {
        for other in sh.players.clone() {
            if (Btn {
                text: other.name(),
                wide: true,
                selected: other.bus == p.bus,
                ..Default::default()
            })
            .show(ui)
            .clicked()
            {
                sh.player = Some(other.bus.clone());
            }
        }
    }
    ui.scope(|ui| {
        ui.spacing_mut().item_spacing.y = d.s / 2.0;
        if sh.players.len() == 1 {
            w::label(ui, w::Txt { text: p.name(), pt: fs.s, color: c.m, ..Default::default() });
        }
        let title = if p.title.is_empty() { "No track information" } else { &p.title };
        w::label(
            ui,
            w::Txt {
                text: title,
                pt: fs.s,
                bold: true,
                color: c.m,
                align: Align::Center,
                ..Default::default()
            },
        );
    });
    let timing = sh.timing();
    let row = d.m + d.s;
    ui.horizontal(|ui| {
        let text = if timing.is_empty() { "Timing unavailable" } else { &timing };
        let tf = font(Fam::Mono, fs.m, false);
        let tw = w::width(ui, text, tf.clone());
        let g = w::galley(
            ui,
            text,
            tf,
            if p.playing { c.f } else { c.m },
            f32::INFINITY,
            0,
            Align::Min,
        );
        let (rect, _) = ui.allocate_exact_size(vec2(tw, row), egui::Sense::hover());
        w::paint(ui, g, rect, Align::Min);
        let to = p.length.filter(|l| *l > 0.0).unwrap_or(1.0) as f32;
        let enabled = p.can_control && p.can_seek && !timing.is_empty();
        let sw = ui.available_width() - row - d.s;
        if let Some(v) = w::slider(ui, sw, p.position() as f32, to, enabled, false) {
            mpris::seek(&p, v as f64);
        }
        let modes = ["None", "Track", "Playlist"];
        let mode = modes.iter().position(|m| Some(*m) == p.loop_status.as_deref()).unwrap_or(0);
        let tip = format!("Repeat: {} (click to cycle)", ["off", "track", "playlist"][mode]);
        let symbol = if mode == 1 { "↻¹" } else { "↻" };
        let btn = Btn {
            muted: mode == 0,
            selected: mode != 0,
            disabled: !p.can_control || p.loop_status.is_none(),
            ..Btn::icon(symbol, &tip)
        };
        if btn.show(ui).clicked() {
            mpris::set_loop(&p, modes[(mode + 1) % 3]);
        }
    });
    ui.horizontal(|ui| {
        ui.add_space((ui.available_width() - row * 3.0 - d.s * 2.0) / 2.0 - d.s);
        let can = p.can_control;
        if (Btn { disabled: !(p.can_previous && can), ..Btn::icon("⏮", "Previous track") })
            .show(ui)
            .clicked()
        {
            mpris::previous(&p);
        }
        let (sym, tip) = if p.playing { ("⏸", "Pause") } else { ("▶", "Play") };
        if (Btn { disabled: !(p.can_toggle() && can), ..Btn::icon(sym, tip) })
            .show(ui)
            .clicked()
        {
            mpris::toggle(&p);
        }
        if (Btn { disabled: !(p.can_next && can), ..Btn::icon("⏭", "Next track") })
            .show(ui)
            .clicked()
        {
            mpris::next(&p);
        }
    });
}

fn audio_options(ui: &mut Ui, sh: &mut Shell, input: bool) {
    let (c, d) = (&t().col, &t().dim);
    let node = sh.audio.default_node(!input).filter(|n| n.ready).cloned();
    let muted = node.as_ref().is_some_and(|n| n.muted);
    let kind = if input { "microphone" } else { "speaker" };
    w::heading(ui, if input { "Microphone" } else { "Speaker" });
    ui.horizontal(|ui| {
        let tip = format!("{} {kind}", if muted { "Unmute" } else { "Mute" });
        let btn = Btn {
            selected: muted,
            disabled: node.is_none(),
            ..Btn::icon(if muted { "○" } else { "●" }, &tip)
        };
        if btn.show(ui).clicked()
            && let Some(n) = &node
        {
            audio::set_mute(n.id, !muted);
        }
        let sw = ui.available_width() - 52.0 - d.s;
        let volume = node.as_ref().map_or(0.0, |n| n.volume);
        if let Some(v) = w::slider(ui, sw, volume, 1.5, node.is_some(), muted)
            && let Some(n) = &node
        {
            audio::set_volume(n.id, v);
        }
        let text =
            node.as_ref().map_or("—".into(), |n| format!("%{}", (n.volume * 100.0).round()));
        let g = w::galley(
            ui,
            &text,
            font(Fam::Mono, t().fs.m, false),
            if muted { c.m } else { c.f },
            52.0,
            0,
            Align::Max,
        );
        let (rect, _) = ui.allocate_exact_size(vec2(52.0, d.m + d.s), egui::Sense::hover());
        w::paint(ui, g, rect, Align::Max);
    });
    let devices: Vec<audio::Node> =
        sh.audio.devices().filter(|n| n.sink != input).cloned().collect();
    for n in devices {
        let unknown = if n.availability == Availability::Unknown {
            " · Availability unknown"
        } else {
            ""
        };
        let text = format!("{}{unknown}", n.label);
        let selected = node.as_ref().is_some_and(|d| d.id == n.id);
        if (Btn { text: &text, wide: true, selected, ..Default::default() }).show(ui).clicked()
        {
            audio::set_default(n.id);
        }
    }
}

fn wifi(ui: &mut Ui, sh: &mut Shell) {
    let c = &t().col;
    let pairing = sh.pair.busy.is_some();
    w::heading(ui, "Bluetooth");
    let text = if sh.bt.powered { "Turn Bluetooth off" } else { "Turn Bluetooth on" };
    if (Btn {
        text,
        wide: true,
        disabled: sh.bt.adapter.is_none() || pairing,
        ..Default::default()
    })
    .show(ui)
    .clicked()
        && let Some(a) = &sh.bt.adapter
    {
        bt::set_powered(a, !sh.bt.powered);
    }
    for dev in sh.bt.devices.clone() {
        let this = sh.pair.busy.as_ref() == Some(&dev.path);
        let verb = match () {
            _ if this => "Pairing…",
            _ if dev.connected => "Disconnect",
            _ if dev.paired => "Connect",
            _ => "Pair",
        };
        let text = format!("{} · {verb}", dev.name);
        let disabled = !sh.bt.powered || pairing || sh.bt_busy.contains(&dev.path);
        if (Btn {
            text: &text,
            wide: true,
            selected: dev.connected,
            disabled,
            ..Default::default()
        })
        .show(ui)
        .clicked()
        {
            if dev.paired {
                sh.bt_busy.insert(dev.path.clone());
                bt::toggle(&dev);
            } else {
                sh.pair.busy = Some(dev.path.clone());
                sh.pair.prompt.clear();
                bt::pair(&dev);
            }
        }
    }
    w::message(ui, &sh.pair.status.clone(), c.m);
    if !sh.pair.prompt.is_empty() {
        w::label(
            ui,
            w::Txt { text: &sh.pair.prompt.clone(), bold: true, ..Default::default() },
        );
    }
    let prompt = pairing && !sh.pair.prompt.is_empty();
    if prompt && !sh.pair.confirm {
        let field =
            w::Field { id: "pin", hint: "PIN / passkey", fam: Fam::Mono, ..Default::default() };
        let resp = field.show(ui, &mut sh.details.pin);
        if w::submitted(ui, &resp) {
            let pin = std::mem::take(&mut sh.details.pin);
            respond(sh, pin);
        }
    }
    if prompt {
        ui.horizontal(|ui| {
            let text = if sh.pair.confirm { "Confirm" } else { "Send" };
            if (Btn { text, ..Default::default() }).show(ui).clicked() {
                let answer = if sh.pair.confirm {
                    "yes".into()
                } else {
                    std::mem::take(&mut sh.details.pin)
                };
                respond(sh, answer);
            }
            if (Btn { text: "Cancel", ..Default::default() }).show(ui).clicked() {
                cancel_pairing(sh);
            }
        });
    }
    if pairing
        && sh.pair.prompt.is_empty()
        && (Btn { text: "Cancel pairing", ..Default::default() }).show(ui).clicked()
    {
        cancel_pairing(sh);
    }

    w::heading(ui, "Wi-Fi");
    let state = bar::wifi_state(sh);
    let dev = sh.net.wifi.clone();
    ui.horizontal(|ui| {
        let tip = if sh.net.enabled { "Turn Wi-Fi off" } else { "Turn Wi-Fi on" };
        let toggle = Btn {
            symbol: "⏻",
            muted: !sh.net.enabled,
            disabled: dev.is_none() || !sh.net.hardware,
            tip,
            ..Default::default()
        };
        if toggle.show(ui).clicked() {
            net::set_enabled(!sh.net.enabled);
        }
        let scanning = sh.scanning();
        let refresh = Btn {
            symbol: "↻",
            selected: scanning,
            disabled: !state.is_empty() || scanning,
            ..Default::default()
        };
        let rw = w::width(ui, "↻", font(Fam::Mono, t().fs.m, false)) + t().dim.s * 2.0;
        ui.add_space(ui.available_width() - rw);
        if refresh.show(ui).clicked() {
            sh.rescan();
        }
    });
    let networks = dev.as_ref().map(|d| d.networks.clone()).unwrap_or_default();
    let reason = match state {
        "unavailable" => "Wi-Fi device unavailable.",
        "blocked" => "Wi-Fi is blocked by the hardware switch.",
        "off" => "Wi-Fi is off.",
        _ if !networks.is_empty() => "",
        _ if sh.scanning() => "Looking for networks…",
        _ => "No networks found.",
    };
    w::message(ui, reason, c.m);
    for n in &networks {
        let suffix = if n.connected {
            " · Disconnect"
        } else if n.changing {
            " · Working…"
        } else {
            ""
        };
        let text = format!("{}{suffix}", n.ssid);
        let value = format!("%{}", (n.strength * 100.0).round());
        let btn = Btn {
            text: &text,
            value: &value,
            wide: true,
            selected: n.connected,
            disabled: !sh.net.enabled || n.changing,
            ..Default::default()
        };
        if btn.show(ui).clicked() {
            sh.connect(&n.ssid);
        }
    }
    let err_color = if sh.details.password_for.is_some() { c.m } else { c.s };
    w::message(ui, &sh.details.error.clone(), err_color);
    if sh.details.password_for.is_some() {
        let resp = w::Field {
            id: "wifi-password",
            hint: "Wi-Fi password",
            password: true,
            ..Default::default()
        }
        .show(ui, &mut sh.details.password);
        if std::mem::take(&mut sh.details.focus_password) {
            w::focus(ui, "wifi-password");
        }
        if w::submitted(ui, &resp) {
            sh.submit_password();
        }
        if (Btn { text: "Connect", ..Default::default() }).show(ui).clicked() {
            sh.submit_password();
        }
    }
}

fn respond(sh: &mut Shell, text: String) {
    sh.pair.prompt.clear();
    bt::answer(Some(text));
}

fn cancel_pairing(sh: &mut Shell) {
    if let Some(dev) = sh.pair.busy.take() {
        bt::cancel_pair(&dev);
    }
    sh.pair.prompt.clear();
    sh.pair.status = "Pairing cancelled.".into();
}
