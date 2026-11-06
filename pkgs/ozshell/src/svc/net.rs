//! NetworkManager Wi-Fi state and connection control.

use super::{Msg, Props, Watch, get, send, set_prop, signals, spawn, system};
use crate::config::{NET_IFACE, WIFI_RESCAN};
use std::collections::HashMap;
use zbus::{ObjectPath, OwnedObjectPath, OwnedVariant, Variant};

const NM: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const DEVICE: &str = "org.freedesktop.NetworkManager.Device";
const ACTIVATED: u32 = 100;
pub const FAILED: u32 = 120;

#[derive(Clone, Copy, PartialEq)]
pub enum Security {
    Open,
    Psk,
    Sae,
    Other,
}

#[derive(Clone, PartialEq)]
pub struct Network {
    pub ssid: String,
    pub ap: OwnedObjectPath,
    pub strength: f32,
    pub connected: bool,
    pub changing: bool,
    pub security: Security,
    pub saved: Option<OwnedObjectPath>,
}

#[derive(Clone, PartialEq)]
pub struct Wifi {
    pub path: OwnedObjectPath,
    pub name: String,
    pub state: u32,
    pub active: OwnedObjectPath,
    pub networks: Vec<Network>,
}

impl Wifi {
    pub fn connected(&self) -> Option<&Network> {
        self.networks.iter().find(|n| n.connected)
    }
}

#[derive(Clone, Default, PartialEq)]
pub struct Net {
    pub enabled: bool,
    pub hardware: bool,
    pub wifi: Option<Wifi>,
    /// Whether [`NET_IFACE`] is connected.
    pub iface_up: bool,
}

type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;

/// Quickshell's names for NetworkManager device state reasons.
pub fn reason(code: u32) -> &'static str {
    match code {
        7 => "NoSecrets",
        8 => "WifiClientDisconnected",
        9 | 10 => "WifiClientFailed",
        11 => "WifiAuthTimeout",
        53 => "WifiNetworkLost",
        _ => "Unknown",
    }
}

fn security(ap: &Props) -> Security {
    let wpa = get::<u32>(ap, "WpaFlags").unwrap_or(0) | get::<u32>(ap, "RsnFlags").unwrap_or(0);
    let privacy = get::<u32>(ap, "Flags").unwrap_or(0) & 1 != 0;
    match () {
        _ if wpa & 0x200 != 0 => Security::Other,
        _ if wpa & 0x100 != 0 => Security::Psk,
        _ if wpa & 0x400 != 0 => Security::Sae,
        _ if wpa == 0 && !privacy => Security::Open,
        _ => Security::Other,
    }
}

fn snapshot(objs: &Objects, saved: &HashMap<OwnedObjectPath, String>) -> Net {
    let iface = |path: &OwnedObjectPath, name: &str| objs.get(path).and_then(|o| o.get(name));
    let nm = objs.get(&OwnedObjectPath::try_from(NM_PATH).unwrap()).and_then(|o| o.get(NM));
    let mut net = Net {
        enabled: nm.and_then(|p| get(p, "WirelessEnabled")).unwrap_or(false),
        hardware: nm.and_then(|p| get(p, "WirelessHardwareEnabled")).unwrap_or(false),
        ..Default::default()
    };
    let mut wifis = Vec::new();
    for (path, ifaces) in objs {
        let Some(dev) = ifaces.get(DEVICE) else { continue };
        let state: u32 = get(dev, "State").unwrap_or(0);
        if get::<String>(dev, "Interface").as_deref() == Some(NET_IFACE) && state == ACTIVATED {
            net.iface_up = true;
        }
        let Some(wl) = ifaces.get("org.freedesktop.NetworkManager.Device.Wireless") else {
            continue;
        };
        let active_ap: Option<OwnedObjectPath> = get(wl, "ActiveAccessPoint");
        let active_ssid = active_ap
            .as_ref()
            .and_then(|p| iface(p, "org.freedesktop.NetworkManager.AccessPoint"))
            .and_then(|ap| get::<Vec<u8>>(ap, "Ssid"))
            .map(|s| String::from_utf8_lossy(&s).into_owned());
        let mut networks: Vec<Network> = Vec::new();
        for ap_path in get::<Vec<OwnedObjectPath>>(wl, "AccessPoints").unwrap_or_default() {
            let Some(ap) = iface(&ap_path, "org.freedesktop.NetworkManager.AccessPoint") else {
                continue;
            };
            let ssid = String::from_utf8_lossy(&get::<Vec<u8>>(ap, "Ssid").unwrap_or_default())
                .into_owned();
            if ssid.is_empty() {
                continue;
            }
            let strength = get::<u8>(ap, "Strength").unwrap_or(0) as f32 / 100.0;
            let mine = active_ssid.as_deref() == Some(ssid.as_str());
            let n = Network {
                connected: mine && state == ACTIVATED,
                changing: mine && (40..ACTIVATED).contains(&state),
                security: security(ap),
                saved: saved.iter().find(|(_, s)| **s == ssid).map(|(p, _)| p.clone()),
                ssid,
                ap: ap_path,
                strength,
            };
            match networks.iter_mut().find(|o| o.ssid == n.ssid) {
                Some(o) if o.strength < n.strength => {
                    *o = Network {
                        connected: o.connected || n.connected,
                        changing: o.changing || n.changing,
                        ..n
                    }
                }
                Some(_) => {}
                None => networks.push(n),
            }
        }
        networks.sort_by(|a, b| b.strength.total_cmp(&a.strength));
        wifis.push(Wifi {
            path: path.clone(),
            name: get(dev, "Interface").unwrap_or_default(),
            state,
            active: get(dev, "ActiveConnection")
                .unwrap_or_else(|| OwnedObjectPath::try_from("/").unwrap()),
            networks,
        });
    }
    wifis.sort_by_key(|w| (w.state != ACTIVATED, w.path.to_string()));
    net.wifi = wifis.into_iter().next();
    net
}

