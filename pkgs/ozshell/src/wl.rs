//! Wayland surfaces drawn with egui on wgpu. Each surface keeps its own egui context.

use crate::{theme::t, ui, ui::Role};
use egui::{Pos2, Rect, ViewportId, vec2};
use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
};
use smithay_client_toolkit::reexports::protocols::wp::linux_dmabuf::zv1::client::{
    zwp_linux_buffer_params_v1::ZwpLinuxBufferParamsV1,
    zwp_linux_dmabuf_feedback_v1::ZwpLinuxDmabufFeedbackV1,
};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData, Region},
    dmabuf::{DmabufFeedback, DmabufHandler, DmabufState},
    output::{OutputHandler, OutputState},
    reexports::{
        calloop::LoopHandle,
        protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::{
            Shape, WpCursorShapeDeviceV1,
        },
    },
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        Capability, SeatHandler, SeatState,
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
        pointer::{
            PointerEvent, PointerEventKind, PointerHandler, cursor_shape::CursorShapeManager,
        },
    },
    session_lock::{
        SessionLock, SessionLockHandler, SessionLockState, SessionLockSurface,
        SessionLockSurfaceConfigure,
    },
    shell::{
        WaylandSurface,
        wlr_layer::{
            Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
            LayerSurfaceConfigure,
        },
        xdg::{
            XdgShell,
            window::{Window, WindowConfigure, WindowDecorations, WindowHandler},
        },
    },
};
use std::{ptr::NonNull, time::Duration, time::Instant};
use wayland_client::{
    Connection, Proxy, QueueHandle,
    globals::GlobalList,
    protocol::{
        wl_keyboard::WlKeyboard, wl_output::WlOutput, wl_pointer::WlPointer, wl_seat::WlSeat,
        wl_surface::WlSurface,
    },
};

pub enum Kind {
    Layer(LayerSurface),
    Lock(SessionLockSurface),
    Window(Window),
}

impl Kind {
    fn wl(&self) -> &WlSurface {
        match self {
            Kind::Layer(s) => s.wl_surface(),
            Kind::Lock(s) => s.wl_surface(),
            Kind::Window(s) => s.wl_surface(),
        }
    }
}

pub struct Win {
    // Dropped before the Wayland surface it renders to.
    gpu: wgpu::Surface<'static>,
    kind: Kind,
    size: (u32, u32),
    scale: i32,
    configured: bool,
    pending: bool,
}

pub struct Surf {
    pub role: Role,
    pub out: String,
    ctx: egui::Context,
    rend: Option<egui_wgpu::Renderer>,
    wall: Option<egui::TextureId>,
    win: Option<Win>,
    events: Vec<egui::Event>,
    /// egui lays out in this height while the surface follows the content.
    layout_h: Option<f32>,
    dirty: bool,
    at: Option<Instant>,
}

struct Dev {
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    format: wgpu::TextureFormat,
    wall: Option<wgpu::TextureView>,
}

pub struct App {
    pub conn: Connection,
    qh: QueueHandle<App>,
    lh: LoopHandle<'static, App>,
    registry: RegistryState,
    seat: SeatState,
    outputs: OutputState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    xdg: XdgShell,
    lock_state: SessionLockState,
    lock: Option<SessionLock>,
    cursor: Option<CursorShapeManager>,
    shape: Option<WpCursorShapeDeviceV1>,
    shape_now: Shape,
    keyboard: Option<WlKeyboard>,
    pointer: Option<WlPointer>,
    kb_focus: Option<WlSurface>,
    ptr_focus: Option<WlSurface>,
    serial: u32,
    mods: egui::Modifiers,
    dmabuf: DmabufState,
    /// PCI bus of the GPU the compositor renders with.
    gpu_bus: Option<String>,
    instance: Option<wgpu::Instance>,
    dev: Option<Dev>,
    wallpaper: Option<egui::ColorImage>,
    surfs: Vec<Surf>,
    start: Instant,
    poke: bool,
    pub sh: ui::Shell,
}

