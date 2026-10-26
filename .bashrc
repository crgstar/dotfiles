# why: .zshrc と同じく対話シェル専用。.bash_profile 経由で非対話のログインシェル (bash -lc) から
#      読まれても bind 等が警告を出さないようにする（素の bash -c はそもそも .bashrc を読まない）
[[ $- == *i* ]] || return

[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
# why: brew の curl は keg-only でリンクされず、素の curl は macOS 同梱の古い版になる。CVE 修正の速い brew 版を優先する
[ -d /opt/homebrew/opt/curl/bin ] && export PATH="/opt/homebrew/opt/curl/bin:$PATH"
command -v mise >/dev/null && eval "$(mise activate bash)"
export PATH="$HOME/.local/bin:$PATH"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# abbreviations
# why: bash には Enter 時に展開する仕組みが無いので alias で代替する（履歴には展開前の語が残る）
alias cl="claude"
alias ｃｌ="claude"
alias じ="zi"
alias ime-dict="open /Library/Input\ Methods/GoogleJapaneseInput.app/Contents/Resources/DictionaryTool.app"

# Claude Code: ちらつき防止（alt-screen レンダリング）
export CLAUDE_CODE_NO_FLICKER=1

# history
HISTSIZE=50000
HISTFILESIZE=50000
# why: erasedups はメモリ上の履歴から重複を消すだけで、history -a で追記した HISTFILE には重複が残る
HISTCONTROL=erasedups
HISTTIMEFORMAT='%F %T '             # タイムスタンプ付き
shopt -s histappend
# why: zsh の SHARE_HISTORY 相当。プロンプトごとに追記して複数タブで共有する
#      （他タブの履歴は history -n を打つか新しいシェルで読まれる）
# why 重複ガード: source ~/.bashrc で読み直すたびに同じフックが積み増されないようにする
[[ "$PROMPT_COMMAND" == *"history -a"* ]] \
  || PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# bat
# why: man を色付きで読みたい。bat 側でパイプ時は自動でプレーンになる
command -v bat >/dev/null && export MANPAGER="sh -c 'col -bx | bat -l man -p'"
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
# why: fzf 0.48+ の bash 統合。Ctrl-T / Ctrl-R / Alt-C を有効化
command -v fzf >/dev/null && eval "$(fzf --bash)"

# zoxide
# why: z 移動時に行き先を表示してマッチ違いに即気づけるようにする
export _ZO_ECHO=1
export _ZO_MAXAGE=10000
export _ZO_FZF_OPTS="$FZF_DEFAULT_OPTS --no-sort --keep-right"
command -v zoxide >/dev/null && eval "$(zoxide init bash)"

# completion
bind 'set completion-ignore-case on'   # 大小文字無視
bind 'set colored-stats on'            # 色付き

# cmux のワークスペースに、cwd の git リポジトリ名から決めた色を着ける。
# シェル起動時と、cd でリポジトリを跨いだときに追従する。
#
# why PROMPT_COMMAND: bash には zsh の chpwd フックが無い。プロンプトごとに呼ぶが、
#   $PWD が変わっていなければ文字列比較だけで抜けるので git は叩かない
# why ( ... & ): cmux CLI を 2 回叩くので、前景で待つとプロンプト表示が数十 ms 伸びる。
#   サブシェル内でバックグラウンド化して、ジョブ完了通知も出さない
if [[ -n "$CMUX_WORKSPACE_ID" ]] && command -v cmux-workspace-color >/dev/null; then
  # why 初期値を空文字にしない: 「非 git ディレクトリで起動した」ケースと区別が
  #   付かず、起動直後の 1 回が走らなくなる。実パスに現れない値を置く
  #   （zsh 版は $'\0' だが、bash の変数は NUL を保持できず空文字になる）
  _CMUX_COLOR_ROOT=$'\x01'
  _CMUX_COLOR_PWD=

  _cmux_workspace_color() {
    # why $PWD の変化を先に見る: 下のリポジトリ前方一致は git 管理下でしか効かず、
    #   非 git ディレクトリ ($HOME 等) に居る間は Enter のたびに git を起動してしまう。
    #   chpwd 相当に「移動したときだけ」動かす
    [[ "$PWD" == "$_CMUX_COLOR_PWD" ]] && return
    _CMUX_COLOR_PWD="$PWD"
    # why -n を先に見る: 非 git ディレクトリへ移動すると _CMUX_COLOR_ROOT は空になり、
    #   前方一致のパターンが `/*` に縮んで**すべての絶対パス**に当たる
    if [[ -n "$_CMUX_COLOR_ROOT" ]] \
       && [[ "$PWD" == "$_CMUX_COLOR_ROOT" || "$PWD" == "$_CMUX_COLOR_ROOT"/* ]]; then
      return
    fi
    local root
    root="$(command git rev-parse --show-toplevel 2>/dev/null)"
    # why 解決結果が前と同じなら何もしない: 非 git ディレクトリ間の移動で毎回 cmux CLI を起動しないため
    [[ "$root" == "$_CMUX_COLOR_ROOT" ]] && return
    _CMUX_COLOR_ROOT="$root"
    (cmux-workspace-color >/dev/null 2>&1 &)
  }

  [[ "$PROMPT_COMMAND" == *_cmux_workspace_color* ]] \
    || PROMPT_COMMAND="_cmux_workspace_color; $PROMPT_COMMAND"
fi

# 環境別の追加設定を読み込む
[[ -f "$HOME/.bashrc.local" ]] && source "$HOME/.bashrc.local"
