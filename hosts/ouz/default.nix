self:

self.inputs.nixpkgs.lib.nixosSystem {
  modules = with self.nixosModules; [
    ./hardware-configuration.nix

    base
    desktop
    dev

    hardware-brightness
    hardware-nvidia
    hardware-swap
    hardware-wifi
    hardware-bluetooth
    hardware-ppd

    # gui-obs
    gui-gimp
    gui-steam
    gui-office

    {
      system.stateVersion = "25.11";
      networking.hostName = "ouz";

      specialisation = {
        mobile = {
          inheritParentConfig = true;
          configuration = {
            system.nixos.tags = [ "mobile" ];

            ozozka.mod = {
              desktop.hypr.mirrorIntegratedMonitor = true;
              hardware.nvidia.integratedGpuPrimary = true;
            };
          };
        };
      };

      fileSystems."/ozozka" = {
        device = "/dev/disk/by-uuid/75bc2a26-dd71-4dde-b1ed-1bb86246bde4";
        fsType = "ext4";
      };

      environment.sessionVariables = {
        KAYNAK_HOME = "/ozozka/al/kaynak";
      };

      users.users.ouz = {
        isNormalUser = true;
        description = "ouz";
        extraGroups = [
          "networkmanager"
          "wheel"
        ];
      };

      ozozka = {
        mod = {
          desktop = {
            music = {
              user = "ouz";
              directory = "/ozozka/at/muz";
            };
          };
        };
        home.users = {
          ouz = {
            claude = true;
            pi = true;
            web = true;
          };
        };
      };
    }
  ];
}
