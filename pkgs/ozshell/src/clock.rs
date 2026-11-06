//! Local time through libc, so the system time zone applies.

pub fn now() -> libc::tm {
    // SAFETY: localtime_r only writes the given struct.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    }
}

/// Formats with strftime, e.g. `%H:%M:%S`.
pub fn format(tm: &libc::tm, fmt: &str) -> String {
    let fmt = std::ffi::CString::new(fmt).unwrap_or_default();
    let mut buf = [0u8; 64];
    // SAFETY: strftime writes at most `buf.len()` bytes and returns the length used.
    let n = unsafe { libc::strftime(buf.as_mut_ptr().cast(), buf.len(), fmt.as_ptr(), tm) };
    String::from_utf8_lossy(&buf[..n]).into_owned()
}
