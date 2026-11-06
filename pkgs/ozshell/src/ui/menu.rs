//! Application search with power actions beside it.

use super::{Frame, Role, Shell, w};
use crate::{
    config::{self, MENU_WIDTH, POPUP_WIDTH, RESULT_LIMIT, RESULT_ROWS},
    img, svc,
    theme::{Fam, font, t},
};
use egui::{Align, Id, Key, Modifiers, Rect, Sense, Ui, UiBuilder, pos2, vec2};

const SEARCH: &str = "search";

fn matches(app: &svc::apps::App, q: &str) -> bool {
    q.is_empty() || app.name.to_lowercase().contains(q) || app.detail.to_lowercase().contains(q)
}

pub fn icon(ui: &Ui, sh: &mut Shell, role: Role, name: &str) -> Option<egui::TextureHandle> {
    let px = (t().dim.m * ui.pixels_per_point()) as u32;
    let path = sh.icon_path(name);
    sh.texture(ui, role, name, || img::load(&path?, Some(px)))
}

fn launch(sh: &mut Shell, id: &str) {
    let home = std::env::var("HOME").unwrap_or_default();
    svc::exec(&config::launch(id, &home));
    sh.close_menu();
}

pub fn draw(ui: &mut Ui, sh: &mut Shell, f: &mut Frame) {
    let (c, d) = (&t().col, &t().dim);
    let (sw, shh) = (f.size.x, f.size.y);
    let q = sh.menu.query.trim().to_lowercase();
    let results: Vec<svc::apps::App> =
        sh.menu.apps.iter().filter(|a| matches(a, &q)).take(RESULT_LIMIT).cloned().collect();
    let count = results.len();
    if sh.menu.current >= count {
        sh.menu.current = 0;
    }

    let row = d.m + d.s;
    let list_h = count.clamp(1, RESULT_ROWS) as f32 * row;
    let mw = MENU_WIDTH.min(sw - d.s * 2.0);
    let mh = (list_h + d.s + row + d.s * 2.0).min((shh - d.m - d.s * 2.0).max(0.0));
    let menu = Rect::from_min_size(pos2(d.s, shh - d.m - d.s - mh), vec2(mw, mh));
    ui.painter().rect_filled(menu, 0.0, c.b);

    let search_focused = ui.memory(|m| m.has_focus(Id::unique(SEARCH)));
    let mut moved = false;
    if search_focused && count > 0 {
        for (key, delta) in [(Key::ArrowDown, 1), (Key::ArrowUp, count - 1)] {
            if ui.input_mut(|i| i.consume_key(Modifiers::NONE, key)) {
                sh.menu.current = (sh.menu.current + delta) % count;
                moved = true;
            }
        }
    }
    if ui.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape)) {
        if sh.menu.power {
            sh.menu.power = false;
            sh.menu.focus = true;
        } else {
            return sh.close_menu();
        }
    }
    if std::mem::take(&mut sh.menu.focus) {
        w::focus(ui, SEARCH);
    }

    let inner = menu.shrink(d.s);
    let mut body = ui.new_child(UiBuilder::new().max_rect(inner));
    body.set_clip_rect(inner);
    let list = Rect::from_min_size(
        pos2(inner.left(), inner.bottom() - row - d.s - list_h),
        vec2(inner.width(), list_h),
    );
    let mut lui = body.new_child(UiBuilder::new().max_rect(list));
    lui.spacing_mut().item_spacing = vec2(0.0, 0.0);
    if count == 0 {
        let g = w::galley(
            &lui,
            "No matching applications",
            font(Fam::Sans, t().fs.m, false),
            c.m,
            list.width(),
            0,
            Align::Center,
        );
        w::paint(&lui, g, list, Align::Center);
    }
    let mut launched = None;
    egui::ScrollArea::vertical()
        .id_salt("results")
        .max_height(list_h)
        .auto_shrink([false, false])
        .scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden)
        .show_rows(&mut lui, row, count, |ui, range| {
            for i in range {
                let app = &results[i];
                let (rect, resp) =
                    ui.allocate_exact_size(vec2(ui.available_width(), row), Sense::click());
                let current = i == sh.menu.current;
                if current && moved {
                    ui.scroll_to_rect(rect, None);
                }
                ui.painter().rect_filled(
                    rect,
                    0.0,
                    if current || resp.hovered() { c.o } else { c.b },
                );
                let name =
                    if app.icon.is_empty() { "application-x-executable" } else { &app.icon };
                let icon_rect = Rect::from_min_size(
                    pos2(rect.left() + d.s, rect.center().y - d.m / 2.0),
                    vec2(d.m, d.m),
                );
                if let Some(tex) = icon(ui, sh, Role::Menu, name) {
                    let uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
                    ui.painter().image(tex.id(), icon_rect, uv, egui::Color32::WHITE);
                }
                let text =
                    rect.with_min_x(icon_rect.right() + d.s).with_max_x(rect.right() - d.s);
                let g = w::galley(
                    ui,
                    &app.name,
                    font(Fam::Sans, t().fs.m, false),
                    if current { c.f } else { c.m },
                    text.width().max(1.0),
                    1,
                    Align::Min,
                );
                w::paint(ui, g, text, Align::Min);
                if resp.clicked() {
                    launched = Some(app.id.clone());
                }
            }
        });

    let search =
        Rect::from_min_size(pos2(inner.left(), inner.bottom() - row), vec2(inner.width(), row));
    let mut sui = body.new_child(
        UiBuilder::new().max_rect(search).layout(egui::Layout::left_to_right(Align::Center)),
    );
    let power = w::Btn {
        symbol: "⏻",
        w: row,
        h: row,
        pad: 0.0,
        selected: sh.menu.power,
        tip: "",
        ..Default::default()
    }
    .show(&mut sui);
    if power.clicked() {
        sh.menu.power = !sh.menu.power;
        sh.menu.pending = None;
        if sh.menu.power {
            sui.memory_mut(|m| m.surrender_focus(Id::unique(SEARCH)));
        } else {
            sh.menu.focus = true;
        }
    }
    let before = sh.menu.query.clone();
    let field =
        w::Field {
            id: SEARCH, hint: "Search applications…", fill: c.b, ..Default::default()
        };
    let resp = field.show(&mut sui, &mut sh.menu.query);
    if sh.menu.query != before {
        sh.menu.current = 0;
        sh.menu.pending = None;
    }
    if w::submitted(&sui, &resp) {
        launched = results.get(sh.menu.current).map(|a| a.id.clone());
        sh.menu.focus = true;
    }
    if let Some(id) = launched {
        return launch(sh, &id);
    }

    let mut boxes = vec![menu];
    if sh.menu.power {
        boxes.push(power_panel(ui, sh, f, menu));
    }
    let clicked =
        ui.input(|i| i.pointer.any_click().then(|| i.pointer.interact_pos()).flatten());
    if let Some(p) = clicked
        && !boxes.iter().any(|b| b.contains(p))
    {
        sh.close_menu();
    }
}

