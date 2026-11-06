//! CPU, memory, network, temperature and process count from procfs and sysfs.

use super::{Msg, send};
use crate::config::{NET_IFACE, PROCS_MS, STATS_MS, THERMAL};
use std::{fs, time::Duration, time::Instant};

#[derive(Clone, Default, PartialEq)]
pub struct Stats {
    pub cpu: f64,
    pub mem: f64,
    pub rate: f64,
    pub temp: f64,
    pub procs: usize,
}

#[derive(Default)]
struct Prev {
    total: f64,
    idle: f64,
    rx: f64,
    tx: f64,
    at: Option<Instant>,
}

fn sample(s: &mut Stats, p: &mut Prev) {
    if let Some(line) =
        fs::read_to_string("/proc/stat").ok().and_then(|t| t.lines().next().map(str::to_owned))
    {
        let v: Vec<f64> =
            line.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
        if v.len() > 4 {
            let total: f64 = v.iter().sum();
            let idle = v[3] + v[4];
            if p.total > 0.0 && total > p.total {
                s.cpu = 100.0 * ((total - p.total) - (idle - p.idle)) / (total - p.total);
            }
            (p.total, p.idle) = (total, idle);
        }
    }
    if let Ok(t) = fs::read_to_string("/proc/meminfo") {
        let kb = |key: &str| {
            t.lines()
                .find(|l| l.starts_with(key))?
                .split_whitespace()
                .nth(1)?
                .parse::<f64>()
                .ok()
        };
        if let (Some(total), Some(avail)) = (kb("MemTotal:"), kb("MemAvailable:")) {
            s.mem = (total - avail) * 1024.0;
        }
    }
    if let Ok(t) = fs::read_to_string("/proc/net/dev")
        && let Some(line) =
            t.lines().find(|l| l.trim_start().starts_with(&format!("{NET_IFACE}:")))
    {
        let v: Vec<f64> = line
            .split(':')
            .nth(1)
            .unwrap_or_default()
            .split_whitespace()
            .filter_map(|x| x.parse().ok())
            .collect();
        if v.len() > 8 {
            let now = Instant::now();
            if let Some(at) = p.at {
                let dt = now.duration_since(at).as_secs_f64();
                if dt > 0.0 {
                    s.rate = ((v[0] - p.rx) / dt).max(0.0) + ((v[8] - p.tx) / dt).max(0.0);
                }
            }
            (p.rx, p.tx, p.at) = (v[0], v[8], Some(now));
        }
    }
    if let Some(n) = fs::read_to_string(THERMAL).ok().and_then(|t| t.trim().parse().ok()) {
        s.temp = n;
    }
}

/// One entry per process, like `ps -e`.
fn processes() -> usize {
    fs::read_dir("/proc").map_or(0, |d| {
        d.flatten()
            .filter(|e| {
                e.file_name().to_str().is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()))
            })
            .count()
    })
}

pub async fn run() {
    let (mut s, mut p) = (Stats::default(), Prev::default());
    let mut tick = tokio::time::interval(Duration::from_millis(STATS_MS));
    let mut procs = tokio::time::interval(Duration::from_millis(PROCS_MS));
    loop {
        let old = s.clone();
        tokio::select! {
            _ = tick.tick() => sample(&mut s, &mut p),
            _ = procs.tick() => s.procs = processes(),
        }
        if s != old {
            send(Msg::Stats(s.clone()));
        }
    }
}
