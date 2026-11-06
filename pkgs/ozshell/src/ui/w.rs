//! Flat widgets shared by every surface.

use crate::theme::{Fam, font, t};
use egui::{
    Align, Color32, FontId, Galley, Response, Sense, Ui, pos2, text::LayoutJob,
    text::TextWrapping, vec2,
};
use std::sync::Arc;

/// Lays out text; `max_rows` 1 elides with an ellipsis.
pub fn galley(
    ui: &Ui,
    text: &str,
    font: FontId,
    color: Color32,
    width: f32,
    max_rows: usize,
    align: Align,
) -> Arc<Galley> {
    let mut job = LayoutJob::simple(text.to_owned(), font, color, width);
    job.halign = align;
    job.wrap = TextWrapping {
        max_width: width,
        max_rows: if max_rows == 0 { usize::MAX } else { max_rows },
        break_anywhere: max_rows == 1,
        overflow_character: Some('…'),
    };
    ui.fonts_mut(|f| f.layout_job(job))
}

pub fn width(ui: &Ui, text: &str, font: FontId) -> f32 {
    if text.is_empty() {
        0.0
    } else {
        galley(ui, text, font, Color32::WHITE, f32::INFINITY, 0, Align::Min).size().x
    }
}

/// Paints a galley laid out with `halign` inside `rect`, vertically centered.
pub fn paint(ui: &Ui, g: Arc<Galley>, rect: egui::Rect, align: Align) {
    let x = match align {
        Align::Min => rect.left(),
        Align::Center => rect.center().x,
        Align::Max => rect.right(),
    };
    let y = rect.center().y - g.size().y / 2.0;
    ui.painter().galley(pos2(x, y), g, Color32::WHITE);
}

pub struct Txt<'a> {
    pub text: &'a str,
    pub fam: Fam,
    pub pt: f32,
    pub bold: bool,
    pub color: Color32,
    pub align: Align,
    /// Wrap to the full width like `Layout.fillWidth` with `wrapMode: Text.Wrap`.
    pub wrap: bool,
}

impl Default for Txt<'_> {
    fn default() -> Self {
        Txt {
            text: "",
            fam: Fam::Sans,
            pt: t().fs.m,
            bold: false,
            color: t().col.f,
            align: Align::Min,
            wrap: true,
        }
    }
}

pub fn label(ui: &mut Ui, x: Txt) -> Response {
    let full = ui.available_width();
    let wrap = if x.wrap { full } else { f32::INFINITY };
    let g = galley(ui, x.text, font(x.fam, x.pt, x.bold), x.color, wrap, 0, x.align);
    let w = if x.wrap || x.align != Align::Min { full } else { g.size().x };
    let (rect, resp) = ui.allocate_exact_size(vec2(w, g.size().y), Sense::hover());
    paint(ui, g, rect, x.align);
    resp
}

pub fn heading(ui: &mut Ui, text: &str) {
    label(ui, Txt { text, bold: true, ..Default::default() });
}

/// Wrapped text that takes no space when empty.
pub fn message(ui: &mut Ui, text: &str, color: Color32) {
    if !text.is_empty() {
        label(ui, Txt { text, color, ..Default::default() });
    }
}

pub struct Btn<'a> {
    pub text: &'a str,
    pub symbol: &'a str,
    pub symbol_pt: f32,
    pub value: &'a str,
    pub selected: bool,
    pub muted: bool,
    pub disabled: bool,
    pub fg: Option<Color32>,
    pub fill: Option<Color32>,
    pub fam: Fam,
    pub bold: bool,
    /// Take the available width, like `Layout.fillWidth`.
    pub wide: bool,
    pub w: f32,
    pub h: f32,
    pub pad: f32,
    pub tip: &'a str,
}

impl Default for Btn<'_> {
    fn default() -> Self {
        let d = &t().dim;
        Btn {
            text: "",
            symbol: "",
            symbol_pt: t().fs.m,
            value: "",
            selected: false,
            muted: false,
            disabled: false,
            fg: None,
            fill: None,
            fam: Fam::Sans,
            bold: false,
            wide: false,
            w: 0.0,
            h: d.m + d.s,
            pad: d.s,
            tip: "",
        }
    }
}

