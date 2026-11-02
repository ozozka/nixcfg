{ pkgs }:

{
  default = pkgs.mkShell {
    packages = with pkgs; [
      nixd
      lua-language-server
      ty
      marksman
      vscode-langservers-extracted
      bash-language-server
    ];
  };
}
