_:

{ pkgs, ... }:

{
  environment = {
    shellAliases = {
      loc = "scc -s lines --no-size --no-cocomo && github-linguist";
      locd = "scc -s lines -a -p --sloccount-format";
      locf = "scc -s lines -a -p --sloccount-format --by-file";
    };

    systemPackages = with pkgs; [
      scc
      github-linguist

      bash-language-server
      vscode-langservers-extracted
      docker-language-server
      just-lsp
      marksman
      sqls
      yaml-language-server
      nixd
      rust-analyzer
      emmylua-ls
      ty
    ];
  };
}
