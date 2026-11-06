//! Background services. They run on a tokio thread and report to the UI thread with [`Msg`].

pub mod apps;
pub mod audio;
pub mod bt;
pub mod hypr;
pub mod ipc;
pub mod mpris;
pub mod net;
pub mod notifd;
pub mod pam;
pub mod polkit;
pub mod power;
pub mod stats;

use futures_util::StreamExt;
use smithay_client_toolkit::reexports::calloop::channel::Sender;
use std::{collections::HashMap, ffi::OsStr, future::Future, sync::OnceLock, time::Duration};
use zbus::{Connection, MatchRule, MessageStream, OwnedVariant};

pub enum Msg {
    Hypr(hypr::Hypr),
    Stats(stats::Stats),
    Battery(power::Battery),
    Profiles(power::Profiles),
    Net(net::Net),
    NetError(String),
    NetFailed(u32),
    Scan(Result<(), String>),
    Bt(bt::Bt),
    BtDone(zbus::OwnedObjectPath),
    Pair(bt::Pair),
    Audio(audio::Audio),
    Media(Vec<mpris::Player>),
    Note(notifd::Note),
    NoteClosed(u32),
    Polkit(Option<polkit::Flow>),
    Pam(pam::Pam),
    Ipc(String),
}

static TX: OnceLock<Sender<Msg>> = OnceLock::new();
static RT: OnceLock<tokio::runtime::Handle> = OnceLock::new();
static SYSTEM: tokio::sync::OnceCell<Connection> = tokio::sync::OnceCell::const_new();
static SESSION: tokio::sync::OnceCell<Connection> = tokio::sync::OnceCell::const_new();

pub fn send(msg: Msg) {
    if let Some(tx) = TX.get() {
        let _ = tx.send(msg);
    }
}

pub fn spawn(fut: impl Future<Output = ()> + Send + 'static) {
    if let Some(rt) = RT.get() {
        rt.spawn(fut);
    }
}

/// Starts a process without waiting on it in the UI thread.
pub fn exec<S: AsRef<OsStr>>(argv: &[S]) {
    let Some((bin, args)) = argv.split_first() else { return };
    let mut cmd = tokio::process::Command::new(bin);
    cmd.args(args).process_group(0);
    spawn(async move {
        if let Ok(mut child) = cmd.spawn() {
            let _ = child.wait().await;
        }
    });
}

pub async fn system() -> zbus::Result<&'static Connection> {
    SYSTEM.get_or_try_init(Connection::system).await
}

pub async fn session() -> zbus::Result<&'static Connection> {
    SESSION.get_or_try_init(Connection::session).await
}

pub type Props = HashMap<String, OwnedVariant>;

pub fn get<T: TryFrom<OwnedVariant>>(p: &Props, key: &str) -> Option<T> {
    T::try_from(p.get(key)?.try_clone().ok()?).ok()
}

pub async fn get_all(
    c: &Connection,
    dest: &str,
    path: &str,
    iface: &str,
) -> zbus::Result<Props> {
    let reply = c
        .call_method(
            Some(dest),
            path,
            Some("org.freedesktop.DBus.Properties"),
            "GetAll",
            &iface,
        )
        .await?;
    reply.body().deserialize()
}

pub async fn set_prop<V: Into<zbus::Variant<'static>>>(
    c: &Connection,
    dest: &str,
    path: &str,
    iface: &str,
    name: &str,
    value: V,
) -> zbus::Result<()> {
    let value: zbus::Variant = value.into();
    c.call_method(
        Some(dest),
        path,
        Some("org.freedesktop.DBus.Properties"),
        "Set",
        &(iface, name, value),
    )
    .await
    .map(drop)
}

/// Resolves at once, then each time signals matching the rules settle for 100ms.
pub struct Watch {
    events: futures_util::stream::SelectAll<MessageStream>,
    first: bool,
}

impl Watch {
    pub async fn new(c: &Connection, rules: Vec<MatchRule<'static>>) -> Self {
        let mut events = futures_util::stream::SelectAll::new();
        for rule in rules {
            match MessageStream::for_match_rule(rule, c, None).await {
                Ok(s) => events.push(s),
                Err(e) => eprintln!("ozshell: signal subscription failed: {e}"),
            }
        }
        Watch { events, first: true }
    }

    /// Returns false once the bus connection closes.
    pub async fn next(&mut self) -> bool {
        if std::mem::take(&mut self.first) {
            return true;
        }
        if self.events.next().await.is_none() {
            return false;
        }
        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_millis(100)) => return true,
                next = self.events.next() => if next.is_none() { return false },
            }
        }
    }
}

pub fn signals(sender: &'static str) -> MatchRule<'static> {
    MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(sender)
        .build()
        .expect("valid match rule")
}

/// Runs the services on their own thread.
pub fn start(tx: Sender<Msg>) {
    let _ = TX.set(tx);
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let _ = RT.set(rt.handle().clone());
    audio::start();
    std::thread::spawn(move || {
        rt.block_on(async {
            tokio::spawn(hypr::run());
            tokio::spawn(stats::run());
            tokio::spawn(power::run());
            tokio::spawn(ipc::serve());
            tokio::spawn(net::run());
            tokio::spawn(bt::run());
            tokio::spawn(mpris::run());
            tokio::spawn(notifd::run());
            tokio::spawn(polkit::run());
            std::future::pending::<()>().await
        })
    });
}