impl App {
    pub fn new(
        conn: Connection,
        globals: &GlobalList,
        qh: QueueHandle<App>,
        lh: LoopHandle<'static, App>,
    ) -> Self {
        let wallpaper = crate::img::load(&t().wallpaper, None);
        let sh = ui::Shell::new(
            wallpaper.as_ref().map(|w| vec2(w.width() as f32, w.height() as f32)),
        );
        let dmabuf = DmabufState::new(globals, &qh);
        let _ = dmabuf.get_default_feedback(&qh);
        App {
            registry: RegistryState::new(globals),
            seat: SeatState::new(globals, &qh),
            outputs: OutputState::new(globals, &qh),
            compositor: CompositorState::bind(globals, &qh).expect("wl_compositor"),
            layer_shell: LayerShell::bind(globals, &qh).expect("wlr-layer-shell"),
            xdg: XdgShell::bind(globals, &qh).expect("xdg-shell"),
            lock_state: SessionLockState::new(globals, &qh),
            cursor: CursorShapeManager::bind(globals, &qh).ok(),
            dmabuf,
            gpu_bus: None,
            instance: None,
            conn,
            qh,
            lh,
            lock: None,
            shape: None,
            shape_now: Shape::Default,
            keyboard: None,
            pointer: None,
            kb_focus: None,
            ptr_focus: None,
            serial: 0,
            mods: egui::Modifiers::NONE,
            dev: None,
            wallpaper,
            surfs: Vec::new(),
            start: Instant::now(),
            poke: false,
            sh,
        }
    }

    fn output_size(&self, name: &str) -> (f32, f32) {
        self.outputs
            .outputs()
            .filter_map(|o| self.outputs.info(&o))
            .find(|i| i.name.as_deref() == Some(name))
            .and_then(|i| i.logical_size)
            .map_or((1920.0, 1080.0), |(w, h)| (w as f32, h as f32))
    }

    fn output(&self, name: &str) -> Option<WlOutput> {
        self.outputs
            .outputs()
            .find(|o| self.outputs.info(o).and_then(|i| i.name).as_deref() == Some(name))
    }

    fn sync_outputs(&mut self) {
        self.sh.outputs =
            self.outputs.outputs().filter_map(|o| self.outputs.info(&o)?.name).collect();
    }