impl Btn<'_> {
    /// Square symbol button with a tooltip.
    pub fn icon<'a>(symbol: &'a str, tip: &'a str) -> Btn<'a> {
        let d = &t().dim;
        Btn { symbol, tip, symbol_pt: t().fs.x, w: d.m + d.s, pad: 0.0, ..Default::default() }
    }

    pub fn show(self, ui: &mut Ui) -> Response {
        let (c, d, fs) = (&t().col, &t().dim, &t().fs);
        let fg = self.fg.unwrap_or(if self.disabled || self.muted { c.m } else { c.f });
        let mono = |pt| font(Fam::Mono, pt, false);
        let side =
            width(ui, self.symbol, mono(self.symbol_pt)).max(width(ui, self.value, mono(fs.m)));
        let inset = if side > 0.0 { side + d.s } else { 0.0 };
        let lfont = font(self.fam, fs.m, self.bold);
        let has_label = !self.text.is_empty();
        let natural =
            if has_label { width(ui, self.text, lfont.clone()) + inset * 2.0 } else { side };
        let w = if self.wide {
            ui.available_width()
        } else if self.w > 0.0 {
            self.w
        } else {
            natural + self.pad * 2.0
        };
        let sense = if self.disabled { Sense::hover() } else { Sense::click() };
        let (rect, resp) = ui.allocate_exact_size(vec2(w, self.h), sense);
        let active = !self.disabled && (resp.hovered() || resp.is_pointer_button_down_on());
        let fill = self.fill.unwrap_or(if self.selected || active { c.o } else { c.b });
        ui.painter().rect_filled(rect, 0.0, fill);
        let content = rect.shrink2(vec2(self.pad, 0.0));
        if !self.symbol.is_empty() {
            let g =
                galley(ui, self.symbol, mono(self.symbol_pt), fg, f32::INFINITY, 0, Align::Min);
            let x =
                if has_label { content.left() } else { content.center().x - g.size().x / 2.0 };
            paint(
                ui,
                g,
                egui::Rect::from_x_y_ranges(x..=content.right(), content.y_range()),
                Align::Min,
            );
        }
        if has_label {
            let inner = content.shrink2(vec2(inset, 0.0));
            let g = galley(ui, self.text, lfont, fg, inner.width().max(1.0), 1, Align::Center);
            paint(ui, g, inner, Align::Center);
        }
        if !self.value.is_empty() {
            let g = galley(ui, self.value, mono(fs.m), fg, f32::INFINITY, 0, Align::Max);
            paint(ui, g, content, Align::Max);
        }
        if self.tip.is_empty() { resp } else { resp.on_hover_text(self.tip) }
    }
}

/// Returns the new value while the user moves the handle.
pub fn slider(
    ui: &mut Ui,
    w: f32,
    value: f32,
    to: f32,
    enabled: bool,
    muted: bool,
) -> Option<f32> {
    let (c, d) = (&t().col, &t().dim);
    let sense = if enabled { Sense::click_and_drag() } else { Sense::hover() };
    let (rect, resp) = ui.allocate_exact_size(vec2(w, d.m), sense);
    let moved = (resp.dragged() || resp.clicked())
        .then(|| resp.interact_pointer_pos())
        .flatten()
        .map(|p| ((p.x - rect.left() - d.t / 2.0) / (rect.width() - d.t)).clamp(0.0, 1.0) * to);
    let pos = (moved.unwrap_or(value) / to.max(f32::EPSILON)).clamp(0.0, 1.0);
    let active = if !enabled || muted { c.m } else { c.f };
    let track = egui::Rect::from_center_size(rect.center(), vec2(rect.width(), d.t));
    ui.painter().rect_filled(track, 0.0, c.o);
    ui.painter().rect_filled(
        egui::Rect::from_min_size(track.min, vec2(pos * track.width(), d.t)),
        0.0,
        active,
    );
    let x = rect.left() + pos * (rect.width() - d.t);
    let handle =
        egui::Rect::from_min_size(pos2(x, rect.center().y - d.s / 2.0), vec2(d.t, d.s));
    ui.painter().rect_filled(handle, 0.0, active);
    moved
}

pub struct Field<'a> {
    pub id: &'a str,
    pub hint: &'a str,
    pub password: bool,
    pub fam: Fam,
    pub pt: f32,
    pub h: f32,
    pub pad: f32,
    pub fill: Color32,
    pub align: Align,
    pub enabled: bool,
}

impl Default for Field<'_> {
    fn default() -> Self {
        let d = &t().dim;
        Field {
            id: "field",
            hint: "",
            password: false,
            fam: Fam::Sans,
            pt: t().fs.m,
            h: d.m + d.s,
            pad: d.s,
            fill: t().col.o,
            align: Align::Min,
            enabled: true,
        }
    }
}

impl Field<'_> {
    /// A single line input filling the available width.
    pub fn show(self, ui: &mut Ui, text: &mut String) -> Response {
        let c = &t().col;
        let (rect, _) =
            ui.allocate_exact_size(vec2(ui.available_width(), self.h), Sense::hover());
        ui.painter().rect_filled(rect, 0.0, self.fill);
        let font = font(self.fam, self.pt, false);
        let hint = egui::RichText::new(self.hint).color(c.m).font(font.clone());
        let edit = egui::TextEdit::singleline(text)
            .id(egui::Id::unique(self.id))
            .frame(egui::Frame::NONE)
            .background_color(Color32::TRANSPARENT)
            .password(self.password)
            .hint_text(hint)
            .font(font)
            .text_color(c.f)
            .align(egui::Align2([self.align, Align::Center]))
            .desired_width(rect.width() - self.pad * 2.0)
            .min_size(vec2(0.0, rect.height()))
            .margin(egui::Margin::ZERO);
        ui.add_enabled_ui(self.enabled, |ui| ui.put(rect.shrink2(vec2(self.pad, 0.0)), edit))
            .inner
    }
}

pub fn focus(ui: &Ui, id: &str) {
    ui.memory_mut(|m| m.request_focus(egui::Id::unique(id)));
}

/// Enter pressed in a single line field this frame.
pub fn submitted(ui: &Ui, resp: &Response) -> bool {
    resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter))
}

/// Vertical scrolling without a scroll bar, like a `Flickable`.
pub fn scroll<R>(ui: &mut Ui, id: &str, max_h: f32, add: impl FnOnce(&mut Ui) -> R) -> R {
    egui::ScrollArea::vertical()
        .id_salt(id)
        .max_height(max_h)
        .auto_shrink([false, true])
        .scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden)
        .show(ui, add)
        .inner
}
