{ pkgs, ... }:

rec {
  default = info;

  wallpaper = {
    type = "app";
    meta.description = "AI-upscale an image to a 4K wallpaper.";
    program =
      let
        script = pkgs.writeShellApplication {
          name = "wallpaper";
          runtimeInputs = with pkgs; [
            coreutils
            realesrgan-ncnn-vulkan
            imagemagick
            ffmpeg
          ];
          text = ''
            die() {
              printf 'wallpaper: %s\n' "$*" >&2
              exit 1
            }

            if [[ $# -ne 2 ]]; then
              die "Usage: wallpaper INPUT OUTPUT.jpg (or OUTPUT.png)"
            fi

            [[ -f "$1" && -r "$1" ]] || die "Input must be a readable image file."
            input=$(realpath -- "$1")
            output=$(realpath -m -- "$2")
            [[ "$input" != "$output" ]] || die "Input and output must be different files."
            [[ ! -e "$2" && ! -L "$2" ]] || die "Output already exists; refusing to overwrite it."
            [[ -d "$(dirname -- "$output")" ]] || die "Output directory does not exist."

            case "''${output,,}" in
              *.jpg|*.jpeg) format=jpg ;;
              *.png) format=png ;;
              *) die "Output must have a .jpg, .jpeg, or .png extension." ;;
            esac

            # Keep the final temporary file on the output filesystem so publishing
            # it with a hard link is atomic and cannot overwrite another file.
            work=$(mktemp -d -- "$(dirname -- "$output")/.wallpaper.XXXXXXXX")
            trap 'rm -rf -- "$work"' EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            printf 'Preparing image…\n'
            magick "''${input}[0]" -auto-orient -colorspace sRGB -background black \
              -alpha remove -alpha off -depth 8 "PNG24:$work/input.png"

            printf 'Upscaling 4× with Real-ESRGAN x4plus (Vulkan required)…\n'
            if ! realesrgan-ncnn-vulkan -i "$work/input.png" -o "$work/upscaled.png" \
              -n realesrgan-x4plus -s 4; then
              die "AI upscaling failed. Check Vulkan drivers and GPU availability."
            fi

            printf 'Resizing to 3840×2160 without stretching…\n'
            magick "$work/upscaled.png" -filter Lanczos -resize '3840x2160^' \
              -gravity center -extent 3840x2160 -depth 8 "PNG24:$work/4k.png"

            if [[ "$format" == jpg ]]; then
              ffmpeg -hide_banner -loglevel warning -n -i "$work/4k.png" \
                -frames:v 1 -c:v mjpeg -q:v 1 -pix_fmt yuvj444p -update 1 "$work/result.jpg"
            else
              magick "$work/4k.png" -define png:compression-level=9 "PNG24:$work/result.png"
            fi

            dimensions=$(magick identify -format '%wx%h' "$work/result.$format")
            [[ "$dimensions" == 3840x2160 ]] || die "Unexpected output dimensions: $dimensions"
            ln -T -- "$work/result.$format" "$output" || die "Could not publish output; nothing was overwritten."
            printf 'Saved %s (%s). Original unchanged.\n' "$output" "$dimensions"
            if [[ "$format" == jpg ]]; then
              printf 'JPEG uses maximum quality and 4:4:4 chroma, but is not lossless.\n'
            fi
          '';
        };
      in
      "${script}/bin/wallpaper";
  };

  info = {
    type = "app";
    meta.description = "Run fastfetch with custom modules.";
    program =
      let
        lockLastModified = toString (builtins.fromJSON (builtins.readFile ./flake.lock))
          .nodes.nixpkgs.locked.lastModified;
        script = pkgs.writeShellApplication {
          name = "info";

          runtimeInputs = with pkgs; [
            fastfetch
            nix
            coreutils
            gawk
          ];

          text = ''
            lock_age_seconds=$(( $(date +%s) - ${lockLastModified} ))
            lock_age_days=$(( lock_age_seconds / 86400 ))
            lock_age_hours=$(( lock_age_seconds % 86400 / 3600 ))
            if (( lock_age_days > 0 )); then
              lock_age="''${lock_age_days}d ''${lock_age_hours}h"
            else
              lock_age="''${lock_age_hours}h"
            fi

            generation=$(readlink /nix/var/nix/profiles/system)
            generation="''${generation#system-}"
            generation="''${generation%-link}"

            shopt -s nullglob
            generations=(/nix/var/nix/profiles/system-*-link)
            retained_generations="''${#generations[@]}"

            count=$(nix-store -qR /run/current-system | wc -l)
            size=$(nix path-info -Sh /run/current-system | awk '{print $2}')

            cat <<EOF | fastfetch -c -
            {
              "logo": {
                "position": "top"
              },
              "modules": [
                "version",
                "title",

                "break",
                {"type": "custom", "format": "{#1}Status{#}", "outputColor": "red"},
                "uptime",
                "player",
                "sound",
                "bluetoothradio",
                "bluetooth",
                {"type": "publicip", "timeout": 1000},
                {"type": "localip", "showIpv6": true, "showMac": true, "showSpeed": true, "showMtu": true, "showLoop": true, "showFlags": true, "showAllIps": true},
                "dns",
                "wifi",
                {"type": "codec", "splitGPU": true},
                "physicalmemory",
                "vulkan",
                "opengl",
                "opencl",
                {"type": "swap", "separate": true},
                "disk",
                {"type": "battery", "temp": true},

                "break",
                {"type": "custom", "format": "{#1}Hardware{#}", "outputColor": "red"},
                "camera",
                "gamepad",
                "mouse",
                "keyboard",
                "monitor",
                {"type": "gpu", "driverSpecific": true},
                "cpucache",
                {"type": "cpu", "showPeCoreCount": true},
                "memory",
                "poweradapter",
                "physicaldisk",
                
                "break",
                {"type": "custom", "format": "{#1}Desktop{#}", "outputColor": "red"},
                "cursor",
                "wallpaper",
                "font",
                "icons",
                "theme",
                "wmtheme",
                "wm",
                "de",
                "lm",
                "brightness",
                "display",
                {"type": "colors", "symbol": "block", "block": {"width": 3}},

                "break",
                {"type": "custom", "format": "{#1}Environment{#}", "outputColor": "red"},
                "terminalfont",
                "terminaltheme",
                "terminalsize",
                "editor",
                "locale",
                "shell",
                "terminal",
                "users",
                
                "break",
                { "type": "custom", "format": "{#1}System{#}", "outputColor": "red" },
                "tpm",
                "initsystem",
                "os",
                "kernel",
                "bootmgr",
                "bios",
                "board",
                "host",
                "chassis",
                
                "break",
                {"type": "custom", "format": "{#1}Packages{#}", "outputColor": "red"},
                {"type": "custom", "key": "Lock Age", "format": "$lock_age"},
                {"type": "custom", "key": "Retained Generations", "format": "$retained_generations"},
                {"type": "custom", "key": "Generation", "format": "$generation"},
                "packages",
                {"type": "custom", "key": "Paths", "format": "$count"},
                {"type": "custom", "key": "Store Size", "format": "$size GiB"}
              ]
            }
            EOF
          '';
        };
      in
      "${script}/bin/info";
  };
}
