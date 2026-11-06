//! Constants injected by Nix through command line flags, and the egui style built from them.

use egui::{Color32, FontData, FontDefinitions, FontFamily, FontId, epaint::text::FontInsert};
use std::{collections::HashMap, process::Command, sync::Arc, sync::Mutex, sync::OnceLock};

pub struct Cols {
    pub p: Color32,
    pub s: Color32,
    pub f: Color32,
    pub m: Color32,
    pub o: Color32,
    pub b: Color32,
}

/// Tiny, small, medium, large, extra, huge.
pub struct Sizes {
    pub t: f32,
    pub s: f32,
    pub m: f32,
    pub l: f32,
    pub x: f32,
    pub h: f32,
}

pub struct Theme {
    pub col: Cols,
    pub fs: Sizes,
    pub dim: Sizes,
    pub wallpaper: String,
}

static THEME: OnceLock<Theme> = OnceLock::new();

pub fn t() -> &'static Theme {
    THEME.get().expect("theme is initialized at startup")
}

const USAGE: &str = "usage: ozshell --colors P,S,F,M,O,B --font-sizes T,S,M,L,X,H \
                     --dims T,S,M,L,X,H --wallpaper PATH\n       ozshell msg TARGET FUNCTION";

/// Parses `--colors`, `--font-sizes`, `--dims` and `--wallpaper`; every flag is required.
pub fn init(args: &[String]) {
    let flag = |name: &str| {
        let i = args.iter().position(|a| a == name).unwrap_or_else(|| exit(name));
        args.get(i + 1).cloned().unwrap_or_else(|| exit(name))
    };
    let list = |name: &str| {
        let v: Vec<String> = flag(name).split(',').map(str::to_owned).collect();
        if v.len() != 6 {
            exit(name)
        }
        v
    };
    let sizes = |name: &str| {
        let v: Vec<f32> =
            list(name).iter().map(|s| s.parse().unwrap_or_else(|_| exit(name))).collect();
        Sizes { t: v[0], s: v[1], m: v[2], l: v[3], x: v[4], h: v[5] }
    };
    let c: Vec<Color32> = list("--colors")
        .iter()
        .map(|h| Color32::from_hex(&format!("#{h}")).unwrap_or_else(|_| exit("--colors")))
        .collect();
    let theme = Theme {
        col: Cols { p: c[0], s: c[1], f: c[2], m: c[3], o: c[4], b: c[5] },
        fs: sizes("--font-sizes"),
        dim: sizes("--dims"),
        wallpaper: flag("--wallpaper"),
    };
    let _ = THEME.set(theme);
}

fn exit(flag: &str) -> ! {
    eprintln!("ozshell: missing or invalid {flag}\n{USAGE}");
    std::process::exit(2)
}

#[derive(Clone, Copy)]
pub enum Fam {
    Sans,
    Mono,
    Serif,
}

impl Fam {
    fn pattern(self) -> &'static str {
        match self {
            Fam::Sans => "sans-serif",
            Fam::Mono => "monospace",
            Fam::Serif => "serif",
        }
    }
}

const FAMILIES: [(&str, Fam, bool); 5] = [
    ("sans", Fam::Sans, false),
    ("sans-bold", Fam::Sans, true),
    ("mono", Fam::Mono, false),
    ("mono-bold", Fam::Mono, true),
    ("serif", Fam::Serif, false),
];

/// Font sizes are Qt points; egui works in logical pixels at 96 DPI.
pub fn font(fam: Fam, pt: f32, bold: bool) -> FontId {
    let name = match (fam, bold) {
        (Fam::Sans, false) => "sans",
        (Fam::Sans, true) => "sans-bold",
        (Fam::Mono, false) => "mono",
        (Fam::Mono, true) => "mono-bold",
        (Fam::Serif, _) => "serif",
    };
    FontId::new(pt * 4.0 / 3.0, FontFamily::Name(name.into()))
}

/// Resolves a fontconfig pattern to font bytes, shared by every egui context.
fn fc(pattern: &str) -> Option<FontData> {
    type Fonts = HashMap<String, Option<(Arc<Vec<u8>>, u32)>>;
    static CACHE: Mutex<Option<Fonts>> = Mutex::new(None);
    let mut cache = CACHE.lock().ok()?;
    let entry = cache.get_or_insert_default().entry(pattern.to_owned()).or_insert_with(|| {
        let out = Command::new("fc-match")
            .args(["-f", "%{file}\n%{index}", pattern])
            .output()
            .ok()?;
        let out = String::from_utf8(out.stdout).ok()?;
        let (file, index) = out.split_once('\n')?;
        Some((Arc::new(std::fs::read(file).ok()?), index.parse().unwrap_or(0)))
    });
    entry.as_ref().map(|(bytes, index)| FontData::from_blob(bytes.clone(), *index))
}

/// Same fonts and fallbacks fontconfig gives Qt: generic families first, then per-glyph matches.
pub fn style(ctx: &egui::Context) {
    let mut defs = FontDefinitions::empty();
    for (name, fam, bold) in FAMILIES {
        let pattern =
            if bold { format!("{}:bold", fam.pattern()) } else { fam.pattern().to_owned() };
        if let Some(data) = fc(&pattern) {
            defs.font_data.insert(name.to_owned(), Arc::new(data));
            defs.families.insert(FontFamily::Name(name.into()), vec![name.to_owned()]);
        }
    }
    defs.families.insert(FontFamily::Proportional, vec!["sans".into()]);
    defs.families.insert(FontFamily::Monospace, vec!["mono".into()]);
    ctx.set_fonts(defs);
    ctx.add_font_provider(Arc::new(|req: &egui::epaint::text::FallbackRequest<'_>| {
        let c = req.cluster.chars().next()?;
        let fam = match req.family {
            FontFamily::Name(n) if n.starts_with("mono") => Fam::Mono,
            FontFamily::Name(n) if n.starts_with("serif") => Fam::Serif,
            _ => Fam::Sans,
        };
        let data = fc(&format!("{}:charset={:x}", fam.pattern(), c as u32))?;
        Some(FontInsert::new(&format!("{}-{:x}", fam.pattern(), c as u32), data, vec![]))
    }));

    let (c, d) = (&t().col, &t().dim);
    ctx.all_styles_mut(|s| {
        s.animation_time = 0.0;
        s.spacing.item_spacing = egui::vec2(d.s, d.s);
        s.spacing.interact_size = egui::vec2(0.0, 0.0);
        s.interaction.selectable_labels = false;
        let v = &mut s.visuals;
        v.panel_fill = Color32::TRANSPARENT;
        v.window_fill = c.b;
        v.window_stroke = egui::Stroke::new(1.0, c.o);
        v.window_shadow = egui::epaint::Shadow::NONE;
        v.popup_shadow = egui::epaint::Shadow::NONE;
        v.override_text_color = Some(c.f);
        v.extreme_bg_color = c.o;
        v.selection.bg_fill = c.p;
        v.selection.stroke.color = c.b;
        v.text_cursor.stroke = egui::Stroke::new(1.0, c.f);
        v.text_cursor.blink = false;
        for w in [&mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active] {
            w.bg_stroke = egui::Stroke::NONE;
            w.fg_stroke.color = c.f;
        }
        v.widgets.noninteractive.fg_stroke.color = c.f;
    });
}
