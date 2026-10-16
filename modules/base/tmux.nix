_:

{
  programs.tmux = {
    enable = true;

    terminal = "tmux-256color";
    secureSocket = true;
    keyMode = "vi";
    historyLimit = 6000;
    escapeTime = 0;
    clock24 = true;
    baseIndex = 1;
    aggressiveResize = true;

    extraConfig = ''
      set -g default-terminal "tmux-256color"
      set -ga terminal-overrides ",*:Tc"
      set -ga terminal-overrides ",xterm-256color:Tc"
      set -sa terminal-features ',xterm-256color:RGB'
      set -sa terminal-features ',tmux-256color:RGB'
      set -sa terminal-features ",foot:RGB"
      set -sa terminal-features ",foot-direct:RGB"

      %hidden f1="colour15"
      %hidden b2="colour0"
      %hidden b3="colour233"

      set -g mouse on
      set -g history-limit 6000
      set -g display-time 0
      set -g base-index 1
      set -g pane-base-index 1
      set -g renumber-windows on
      set -g automatic-rename off
      set -g allow-rename off
      set -g aggressive-resize on
      set -g scroll-on-clear on
      set -g status-keys vi
      set -g mode-keys vi
      set -g focus-events on
      set -g exit-empty off

      set -s extended-keys on
      set -g extended-keys-format csi-u
      set-environment -g LC_CTYPE "en_US.UTF-8"
      set-environment -g LANG "en_US.UTF-8"

      set -g pane-border-style                fg=$b2
      set -g pane-active-border-style         fg=$b2
      set -g message-style                    bg=$b2,fg=red
      set -g message-command-style            bg=$b2,fg=cyan
      set -g mode-style                       bg=$b3
      set -g copy-mode-match-style            bg=$b2
      set -g copy-mode-current-match-style    bg=$b3
      set -g status-style                     bg=$b2,fg=$f1
      set -g popup-style                      bg=$b2
      set -g popup-border-style               bg=$b2,fg=$b2

      set -g status-interval 1
      set -g status-position bottom
      set -g status-right "#(git status --porcelain 2>/dev/null | wc -l | grep -q '^0$' || echo '*')#(git branch --show-current 2>/dev/null) #[fg=cyan]#S #[fg=red]#H "
      set -g status-left '#{window_list}'
      set -g window-status-separator ""
      set -g window-status-format ' #I:#W '
      set -g window-status-current-format '#[bg=#{b3}] #I:#W '


      set -g escape-time 0
      set -g assume-paste-time 0
      set -g prefix None
      unbind -a
      unbind -T copy-mode-vi MouseDragEnd1Pane

      bind -n M-0         send C-l \; run "sleep 0" \; clearhist \; send just \; send Enter
      bind -n M-a         send just \; send Enter
      bind -n M-i         send "exec nix develop" \; send Enter
      bind -n M-c         send C-l \; run "sleep 0" \; clearhist

      bind -n M-\"        lastp
      bind -n M-h         selectp -L
      bind -n M-j         selectp -D
      bind -n M-k         selectp -U
      bind -n M-l         selectp -R
      bind -n M-H         resizep -L
      bind -n M-J         resizep -D
      bind -n M-K         resizep -U
      bind -n M-L         resizep -R
      bind -n M-f         resizep -Z
      bind -n M-?         breakp
      bind -n M-O         rotatew -D
      bind -n M-o         rotatew
      bind -n M-m         selectp -m
      bind -n M-g         swapp
      bind -n M--         splitw -h -c "#{pane_current_path}"
      bind -n M-|         splitw -b -c "#{pane_current_path}"
      bind -n M-S--       splitw -h -c "#{pane_current_path}" "nix develop"
      bind -n M-S-|       splitw -b -c "#{pane_current_path}" "nix develop"
      bind -n M-q         killp

      bind -n M-Tab       last
      bind -n M-1         selectw -t :=1
      bind -n M-2         selectw -t :=2
      bind -n M-3         selectw -t :=3
      bind -n M-4         selectw -t :=4
      bind -n M-5         selectw -t :=5
      bind -n M-6         selectw -t :=6
      bind -n M-7         selectw -t :=7
      bind -n M-8         selectw -t :=8
      bind -n M-9         selectw -t :=9
      bind -n M-Left      selectw -t :-1
      bind -n M-Right     selectw -t :+1
      bind -n M-S-Left    swapw -dt :-1
      bind -n M-S-Right   swapw -dt :+1
      bind -n M-n         command-prompt -I "#W" { renamew "%%" }
      bind -n M-S-Enter   neww "nix develop"
      bind -n M-Enter     neww
      bind -n M-Q         killw

      bind -n M-r         refresh
      bind -n M-<         switchc -l
      bind -n M-Down      switchc -p
      bind -n M-Up        switchc -n
      bind -n M-s         choose-tree -Zs
      bind -n M-S         choose-client -Z
      bind -n M-Escape    detach

      bind -n M-w         copy-mode
      bind -n M-,         command-prompt
    '';
  };
}
