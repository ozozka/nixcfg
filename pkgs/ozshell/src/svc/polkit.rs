//! Polkit authentication agent backed by the socket-activated `polkit-agent-helper-1`.

use super::{Msg, Props, get, send, system};
use std::{collections::HashMap, sync::Mutex};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    sync::mpsc,
};
use zbus::{OwnedObjectPath, Variant};

const PATH: &str = "/org/ozshell/PolicyKit1/AuthenticationAgent";
const HELPER: &str = "/run/polkit/agent-helper.socket";

#[derive(Clone, Default)]
pub struct Flow {
    pub message: String,
    pub prompt: String,
    pub visible: bool,
    pub info: String,
    pub info_error: bool,
    pub required: bool,
    pub failed: bool,
}

/// User responses for the running flow, with its cookie. `None` cancels.
static RESPOND: Mutex<Option<(String, mpsc::UnboundedSender<Option<String>>)>> =
    Mutex::new(None);

pub fn respond(text: Option<String>) {
    if let Some((_, tx)) = RESPOND.lock().unwrap().as_ref() {
        let _ = tx.send(text);
    }
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.PolicyKit1.Error")]
enum Error {
    #[zbus(error)]
    ZBus(zbus::Error),
    Failed(String),
    Cancelled(String),
}

struct Agent {
    busy: tokio::sync::Mutex<()>,
}

pub fn user_name(uid: u32) -> Option<String> {
    // SAFETY: getpwuid returns a pointer into static storage or null.
    unsafe {
        let pw = libc::getpwuid(uid);
        (!pw.is_null())
            .then(|| std::ffi::CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned())
    }
}

/// Like `g_strcompress` for the escapes the helper writes.
fn unescape(s: &str) -> String {
    s.replace("\\n", "\n").replace("\\t", "\t").replace("\\\"", "\"").replace("\\\\", "\\")
}

enum End {
    Success,
    Failure,
    Cancel,
}

async fn session(
    user: &str,
    cookie: &str,
    flow: &mut Flow,
    rx: &mut mpsc::UnboundedReceiver<Option<String>>,
) -> End {
    let Ok(stream) = UnixStream::connect(HELPER).await else { return End::Failure };
    let (read, mut write) = stream.into_split();
    if write.write_all(format!("{user}\n{cookie}\n").as_bytes()).await.is_err() {
        return End::Failure;
    }
    let mut lines = BufReader::new(read).lines();
    loop {
        let line = tokio::select! {
            line = lines.next_line() => line,
            r = rx.recv() => match r {
                Some(Some(text)) if flow.required => {
                    flow.required = false;
                    send(Msg::Polkit(Some(flow.clone())));
                    if write.write_all(format!("{text}\n").as_bytes()).await.is_err() {
                        return End::Failure;
                    }
                    continue;
                }
                Some(Some(_)) => continue,
                _ => return End::Cancel,
            },
        };
        let Ok(Some(line)) = line else { return End::Failure };
        let line = unescape(&line);
        let (kind, text) = line.split_once(' ').unwrap_or((line.as_str(), ""));
        match kind {
            "PAM_PROMPT_ECHO_OFF" | "PAM_PROMPT_ECHO_ON" => {
                flow.prompt = text.to_owned();
                flow.visible = kind == "PAM_PROMPT_ECHO_ON";
                flow.required = true;
            }
            "PAM_ERROR_MSG" | "PAM_TEXT_INFO" => {
                flow.info = text.to_owned();
                flow.info_error = kind == "PAM_ERROR_MSG";
            }
            "SUCCESS" => return End::Success,
            _ => return End::Failure,
        }
        send(Msg::Polkit(Some(flow.clone())));
    }
}

#[zbus::interface(name = "org.freedesktop.PolicyKit1.AuthenticationAgent")]
impl Agent {
    async fn begin_authentication(
        &self,
        _action_id: String,
        message: String,
        _icon_name: String,
        _details: HashMap<String, String>,
        cookie: String,
        identities: Vec<(String, Props)>,
    ) -> Result<(), Error> {
        let _busy = self.busy.lock().await;
        let me = unsafe { libc::getuid() };
        let uids: Vec<u32> = identities
            .iter()
            .filter(|(k, _)| k == "unix-user")
            .filter_map(|(_, d)| get(d, "uid"))
            .collect();
        let uid =
            uids.iter().copied().find(|u| *u == me).or(uids.first().copied()).unwrap_or(me);
        let user = user_name(uid).ok_or_else(|| Error::Failed("Unknown user".into()))?;

        let (tx, mut rx) = mpsc::unbounded_channel();
        *RESPOND.lock().unwrap() = Some((cookie.clone(), tx));
        let mut flow = Flow { message, ..Default::default() };
        send(Msg::Polkit(Some(flow.clone())));
        let result = loop {
            match session(&user, &cookie, &mut flow, &mut rx).await {
                End::Success => break Ok(()),
                End::Cancel => break Err(Error::Cancelled("Authentication cancelled".into())),
                // A failed attempt starts a new conversation, like polkit's own agents.
                End::Failure => {
                    flow = Flow { message: flow.message, failed: true, ..Default::default() };
                    send(Msg::Polkit(Some(flow.clone())));
                }
            }
        };
        *RESPOND.lock().unwrap() = None;
        send(Msg::Polkit(None));
        result
    }

    async fn cancel_authentication(&self, cookie: String) {
        if let Some((c, tx)) = RESPOND.lock().unwrap().as_ref()
            && *c == cookie
        {
            let _ = tx.send(None);
        }
    }
}

/// The logind session to register for; user services have no `XDG_SESSION_ID`.
async fn session_id(c: &zbus::Connection) -> Option<String> {
    if let Ok(id) = std::env::var("XDG_SESSION_ID") {
        return Some(id);
    }
    let login = "org.freedesktop.login1";
    let uid = unsafe { libc::getuid() };
    let reply = c
        .call_method(
            Some(login),
            "/org/freedesktop/login1",
            Some("org.freedesktop.login1.Manager"),
            "GetUser",
            &uid,
        )
        .await
        .ok()?;
    let user: OwnedObjectPath = reply.body().deserialize().ok()?;
    let props =
        super::get_all(c, login, user.as_str(), "org.freedesktop.login1.User").await.ok()?;
    let (id, _): (String, OwnedObjectPath) = get(&props, "Display")?;
    (!id.is_empty()).then_some(id)
}

pub async fn run() {
    let Ok(c) = system().await else { return };
    if c.object_server().at(PATH, Agent { busy: Default::default() }).await.is_err() {
        return;
    }
    let Some(id) = session_id(c).await else {
        return eprintln!("ozshell: no login session for the polkit agent");
    };
    let subject: (&str, HashMap<&str, Variant>) =
        ("unix-session", [("session-id", Variant::from(id))].into());
    let locale = std::env::var("LANG").unwrap_or_else(|_| "C".into());
    let reply = c
        .call_method(
            Some("org.freedesktop.PolicyKit1"),
            "/org/freedesktop/PolicyKit1/Authority",
            Some("org.freedesktop.PolicyKit1.Authority"),
            "RegisterAuthenticationAgent",
            &(subject, locale, PATH),
        )
        .await;
    if let Err(e) = reply {
        eprintln!("ozshell: polkit agent registration failed: {e}");
    }
}
