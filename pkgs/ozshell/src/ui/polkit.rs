//! Polkit authentication dialog.

use super::{Frame, Shell, w, w::Btn};
use crate::{
    svc::polkit,
    theme::{Fam, t},
};
use egui::{Align, Color32, Key, Layout, Modifiers, Ui};

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    let (c, d, fs) = (&t().col, &t().dim, &t().fs);
    let Some(flow) = sh.polkit.flow.clone() else { return };
    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape)) {
        polkit::respond(None);
    }
    let resp = egui::Frame::NONE.fill(c.b).inner_margin(d.s).show(ui, |ui| {
        ui.set_width(f.size.x - d.s * 2.0);
        let text = "Authentication required";
        w::label(
            ui,
            w::Txt { text, fam: Fam::Mono, pt: fs.l, bold: true, ..Default::default() },
        );
        w::label(ui, w::Txt { text: &flow.message, ..Default::default() });
        w::message(ui, &flow.prompt, c.m);
        w::message(ui, &flow.info, if flow.info_error { c.s } else { c.m });
        if flow.failed {
            w::label(
                ui,
                w::Txt { text: "Authentication failed", color: c.s, ..Default::default() },
            );
        }
        let field = w::Field {
            id: "polkit",
            password: !flow.visible,
            fam: Fam::Mono,
            h: d.m * 1.5,
            fill: Color32::TRANSPARENT,
            enabled: flow.required,
            ..Default::default()
        };
        let resp = field.show(ui, &mut sh.polkit.text);
        if std::mem::take(&mut sh.polkit.focus) {
            w::focus(ui, "polkit");
        }
        let submit = |sh: &mut Shell| {
            if flow.required {
                polkit::respond(Some(std::mem::take(&mut sh.polkit.text)));
            }
        };
        if w::submitted(ui, &resp) {
            submit(sh);
        }
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            let base = Btn { fam: Fam::Mono, h: d.m, ..Default::default() };
            let auth = Btn {
                text: "Authenticate",
                fill: Some(if flow.required { c.p } else { c.m }),
                fg: Some(c.b),
                bold: true,
                disabled: !flow.required,
                ..base
            };
            if auth.show(ui).clicked() {
                submit(sh);
            }
            if (Btn {
                text: "Cancel",
                fill: Some(c.o),
                fam: Fam::Mono,
                h: d.m,
                ..Default::default()
            })
            .show(ui)
            .clicked()
            {
                polkit::respond(None);
            }
        });
    });
    f.want_h = Some(resp.response.rect.height());
}
