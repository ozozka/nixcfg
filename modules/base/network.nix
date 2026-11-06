_:

_:

{
  networking.networkmanager.enable = true;
  services.resolved = {
    enable = true;
    settings = {
      Resolve = {
        dnssec = "allow-downgrade";
        dnsovertls = "true";
      };
    };
  };
}
