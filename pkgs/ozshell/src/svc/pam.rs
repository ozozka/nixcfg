//! PAM authentication for the lock screen on a worker thread.

use super::{Msg, send};
use crate::config::PAM_SERVICE;
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    sync::mpsc,
};

pub enum Pam {
    /// A further prompt after the submitted password, and whether to echo the answer.
    Prompt(String, bool),
    Done(bool),
}

#[repr(C)]
struct Message {
    style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct Response {
    resp: *mut c_char,
    retcode: c_int,
}

#[repr(C)]
struct Conv {
    conv: extern "C" fn(c_int, *mut *const Message, *mut *mut Response, *mut c_void) -> c_int,
    data: *mut c_void,
}

#[link(name = "pam")]
unsafe extern "C" {
    fn pam_start(
        service: *const c_char,
        user: *const c_char,
        conv: *const Conv,
        h: *mut *mut c_void,
    ) -> c_int;
    fn pam_authenticate(h: *mut c_void, flags: c_int) -> c_int;
    fn pam_end(h: *mut c_void, status: c_int) -> c_int;
}

const PROMPT_ECHO_OFF: c_int = 1;
const PROMPT_ECHO_ON: c_int = 2;
const CONV_ERR: c_int = 19;

struct State {
    password: Option<String>,
    answers: mpsc::Receiver<Option<String>>,
}

extern "C" fn conv(
    n: c_int,
    msgs: *mut *const Message,
    out: *mut *mut Response,
    data: *mut c_void,
) -> c_int {
    // SAFETY: PAM passes `n` messages and the `State` given to `pam_start`; it frees the
    // responses, so they are allocated with calloc and strdup.
    unsafe {
        let state = &mut *(data as *mut State);
        let resps = libc::calloc(n as usize, size_of::<Response>()) as *mut Response;
        if resps.is_null() {
            return CONV_ERR;
        }
        for i in 0..n as usize {
            let m = &**msgs.add(i);
            let text = CStr::from_ptr(m.msg).to_string_lossy().into_owned();
            if m.style == PROMPT_ECHO_OFF || m.style == PROMPT_ECHO_ON {
                let answer = state.password.take().or_else(|| {
                    send(Msg::Pam(Pam::Prompt(text, m.style == PROMPT_ECHO_ON)));
                    state.answers.recv().ok().flatten()
                });
                let Some(answer) = answer.and_then(|a| CString::new(a).ok()) else {
                    libc::free(resps.cast());
                    return CONV_ERR;
                };
                (*resps.add(i)).resp = libc::strdup(answer.as_ptr());
            }
        }
        *out = resps;
        0
    }
}

/// Authenticates `user` with `password`; further prompts are answered through the sender.
pub fn start(user: &str, password: String) -> mpsc::Sender<Option<String>> {
    let (tx, answers) = mpsc::channel();
    let user = CString::new(user).unwrap_or_default();
    std::thread::spawn(move || {
        let mut state = State { password: Some(password), answers };
        let conv = Conv { conv, data: (&mut state as *mut State).cast() };
        let service = CString::new(PAM_SERVICE).unwrap();
        let mut h = std::ptr::null_mut();
        // SAFETY: every pointer stays valid until `pam_end` returns.
        let ok = unsafe {
            let mut rc = pam_start(service.as_ptr(), user.as_ptr(), &conv, &mut h);
            if rc == 0 {
                rc = pam_authenticate(h, 0);
                pam_end(h, rc);
            }
            rc == 0
        };
        send(Msg::Pam(Pam::Done(ok)));
    });
    tx
}
