fish_add_path ~/.local/bin ~/bin

if test -x /home/linuxbrew/.linuxbrew/bin/brew
    eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)
end

alias ls='eza --icons --group-directories-first --color=always'
alias ll='eza --icons --group-directories-first --color=always -lh --git'
alias la='eza --icons --group-directories-first --color=always -lha --git'
alias tree='eza --icons --tree --color=always'

alias cat='bat --pager=never'
set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"

alias grep='grep --color=auto'
alias diff='diff --color=auto'

set -gx GIT_PAGER delta

alias lg='lazygit'

# Gamescope at the primary monitor's current mode, RT scheduling, async flips, MangoApp overlay
function gcs2
    set -l mode (kscreen-doctor -j | jq -r '.outputs[] | select(.priority == 1) | .currentModeId as $m | .modes[] | select(.id == $m) | "\(.size.width) \(.size.height) \(.refreshRate | round)"' | string split ' ')
    gamescope -W $mode[1] -H $mode[2] -r $mode[3] --rt --immediate-flips --mangoapp -e -- $argv
end

alias rice="$HOME/scripts/rice-start.sh"
alias sysinfo="$HOME/scripts/sysinfo.sh"

zoxide init fish | source

command -q mise; and mise activate fish | source

starship init fish | source
