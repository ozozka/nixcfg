//! PipeWire audio devices from `pw-dump --monitor`, controlled with `wpctl`.

use super::{Msg, exec, send};
use serde_json::{Map, Value};
use std::{collections::BTreeMap, io::BufReader, process::Stdio, sync::Mutex, time::Duration};

#[derive(Clone, Copy, PartialEq)]
pub enum Availability {
    Yes,
    Unknown,
    No,
    Unreported,
}

#[derive(Clone, PartialEq)]
pub struct Node {
    pub id: u64,
    pub name: String,
    pub sink: bool,
    pub label: String,
    pub availability: Availability,
    pub volume: f32,
    pub muted: bool,
    pub ready: bool,
}

#[derive(Clone, Default, PartialEq)]
pub struct Audio {
    pub nodes: Vec<Node>,
    pub sink: Option<String>,
    pub source: Option<String>,
}

impl Audio {
    pub fn default_node(&self, sink: bool) -> Option<&Node> {
        let name = if sink { &self.sink } else { &self.source };
        self.nodes.iter().find(|n| Some(&n.name) == name.as_ref())
    }

    /// Devices whose routes are not known to be unplugged.
    pub fn devices(&self) -> impl Iterator<Item = &Node> {
        self.nodes.iter().filter(|n| n.availability != Availability::No)
    }
}

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or_default()
}

fn route_info<'a>(route: &'a Value, key: &str) -> &'a str {
    let info = route["info"].as_array().map(Vec::as_slice).unwrap_or_default();
    info.iter()
        .skip(1)
        .collect::<Vec<_>>()
        .chunks(2)
        .find(|c| c.len() == 2 && s(c[0]) == key)
        .map_or("", |c| s(c[1]))
}

/// Port of the route availability and labels Quickshell does not expose.
fn endpoint(
    objs: &BTreeMap<u64, Value>,
    props: &Map<String, Value>,
    sink: bool,
) -> Option<(Availability, String)> {
    if matches!(props.get("node.virtual"), Some(Value::Bool(true)))
        || props.get("node.virtual").map(s) == Some("true")
    {
        return None;
    }
    let device = props.get("card.profile.device")?;
    let params = objs.values().find(|o| {
        s(&o["type"]) == "PipeWire:Interface:Device" && Some(&o["id"]) == props.get("device.id")
    })?["info"]["params"]
        .clone();
    let dir = if sink { "Output" } else { "Input" };
    let matches = |r: &Value, ids: &[Value]| s(&r["direction"]) == dir && ids.contains(device);
    let list = |v: &Value| v.as_array().cloned().unwrap_or_default();
    let routes: Vec<&Value> = params["EnumRoute"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| matches(r, &list(&r["devices"])))
        .collect();
    if routes.is_empty() {
        return None;
    }
    let current = params["Route"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| matches(r, std::slice::from_ref(&r["device"])));
    let usable: Vec<&&Value> = routes.iter().filter(|r| s(&r["available"]) != "no").collect();
    let yes = routes.iter().find(|r| s(&r["available"]) == "yes");
    let route = usable
        .iter()
        .find(|r| Some(&r["index"]) == current.map(|c| &c["index"]))
        .map(|r| **r)
        .or(yes.copied())
        .or(usable.first().map(|r| **r))
        .unwrap_or(routes[0]);
    let availability = match (usable.is_empty(), yes.is_some()) {
        (true, _) => Availability::No,
        (_, true) => Availability::Yes,
        _ => Availability::Unknown,
    };
    let product = route_info(route, "device.product.name");
    let desc = s(&route["description"]);
    let label = match (product, desc) {
        ("", "") => props.get("node.description").map(s).unwrap_or_default().to_owned(),
        ("", d) => d.to_owned(),
        (p, d) => format!("{p} · {d}"),
    };
    Some((availability, label))
}

