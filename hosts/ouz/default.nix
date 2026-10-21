{ inputs }:

inputs.nixpkgs.lib.nixosSystem {
  modules = with inputs.self.nixosModules; [
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

      users.users.ouz = {
        isNormalUser = true;
        description = "ouz";
        extraGroups = [
          "networkmanager"
          "wheel"
        ];
      };

      ozozka.home.users = {
        ouz = {
          emacs = true;
          pi = true;
        };
      };
    }
  ];
}
