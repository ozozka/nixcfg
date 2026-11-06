//! BlueZ adapter and devices, with a native pairing agent.

use super::{Msg, Props, Watch, get, send, set_prop, signals, spawn, system};
use crate::config::PAIR_TIMEOUT_S;
use std::{collections::HashMap, sync::Mutex, time::Duration};
use tokio::sync::oneshot;
use zbus::{ObjectPath, OwnedObjectPath};

const BLUEZ: &str = "org.bluez";
const AGENT: &str = "/ozshell/agent";

#[derive(Clone, PartialEq)]
pub struct Device {
    pub path: OwnedObjectPath,
    pub name: String,
    pub paired: bool,
    pub connected: bool,
}

#[derive(Clone, Default, PartialEq)]
pub struct Bt {
    pub adapter: Option<OwnedObjectPath>,
    pub powered: bool,
    pub devices: Vec<Device>,
}

pub enum Pair {
    Status(String),
    Prompt { text: String, confirm: bool },
    Done,
}

type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;

/// The pairing agent's question awaiting a user answer.
static ANSWER: Mutex<Option<oneshot::Sender<Option<String>>>> = Mutex::new(None);

pub fn answer(text: Option<String>) {
    if let Some(tx) = ANSWER.lock().ok().and_then(|mut a| a.take()) {
        let _ = tx.send(text);
    }
}

