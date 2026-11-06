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
    egui::Area::new(Id::unique("lock")).anchor(Align2::CENTER_CENTER, vec2(0.0, 0.0)).show(
        ui.ctx(),
        |ui| {
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
        },
    );
}