pub async fn run() {
    let Ok(c) = system().await else { return };
    tokio::spawn(failures(c));
    let mut saved: HashMap<OwnedObjectPath, Option<String>> = HashMap::new();
    let mut last = None;
    let mut w = Watch::new(c, vec![signals(NM)]).await;
    while w.next().await {
        let Ok(reply) = c
            .call_method(
                Some(NM),
                "/org/freedesktop",
                Some("org.freedesktop.DBus.ObjectManager"),
                "GetManagedObjects",
                &(),
            )
            .await
        else {
            continue;
        };
        let Ok(objs) = reply.body().deserialize::<Objects>() else { continue };
        let conns: Vec<&OwnedObjectPath> = objs
            .iter()
            .filter(|(_, i)| {
                i.contains_key("org.freedesktop.NetworkManager.Settings.Connection")
            })
            .map(|(p, _)| p)
            .collect();
        saved.retain(|p, _| conns.contains(&p));
        for p in conns {
            if !saved.contains_key(p) {
                saved.insert(p.clone(), ssid_of(c, p).await);
            }
        }
        let ssids = saved.iter().filter_map(|(p, s)| Some((p.clone(), s.clone()?))).collect();
        let net = snapshot(&objs, &ssids);
        if last.as_ref() != Some(&net) {
            send(Msg::Net(net.clone()));
            last = Some(net);
        }
    }
}

async fn ssid_of(c: &zbus::Connection, path: &OwnedObjectPath) -> Option<String> {
    let reply = c
        .call_method(
            Some(NM),
            path.as_str(),
            Some("org.freedesktop.NetworkManager.Settings.Connection"),
            "GetSettings",
            &(),
        )
        .await
        .ok()?;
    let settings: HashMap<String, Props> = reply.body().deserialize().ok()?;
    let ssid: Vec<u8> = get(settings.get("802-11-wireless")?, "ssid")?;
    Some(String::from_utf8_lossy(&ssid).into_owned())
}

fn call<B>(path: String, iface: &'static str, method: &'static str, body: B)
where
    B: serde::ser::Serialize + zbus::zvariant::DynamicType + Send + Sync + 'static,
{
    spawn(async move {
        let Ok(c) = system().await else { return };
        if let Err(e) = c.call_method(Some(NM), path.as_str(), Some(iface), method, &body).await
        {
            send(Msg::NetError(e.to_string()));
        }
    });
}

pub fn set_enabled(on: bool) {
    spawn(async move {
        if let Ok(c) = system().await {
            let _ = set_prop(c, NM, NM_PATH, NM, "WirelessEnabled", on).await;
        }
    });
}

pub fn request_scan(dev: &Wifi) {
    let opts: HashMap<String, OwnedVariant> = HashMap::new();
    call(
        dev.path.to_string(),
        "org.freedesktop.NetworkManager.Device.Wireless",
        "RequestScan",
        opts,
    );
}

/// `nmcli` waits until NetworkManager acknowledges the scan.
pub fn rescan(dev: &Wifi) {
    let ifname = dev.name.clone();
    spawn(async move {
        let out = tokio::process::Command::new(WIFI_RESCAN[0])
            .args(&WIFI_RESCAN[1..])
            .arg(ifname)
            .output()
            .await;
        let result = match out {
            Ok(o) if o.status.success() => Ok(()),
            Ok(o) => {
                let text = String::from_utf8_lossy(if o.stderr.trim_ascii().is_empty() {
                    &o.stdout
                } else {
                    &o.stderr
                });
                Err(text.trim().to_owned())
            }
            Err(e) => Err(e.to_string()),
        };
        send(Msg::Scan(
            result.map_err(|e| if e.is_empty() { "Wi-Fi scan failed.".into() } else { e }),
        ));
    });
}

fn root() -> ObjectPath<'static> {
    ObjectPath::from_static_str_unchecked("/")
}

pub fn disconnect(dev: &Wifi) {
    call(NM_PATH.into(), NM, "DeactivateConnection", dev.active.clone());
}

pub fn activate(dev: &Wifi, n: &Network) {
    let body =
        (n.saved.clone().map_or(root(), |p| p.into_inner()), dev.path.clone(), n.ap.clone());
    call(NM_PATH.into(), NM, "ActivateConnection", body);
}

pub fn connect_psk(dev: &Wifi, n: &Network, psk: &str) {
    let mgmt = if n.security == Security::Sae { "sae" } else { "wpa-psk" };
    let sec: HashMap<String, Variant<'static>> = [
        ("key-mgmt".into(), Variant::from(mgmt.to_owned())),
        ("psk".into(), Variant::from(psk.to_owned())),
    ]
    .into();
    let settings: HashMap<String, HashMap<String, Variant<'static>>> =
        [("802-11-wireless-security".into(), sec)].into();
    call(
        NM_PATH.into(),
        NM,
        "AddAndActivateConnection",
        (settings, dev.path.clone(), n.ap.clone()),
    );
}

/// Activation failures are transient device states, so they come from signals.
async fn failures(c: &'static zbus::Connection) {
    use futures_util::StreamExt;
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(NM)
        .interface(DEVICE)
        .member("StateChanged")
        .build()
        .expect("valid match rule");
    let Ok(mut stream) = zbus::MessageStream::for_match_rule(rule, c, None).await else {
        return;
    };
    while let Some(Ok(msg)) = stream.next().await {
        if let Ok((new, _, reason)) = msg.body().deserialize::<(u32, u32, u32)>()
            && new == FAILED
        {
            send(Msg::NetFailed(reason));
        }
    }
}
