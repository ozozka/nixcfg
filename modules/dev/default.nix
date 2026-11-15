_:

{ pkgs, ... }:

let
  # Commands rather than aliases, so non-interactive shells have them too. Arguments go where
  # the aliases appended them.
  lineCounts = pkgs.lib.mapAttrsToList pkgs.writeShellScriptBin {
    loc = ''${pkgs.scc}/bin/scc -s lines --no-size --no-cocomo && exec ${pkgs.github-linguist}/bin/github-linguist "$@"'';
    locd = ''exec ${pkgs.scc}/bin/scc -s lines -a -p --sloccount-format "$@"'';
    locf = ''exec ${pkgs.scc}/bin/scc -s lines -a -p --sloccount-format --by-file "$@"'';
  };
in
{
  environment = {
    systemPackages =
      lineCounts
      ++ (with pkgs; [
        scc
        github-linguist

        typescript-language-server
        tinymist
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
      ]);
  };
}
