//! Desktop entries and icon lookup from the XDG data directories.

use std::{collections::HashMap, fs, path::Path, path::PathBuf, time::SystemTime};

#[derive(Clone)]
pub struct App {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub icon: String,
}

pub fn data_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let user =
        std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{home}/.local/share"));
    let system =
        std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    std::iter::once(user.as_str())
        .chain(system.split(':'))
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .collect()
}

fn parse(text: &str) -> Option<App> {
    let mut entry = HashMap::new();
    let mut section = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            section = line == "[Desktop Entry]";
        } else if section && let Some((k, v)) = line.split_once('=') {
            entry.entry(k.trim()).or_insert(v.trim());
        }
    }
    let flag = |k| entry.get(k) == Some(&"true");
    if entry.get("Type") != Some(&"Application") || flag("NoDisplay") || flag("Hidden") {
        return None;
    }
    let get = |k| entry.get(k).copied().unwrap_or_default().to_owned();
    let detail =
        Some(get("GenericName")).filter(|g| !g.is_empty()).unwrap_or_else(|| get("Comment"));
    Some(App { id: String::new(), name: get("Name"), detail, icon: get("Icon") })
}

fn scan(dir: &Path, prefix: &str, seen: &mut HashMap<String, Option<App>>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let path = e.path();
        if path.is_dir() {
            scan(&path, &format!("{prefix}{name}-"), seen);
        } else if let Some(stem) = name.strip_suffix(".desktop") {
            let id = format!("{prefix}{stem}");
            // Earlier data directories shadow later ones, including hidden entries.
            seen.entry(id.clone()).or_insert_with(|| {
                fs::read_to_string(&path).ok().and_then(|t| parse(&t)).map(|a| App { id, ..a })
            });
        }
    }
}

/// Modification times of the application directories, to reload only on change.
pub fn stamp() -> Vec<Option<SystemTime>> {
    data_dirs()
        .iter()
        .map(|d| fs::metadata(d.join("applications")).and_then(|m| m.modified()).ok())
        .collect()
}

pub fn load() -> Vec<App> {
    let mut seen = HashMap::new();
    for dir in data_dirs() {
        scan(&dir.join("applications"), "", &mut seen);
    }
    let mut apps: Vec<App> = seen.into_values().flatten().collect();
    apps.sort_by_cached_key(|a| a.name.to_lowercase());
    apps
}

/// Icon name to file, preferring the hicolor theme, scalable icons, then larger bitmaps.
pub fn icons() -> HashMap<String, String> {
    let mut best: HashMap<String, (u32, String)> = HashMap::new();
    let mut offer = |name: &str, score: u32, path: &Path| {
        let e = best.entry(name.to_owned()).or_insert((0, String::new()));
        if score > e.0 {
            *e = (score, path.to_string_lossy().into_owned());
        }
    };
    for dir in data_dirs() {
        let theme = dir.join("icons/hicolor");
        for size in fs::read_dir(&theme).into_iter().flatten().flatten() {
            let size_name = size.file_name().to_string_lossy().into_owned();
            let px: u32 = size_name.split('x').next().and_then(|n| n.parse().ok()).unwrap_or(0);
            for ctx in fs::read_dir(size.path()).into_iter().flatten().flatten() {
                for icon in fs::read_dir(ctx.path()).into_iter().flatten().flatten() {
                    let path = icon.path();
                    let (Some(stem), Some(ext)) = (path.file_stem(), path.extension()) else {
                        continue;
                    };
                    let score = match (ext.to_str(), size_name.as_str()) {
                        (Some("svg"), _) => 2000,
                        (Some("png"), _) if px >= 48 => 1000 - px.min(999),
                        (Some("png"), _) => 500 + px,
                        _ => continue,
                    };
                    offer(&stem.to_string_lossy(), score, &path);
                }
            }
        }
        for icon in fs::read_dir(dir.join("pixmaps")).into_iter().flatten().flatten() {
            let path = icon.path();
            if let Some(stem) = path.file_stem()
                && matches!(path.extension().and_then(|e| e.to_str()), Some("png" | "svg"))
            {
                offer(&stem.to_string_lossy(), 1, &path);
            }
        }
    }
    best.into_iter().map(|(k, (_, v))| (k, v)).collect()
}