    fn gpu_surface(&self, wl: &WlSurface) -> wgpu::Surface<'static> {
        let display = WaylandDisplayHandle::new(
            NonNull::new(self.conn.backend().display_ptr().cast()).unwrap(),
        );
        let window = WaylandWindowHandle::new(NonNull::new(wl.id().as_ptr().cast()).unwrap());
        // SAFETY: the Wayland surface outlives its wgpu surface, see `Win`.
        unsafe {
            self.instance.as_ref().expect("GPU initialized").create_surface_unsafe(
                wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: Some(RawDisplayHandle::Wayland(display)),
                    raw_window_handle: RawWindowHandle::Wayland(window),
                },
            )
        }
        .expect("wgpu surface")
    }

    /// Creates the Wayland side of a surface for `role` on output `out`.
    fn open(&mut self, role: Role, out: &str) {
        let (ow, oh) = self.output_size(out);
        let d = &t().dim;
        let output = self.output(out);
        let wl = self.compositor.create_surface(&self.qh);
        let mut layout_h = None;
        let kind = if role == Role::Lock {
            let Some(lock) = &self.lock else { return };
            let Some(output) = &output else { return };
            Kind::Lock(lock.create_lock_surface(wl, output, &self.qh))
        } else if role == Role::Polkit {
            let w = self.xdg.create_window(wl, WindowDecorations::ServerDefault, &self.qh);
            w.set_title("ozshell-polkit");
            w.set_app_id("ozshell");
            w.commit();
            layout_h = Some(oh);
            Kind::Window(w)
        } else {
            use Anchor as A;
            let all = A::TOP | A::BOTTOM | A::LEFT | A::RIGHT;
            let (layer, anchor, size, zone, kb, ns) = match role {
                Role::Bar => (
                    Layer::Top,
                    A::LEFT | A::RIGHT | A::BOTTOM,
                    (0, d.m as u32),
                    d.m as i32,
                    false,
                    "bar",
                ),
                Role::Wall => (Layer::Background, all, (0, 0), -1, false, "wallpaper"),
                Role::Notes => {
                    layout_h = Some(oh - d.m - d.s * 2.0);
                    let w = d.h.min(ow - d.s * 2.0) as u32;
                    (Layer::Overlay, A::TOP | A::LEFT, (w, 1), -1, false, "notifications")
                }
                Role::Details => (Layer::Overlay, all, (0, 0), -1, true, "controls"),
                _ => (Layer::Overlay, all, (0, 0), -1, true, "menu"),
            };
            let s = self.layer_shell.create_layer_surface(
                &self.qh,
                wl,
                layer,
                Some(format!("ozshell-{ns}")),
                output.as_ref(),
            );
            s.set_anchor(anchor);
            s.set_size(size.0, size.1);
            s.set_exclusive_zone(zone);
            if role == Role::Notes {
                s.set_margin(d.s as i32, 0, 0, d.s as i32);
            }
            s.set_keyboard_interactivity(if kb {
                KeyboardInteractivity::Exclusive
            } else {
                KeyboardInteractivity::None
            });
            s.commit();
            Kind::Layer(s)
        };
        let gpu = self.gpu_surface(kind.wl());
        let win = Win { gpu, kind, size: (0, 0), scale: 1, configured: false, pending: false };
        let i = match self
            .surfs
            .iter()
            .position(|s| s.role == role && s.out == out && s.win.is_none())
        {
            Some(i) => i,
            None => {
                let ctx = egui::Context::default();
                crate::theme::style(&ctx);
                self.surfs.push(Surf {
                    role,
                    out: out.to_owned(),
                    ctx,
                    rend: None,
                    wall: None,
                    win: None,
                    events: Vec::new(),
                    layout_h: None,
                    dirty: true,
                    at: None,
                });
                self.surfs.len() - 1
            }
        };
        let s = &mut self.surfs[i];
        s.win = Some(win);
        s.layout_h = layout_h;
        s.dirty = true;
    }

    /// Drops the Wayland side of transient surfaces; their egui state stays for reuse.
    fn close(&mut self, role: Role) {
        for s in self.surfs.iter_mut().filter(|s| s.role == role) {
            s.win = None;
            s.events.clear();
        }
    }

    fn find(&mut self, wl: &WlSurface) -> Option<&mut Surf> {
        self.surfs.iter_mut().find(|s| s.win.as_ref().is_some_and(|w| w.kind.wl() == wl))
    }

    /// Opens, moves and closes surfaces to match the shell state.
    fn sync(&mut self) {
        for out in self.sh.outputs.clone() {
            if !self.surfs.iter().any(|s| s.role == Role::Bar && s.out == out) {
                self.open(Role::Wall, &out);
                self.open(Role::Bar, &out);
                if self.lock.is_some() {
                    self.open(Role::Lock, &out);
                }
            }
        }
        let wants = [
            (Role::Menu, self.sh.menu.open.then(|| self.sh.menu.out.clone())),
            (Role::Details, self.sh.details.section.map(|_| self.sh.details.out.clone())),
            (Role::Notes, (!self.sh.notes.list.is_empty()).then(|| self.sh.notes.out.clone())),
            (Role::Polkit, self.sh.polkit.flow.is_some().then(String::new)),
        ];
        for (role, want) in wants {
            let cur = self
                .surfs
                .iter()
                .find(|s| s.role == role && s.win.is_some())
                .map(|s| s.out.clone());
            if cur != want {
                self.close(role);
                if let Some(out) = want {
                    self.open(role, &out);
                }
            }
        }
        if self.sh.lock.locked && self.lock.is_none() {
            match self.lock_state.lock(&self.qh) {
                Ok(lock) => {
                    self.lock = Some(lock);
                    for out in self.sh.outputs.clone() {
                        self.open(Role::Lock, &out);
                    }
                }
                Err(e) => {
                    eprintln!("ozshell: session lock unavailable: {e}");
                    self.sh.lock.locked = false;
                }
            }
        } else if !self.sh.lock.locked
            && let Some(lock) = self.lock.take()
        {
            lock.unlock();
            let _ = self.conn.roundtrip();
            self.surfs.retain(|s| s.role != Role::Lock);
        }
    }

    fn mark(&mut self, f: impl Fn(&Surf) -> bool) {
        for s in self.surfs.iter_mut().filter(|s| f(s)) {
            s.dirty = true;
        }
    }

    /// Everything but the static wallpaper may show changed state.
    pub fn mark_all(&mut self) {
        self.mark(|s| s.role != Role::Wall);
    }

    pub fn mark_role(&mut self, role: Role) {
        self.mark(|s| s.role == role);
    }

    /// Time until the next egui-requested repaint, if any.
    pub fn timeout(&self) -> Option<Duration> {
        let now = Instant::now();
        self.surfs.iter().filter_map(|s| s.at).min().map(|at| at.saturating_duration_since(now))
    }

    pub fn update(&mut self) {
        for _ in 0..3 {
            self.sync();
            let now = Instant::now();
            for i in 0..self.surfs.len() {
                let s = &self.surfs[i];
                if s.dirty || s.at.is_some_and(|at| at <= now) {
                    self.draw(i);
                }
            }
            if !std::mem::take(&mut self.poke) {
                break;
            }
            self.mark_all();
        }
        let _ = self.conn.flush();
    }

    /// Creates the wgpu instance with only the Vulkan driver of the compositor's GPU, which
    /// the initial roundtrip reported. Call before other threads start.
    pub fn init_gpu(&mut self) {
        let vendor = self.gpu_bus.as_ref().and_then(|b| {
            std::fs::read_to_string(format!("/sys/bus/pci/devices/{b}/vendor")).ok()
        });
        let driver = match vendor.as_deref().map(str::trim) {
            Some("0x10de") => Some("*nvidia*"),
            Some("0x8086") => Some("*intel*"),
            Some("0x1002") => Some("*radeon*"),
            _ => None,
        };
        if let Some(d) = driver
            && std::env::var_os("VK_LOADER_DRIVERS_SELECT").is_none()
        {
            // SAFETY: no other thread runs yet.
            unsafe { std::env::set_var("VK_LOADER_DRIVERS_SELECT", d) };
        }
        self.instance = Some(wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::VULKAN,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        }));
    }

    fn device(&mut self, surface: &wgpu::Surface) -> &Dev {
        let instance = self.instance.as_ref().expect("GPU initialized");
        self.dev.get_or_insert_with(|| {
            // Buffers from another GPU may not import, so render where the compositor does.
            let same = pollster::block_on(instance.enumerate_adapters(wgpu::Backends::VULKAN))
                .into_iter()
                .find(|a| {
                    self.gpu_bus.as_deref() == Some(a.get_info().device_pci_bus_id.as_str())
                });
            let adapter = same.unwrap_or_else(|| {
                pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                    compatible_surface: Some(surface),
                    ..Default::default()
                }))
                .expect("no compatible GPU adapter")
            });
            let (device, queue) =
                pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
                    .expect("GPU device");
            let caps = surface.get_capabilities(&adapter);
            let format =
                caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
            let wall = self.wallpaper.take().map(|img| {
                use wgpu::util::DeviceExt;
                let size = wgpu::Extent3d {
                    width: img.width() as u32,
                    height: img.height() as u32,
                    depth_or_array_layers: 1,
                };
                let bytes: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_array()).collect();
                device
                    .create_texture_with_data(
                        &queue,
                        &wgpu::TextureDescriptor {
                            label: Some("wallpaper"),
                            size,
                            mip_level_count: 1,
                            sample_count: 1,
                            dimension: wgpu::TextureDimension::D2,
                            format: wgpu::TextureFormat::Rgba8UnormSrgb,
                            usage: wgpu::TextureUsages::TEXTURE_BINDING,
                            view_formats: &[],
                        },
                        wgpu::util::TextureDataOrder::LayerMajor,
                        &bytes,
                    )
                    .create_view(&Default::default())
            });
            // Return the decoded wallpaper buffers to the system.
            unsafe { libc::malloc_trim(0) };
            Dev { adapter, device, queue, format, wall }
        })
    }

    fn configure(&mut self, i: usize) {
        let Some(win) = self.surfs[i].win.take() else { return };
        self.device(&win.gpu);
        let dev = self.dev.as_ref().unwrap();
        let (w, h) =
            (win.size.0.max(1) * win.scale as u32, win.size.1.max(1) * win.scale as u32);
        let caps = win.gpu.get_capabilities(&dev.adapter);
        let alpha = if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::PreMultiplied) {
            wgpu::CompositeAlphaMode::PreMultiplied
        } else {
            caps.alpha_modes[0]
        };
        let present = if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) {
            wgpu::PresentMode::Mailbox
        } else {
            wgpu::PresentMode::Fifo
        };
        if let Some(mut config) = win.gpu.get_default_config(&dev.adapter, w, h) {
            config.format = dev.format;
            config.alpha_mode = alpha;
            config.present_mode = present;
            config.view_formats.clear();
            win.gpu.configure(&dev.device, &config);
        }
        let s = &mut self.surfs[i];
        if s.rend.is_none() {
            let mut rend = egui_wgpu::Renderer::new(
                &dev.device,
                dev.format,
                egui_wgpu::RendererOptions {
                    msaa_samples: 1,
                    dithering: false,
                    ..Default::default()
                },
            );
            if matches!(s.role, Role::Wall | Role::Lock)
                && let Some(view) = &dev.wall
            {
                s.wall = Some(rend.register_native_texture(
                    &dev.device,
                    view,
                    wgpu::FilterMode::Linear,
                ));
            }
            s.rend = Some(rend);
        }
        s.win = Some(win);
        s.dirty = true;
    }

    fn draw(&mut self, i: usize) {
        let App {
            surfs,
            sh,
            dev,
            qh,
            start,
            cursor: _,
            shape,
            shape_now,
            ptr_focus,
            poke,
            serial,
            ..
        } = self;
        let s = &mut surfs[i];
        let Some(win) = s.win.as_mut() else { return };
        let Some(dev) = dev.as_ref() else { return };
        if !win.configured || win.pending {
            return;
        }
        s.dirty = false;
        s.at = None;
        let scale = win.scale as f32;
        let size = vec2(win.size.0 as f32, win.size.1 as f32);
        let layout = vec2(size.x, s.layout_h.unwrap_or(size.y));
        let events = std::mem::take(&mut s.events);
        *poke |= events.iter().any(|e| !matches!(e, egui::Event::PointerMoved(_)));
        let mut raw = egui::RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, layout)),
            time: Some(start.elapsed().as_secs_f64()),
            max_texture_side: Some(dev.device.limits().max_texture_dimension_2d as usize),
            focused: true,
            events,
            ..Default::default()
        };
        raw.viewports.entry(ViewportId::ROOT).or_default().native_pixels_per_point =
            Some(scale);
        let mut f =
            ui::Frame { role: s.role, out: &s.out, size: layout, wall: s.wall, want_h: None };
        let out = s.ctx.run_ui(raw, |ui| ui::draw(ui, sh, &mut f));
        let want_h = f.want_h;

        if let Some(vo) = out.viewport_output.get(&ViewportId::ROOT) {
            if vo.repaint_delay.is_zero() {
                s.dirty = true;
            } else if vo.repaint_delay < Duration::from_secs(60) {
                s.at = Some(Instant::now() + vo.repaint_delay);
            }
        }
        if ptr_focus.as_ref() == Some(win.kind.wl()) {
            let want = match out.platform_output.cursor_icon {
                egui::CursorIcon::Text => Shape::Text,
                _ => Shape::Default,
            };
            if want != *shape_now
                && let Some(device) = shape
            {
                device.set_shape(*serial, want);
                *shape_now = want;
            }
        }

        let mut out = out;
        let rend = s.rend.as_mut().expect("renderer exists once configured");
        for (id, deltas) in &out.textures_delta.set {
            for delta in deltas {
                rend.update_texture(&dev.device, &dev.queue, *id, delta);
            }
        }
        for id in &out.textures_delta.free {
            rend.free_texture(id);
        }
        out.textures_delta.clear();
        let frame = match win.gpu.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t)
            | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            _ => {
                s.dirty = true;
                return;
            }
        };
        let view = frame.texture.create_view(&Default::default());
        let px = [win.size.0 * win.scale as u32, win.size.1 * win.scale as u32];
        let sd = egui_wgpu::ScreenDescriptor { size_in_pixels: px, pixels_per_point: scale };
        let prims = s.ctx.tessellate(out.shapes, out.pixels_per_point);
        let mut enc = dev.device.create_command_encoder(&Default::default());
        let mut cmds = rend.update_buffers(&dev.device, &dev.queue, &mut enc, &prims, &sd);
        let clear = match s.role {
            Role::Bar | Role::Wall | Role::Lock => {
                let b = t().col.b;
                wgpu::Color {
                    r: b.r() as f64 / 255.0,
                    g: b.g() as f64 / 255.0,
                    b: b.b() as f64 / 255.0,
                    a: 1.0,
                }
            }
            _ => wgpu::Color::TRANSPARENT,
        };
        {
            let mut pass = enc
                .begin_render_pass(&wgpu::RenderPassDescriptor {
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        depth_slice: None,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(clear),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    ..Default::default()
                })
                .forget_lifetime();
            rend.render(&mut pass, &prims, &sd);
        }
        cmds.push(enc.finish());
        dev.queue.submit(cmds);
        let wl = win.kind.wl();
        wl.frame(qh, FrameCallbackData(wl.clone()));
        win.pending = true;
        dev.queue.present(frame);

        let mut resize = false;
        if let Some(h) = want_h.map(|h| h.ceil().max(1.0) as u32)
            && h != win.size.1
        {
            match &win.kind {
                Kind::Layer(l) => {
                    l.set_size(win.size.0, h);
                    l.commit();
                }
                Kind::Window(w) => {
                    w.set_min_size(Some((win.size.0, h)));
                    w.set_max_size(Some((win.size.0, h)));
                    win.size.1 = h;
                    resize = true;
                }
                Kind::Lock(_) => {}
            }
        }
        if resize {
            self.configure(i);
        }
    }

    fn push(&mut self, wl: &WlSurface, event: egui::Event) {
        if let Some(s) = self.find(wl) {
            s.events.push(event);
            s.dirty = true;
        }
    }

    fn key(&mut self, event: KeyEvent, pressed: bool, repeat: bool) {
        let Some(wl) = self.kb_focus.clone() else { return };
        let k = match event.keysym {
            Keysym::Escape => Some(egui::Key::Escape),
            Keysym::Return | Keysym::KP_Enter => Some(egui::Key::Enter),
            Keysym::Tab | Keysym::ISO_Left_Tab => Some(egui::Key::Tab),
            Keysym::BackSpace => Some(egui::Key::Backspace),
            Keysym::Delete => Some(egui::Key::Delete),
            Keysym::Left => Some(egui::Key::ArrowLeft),
            Keysym::Right => Some(egui::Key::ArrowRight),
            Keysym::Up => Some(egui::Key::ArrowUp),
            Keysym::Down => Some(egui::Key::ArrowDown),
            Keysym::Home => Some(egui::Key::Home),
            Keysym::End => Some(egui::Key::End),
            Keysym::space => Some(egui::Key::Space),
            k => k
                .key_char()
                .and_then(|c| egui::Key::from_name(&c.to_ascii_uppercase().to_string())),
        };
        if let Some(key) = k {
            let modifiers = self.mods;
            self.push(
                &wl,
                egui::Event::Key { key, physical_key: None, pressed, repeat, modifiers },
            );
        }
        if pressed
            && !self.mods.ctrl
            && !self.mods.alt
            && let Some(text) = event.utf8.filter(|t| t.chars().all(|c| !c.is_control()))
        {
            self.push(&wl, egui::Event::Text(text));
        }
    }

    fn output_added(&mut self, _: &WlOutput) {
        self.sync_outputs();
    }
}

