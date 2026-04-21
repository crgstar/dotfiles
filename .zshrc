eval "$(/opt/homebrew/bin/brew shellenv)"
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
  "ｃｌ" "claude"
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

# Claude Code: ちらつき防止（alt-screen レンダリング）
export CLAUDE_CODE_NO_FLICKER=1

# history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY          # 複数タブで共有
setopt HIST_IGNORE_ALL_DUPS   # 重複を全削除
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY       # タイムスタンプ付き

# completion
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # 大小文字無視
zstyle ':completion:*' menu select                          # Tab でメニュー選択
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"     # 色付き

# 環境別の追加設定を読み込む
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
