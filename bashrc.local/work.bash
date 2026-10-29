# work 環境固有の設定
export PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"
if command -v direnv >/dev/null; then eval "$(direnv hook bash)"; fi