fn snapshot(objs: &BTreeMap<u64, Value>) -> Audio {
    let mut audio = Audio::default();
    for o in objs.values() {
        if s(&o["type"]) == "PipeWire:Interface:Metadata"
            && s(&o["props"]["metadata.name"]) == "default"
        {
            for m in o["metadata"].as_array().into_iter().flatten() {
                let name = m["value"]["name"].as_str().map(str::to_owned);
                match s(&m["key"]) {
                    "default.audio.sink" => audio.sink = name,
                    "default.audio.source" => audio.source = name,
                    _ => {}
                }
            }
        }
        let Some(props) = o["info"]["props"].as_object() else { continue };
        let class = props.get("media.class").map(s).unwrap_or_default();
        if s(&o["type"]) != "PipeWire:Interface:Node" || !class.starts_with("Audio/") {
            continue;
        }
        let sink = class.contains("Sink");
        let vol = o["info"]["params"]["Props"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|p| p["channelVolumes"].is_array());
        let volumes: Vec<f64> = vol.map_or(vec![], |p| {
            p["channelVolumes"].as_array().unwrap().iter().filter_map(Value::as_f64).collect()
        });
        let linear = if volumes.is_empty() {
            0.0
        } else {
            volumes.iter().sum::<f64>() / volumes.len() as f64
        };
        let (availability, label) =
            endpoint(objs, props, sink).unwrap_or((Availability::Unreported, String::new()));
        let pick = |k: &str| props.get(k).map(s).filter(|v| !v.is_empty());
        let label = Some(label.as_str())
            .filter(|l| !l.is_empty())
            .or_else(|| pick("node.description"))
            .or_else(|| pick("node.nick"))
            .or_else(|| pick("node.name"))
            .unwrap_or("Unavailable")
            .to_owned();
        audio.nodes.push(Node {
            id: o["id"].as_u64().unwrap_or(0),
            name: pick("node.name").unwrap_or_default().to_owned(),
            sink,
            label,
            availability,
            // PipeWire volumes are linear; wpctl and Quickshell show them cubic.
            volume: linear.cbrt() as f32,
            muted: vol.is_some_and(|p| p["mute"] == true),
            ready: vol.is_some(),
        });
    }
    audio
}

fn monitor() -> std::io::Result<()> {
    let mut child = std::process::Command::new("pw-dump")
        .args(["--monitor", "--no-colors"])
        .stdout(Stdio::piped())
        .spawn()?;
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let mut objs: BTreeMap<u64, Value> = BTreeMap::new();
    let mut last = None;
    for batch in serde_json::Deserializer::from_reader(stdout).into_iter::<Vec<Value>>() {
        let Ok(batch) = batch else { break };
        for o in batch {
            let Some(id) = o["id"].as_u64() else { continue };
            if o.get("info").is_some_and(Value::is_null) && o.get("metadata").is_none() {
                objs.remove(&id);
                continue;
            }
            // Updates may only carry changed fields; merge them into what is known.
            let entry = objs.entry(id).or_insert_with(|| Value::Object(Map::new()));
            for (k, v) in o.as_object().unwrap() {
                match (entry.get_mut(k), v) {
                    (Some(Value::Object(old)), Value::Object(new)) if k == "info" => {
                        old.extend(new.clone());
                    }
                    _ => {
                        entry[k] = v.clone();
                    }
                }
            }
        }
        let audio = snapshot(&objs);
        if last.as_ref() != Some(&audio) {
            send(Msg::Audio(audio.clone()));
            last = Some(audio);
        }
    }
    let _ = child.kill();
    child.wait().map(drop)
}

pub fn start() {
    std::thread::spawn(|| {
        loop {
            if let Err(e) = monitor() {
                eprintln!("ozshell: pw-dump: {e}");
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
}

/// Slider drags coalesce: only the latest volume waits while `wpctl` runs.
static VOLUME: Mutex<(Option<(u64, f32)>, bool)> = Mutex::new((None, false));

pub fn set_volume(id: u64, volume: f32) {
    let mut v = VOLUME.lock().unwrap();
    v.0 = Some((id, volume));
    if std::mem::replace(&mut v.1, true) {
        return;
    }
    super::spawn(async {
        loop {
            let next = VOLUME.lock().unwrap().0.take();
            let Some((id, vol)) = next else {
                VOLUME.lock().unwrap().1 = false;
                break;
            };
            let _ = tokio::process::Command::new("wpctl")
                .args(["set-volume", &id.to_string(), &format!("{vol:.4}")])
                .status()
                .await;
        }
    });
}

pub fn set_mute(id: u64, mute: bool) {
    exec(&["wpctl", "set-mute", &id.to_string(), if mute { "1" } else { "0" }]);
}

pub fn set_default(id: u64) {
    exec(&["wpctl", "set-default", &id.to_string()]);
}
