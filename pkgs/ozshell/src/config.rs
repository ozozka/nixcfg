//! Shell configuration. Edit and rebuild; only theme constants come from the command line.

/// Hyprland workspaces shown in the bar.
pub const WORKSPACES: i32 = 6;
/// Interface whose traffic the bar shows.
pub const NET_IFACE: &str = "wlan0";
/// Temperature shown in the bar, in millidegrees.
pub const THERMAL: &str = "/sys/class/thermal/thermal_zone3/temp";
/// PAM service used by the lock screen.
pub const PAM_SERVICE: &str = "ozshell";

pub const STATS_MS: u64 = 600;
pub const PROCS_MS: u64 = 2000;
pub const SCAN_SETTLE_MS: u64 = 3000;
pub const PAIR_TIMEOUT_S: u64 = 60;
pub const SUSPEND_TIMEOUT_MS: u64 = 5000;

pub const MENU_WIDTH: f32 = 480.0;
pub const POPUP_WIDTH: f32 = 380.0;
pub const LOCK_WIDTH: f32 = 360.0;
pub const POLKIT_WIDTH: f32 = 420.0;
pub const RESULT_ROWS: usize = 6;
pub const RESULT_LIMIT: usize = 50;

pub const SUSPEND: &[&str] = &["systemctl", "suspend-then-hibernate"];
pub const WIFI_RESCAN: &[&str] =
    &["nmcli", "--wait", "15", "device", "wifi", "rescan", "ifname"];

/// Application launch command; the desktop file id and working directory are appended at runtime.
pub fn launch(id: &str, home: &str) -> Vec<String> {
    let mut cmd: Vec<String> = [
        "systemd-run",
        "--user",
        "--collect",
        "--slice=app.slice",
        "--property=Type=exec",
        "--property=ExitType=cgroup",
        "--property=PartOf=graphical-session.target",
        "--property=After=graphical-session.target",
    ]
    .map(String::from)
    .into();
    cmd.push(format!("--property=WorkingDirectory={home}"));
    cmd.extend(["--".into(), "gtk-launch".into(), format!("{id}.desktop")]);
    cmd
}

pub enum Act {
    Lock,
    Suspend,
    Run(&'static [&'static str]),
}

pub struct Power {
    pub symbol: &'static str,
    pub name: &'static str,
    pub act: Act,
    pub destructive: bool,
}

pub const POWER: &[Power] = &[
    Power { symbol: "⎋", name: "Lock", act: Act::Lock, destructive: false },
    Power {
        symbol: "🆥",
        name: "Monitors off",
        act: Act::Run(&["hyprctl", "dispatch", "dpms", "off"]),
        destructive: false,
    },
    Power { symbol: "⏾", name: "Suspend", act: Act::Suspend, destructive: false },
    Power {
        symbol: "⏎",
        name: "Logout",
        act: Act::Run(&["hyprctl", "dispatch", "exit"]),
        destructive: true,
    },
    Power {
        symbol: "⏼",
        name: "Reboot",
        act: Act::Run(&["systemctl", "reboot"]),
        destructive: true,
    },
    Power {
        symbol: "⏻",
        name: "Shutdown",
        act: Act::Run(&["systemctl", "poweroff"]),
        destructive: true,
    },
];
