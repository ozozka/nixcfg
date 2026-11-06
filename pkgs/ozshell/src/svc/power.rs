//! UPower display device and power profiles.

use super::{Msg, Watch, get, get_all, send, set_prop, signals, spawn, system};

const UPOWER: &str = "org.freedesktop.UPower";
const DEVICE: &str = "/org/freedesktop/UPower/devices/DisplayDevice";
const PROFILES: &str = "org.freedesktop.UPower.PowerProfiles";
const PROFILES_PATH: &str = "/org/freedesktop/UPower/PowerProfiles";

#[derive(Clone, Default, PartialEq)]
pub struct Battery {
    pub percentage: f64,
    pub state: u32,
    pub time_to_empty: i64,
    pub time_to_full: i64,
}

impl Battery {
    /// Status names as sysfs reports them.
    pub fn status(&self) -> &'static str {
        match self.state {
            1 => "Charging",
            2 => "Discharging",
            3 => "Empty",
            4 => "Full",
            5 => "Not charging",
            _ => "Unknown",
        }
    }

    pub fn remaining(&self) -> i64 {
        if self.state == 1 { self.time_to_full } else { self.time_to_empty }
    }
}

#[derive(Clone, Default, PartialEq)]
pub struct Profiles {
    pub active: String,
    pub available: Vec<String>,
}

async fn battery() {
    let Ok(c) = system().await else { return };
    let mut w = Watch::new(c, vec![signals(UPOWER)]).await;
    while w.next().await {
        if let Ok(p) = get_all(c, UPOWER, DEVICE, "org.freedesktop.UPower.Device").await {
            send(Msg::Battery(Battery {
                percentage: get(&p, "Percentage").unwrap_or(0.0),
                state: get(&p, "State").unwrap_or(0),
                time_to_empty: get(&p, "TimeToEmpty").unwrap_or(0),
                time_to_full: get(&p, "TimeToFull").unwrap_or(0),
            }));
        }
    }
}

async fn profiles() {
    let Ok(c) = system().await else { return };
    let mut w = Watch::new(c, vec![signals(PROFILES)]).await;
    while w.next().await {
        let Ok(p) = get_all(c, PROFILES, PROFILES_PATH, PROFILES).await else { continue };
        let profiles: Vec<super::Props> = get(&p, "Profiles").unwrap_or_default();
        let available = profiles.iter().filter_map(|d| get::<String>(d, "Profile")).collect();
        send(Msg::Profiles(Profiles {
            active: get(&p, "ActiveProfile").unwrap_or_default(),
            available,
        }));
    }
}

pub fn set_profile(name: &str) {
    let name = name.to_owned();
    spawn(async move {
        if let Ok(c) = system().await {
            let _ = set_prop(c, PROFILES, PROFILES_PATH, PROFILES, "ActiveProfile", name).await;
        }
    });
}

pub async fn run() {
    tokio::join!(battery(), profiles());
}
