//! Notification stack in the top left corner, newest first.

use super::{Frame, Role, Shell, menu, w};
use crate::{
    img,
    svc::notifd::{Image, Note},
    theme::{Fam, font, t},
};
use egui::{Align, Color32, Rect, Sense, Ui, pos2, text::LayoutJob, vec2};

fn texture(ui: &Ui, sh: &mut Shell, n: &Note) -> Option<egui::TextureHandle> {
    let px = (t().dim.m * ui.pixels_per_point()) as u32;
    match &n.image {
        Some(Image::Raw(i)) => {
            sh.texture(ui, Role::Notes, &format!("raw{}-{:p}", n.id, i), || Some((**i).clone()))
        }
        Some(Image::Path(p)) if p.starts_with('/') || p.starts_with("file://") => {
            sh.texture(ui, Role::Notes, p, || img::load(p, Some(px)))
        }
        Some(Image::Path(name)) => menu::icon(ui, sh, Role::Notes, name),
        None if !n.icon.is_empty() => menu::icon(ui, sh, Role::Notes, &n.icon),
        None => None,
    }
}

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    let mut area = egui::ScrollArea::vertical()
        .id_salt("notes")
        .max_height(f.size.y)
        .auto_shrink([false, true])
        .scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden);
    if std::mem::take(&mut sh.notes.to_top) {
        area = area.vertical_scroll_offset(0.0);
    }
    let notes = sh.notes.list.clone();
    let out = area.show(ui, |ui| {
        for n in &notes {
            card(ui, sh, n);
        }
    });
    f.want_h = Some(out.content_size.y.min(f.size.y));
}

fn card(ui: &mut Ui, sh: &mut Shell, n: &Note) {
    let (c, d, fs) = (&t().col, &t().dim, &t().fs);
    let bg = ui.painter().add(egui::Shape::Noop);
    let width = ui.available_width();
    let inner_w = width - d.s * 2.0;
    let top = ui.cursor().min;
    let tex = texture(ui, sh, n);

    let time_font = font(Fam::Mono, fs.m, false);
    let tw = w::width(ui, &n.time, time_font.clone());
    let image_w = if tex.is_some() { d.m + d.s } else { 0.0 };
    let text_w = (inner_w - image_w - tw - d.s).max(1.0);
    let mut job = LayoutJob::default();
    let fmt = |bold| egui::TextFormat::simple(font(Fam::Sans, fs.m, bold), c.f);
    job.append(&n.app, 0.0, fmt(true));
    job.append(&format!(": {}", n.summary), 0.0, fmt(false));
    job.wrap.max_width = text_w;
    let head = ui.fonts_mut(|f| f.layout_job(job));
    let time = w::galley(ui, &n.time, time_font, c.m, f32::INFINITY, 0, Align::Min);
    let row_h = head.size().y.max(time.size().y).max(if tex.is_some() { d.m } else { 0.0 });
    let body = (!n.body.is_empty()).then(|| {
        w::galley(ui, &n.body, font(Fam::Serif, fs.m, false), c.f, inner_w, 0, Align::Min)
    });
    let body_h = body.as_ref().map_or(0.0, |b| b.size().y + d.s);
    let rect = Rect::from_min_size(top, vec2(width, row_h + body_h + d.s * 2.0));
    let resp = ui.allocate_rect(rect, Sense::click());

    let origin = top + vec2(d.s, d.s);
    let mut x = origin.x;
    if let Some(tex) = &tex {
        let r = Rect::from_min_size(pos2(x, origin.y), vec2(d.m, d.m));
        let size = tex.size_vec2();
        let s = (d.m / size.x).max(d.m / size.y);
        let (u, v) = (d.m / (size.x * s), d.m / (size.y * s));
        let uv = Rect::from_center_size(pos2(0.5, 0.5), vec2(u, v));
        ui.painter().image(tex.id(), r, uv, Color32::WHITE);
        x += d.m + d.s;
    }
    ui.painter().galley(pos2(x, origin.y), head, c.f);
    ui.painter().galley(pos2(origin.x + inner_w - tw, origin.y), time, c.m);
    if let Some(body) = body {
        ui.painter().galley(pos2(origin.x, origin.y + row_h + d.s), body, c.f);
    }
    ui.painter()
        .set(bg, egui::Shape::rect_filled(rect, 0.0, if resp.hovered() { c.o } else { c.b }));

    if resp.secondary_clicked() {
        sh.dismiss(n.id);
    } else if resp.clicked() {
        sh.activate_note(n.id);
    }
}
