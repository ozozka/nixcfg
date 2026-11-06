//! ozshell: a Wayland desktop shell for Hyprland.

mod clock;
mod config;
mod img;
mod svc;
mod theme;
mod ui;
mod wl;

use smithay_client_toolkit::reexports::{
    calloop::{EventLoop, channel, timer::TimeoutAction, timer::Timer},
    calloop_wayland_source::WaylandSource,
};
use std::time::{Duration, Instant, SystemTime};
use wayland_client::{Connection, globals::registry_queue_init};

/// Fires just after the next wall clock second.
fn next_second() -> Instant {
    let into = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    Instant::now()
        + Duration::from_nanos(1_000_000_000 - into as u64)
        + Duration::from_millis(5)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("msg") {
        return svc::ipc::client(&args[1..]);
    }
    theme::init(&args);

    let conn = Connection::connect_to_env().expect("no Wayland compositor");
    let (globals, mut queue) = registry_queue_init(&conn).expect("Wayland registry");
    let qh = queue.handle();
    let mut event_loop: EventLoop<wl::App> = EventLoop::try_new().expect("event loop");
    let lh = event_loop.handle();
    let mut app = wl::App::new(conn.clone(), &globals, qh, lh.clone());
    // Outputs and the compositor's GPU are known after one roundtrip.
    queue.roundtrip(&mut app).expect("Wayland roundtrip");
    app.init_gpu();
    WaylandSource::new(conn, queue).insert(lh.clone()).expect("Wayland source");

    let (tx, rx) = channel::channel();
    lh.insert_source(rx, |event, _, app| {
        if let channel::Event::Msg(msg) = event {
            if app.sh.on_msg(msg) {
                app.mark_all();
            } else {
                app.mark_role(ui::Role::Bar);
            }
        }
    })
    .expect("message source");
    lh.insert_source(Timer::from_deadline(next_second()), |_, _, app| {
        app.sh.tick();
        app.mark_role(ui::Role::Bar);
        app.mark_role(ui::Role::Details);
        TimeoutAction::ToInstant(next_second())
    })
    .expect("clock timer");

    svc::start(tx);
    loop {
        let timeout = app.timeout();
        if let Err(e) = event_loop.dispatch(timeout, &mut app) {
            eprintln!("ozshell: {e}");
            std::process::exit(1);
        }
        app.update();
    }
}
