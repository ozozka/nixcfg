self:

{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [ self.nixosModules.options ];

  environment = {
    systemPackages = [
      pkgs.gh
      # A command rather than an alias, so non-interactive shells have it too.
      (pkgs.writeShellScriptBin "g" ''exec git "$@"'')
    ];

    sessionVariables = {
      GH_TELEMETRY = "0";
    };
  };

  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      user = {
        name = cfg.user.fullname;
        email = cfg.user.email;
      };

      alias = {
        s = "status --short --branch";
        l = "log --oneline -6";
        ld = "log --oneline --graph --decorate --all";
        i = "diff --stat";
        ch = "diff --check";
      };

      diff.tool = "nvimdiff";
      difftool.nvimdiff.cmd = ''nvim -d "$LOCAL" "$REMOTE"'';
      difftool = {
        prompt = false;
        trustExitCode = true;
      };

      merge.tool = "nvimdiff";
      mergetool.nvimdiff.cmd = ''nvim -d "$LOCAL" "$BASE" "$REMOTE" "$MERGED"'';
      mergetool = {
        prompt = false;
      };
    };
  };
}
