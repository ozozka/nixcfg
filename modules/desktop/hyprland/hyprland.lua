local options = require "options"

local outs = {
  hdmi = {
    internal = "eDP-1",
    external = "HDMI-A-1",
  },
}

local monitors = {
  function ()
    hl.monitor {
      output = outs.hdmi.external,
      disabled = false,
      mode = "1920x1080@180",
      position = "auto",
      scale = 1,
    }
    hl.monitor {
      output = outs.hdmi.internal,
      disabled = true,
    }
  end,
  function ()
    hl.monitor {
      output = outs.hdmi.external,
      disabled = true,
    }
    hl.monitor {
      output = outs.hdmi.internal,
      disabled = false,
      mode = "1920x1080@165",
      position = "auto",
      scale = 1,
    }
  end,
  function ()
    hl.monitor {
      output = outs.hdmi.external,
      disabled = false,
      mode = "preferred",
      position = "auto",
      scale = 1,
      mirror = outs.hdmi.internal,
    }
    hl.monitor {
      output = outs.hdmi.internal,
      disabled = false,
      mode = "1920x1080@165",
      position = "auto",
      scale = 1,
    }
  end,
  function ()
    hl.monitor {
      output = outs.hdmi.external,
      disabled = false,
      mode = "preferred",
      position = "auto",
      scale = 1,
    }
    hl.monitor {
      output = outs.hdmi.internal,
      disabled = false,
      position = "auto",
      scale = 1,
      mirror = outs.hdmi.external,
    }
  end,
}

monitors[options.monitor]()

-- hl.permission("/usr/(bin|local/bin)/grim", "screencopy", "allow")

hl.config {
  general = {
    border_size = 0,
    gaps_in = 0,
    gaps_out = 0,
    allow_tearing = false,
  },
  decoration = {
    rounding = 0,
    dim_inactive = true,
    dim_strength = 0.24,
    dim_special = 0.24,
    blur = { enabled = false },
    shadow = { enabled = false },
  },
  animations = { enabled = false },
  input = {
    kb_layout = options.keyboard.layout,
    kb_variant = "",
    kb_model = "",
    kb_options = options.keyboard.options,
    kb_rules = "",
    -- resolve_binds_by_sym
    repeat_rate = 60,
    repeat_delay = 240,
    sensitivity = 0.0,
    accel_profile = "adaptive",
    natural_scroll = true,
    scroll_factor = 3.6,
    follow_mouse = 1,

    touchpad = {
      natural_scroll = true,
    },
  },
  misc = {
    disable_hyprland_logo = true,
    -- disable_splash_rendering = true,
    force_default_wallpaper = -1,
    -- font_family = "oziosevka",
    -- splash_font_family = "oziosevka",
    -- vrr = 1,
    -- vfr = true,
    close_special_on_empty = true,
    render_unfocused_fps = 30,
  },
  binds = {
    scroll_event_delay = 0,
    workspace_back_and_forth = true,
    hide_special_on_workspace_change = true,
    workspace_center_on = 1,
  },
  cursor = {},
  ecosystem = {
    no_update_news = false,
    no_donation_nag = true,
    enforce_permissions = false,
  },

  master = {
    new_status = "master",
    orientation = "right",
  },
}

hl.window_rule {
  name = "float-quickshell-polkit",
  match = { title = "^quickshell-polkit$" },
  float = true,
  center = true,
}

local mainMod = "SUPER"

hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd "qs ipc call lock lock")
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd "qs ipc call menu toggle")
hl.bind(
  mainMod .. " + P",
  hl.dsp.exec_cmd [[sh -c 'geometry=$(slurp) || exit; dir="$HOME/Pictures/Screenshots"; mkdir -p "$dir" && file="$dir/$(date +%Y-%m-%d_%H-%M-%S_%N).png" && grim -g "$geometry" "$file" && wl-copy --type image/png < "$file"']]
)
hl.bind(
  mainMod .. " + SHIFT + P",
  hl.dsp.exec_cmd [[sh -c 'dir="$HOME/Pictures/Screenshots"; mkdir -p "$dir" && file="$dir/$(date +%Y-%m-%d_%H-%M-%S_%N).png" && grim "$file" && wl-copy --type image/png < "$file"']]
)
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd "thunar")
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd "emacsclient -c")
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd "alacritty")

hl.bind(mainMod .. " + H", hl.dsp.focus { direction = "left" })
hl.bind(mainMod .. " + L", hl.dsp.focus { direction = "right" })
hl.bind(mainMod .. " + K", hl.dsp.focus { direction = "up" })
hl.bind(mainMod .. " + J", hl.dsp.focus { direction = "down" })

hl.bind(mainMod .. " + G", hl.dsp.window.float { action = "toggle" })
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen { mode = "fullscreen", action = "toggle" })
hl.bind(mainMod .. " + Q", hl.dsp.window.close())

hl.bind(mainMod .. " + Tab", hl.dsp.focus { workspace = "previous" })
hl.bind(mainMod .. " + SHIFT + Tab", hl.dsp.window.move { workspace = "previous" })
hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special "magic")
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move { workspace = "special:magic" })
for i = 1, 6 do
  hl.bind(mainMod .. " + " .. i, hl.dsp.focus { workspace = i })
  hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move { workspace = i })
end

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus { workspace = "e+1" })
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus { workspace = "e-1" })

hl.bind(mainMod .. " + D", hl.dsp.submap "display")
hl.define_submap("display", function ()
  hl.bind("escape", hl.dsp.submap "reset")
  for i, v in ipairs(monitors) do
    hl.bind(tostring(i), v)
  end
end)

hl.bind(mainMod .. " + Right", hl.dsp.exec_cmd "playerctl next", { locked = true })
hl.bind(mainMod .. " + Left", hl.dsp.exec_cmd "playerctl previous", { locked = true })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd "playerctl play-pause", { locked = true })
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
hl.bind(mainMod .. " + Up", hl.dsp.exec_cmd "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 6%+", { locked = true })
hl.bind(mainMod .. " + Down", hl.dsp.exec_cmd "wpctl set-volume @DEFAULT_AUDIO_SINK@ 6%-", { locked = true })

hl.bind(
  "XF86AudioRaiseVolume",
  hl.dsp.exec_cmd "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 6%+",
  { locked = true, repeating = true }
)
hl.bind(
  "XF86AudioLowerVolume",
  hl.dsp.exec_cmd "wpctl set-volume @DEFAULT_AUDIO_SINK@ 6%-",
  { locked = true, repeating = true }
)
hl.bind(
  "XF86AudioMute",
  hl.dsp.exec_cmd "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
  { locked = true, repeating = true }
)
hl.bind(
  "XF86AudioMicMute",
  hl.dsp.exec_cmd "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle",
  { locked = true, repeating = true }
)
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd "brightnessctl -e4 -n2 set 5%+", { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd "brightnessctl -e4 -n2 set 5%-", { locked = true, repeating = true })

hl.bind("XF86AudioNext", hl.dsp.exec_cmd "playerctl next", { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd "playerctl play-pause", { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd "playerctl play-pause", { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd "playerctl previous", { locked = true })

hl.window_rule {
  name = "fix-xwayland-drags",
  match = {
    class = "^$",
    title = "^$",
    xwayland = true,
    float = true,
    fullscreen = false,
    pin = false,
  },
  no_focus = true,
}

hl.window_rule {
  name = "move-hyprland-run",
  match = { class = "hyprland-run" },
  move = "20 monitor_h-120",
  float = true,
}
