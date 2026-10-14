# _env.bash — the one PATH bootstrap every tmux-spawned script shares.
# tmux hands `#()` children the server's env, whose PATH can be minimal
# (a non-login start); append the standard bins so date/awk/jq/tmux resolve.
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