impl CompositorHandler for App {
    fn scale_factor_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        wl: &WlSurface,
        factor: i32,
    ) {
        if let Some(i) =
            self.surfs.iter().position(|s| s.win.as_ref().is_some_and(|w| w.kind.wl() == wl))
        {
            let win = self.surfs[i].win.as_mut().unwrap();
            win.scale = factor;
            wl.set_buffer_scale(factor);
            if win.configured {
                self.configure(i);
            }
        }
    }

    fn transform_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlSurface,
        _: wayland_client::protocol::wl_output::Transform,
    ) {
    }

    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, wl: &WlSurface, _: u32) {
        if let Some(win) = self.find(wl).and_then(|s| s.win.as_mut()) {
            win.pending = false;
        }
    }

    fn surface_enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlSurface,
        _: &WlOutput,
    ) {
    }
    fn surface_leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlSurface,
        _: &WlOutput,
    ) {
    }
}

impl OutputHandler for App {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.outputs
    }

    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, output: WlOutput) {
        self.output_added(&output);
    }

    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, output: WlOutput) {
        self.output_added(&output);
    }

    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, output: WlOutput) {
        let name = self.outputs.info(&output).and_then(|i| i.name).unwrap_or_default();
        self.surfs.retain(|s| {
            !(matches!(s.role, Role::Bar | Role::Wall | Role::Lock) && s.out == name)
        });
        self.sync_outputs();
        self.sh.sync_outputs();
    }
}

