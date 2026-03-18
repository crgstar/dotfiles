eval "$(mise activate zsh)"
export PATH="$HOME/.local/bin:$PATH"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# abbreviations (Enter時に展開して実行)
typeset -A abbreviations
abbreviations=(
  "cl" "claude"
)

expand-abbreviation() {
  local first_word="${BUFFER%% *}"
  local expanded="${abbreviations[$first_word]}"
  if [[ -n "$expanded" ]]; then
    BUFFER="${expanded}${BUFFER#$first_word}"
  fi
  zle accept-line
}
zle -N expand-abbreviation
bindkey '^M' expand-abbreviation

# 環境別の追加設定を読み込む
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
