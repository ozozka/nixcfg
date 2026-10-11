{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.ozozka.mod.hardware.nvidia;
in
{
  options.ozozka.mod.hardware.nvidia = {
    integratedGpuPrimary = lib.mkEnableOption "integratedPrimary";
  };

  config = {
    nixpkgs.config.allowUnfreePackages = [
      "nvidia-x11"
      "nvidia-settings"
    ];

    nix.settings = {
      substituters = [ "https://cache.nixos-cuda.org" ];
      trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
    };

    services = {
      xserver.videoDrivers = [ "nvidia" ];
      udev.extraRules = ''
        SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="nvidia", SYMLINK+="dri/by-driver/nvidia-card"
        SUBSYSTEM=="drm", KERNEL=="card*", DRIVERS=="i915", SYMLINK+="dri/by-driver/intel-card"
      '';
    };

    # boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_drm" "nvidia_uvm" ];

    hardware = {
      graphics = {
        enable = true;
        enable32Bit = pkgs.stdenv.hostPlatform.isx86_64;
      };

      nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.latest;
        open = true;
        nvidiaSettings = true;
        nvidiaPersistenced = !cfg.integratedGpuPrimary;
        modesetting.enable = true;
        powerManagement = {
          enable = true;
          finegrained = cfg.integratedGpuPrimary;
        };
        prime = {
          intelBusId = "PCI:0:2:0";
          nvidiaBusId = "PCI:1:0:0";
          offload = {
            enable = cfg.integratedGpuPrimary;
            enableOffloadCmd = cfg.integratedGpuPrimary;
          };
        };
      };
    };

    systemd.services.nvidia-uvm = {
      description = "Load NVIDIA UVM module for CUDA";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/modprobe nvidia_uvm";
        RemainAfterExit = true;
      };
    };

    environment.sessionVariables = {
      AQ_DRM_DEVICES =
        if cfg.integratedGpuPrimary then
          "/dev/dri/by-driver/intel-card:/dev/dri/by-driver/nvidia-card"
        else
          "/dev/dri/by-driver/nvidia-card:/dev/dri/by-driver/intel-card";
    };
  };
}
