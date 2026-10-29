{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [
    ../options.nix

    ./nvim
    ./console.nix
    ./git.nix
    ./network.nix
    ./tmux.nix
  ];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    loader = {
      efi.canTouchEfiVariables = true;
      timeout = 3;
      systemd-boot = {
        enable = true;
        editor = false;
        configurationLimit = 6;
        consoleMode = "auto";
      };
    };
  };

  nix = {
    # firewall.enable = true;
    # sshServe.enable = true;
    checkAllErrors = true;
    checkConfig = true;
    # daemonCPUSchedPolicy = "other";

    settings = {
      auto-optimise-store = true;
      cores = 0;
      max-jobs = "auto";
      sandbox = true;

      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    optimise = {
      automatic = true;
      persistent = true;
      dates = "weekly";
    };

    gc = {
      automatic = true;
      persistent = true;
      dates = "weekly";
      options = "--delete-older-than 6d";
    };
  };

  systemd.enableStrictShellChecks = true;

  time.timeZone = "Europe/Istanbul";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocales = [ "tr_TR.UTF-8/UTF-8" ];
    extraLocaleSettings = {
      LC_ADDRESS = "tr_TR.UTF-8";
      LC_IDENTIFICATION = "tr_TR.UTF-8";
      LC_MEASUREMENT = "tr_TR.UTF-8";
      LC_MONETARY = "tr_TR.UTF-8";
      LC_NAME = "tr_TR.UTF-8";
      LC_NUMERIC = "tr_TR.UTF-8";
      LC_PAPER = "tr_TR.UTF-8";
      LC_TELEPHONE = "tr_TR.UTF-8";
      LC_TIME = "tr_TR.UTF-8";
    };
  };

  services = {
    # fwupd.enable = true; # Firmware/bios updates.

    xserver.xkb = {
      layout = cfg.keyboard.layout;
      options = cfg.keyboard.options;
    };
  };

  programs = {
    nix-ld = {
      enable = true;
      # libraries = with pkgs; [];
    };

    gnupg.agent = {
      enable = true;
      enableBrowserSocket = false;
      enableExtraSocket = false;
      enableSSHSupport = false;
      pinentryPackage = pkgs.pinentry-curses;
      settings = {
        default-cache-ttl = 600;
        max-cache-ttl = 7200;
      };
    };

    direnv = {
      enable = true;
      nix-direnv.enable = true;
      settings = {
        global = {
          hide_env_diff = true;
          warn_timeout = "5m";
          log_format = "";
        };
      };
    };

    bash = {
      enable = true;
      shellInit = ''
        shopt -s histappend
        shopt -s cmdhist
      '';
      promptInit = ''
        PS1='\[\033[36m\]\w\[\033[31m\] \$ \[\033[00m\]'
        PS2='\[\033[31m\]> \[\033[00m\]'
      '';
    };
  };

  environment = {
    localBinInPath = true;

    shellAliases = {
      l = "LC_COLLATE=C ls -ACx --group-directories-first --color=auto"; # -F (symbols), -x
      c = "printf '\\033c'";
      nd = "exec nix develop";
      nf = "nix flake";
      n = "f() { nix run \".#$1\" -- \"\${@:2}\"; }; f";
      j = "just";
    };

    variables = {
      HISTSIZE = 6000;
      HISTFILESIZE = 6000;
      HISTIGNORE = "l:exit:clear:history";
      HISTCONTROL = "ignoreboth:erasedups";
    };

    systemPackages = with pkgs; [
      libarchive
      wget
      fd
      ripgrep
      just
    ];
  };
}