fn power_panel(ui: &mut Ui, sh: &mut Shell, f: &Frame, menu: Rect) -> Rect {
    let (c, d) = (&t().col, &t().dim);
    let inset = d.s;
    let row = d.m + d.s;
    let heading = w::galley(
        ui,
        "Power actions",
        font(Fam::Sans, t().fs.m, true),
        c.f,
        f32::INFINITY,
        0,
        Align::Min,
    );
    let n = config::POWER.len() as f32;
    let content = heading.size().y + d.s + n * row + (n - 1.0) * d.s;
    let pw = POPUP_WIDTH.min(f.size.x - inset * 2.0);
    let ph = (content + inset * 2.0).min(f.size.y - d.m - inset * 2.0);
    let beside = menu.right() + d.s;
    let x =
        if beside + pw + inset <= f.size.x { beside } else { inset.max(f.size.x - pw - inset) };
    let y = inset.max((menu.bottom() - ph).min(f.size.y - d.m - inset - ph));
    let rect = Rect::from_min_size(pos2(x, y), vec2(pw, ph));
    ui.painter().rect_filled(rect, 0.0, c.b);
    let mut body = ui.new_child(UiBuilder::new().max_rect(rect.shrink(inset)));
    w::scroll(&mut body, "power", ph - inset * 2.0, |ui| {
        w::heading(ui, "Power actions");
        for (i, p) in config::POWER.iter().enumerate() {
            let pending = sh.menu.pending == Some(i);
            let text = if pending { format!("Confirm {}", p.name) } else { p.name.to_owned() };
            if (w::Btn {
                symbol: p.symbol,
                text: &text,
                selected: pending,
                wide: true,
                ..Default::default()
            })
            .show(ui)
            .clicked()
            {
                sh.power(i);
            }
        }
    });
    rect
}
