_: pkgs:

{
  default = pkgs.mkShell {
    packages = with pkgs; [
      nixd
      emmylua-ls
      ty
      marksman
      vscode-langservers-extracted
      bash-language-server
    ];
  };
}
