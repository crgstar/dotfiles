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

# bat
# why: man を色付きで読みたい。bat 側でパイプ時は自動でプレーンになる
export MANPAGER="sh -c 'col -bx | bat -l man -p'"
export BAT_THEME="TwoDark"

# fzf
# why: 既定オプション・ファイル/ディレクトリ選択時のプレビューを集約
export FZF_DEFAULT_OPTS='
  --height=60% --layout=reverse --border=rounded
  --bind=ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down
'
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always {} 2>/dev/null'"
# why: ? で長い履歴コマンドの全文をトグル表示
export FZF_CTRL_R_OPTS="--preview 'echo {}' --preview-window=down:3:hidden:wrap --bind='?:toggle-preview'"
# why: fzf 0.48+ の zsh 統合。Ctrl-T / Ctrl-R / Alt-C を有効化
source <(fzf --zsh)

# zoxide
# why: z 移動時に行き先を表示してマッチ違いに即気づけるようにする
export _ZO_ECHO=1
export _ZO_MAXAGE=10000
export _ZO_FZF_OPTS="$FZF_DEFAULT_OPTS --no-sort --keep-right"
eval "$(zoxide init zsh)"

# completion
# why: compinit は重いので一度だけ。fzf-tab はこの後に source する
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # 大小文字無視
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"    # 色付き
zstyle ':completion:*:descriptions' format '[%d]'          # グループ見出し（fzf-tab 前提）
zstyle ':completion:*' menu no                             # fzf-tab がフックを取れるよう標準メニューは無効
zstyle ':completion:*:git-checkout:*' sort false           # git branch の最新順を維持

# fzf-tab
# why: 補完候補を fzf 化。プレビューは cd/ファイル/kill/変数 をそれぞれ最適化
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' switch-group '<' '>'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:complete:*:*' fzf-preview \
  '[[ -d $realpath ]] && eza -1 --color=always $realpath || bat -n --color=always --line-range :500 $realpath 2>/dev/null'
zstyle ':completion:*:*:*:*:processes' command 'ps -u $USER -o pid,user,comm -w'
zstyle ':fzf-tab:complete:(kill|ps):argument-rest' fzf-preview \
  '[[ $group == "[process ID]" ]] && ps -p $word -o command'
zstyle ':fzf-tab:complete:(kill|ps):argument-rest' fzf-flags --preview-window=down:3:wrap
zstyle ':fzf-tab:complete:(-command-|-parameter-|-brace-parameter-|export|unset|expand):*' \
  fzf-preview 'echo ${(P)word}'
source ~/projects/fzf-tab/fzf-tab.plugin.zsh

# 環境別の追加設定を読み込む
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
