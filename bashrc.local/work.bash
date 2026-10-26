# work 環境固有の設定
[ -d /opt/homebrew/opt/postgresql@16/bin ] && export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"
if command -v direnv >/dev/null; then eval "$(direnv hook bash)"; fi
