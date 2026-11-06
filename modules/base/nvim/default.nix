self:

{ pkgs, ... }:

let
  inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) treesitter-runtime;
in
{
  # environment.sessionVariables = {
  #   EDITOR = "nvim";
  #   VISUAL = "nvim";
  #   MANPAGER = "nvim +Man!";
  # };

  programs.neovim = {
    enable = true;
    defaultEditor = false;
    viAlias = true;
    withNodeJs = false;
    withPython3 = false;
    withRuby = false;
    runtime = {
      "init.lua".source = ./init.lua;
      "lua".source = ./lua;
      "lsp".source = ./lsp;
      "colors".source = ./colors;
      "spell".source = ./spell;
      "parser".source = "${treesitter-runtime}/parser";
      "queries".source = "${treesitter-runtime}/queries";
    };
  };
}
