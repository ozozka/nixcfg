self:

{ config, pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };
  searxPort = 8888;

  # One short command for the web skill and permission rules; queries run in parallel.
  webSearch = pkgs.writeShellApplication {
    name = "web-search";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      usage() {
        echo "Usage: web-search [-t day|week|month|year] [-n count] query..." >&2
        echo "Each query is a separate search; results are CSV lines: title,url,content,host,engine,score,type" >&2
      }

      count=10
      filters=()
      while getopts "t:n:h" opt; do
        case $opt in
          t) filters+=(-d "time_range=$OPTARG") ;;
          n) count=$OPTARG ;;
          *) usage; exit 2 ;;
        esac
      done
      shift $((OPTIND - 1))
      if [ $# -eq 0 ]; then usage; exit 2; fi

      results=$(mktemp -d)
      trap 'rm -rf "$results"' EXIT

      i=0
      for query in "$@"; do
        curl -sf --max-time 20 --get "http://127.0.0.1:${toString searxPort}/search" \
          --data-urlencode "q=$query" -d format=csv "''${filters[@]}" >"$results/$i" &
        i=$((i + 1))
      done
      wait || true

      i=0
      for query in "$@"; do
        echo "# $query"
        if [ -s "$results/$i" ]; then
          tail -n +2 "$results/$i" | head -n "$count"
        else
          echo "(no results; SearXNG unreachable or every engine failed)"
        fi
        i=$((i + 1))
      done
    '';
  };
in
{
  imports = with self.nixosModules; [
    home
    options
  ];

  # Local metasearch for agents: queries several engines, so one engine throttling or
  # asking for a CAPTCHA does not stop search.
  services.searx = {
    enable = true;
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = searxPort;
        # Required by SearXNG; it signs only local cookies and image proxy URLs.
        secret_key = "ozozka-local-searxng";
      };
      # CSV keeps agent context small: one line per result.
      search.formats = [
        "html"
        "csv"
        "json"
      ];
    };
  };

  # Browser CLI for agents: reads pages over HTTP and drives Chromium when needed.
  environment.systemPackages = [
    pkgs.agent-browser
    webSearch
  ];

  ozozka.home.profiles.web.files.".agent-browser"."config.json" =
    settingsFormat.generate "agent-browser.json"
      {
        # The package does not wire a browser.
        executablePath = "${pkgs.chromium}/bin/chromium";
        # A visible window shows what agents do; `--headed false` for a single run.
        headed = true;
        # Own window class, so Hyprland places it on its workspace.
        args = "--class=agent-browser";
        # Headed browsers otherwise stay open until closed.
        idleTimeout = "30m";
        colorScheme = if config.ozozka.col.isDark then "dark" else "light";
        # Marks page text as untrusted against prompt injection.
        contentBoundaries = true;
        maxOutput = 40000;
      };
}
