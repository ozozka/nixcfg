//! Lock screen panel over the cropped wallpaper.

use super::{Frame, Shell, w};
use crate::{
    config::LOCK_WIDTH,
    theme::{Fam, t},
};
use egui::{Align, Align2, Color32, Id, Ui, vec2};

pub fn draw(ui: &mut Ui, sh: &mut Shell, _: &mut Frame) {
    let (c, d, fs) = (&t().col, &t().dim, &t().fs);
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| "User".into());
    egui::Area::new(Id::unique("lock-panel"))
        .anchor(Align2::CENTER_CENTER, vec2(0.0, 0.0))
        .show(ui.ctx(), |ui| {
            egui::Frame::NONE.fill(c.b).inner_margin(d.s).show(ui, |ui| {
                ui.set_width(LOCK_WIDTH - d.s * 2.0);
                w::label(
                    ui,
                    w::Txt {
                        text: &user,
                        fam: Fam::Mono,
                        pt: fs.h,
                        bold: true,
                        align: Align::Center,
                        ..Default::default()
                    },
                );
                let l = &mut sh.lock;
                let enabled = !l.authenticating || l.awaiting;
                let field = w::Field {
                    id: "lock",
                    password: !l.visible,
                    fam: Fam::Mono,
                    pt: fs.l,
                    h: d.m * 2.0,
                    fill: Color32::TRANSPARENT,
                    align: Align::Center,
                    enabled,
                    ..Default::default()
                };
                let before = l.password.len();
                let resp = field.show(ui, &mut l.password);
                if l.password.len() != before {
                    l.failed = false;
                }
                if w::submitted(ui, &resp) {
                    let text = std::mem::take(&mut sh.lock.password);
                    sh.submit_lock(text);
                }
                let l = &mut sh.lock;
                if enabled && (std::mem::take(&mut l.focus) || !resp.has_focus()) {
                    w::focus(ui, "lock");
                }
                if l.failed {
                    let text = "Authentication failed";
                    w::label(
                        ui,
                        w::Txt { text, color: c.s, align: Align::Center, ..Default::default() },
                    );
                }
                if l.authenticating {
                    let text = if l.awaiting { l.message.as_str() } else { "Authenticating" };
                    w::label(
                        ui,
                        w::Txt { text, color: c.m, align: Align::Center, ..Default::default() },
                    );
                }
            });
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// The password field keeps keyboard focus; an id clash once dropped it every frame.
    fn typing() {
        let args: Vec<String> = "--colors 09bea8,ff3963,ffffff,7e8180,101212,000000 --font-sizes 6,9,12,15,18,24 --dims 3,12,24,72,144,360 --wallpaper /x"
            .split(' ').map(String::from).collect();
        crate::theme::init(&args);
        let ctx = egui::Context::default();
        crate::theme::style(&ctx);
        let mut sh = Shell::default();
        sh.lock.locked = true;
        sh.lock.focus = true;
        let size = vec2(1920.0, 1080.0);
        let mut t = 0.0;
        let mut frame = |events: Vec<egui::Event>, sh: &mut Shell| {
            t += 0.1;
            let raw = egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, size)),
                time: Some(t),
                focused: true,
                events,
                ..Default::default()
            };
            let mut f =
                Frame { role: crate::ui::Role::Lock, out: "", size, wall: None, want_h: None };
            ctx.run_ui(raw, |ui| draw(ui, sh, &mut f)).textures_delta.clear();
        };
        for _ in 0..3 {
            frame(vec![], &mut sh);
        }
        let m = egui::Modifiers::NONE;
        for c in ["a", "b", "c"] {
            let key = egui::Key::from_name(&c.to_uppercase()).unwrap();
            let ev = vec![
                egui::Event::Key {
                    key,
                    physical_key: None,
                    pressed: true,
                    repeat: false,
                    modifiers: m,
                },
                egui::Event::Text(c.into()),
            ];
            frame(ev, &mut sh);
            frame(
                vec![egui::Event::Key {
                    key,
                    physical_key: None,
                    pressed: false,
                    repeat: false,
                    modifiers: m,
                }],
                &mut sh,
            );
        }
        assert_eq!(sh.lock.password, "abc");
    }
}