impl LayerShellHandler for App {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        let wl = layer.wl_surface().clone();
        if let Some(s) = self.find(&wl) {
            s.win = None;
        }
    }

    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        layer: &LayerSurface,
        c: LayerSurfaceConfigure,
        _: u32,
    ) {
        let wl = layer.wl_surface().clone();
        let Some(i) =
            self.surfs.iter().position(|s| s.win.as_ref().is_some_and(|w| w.kind.wl() == &wl))
        else {
            return;
        };
        let s = &mut self.surfs[i];
        let win = s.win.as_mut().unwrap();
        win.size = (c.new_size.0.max(1), c.new_size.1.max(1));
        win.configured = true;
        if s.role == Role::Details {
            // Let clicks on the bar reach it while the popup is open.
            if let Ok(region) = Region::new(&self.compositor) {
                region.add(0, 0, win.size.0 as i32, win.size.1 as i32 - t().dim.m as i32);
                wl.set_input_region(Some(region.wl_region()));
            }
        }
        self.configure(i);
    }
}

impl SessionLockHandler for App {
    fn locked(&mut self, _: &Connection, _: &QueueHandle<Self>, _: SessionLock) {
        self.sh.lock_secured();
    }

    fn finished(&mut self, _: &Connection, _: &QueueHandle<Self>, _: SessionLock) {
        eprintln!("ozshell: compositor refused the session lock");
        self.lock = None;
        self.surfs.retain(|s| s.role != Role::Lock);
        self.sh.lock.locked = false;
    }

    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        surface: SessionLockSurface,
        c: SessionLockSurfaceConfigure,
        _: u32,
    ) {
        let wl = surface.wl_surface().clone();
        let Some(i) =
            self.surfs.iter().position(|s| s.win.as_ref().is_some_and(|w| w.kind.wl() == &wl))
        else {
            return;
        };
        let win = self.surfs[i].win.as_mut().unwrap();
        win.size = c.new_size;
        win.configured = true;
        self.configure(i);
    }
}