async fn ask(text: String, confirm: bool) -> Option<String> {
    let (tx, rx) = oneshot::channel();
    if let Ok(mut a) = ANSWER.lock() {
        *a = Some(tx);
    }
    send(Msg::Pair(Pair::Prompt { text, confirm }));
    rx.await.ok().flatten()
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.bluez.Error")]
enum Error {
    #[zbus(error)]
    ZBus(zbus::Error),
    Rejected(String),
}

fn rejected<T>() -> Result<T, Error> {
    Err(Error::Rejected("Rejected".into()))
}

async fn confirm(text: String) -> Result<(), Error> {
    match ask(text, true).await.as_deref() {
        Some("yes") => Ok(()),
        _ => rejected(),
    }
}

struct Agent;

#[zbus::interface(name = "org.bluez.Agent1")]
impl Agent {
    async fn release(&self) {}

    async fn request_pin_code(&self, _device: ObjectPath<'_>) -> Result<String, Error> {
        ask("Enter PIN code:".into(), false).await.map_or_else(rejected, Ok)
    }

    async fn display_pin_code(&self, _device: ObjectPath<'_>, code: String) {
        send(Msg::Pair(Pair::Status(format!("Enter this code on your device: {code}"))));
    }

    async fn request_passkey(&self, _device: ObjectPath<'_>) -> Result<u32, Error> {
        let reply = ask("Enter passkey:".into(), false).await;
        reply.and_then(|r| r.trim().parse().ok()).map_or_else(rejected, Ok)
    }

    async fn display_passkey(&self, _device: ObjectPath<'_>, passkey: u32, _entered: u16) {
        send(Msg::Pair(Pair::Status(format!("Enter this code on your device: {passkey:06}"))));
    }

    async fn request_confirmation(
        &self,
        _device: ObjectPath<'_>,
        passkey: u32,
    ) -> Result<(), Error> {
        confirm(format!("Confirm passkey {passkey:06} (yes/no):")).await
    }

    async fn request_authorization(&self, _device: ObjectPath<'_>) -> Result<(), Error> {
        confirm("Accept pairing (yes/no):".into()).await
    }

    async fn authorize_service(
        &self,
        _device: ObjectPath<'_>,
        uuid: String,
    ) -> Result<(), Error> {
        confirm(format!("Authorize service {uuid} (yes/no):")).await
    }

    async fn cancel(&self) {
        answer(None);
    }
}

fn snapshot(objs: &Objects) -> Bt {
    let mut adapters: Vec<(&OwnedObjectPath, &Props)> =
        objs.iter().filter_map(|(p, i)| Some((p, i.get("org.bluez.Adapter1")?))).collect();
    adapters.sort_by_key(|(p, _)| p.to_string());
    let Some((path, adapter)) = adapters.first() else { return Bt::default() };
    let mut devices: Vec<Device> = objs
        .iter()
        .filter_map(|(p, i)| {
            let d = i.get("org.bluez.Device1")?;
            (get::<OwnedObjectPath>(d, "Adapter").as_ref() == Some(*path)).then(|| Device {
                path: p.clone(),
                name: get::<String>(d, "Alias")
                    .or_else(|| get(d, "Name"))
                    .or_else(|| get(d, "Address"))
                    .unwrap_or_default(),
                paired: get(d, "Paired").unwrap_or(false),
                connected: get(d, "Connected").unwrap_or(false),
            })
        })
        .collect();
    devices.sort_by_key(|d| d.path.to_string());
    Bt {
        adapter: Some((*path).clone()),
        powered: get(adapter, "Powered").unwrap_or(false),
        devices,
    }
}

pub async fn run() {
    let Ok(c) = system().await else { return };
    if c.object_server().at(AGENT, Agent).await.is_ok() {
        let path = ObjectPath::from_static_str_unchecked(AGENT);
        let _ = c
            .call_method(
                Some(BLUEZ),
                "/org/bluez",
                Some("org.bluez.AgentManager1"),
                "RegisterAgent",
                &(path, "KeyboardDisplay"),
            )
            .await;
    }
    let mut last = None;
    let mut w = Watch::new(c, vec![signals(BLUEZ)]).await;
    while w.next().await {
        let Ok(reply) = c
            .call_method(
                Some(BLUEZ),
                "/",
                Some("org.freedesktop.DBus.ObjectManager"),
                "GetManagedObjects",
                &(),
            )
            .await
        else {
            continue;
        };
        let Ok(objs) = reply.body().deserialize::<Objects>() else { continue };
        let bt = snapshot(&objs);
        if last.as_ref() != Some(&bt) {
            send(Msg::Bt(bt.clone()));
            last = Some(bt);
        }
    }
}

async fn call(path: &str, iface: &str, method: &str) -> zbus::Result<()> {
    system().await?.call_method(Some(BLUEZ), path, Some(iface), method, &()).await.map(drop)
}

pub fn set_powered(adapter: &OwnedObjectPath, on: bool) {
    let path = adapter.to_string();
    spawn(async move {
        if let Ok(c) = system().await {
            let _ = set_prop(c, BLUEZ, &path, "org.bluez.Adapter1", "Powered", on).await;
        }
    });
}

pub fn discover(adapter: &OwnedObjectPath, on: bool) {
    let path = adapter.to_string();
    spawn(async move {
        let _ = call(
            &path,
            "org.bluez.Adapter1",
            if on { "StartDiscovery" } else { "StopDiscovery" },
        )
        .await;
    });
}

/// Connects or disconnects a paired device, reporting when the call finishes.
pub fn toggle(dev: &Device) {
    let (path, method) =
        (dev.path.clone(), if dev.connected { "Disconnect" } else { "Connect" });
    spawn(async move {
        let _ = call(path.as_str(), "org.bluez.Device1", method).await;
        send(Msg::BtDone(path));
    });
}

pub fn pair(dev: &Device) {
    let path = dev.path.clone();
    send(Msg::Pair(Pair::Status(format!("Pairing with {}…", dev.name))));
    spawn(async move {
        let p = path.as_str();
        let status = match tokio::time::timeout(
            Duration::from_secs(PAIR_TIMEOUT_S),
            call(p, "org.bluez.Device1", "Pair"),
        )
        .await
        {
            Ok(Ok(())) => {
                let _ = call(p, "org.bluez.Device1", "Connect").await;
                "Paired successfully.".to_owned()
            }
            Ok(Err(zbus::Error::MethodError(name, _, _)))
                if name.contains("AuthenticationCanceled") =>
            {
                "Pairing cancelled.".to_owned()
            }
            Ok(Err(e)) => format!("Failed to pair: {e}"),
            Err(_) => {
                let _ = call(p, "org.bluez.Device1", "CancelPairing").await;
                "Pairing cancelled.".to_owned()
            }
        };
        answer(None);
        send(Msg::Pair(Pair::Status(status)));
        send(Msg::Pair(Pair::Done));
    });
}

pub fn cancel_pair(dev: &OwnedObjectPath) {
    let path = dev.to_string();
    answer(None);
    spawn(async move {
        let _ = call(&path, "org.bluez.Device1", "CancelPairing").await;
    });
}
