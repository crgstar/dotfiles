# work 環境固有の設定
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"
eval "$(direnv hook zsh)"