impl WindowHandler for App {
    fn request_close(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window) {
        self.sh.polkit_cancel();
    }

    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        window: &Window,
        _: WindowConfigure,
        _: u32,
    ) {
        let wl = window.wl_surface().clone();
        let Some(i) =
            self.surfs.iter().position(|s| s.win.as_ref().is_some_and(|w| w.kind.wl() == &wl))
        else {
            return;
        };
        let win = self.surfs[i].win.as_mut().unwrap();
        if !win.configured {
            win.size = (crate::config::POLKIT_WIDTH as u32, 1);
            win.configured = true;
            self.configure(i);
        }
    }
}

impl SeatHandler for App {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat
    }

    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}

    fn new_capability(
        &mut self,
        _: &Connection,
        qh: &QueueHandle<Self>,
        seat: WlSeat,
        cap: Capability,
    ) {
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            let repeat =
                Box::new(|app: &mut App, _: &WlKeyboard, e: KeyEvent| app.key(e, true, true));
            self.keyboard = self
                .seat
                .get_keyboard_with_repeat(qh, &seat, None, self.lh.clone(), repeat)
                .ok();
        }
        if cap == Capability::Pointer && self.pointer.is_none() {
            let pointer = self.seat.get_pointer(qh, &seat).ok();
            if let (Some(p), Some(m)) = (&pointer, &self.cursor) {
                self.shape = Some(m.get_shape_device(p, qh));
            }
            self.pointer = pointer;
        }
    }

    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: WlSeat,
        cap: Capability,
    ) {
        if cap == Capability::Keyboard
            && let Some(k) = self.keyboard.take()
        {
            k.release();
        }
        if cap == Capability::Pointer {
            self.shape = None;
            if let Some(p) = self.pointer.take() {
                p.release();
            }
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: WlSeat) {}
}

impl KeyboardHandler for App {
    fn enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        wl: &WlSurface,
        _: u32,
        _: &[u32],
        _: &[Keysym],
    ) {
        self.kb_focus = Some(wl.clone());
        self.push(wl, egui::Event::WindowFocused(true));
    }

    fn leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        wl: &WlSurface,
        _: u32,
    ) {
        self.push(wl, egui::Event::WindowFocused(false));
        self.kb_focus = None;
    }

    fn press_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        _: u32,
        e: KeyEvent,
    ) {
        self.key(e, true, false);
    }

    fn repeat_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        _: u32,
        e: KeyEvent,
    ) {
        self.key(e, true, true);
    }

    fn release_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        _: u32,
        e: KeyEvent,
    ) {
        self.key(e, false, false);
    }

    fn update_modifiers(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlKeyboard,
        _: u32,
        m: Modifiers,
        _: RawModifiers,
        _: u32,
    ) {
        self.mods = egui::Modifiers {
            alt: m.alt,
            ctrl: m.ctrl,
            shift: m.shift,
            mac_cmd: false,
            command: m.ctrl,
        };
    }
}

impl PointerHandler for App {
    fn pointer_frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &WlPointer,
        events: &[PointerEvent],
    ) {
        let modifiers = self.mods;
        for e in events {
            let pos = Pos2::new(e.position.0 as f32, e.position.1 as f32);
            let button = |b: u32| match b {
                0x111 => egui::PointerButton::Secondary,
                0x112 => egui::PointerButton::Middle,
                _ => egui::PointerButton::Primary,
            };
            let ev = match e.kind {
                PointerEventKind::Enter { serial } => {
                    self.serial = serial;
                    self.ptr_focus = Some(e.surface.clone());
                    self.shape_now = Shape::Default;
                    if let Some(d) = &self.shape {
                        d.set_shape(serial, Shape::Default);
                    }
                    egui::Event::PointerMoved(pos)
                }
                PointerEventKind::Leave { .. } => {
                    self.ptr_focus = None;
                    egui::Event::PointerGone
                }
                PointerEventKind::Motion { .. } => egui::Event::PointerMoved(pos),
                PointerEventKind::Press { button: b, .. } => egui::Event::PointerButton {
                    pos,
                    button: button(b),
                    pressed: true,
                    modifiers,
                },
                PointerEventKind::Release { button: b, .. } => egui::Event::PointerButton {
                    pos,
                    button: button(b),
                    pressed: false,
                    modifiers,
                },
                PointerEventKind::Axis { horizontal, vertical, .. } => {
                    let (unit, delta) = if vertical.value120 != 0 || horizontal.value120 != 0 {
                        let d =
                            vec2(horizontal.value120 as f32, vertical.value120 as f32) / -120.0;
                        (egui::MouseWheelUnit::Line, d)
                    } else {
                        (
                            egui::MouseWheelUnit::Point,
                            vec2(-horizontal.absolute as f32, -vertical.absolute as f32),
                        )
                    };
                    egui::Event::MouseWheel {
                        unit,
                        delta,
                        phase: egui::TouchPhase::Move,
                        source: egui::MouseWheelSource::Wheel,
                        modifiers,
                    }
                }
            };
            self.push(&e.surface, ev);
        }
    }
}

impl ProvidesRegistryState for App {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState, SeatState];
}

smithay_client_toolkit::delegate_registry!(App);
smithay_client_toolkit::delegate_dispatch2!(App);

impl DmabufHandler for App {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf
    }

    fn dmabuf_feedback(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ZwpLinuxDmabufFeedbackV1,
        f: DmabufFeedback,
    ) {
        let dev = f.main_device();
        let link = format!("/sys/dev/char/{}:{}/device", libc::major(dev), libc::minor(dev));
        self.gpu_bus = std::fs::canonicalize(link)
            .ok()
            .and_then(|p| Some(p.file_name()?.to_string_lossy().into_owned()));
    }

    fn created(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &ZwpLinuxBufferParamsV1,
        _: wayland_client::protocol::wl_buffer::WlBuffer,
    ) {
    }
    fn failed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &ZwpLinuxBufferParamsV1) {}
    fn released(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wayland_client::protocol::wl_buffer::WlBuffer,
    ) {
    }
}
