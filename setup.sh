#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# why: Claude / CI から「skills だけ貼り直す」のような部分実行をしたいので、処理を
#      名前付きターゲットに分けて --only で選べるようにする。配列の並びが実行順で、
#      prefixes が claude-settings の生成物 (~/.claude/settings.json) を読むという
#      唯一の順序依存もこの並びで保証する。
TARGETS=(
  "ghostty:Ghostty config (base + env をマージして ~/.config/ghostty/config へ)"
  "bin:bin/ 配下と reflect-extract を ~/.local/bin へ"
  "git:.gitignore_global を ~ へ"
  "shell:.zshrc / zshrc.local/<env>.zsh のリンクと fzf-tab の clone"
  "claude-settings:settings.json を base+common+env でマージして ~/.claude/settings.json へ"
  "claude-md:CLAUDE.md を base+env でマージし、FABLE.md と併せてリンク"
  "skills:スキル・サブエージェント定義のリンク (第三者リポの clone を含む)"
  "hooks:permission 系 hook スクリプトのリンク"
  "statusline:statusLine ラッパと RunCat Neo 用スナップショット生成のリンク"
  "reflect:reflect 無人実行 (SessionEnd hook + launchd 夜間ドライバ)"
  "prefixes:segment-allow.prefixes を permissions.allow から再生成 (claude-settings の後)"
  "mcp:settings.local/<env>.json の mcpServers を ~/.claude.json へマージ"
)

usage() {
  cat <<'EOF'
使い方: ./setup.sh [env] [オプション]

  env             home / work (省略時は各設定の base のみをリンクし、マージは行わない)

オプション:
  --only t1,t2    指定したターゲットだけ実行する (一覧は --list)
  --list          ターゲット一覧を表示して終了
  --force         衝突時にマージ結果 / dotfiles 側を採用する (既存は .bak に退避)
  --keep          衝突時は既存を維持してスキップし、正常終了する
  -h, --help      このヘルプを表示

衝突時の既定は TTY なら対話、非 TTY なら「何も変更せず、最後にまとめて exit 1」。
EOF
}

list_targets() {
  echo "ターゲット一覧 (実行順):"
  local entry
  for entry in "${TARGETS[@]}"; do
    printf '  %-16s %s\n' "${entry%%:*}" "${entry#*:}"
  done
}

# ----- 引数パース -----

HOST_ENV=""
ONLY_TARGETS=""
CONFLICT_MODE=""  # 空 = 自動判定 (TTY なら対話 / 非 TTY なら fail)

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "エラー: --only にターゲットが指定されていません" >&2; exit 1; }
      ONLY_TARGETS="$2"; shift 2 ;;
    --only=*)
      ONLY_TARGETS="${1#--only=}"; shift ;;
    --list)
      list_targets; exit 0 ;;
    --force|--keep)
      # why: 後勝ちで黙って決まると、既存を捨てるつもりが残す (逆も) に化ける。
      #      衝突の解決方針は取り違えると復旧が面倒なので、矛盾指定は即エラーにする。
      _mode="${1#--}"
      if [ -n "$CONFLICT_MODE" ] && [ "$CONFLICT_MODE" != "$_mode" ]; then
        echo "エラー: --force と --keep は同時に指定できません" >&2; exit 1
      fi
      CONFLICT_MODE="$_mode"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "エラー: 不明なオプション '$1'" >&2; usage >&2; exit 1 ;;
    *)
      if [ -n "$HOST_ENV" ]; then
        echo "エラー: 位置引数は env 1 つだけです ('$HOST_ENV' の後に '$1')。ターゲット指定は --only を使ってください" >&2
        exit 1
      fi
      HOST_ENV="$1"; shift ;;
  esac
done

# why: typo (例: `setup.sh hoem`) を「base のみリンクで成功」と誤認させないため、
#      未知の環境名は即エラーにする。有効 env は settings.local/<env>.json から導出する
#      (common は層であって env ではないので除外)。env 未指定 (空) は base のみで従来通り許容。
if [ -n "$HOST_ENV" ]; then
  _valid_envs=""
  for _f in "$DOTFILES_DIR"/.claude/settings.local/*.json; do
    [ -e "$_f" ] || continue
    _name="$(basename "$_f" .json)"
    [ "$_name" = "common" ] && continue
    _valid_envs="$_valid_envs $_name"
  done
  case " $_valid_envs " in
    *" $HOST_ENV "*) ;;
    *) echo "エラー: 未知の環境名 '$HOST_ENV'。有効:$_valid_envs" >&2; exit 1 ;;
  esac
fi

# why: env と同じく、ターゲット名の typo を「何も実行せず成功」で見逃さない。
if [ -n "$ONLY_TARGETS" ]; then
  _known=""
  for _entry in "${TARGETS[@]}"; do
    _known="$_known ${_entry%%:*}"
  done
  IFS=',' read -ra _requested <<< "$ONLY_TARGETS"
  for _t in "${_requested[@]}"; do
    case " $_known " in
      *" $_t "*) ;;
      *) echo "エラー: 未知のターゲット '$_t'。有効:$_known" >&2; exit 1 ;;
    esac
  done
fi

target_enabled() {
  [ -z "$ONLY_TARGETS" ] && return 0
  case ",$ONLY_TARGETS," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

MERGE_TOOL="${MERGE_TOOL:-code --wait --diff}"

# ----- 衝突の解決方針 -----

# why: 未解決の衝突は最後にまとめて報告して exit 1 する。bash 3.2 (macOS 同梱) は
#      set -u 下で空配列の展開が unbound になるため、配列ではなくカウンタと文字列で持つ。
CONFLICT_COUNT=0
CONFLICT_LIST=""

effective_mode() {
  if [ -n "$CONFLICT_MODE" ]; then
    echo "$CONFLICT_MODE"
  elif [ -t 0 ]; then
    echo "ask"
  else
    echo "fail"
  fi
}

# 衝突時の選択を決める
# $1: プロンプト文字列 / $2: --force 時の選択 / $3: --keep 時の選択
# $4: 代入先の変数名 / $5: 対象パス (未解決として報告するときの表示用)
#
# why: 非対話 (Claude / CI) で read は EOF を返し set -e で setup 全体が半構成のまま
#      abort する。既定の fail では「何も壊さない選択」で処理を進めつつ未解決として
#      記録し、全ターゲットを走らせてから exit 1 する。1 回の実行で drift を全部
#      見せるためで、黙って既存維持のまま done! と出す旧挙動を避けるのが目的。
record_unresolved() {
  # $1: 対象パス / $2: 代入先の変数名 / $3: 何も壊さない側の選択
  CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
  CONFLICT_LIST="$CONFLICT_LIST  - $1"$'\n'
  printf -v "$2" '%s' "$3"
}

decide() {
  local prompt="$1" on_force="$2" on_keep="$3" var="$4" target="$5"

  case "$(effective_mode)" in
    ask)
      # why: 対話中の Ctrl-D で read が EOF を返すと、素の呼び出しでは set -e が
      #      発火し、理由も残らないまま setup ごと落ちる。非対話と同じ「何も壊さず
      #      未解決として記録」に倒して、最後のサマリで気づけるようにする。
      if ! read -rp "$prompt" "$var"; then
        printf '\n  [入力が中断されたため未解決として記録]\n'
        record_unresolved "$target" "$var" "$on_keep"
      fi
      ;;
    force)
      printf '%s[--force のため %s を自動選択]\n' "$prompt" "$on_force"
      printf -v "$var" '%s' "$on_force"
      ;;
    keep)
      printf '%s[--keep のため %s を自動選択]\n' "$prompt" "$on_keep"
      printf -v "$var" '%s' "$on_keep"
      ;;
    fail)
      printf '%s[非対話のため未解決として記録 (--force / --keep で明示できます)]\n' "$prompt"
      record_unresolved "$target" "$var" "$on_keep"
      ;;
  esac
}

# マージ生成ファイルの上書き前に既存内容との差分を確認する
# 差分がなければそのまま上書き、差分があればユーザに選択を求める
safe_overwrite() {
  local new_content_file="$1"  # 新しく生成された一時ファイル
  local dest="$2"              # 上書き対象

  if [ ! -f "$dest" ]; then
    mv "$new_content_file" "$dest"
    return
  fi

  if diff -q "$new_content_file" "$dest" > /dev/null 2>&1; then
    # 差分なし — そのまま上書き
    mv "$new_content_file" "$dest"
    return
  fi

  echo ""
  echo "========================================="
  echo "CONFLICT: $dest"
  echo "マージ元にない変更が既存ファイルに含まれています"
  echo "========================================="
  diff -u "$new_content_file" "$dest" || true
  echo "========================================="
  echo ""
  echo "  n) 新しいマージ結果で上書き (既存は .bak に保存)"
  echo "  k) 既存の内容を残す (マージ結果を破棄)"
  echo "  m) マージする ($MERGE_TOOL で編集)"
  echo "  s) スキップ"
  echo ""
  decide "  選択 [n/k/m/s]: " n k choice "$dest"

  case "$choice" in
    n)
      cp "$dest" "${dest}.bak"
      mv "$new_content_file" "$dest"
      echo "  -> 新しいマージ結果を採用 (バックアップ: ${dest}.bak)"
      ;;
    k)
      rm "$new_content_file"
      echo "  -> 既存の内容を維持"
      ;;
    m)
      cp "$dest" "${dest}.bak"
      echo "  -> $MERGE_TOOL を起動します..."
      echo "     左: 新しいマージ結果 ($new_content_file)"
      echo "     右: 既存 ($dest)"
      $MERGE_TOOL "$new_content_file" "$dest"

      echo ""
      echo "  マージ結果 ($dest):"
      echo "  -----------------------------------------"
      cat "$dest"
      echo "  -----------------------------------------"
      decide "  この内容でよいですか？ [y/n]: " y n confirm "$dest"

      if [ "$confirm" = "y" ]; then
        rm -f "$new_content_file"
        echo "  -> マージ完了 (バックアップ: ${dest}.bak)"
      else
        cp "${dest}.bak" "$dest"
        rm -f "$new_content_file"
        echo "  -> 取り消し、変更なし"
      fi
      ;;
    s)
      rm -f "$new_content_file"
      echo "  -> スキップ"
      ;;
    *)
      rm -f "$new_content_file"
      echo "  -> 不明な入力、スキップ"
      ;;
  esac
}

link_file() {
  local src="$1"
  local dest="$2"

  mkdir -p "$(dirname "$dest")"

  if [ -L "$dest" ]; then
    local current
    current="$(readlink "$dest")"
    if [ "$current" = "$src" ]; then
      echo "skip: $dest (already linked)"
      return
    fi
    echo "relink: $dest"
    # why: BSD ln (macOS) は dest がディレクトリ symlink の場合 -sf でも
    #      リンク先の中に新規 symlink を作ってしまう。-n (--no-dereference)
    #      で dest を「symlink そのもの」として扱わせる必要がある。
    ln -sfn "$src" "$dest"

  elif [ -e "$dest" ]; then
    if diff -u "$src" "$dest" > /dev/null 2>&1; then
      echo "replace: $dest (same content)"
      rm "$dest"
      ln -s "$src" "$dest"
    else
      echo ""
      echo "========================================="
      echo "CONFLICT: $dest"
      echo "--- dotfiles (src): $src"
      echo "+++ existing (dest): $dest"
      echo "========================================="
      diff -u "$src" "$dest" || true
      echo "========================================="
      echo ""
      echo "  d) dotfiles の内容を使う (既存は .bak に保存)"
      echo "  e) 既存ファイルの内容を残す (dotfiles 側を更新)"
      echo "  m) マージする ($MERGE_TOOL で編集)"
      echo "  s) スキップ"
      echo ""
      decide "  選択 [d/e/m/s]: " d s choice "$dest"

      case "$choice" in
        d)
          mv "$dest" "${dest}.bak"
          ln -s "$src" "$dest"
          echo "  -> dotfiles を採用 (バックアップ: ${dest}.bak)"
          ;;
        e)
          cp "$dest" "$src"
          rm "$dest"
          ln -s "$src" "$dest"
          echo "  -> 既存の内容で dotfiles を更新してリンク"
          ;;
        m)
          cp "$dest" "${dest}.bak"
          echo "  -> $MERGE_TOOL を起動します..."
          echo "     左: dotfiles ($src)"
          echo "     右: 既存 ($dest)"
          $MERGE_TOOL "$src" "$dest"

          echo ""
          echo "  マージ結果 ($src):"
          echo "  -----------------------------------------"
          cat "$src"
          echo "  -----------------------------------------"
          decide "  この内容でリンクしますか？ [y/n]: " y n confirm "$dest"

          if [ "$confirm" = "y" ]; then
            rm "$dest"
            ln -s "$src" "$dest"
            echo "  -> マージ完了、リンク作成 (バックアップ: ${dest}.bak)"
          else
            cp "${dest}.bak" "$src"
            echo "  -> 取り消し、変更なし"
          fi
          ;;
        s)
          echo "  -> スキップ"
          ;;
        *)
          echo "  -> 不明な入力、スキップ"
          ;;
      esac
    fi

  else
    ln -s "$src" "$dest"
    echo "link: $dest -> $src"
  fi
}

# ----- ターゲット -----

target_ghostty() {
  local ghostty_src
  if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/ghostty/config.local/$HOST_ENV" ]; then
    { cat "$DOTFILES_DIR/ghostty/config"; echo; cat "$DOTFILES_DIR/ghostty/config.local/$HOST_ENV"; } \
      > "$DOTFILES_DIR/ghostty/config.merged.tmp"

    safe_overwrite "$DOTFILES_DIR/ghostty/config.merged.tmp" \
                   "$DOTFILES_DIR/ghostty/config.merged"

    ghostty_src="$DOTFILES_DIR/ghostty/config.merged"
    echo "Ghostty config をマージしました: config + config.local/$HOST_ENV"
  else
    ghostty_src="$DOTFILES_DIR/ghostty/config"
  fi
  link_file "$ghostty_src" "$HOME/.config/ghostty/config"
}

target_bin() {
  # nullglob: bin/ が空ならループ自体スキップ（リテラル `bin/*` を処理してしまうのを防ぐ）
  shopt -s nullglob
  local script
  for script in "$DOTFILES_DIR/bin/"*; do
    [ -f "$script" ] || continue
    link_file "$script" "$HOME/.local/bin/$(basename "$script")"
  done
  shopt -u nullglob

  # why: スキル本文から "reflect-extract" の短縮名で呼べるようにし、
  #      Bash(reflect-extract:*) の allow ルールだけで権限ダイアログを抑える
  link_file "$DOTFILES_DIR/.claude/skills/reflect/extract/reflect-extract.mjs" \
            "$HOME/.local/bin/reflect-extract"
}

target_git() {
  link_file "$DOTFILES_DIR/.gitignore_global" \
            "$HOME/.gitignore_global"
}

target_shell() {
  link_file "$DOTFILES_DIR/.zshrc" \
            "$HOME/.zshrc"

  if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/zshrc.local/$HOST_ENV.zsh" ]; then
    link_file "$DOTFILES_DIR/zshrc.local/$HOST_ENV.zsh" \
              "$HOME/.zshrc.local"
  fi

  # why: .zshrc が ~/projects/fzf-tab を source するので、未クローンなら shallow clone する
  #      （新規マシンで SSH 鍵が無くても済むよう HTTPS 経由）。
  local fzf_tab_dir="$HOME/projects/fzf-tab"
  if [ ! -d "$fzf_tab_dir/.git" ]; then
    mkdir -p "$(dirname "$fzf_tab_dir")"
    git clone --depth 1 https://github.com/Aloxaf/fzf-tab.git "$fzf_tab_dir" \
      || echo "警告: fzf-tab の clone に失敗しました（fzf-tab 補完は無効のまま続行）"
  fi
}

target_claude_settings() {
  if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" ]; then
    echo "環境: $HOST_ENV"

    if command -v jq &> /dev/null; then
      # why: common.json は全ローカル env 共通の追加層。base (settings.json) は
      #      routine がクローン先で project 設定として直読みするため、対話確認用の
      #      permissions.ask 等は base に置かず common に集約する。routine は setup.sh
      #      を通らず base だけ読むので ask を受け取らず自律実行でき、ローカルは
      #      この common 経由で ask を1箇所定義のまま受け取れる (DRY)。
      #      マージ順は base → common → env で、配列は順に結合される。
      local merge_inputs
      merge_inputs=("$DOTFILES_DIR/.claude/settings.json")
      [ -f "$DOTFILES_DIR/.claude/settings.local/common.json" ] \
        && merge_inputs+=("$DOTFILES_DIR/.claude/settings.local/common.json")
      # why: 別リポは git pull で中身が変わるので、ファイル全体を混ぜると permissions /
      #      hooks を無審査で取り込む (allow は prefixes が safe-prefix に転写する)。
      local spinner_json="$HOME/projects/claude-spinner-verbs-japanese/spinner-verbs.json"
      local spinner_tmp="" spinner_note=""
      if [ -f "$spinner_json" ]; then
        spinner_tmp="$(mktemp "${TMPDIR:-/tmp/}spinner-verbs-XXXXXX")"
        jq 'if has("spinnerVerbs") then {spinnerVerbs} else {} end' "$spinner_json" > "$spinner_tmp"
        merge_inputs+=("$spinner_tmp")
        spinner_note=" + spinner-verbs.json"
      fi
      merge_inputs+=("$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json")

      # jqで設定をマージ（配列は自動的に結合）
      jq -s '
        def merge_with_arrays:
          . as [$a, $b] |
          if ($a | type) == "object" and ($b | type) == "object" then
            ($a + $b) | to_entries | map(
              .key as $k |
              .value as $v |
              if ($a | has($k)) and ($b | has($k)) then
                if ($a[$k] | type) == "array" and ($b[$k] | type) == "array" then
                  {key: $k, value: ($a[$k] + $b[$k])}
                elif ($a[$k] | type) == "object" and ($b[$k] | type) == "object" then
                  {key: $k, value: ([($a[$k]), ($b[$k])] | merge_with_arrays)}
                else
                  {key: $k, value: $v}
                end
              else
                {key: $k, value: $v}
              end
            ) | from_entries
          elif ($a | type) == "array" and ($b | type) == "array" then
            $a + $b
          else
            $b
          end;

        reduce .[1:][] as $next (.[0]; [., $next] | merge_with_arrays)
      ' \
        "${merge_inputs[@]}" \
        > "$DOTFILES_DIR/.claude/settings.merged.json.tmp"

      if [ -n "$spinner_tmp" ]; then
        rm -f "$spinner_tmp"
      fi

      safe_overwrite "$DOTFILES_DIR/.claude/settings.merged.json.tmp" \
                     "$DOTFILES_DIR/.claude/settings.merged.json"

      link_file "$DOTFILES_DIR/.claude/settings.merged.json" \
                "$HOME/.claude/settings.json"

      echo "設定をマージしました: settings.json + common.json${spinner_note} + settings.local/$HOST_ENV.json"
    else
      echo "警告: jqがインストールされていません。設定のマージをスキップします。"
      link_file "$DOTFILES_DIR/.claude/settings.json" \
                "$HOME/.claude/settings.json"
    fi
  elif [ -n "$HOST_ENV" ]; then
    echo "警告: settings.local/$HOST_ENV.json が見つかりません"
    link_file "$DOTFILES_DIR/.claude/settings.json" \
              "$HOME/.claude/settings.json"
  else
    echo "環境が指定されていません。共通設定のみを使用します。"
    echo "使い方: ./setup.sh [home|work]"
    link_file "$DOTFILES_DIR/.claude/settings.json" \
              "$HOME/.claude/settings.json"
  fi
}

target_claude_md() {
  local claude_src
  if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/CLAUDE.local/$HOST_ENV.md" ]; then
    { cat "$DOTFILES_DIR/.claude/CLAUDE.md"; echo; cat "$DOTFILES_DIR/.claude/CLAUDE.local/$HOST_ENV.md"; } \
      > "$DOTFILES_DIR/.claude/CLAUDE.merged.md.tmp"

    safe_overwrite "$DOTFILES_DIR/.claude/CLAUDE.merged.md.tmp" \
                   "$DOTFILES_DIR/.claude/CLAUDE.merged.md"

    claude_src="$DOTFILES_DIR/.claude/CLAUDE.merged.md"
    echo "CLAUDE.md をマージしました: CLAUDE.md + CLAUDE.local/$HOST_ENV.md"
  else
    claude_src="$DOTFILES_DIR/.claude/CLAUDE.md"
  fi
  link_file "$claude_src" "$HOME/.claude/CLAUDE.md"

  # why: CLAUDE.md から @FABLE.md で import する。相対パス解決はインポート元と
  #      同じディレクトリ基準なので、CLAUDE.md (CLAUDE.merged.md) と同じ
  #      .claude/ 直下に置く。
  link_file "$DOTFILES_DIR/.claude/FABLE.md" \
            "$HOME/.claude/FABLE.md"
}

target_skills() {
  link_file "$DOTFILES_DIR/.claude/skills/docbase-mermaid/SKILL.md" \
            "$HOME/.claude/skills/docbase-mermaid/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/reflect/SKILL.md" \
            "$HOME/.claude/skills/reflect/SKILL.md"
  # why: スキルが委譲する専用サブエージェント。生ログ隔離 (retro-extractor)・漏洩監査
  #      (sanitize-auditor)・HTML ドキュメントレビュー (doc-reviewer)・SKILL.md 書き味レビュー
  #      (skill-md-reviewer) を tools 制限付きで担う。user スコープ (~/.claude/agents) に置く。
  link_file "$DOTFILES_DIR/.claude/agents/retro-extractor.md" \
            "$HOME/.claude/agents/retro-extractor.md"
  link_file "$DOTFILES_DIR/.claude/agents/sanitize-auditor.md" \
            "$HOME/.claude/agents/sanitize-auditor.md"
  link_file "$DOTFILES_DIR/.claude/agents/doc-reviewer.md" \
            "$HOME/.claude/agents/doc-reviewer.md"
  link_file "$DOTFILES_DIR/.claude/agents/skill-md-reviewer.md" \
            "$HOME/.claude/agents/skill-md-reviewer.md"
  link_file "$DOTFILES_DIR/.claude/skills/baton/SKILL.md" \
            "$HOME/.claude/skills/baton/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/read-baton/SKILL.md" \
            "$HOME/.claude/skills/read-baton/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/add-dir-manager/SKILL.md" \
            "$HOME/.claude/skills/add-dir-manager/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/add-dir-manager/scripts/addir.sh" \
            "$HOME/.claude/skills/add-dir-manager/scripts/addir.sh"
  link_file "$DOTFILES_DIR/.claude/skills/skill-md-guide/SKILL.md" \
            "$HOME/.claude/skills/skill-md-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/claude-md-guide/SKILL.md" \
            "$HOME/.claude/skills/claude-md-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/claude-md-guide/references/anti-patterns.md" \
            "$HOME/.claude/skills/claude-md-guide/references/anti-patterns.md"
  link_file "$DOTFILES_DIR/.claude/skills/claude-md-guide/references/examples.md" \
            "$HOME/.claude/skills/claude-md-guide/references/examples.md"
  link_file "$DOTFILES_DIR/.claude/skills/explain/SKILL.md" \
            "$HOME/.claude/skills/explain/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/explain/assets/template.html" \
            "$HOME/.claude/skills/explain/assets/template.html"
  link_file "$DOTFILES_DIR/.claude/skills/write-shared-docs/SKILL.md" \
            "$HOME/.claude/skills/write-shared-docs/SKILL.md"

  # why: sentinel (多角レビュー) は入口スキル comment-scrutiny / implementation-review /
  #      test-design-guide に fan-out し、それらと sentinel 自身が
  #      shared/review-severity.md を共通参照する。スキル単体では完結しないので
  #      依存スキルと共有定義をまとめて配線する。evals は skill-creator 用の dev 資産。
  link_file "$DOTFILES_DIR/.claude/skills/sentinel/SKILL.md" \
            "$HOME/.claude/skills/sentinel/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/sentinel/evals/evals.json" \
            "$HOME/.claude/skills/sentinel/evals/evals.json"
  link_file "$DOTFILES_DIR/.claude/skills/comment-scrutiny/SKILL.md" \
            "$HOME/.claude/skills/comment-scrutiny/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/implementation-review/SKILL.md" \
            "$HOME/.claude/skills/implementation-review/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/implement-from-wireframe/SKILL.md" \
            "$HOME/.claude/skills/implement-from-wireframe/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/test-design-guide/SKILL.md" \
            "$HOME/.claude/skills/test-design-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/shared/review-severity.md" \
            "$HOME/.claude/skills/shared/review-severity.md"

  # why: PR レビューの投稿・返信フロー。どちらも返信/指摘本文の末尾に署名を必須と
  #      しており、PreToolUse hook (pr-comment-signature.sh) が「スキルを経由せず
  #      gh api を直接叩いた投稿」を ask に格上げしてこの規定を担保する。
  #      hook 側だけ dotfiles にあってスキル本体が外に残ると、規定の出典が
  #      公開リポから読めなくなるので揃えて管理する。
  link_file "$DOTFILES_DIR/.claude/skills/review-comment/SKILL.md" \
            "$HOME/.claude/skills/review-comment/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/respond-to-pr-review/SKILL.md" \
            "$HOME/.claude/skills/respond-to-pr-review/SKILL.md"

  # ----- auq-web skill -----
  # why: auq-web は SKILL.md/references (Claude が読むテキスト) を他スキルと同じく
  #   dotfiles で管理し、server 実体は別リポ (auq-web) に置く分割構成。
  #   run.sh は server に sibling 依存するので、リポを単一の正として PATH に通す。
  # 旧構成 (~/.claude/skills/auq-web が repo/skill へのディレクトリ symlink) からの移行:
  #   ファイル単位 link に切り替えるため、残っていれば dir-symlink を除去する。
  [ -L "$HOME/.claude/skills/auq-web" ] && rm "$HOME/.claude/skills/auq-web"
  link_file "$DOTFILES_DIR/.claude/skills/auq-web/SKILL.md" \
            "$HOME/.claude/skills/auq-web/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills/auq-web/references/input-format.md" \
            "$HOME/.claude/skills/auq-web/references/input-format.md"
  # why: server を起動する run.sh を `auq-web` として PATH に通す (SKILL.md は
  #   `auq-web ...` で呼ぶ)。auq-web リポが無いと壊れた symlink になるので、
  #   存在する時だけ配線する (このリポがある前提)。
  if [ -f "$HOME/projects/auq-web/skill/run.sh" ]; then
    link_file "$HOME/projects/auq-web/skill/run.sh" "$HOME/.local/bin/auq-web"
  else
    echo "警告: ~/projects/auq-web が無いため auq-web コマンドは未配線"
    echo "      git clone \"\$AUQ_WEB_REPO\" ~/projects/auq-web  # set AUQ_WEB_REPO to your fork"
  fi

  # why: mattpocock/skills は第三者リポなので dotfiles に取り込まず、
  #      XDG_DATA_HOME 配下に shallow clone してから symlink で配る。
  #      npx skills@latest installer を経由しないので claude-code 専用に閉じる。
  local mp_skills_dir="$HOME/.local/share/mattpocock-skills"
  if [ -d "$mp_skills_dir/.git" ]; then
    # why: オフラインや upstream force-push で pull が失敗しても setup 全体を
    #      止めない（後続の hook 配線・prefix 生成まで到達させるため）。
    if git -C "$mp_skills_dir" pull --ff-only --quiet; then
      echo "updated: $mp_skills_dir"
    else
      echo "警告: $mp_skills_dir の更新に失敗しました（既存の clone のまま続行）"
    fi
  else
    mkdir -p "$(dirname "$mp_skills_dir")"
    git clone --depth 1 https://github.com/mattpocock/skills.git "$mp_skills_dir"
  fi
  # why: grill-with-docs の SKILL.md は CONTEXT-FORMAT.md / ADR-FORMAT.md を
  #      相対パスで参照するので、ファイル単位ではなくディレクトリごとリンクする。
  link_file "$mp_skills_dir/skills/productivity/grill-me" \
            "$HOME/.claude/skills/grill-me"
  link_file "$mp_skills_dir/skills/engineering/grill-with-docs" \
            "$HOME/.claude/skills/grill-with-docs"

  # work 環境専用スキル (PR 作成ワークフローは work リポジトリの規約前提)
  # beat-copilot は create-pr の SKILL.md を Edit で更新する強依存があるため、
  # create-pr と同じ work gate に置く (home では create-pr が無く参照先を失う)。
  if [ "$HOST_ENV" = "work" ]; then
    link_file "$DOTFILES_DIR/.claude/skills/create-pr/SKILL.md" \
              "$HOME/.claude/skills/create-pr/SKILL.md"
    link_file "$DOTFILES_DIR/.claude/skills/beat-copilot/SKILL.md" \
              "$HOME/.claude/skills/beat-copilot/SKILL.md"
  fi
}

target_hooks() {
  link_file "$DOTFILES_DIR/.claude/hooks/lib/bash-safety.sh" \
            "$HOME/.claude/hooks/lib/bash-safety.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/segment-allow.sh" \
            "$HOME/.claude/hooks/segment-allow.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/mcp-error-toolsearch.sh" \
            "$HOME/.claude/hooks/mcp-error-toolsearch.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/escalate-unsafe-bash.sh" \
            "$HOME/.claude/hooks/escalate-unsafe-bash.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/scratchpad-rm-allow.sh" \
            "$HOME/.claude/hooks/scratchpad-rm-allow.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/pr-comment-signature.sh" \
            "$HOME/.claude/hooks/pr-comment-signature.sh"
}

target_statusline() {
  link_file "$DOTFILES_DIR/.claude/statusline/statusline.sh" \
    "$HOME/.claude/statusline.sh"
  link_file "$DOTFILES_DIR/.claude/statusline/runcat-statusline.py" \
    "$HOME/.claude/runcat-statusline.py"
}

target_reflect() {
  link_file "$DOTFILES_DIR/.claude/hooks/reflect-enqueue.sh" \
            "$HOME/.claude/hooks/reflect-enqueue.sh"
  mkdir -p "$HOME/.local/state/reflect"
  link_file "$DOTFILES_DIR/launchd/com.crgstar.reflect.plist" \
            "$HOME/Library/LaunchAgents/com.crgstar.reflect.plist"
  # why 毎回 bootout→bootstrap: plist 変更を launchd に反映させる最短手順。
  # 未ロード時の bootout 失敗は無視してよい
  launchctl bootout "gui/$(id -u)/com.crgstar.reflect" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.crgstar.reflect.plist" 2>/dev/null; then
    echo "launchd: com.crgstar.reflect を登録しました (毎日 3:00)"
  else
    echo "警告: com.crgstar.reflect の launchctl bootstrap に失敗しました"
  fi
}

# why: segment-allow.sh の safe-prefix を静的 allow から派生させる。
#   抽出対象:
#     Bash(cmd)         → "cmd" (exact)
#     Bash(cmd *)       → "cmd *" (cmd + space + args)
#     Bash(cmd:*)       → "cmd" と "cmd *" の両方 (Claude Code の :* セマンティクス)
#     Bash(cmd sub *)   → "cmd sub *"  (`git status *` / `gh pr view *` 等の多語サブコマンド)
#     Bash(cmd sub:*)   → "cmd sub" と "cmd sub *"
#     Bash(cmd sub +helper *) → "cmd sub +helper *" (gws の helper 命名規約 `+read`/`+append` 等。
#         先頭 cmd には `+` を許さない / 連続 `++` 不可 / sub-word のみ単独 `+` を許す)
#   除外対象 (内部に `*` や `/` を含む複合パターンは bash glob として 1 セグメント
#   照合できないので hook の責務外):
#     Bash(git -C * status *) / Bash(xargs -n* ls *) / Bash(cat */.mirugit/*)
#   静的 allow ⊇ hook 許容範囲 が build-time に保証されるので、2 箇所メンテによる
#   drift を避ける。
target_prefixes() {
  local out="$HOME/.claude/hooks/segment-allow.prefixes"
  if command -v jq &> /dev/null && [ -r "$HOME/.claude/settings.json" ]; then
    mkdir -p "$(dirname "$out")"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp/}segment-allow-XXXXXX")"
    {
      echo "# Generated by setup.sh from ~/.claude/settings.json (permissions.allow)."
      echo "# Read by ~/.claude/hooks/segment-allow.sh as bash glob patterns."
      echo "# To change: edit settings.json allow list and re-run ./setup.sh <env>."
      jq -r '
        .permissions.allow[]
        | select(type == "string")
        | (capture("^Bash\\((?<cmd>[A-Za-z][A-Za-z0-9_-]*(?: \\+?[A-Za-z][A-Za-z0-9_-]*)*)(?<suf>:\\*| \\*)?\\)$")? // empty)
        | if   .suf == ":*" then [.cmd, "\(.cmd) *"]
          elif .suf == " *" then ["\(.cmd) *"]
          else                   [.cmd]
          end
        | .[]
      ' "$HOME/.claude/settings.json" | sort -u
    } > "$tmp"
    mv "$tmp" "$out"
    echo "segment-allow safe-prefix を生成しました: $out ($(grep -cv '^#' "$out") 件)"
  fi
}

target_mcp() {
  if [ -f "$HOME/.claude.json" ] && command -v jq &> /dev/null; then
    if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" ]; then
      # $HOST_ENV.json から mcpServers を抽出
      local mcp_servers
      mcp_servers=$(jq '.mcpServers // {}' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json")

      if jq -e '.mcpServers | length > 0' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" &> /dev/null; then
        echo ""
        echo "MCP サーバー設定をマージしています..."

        # .claude.json の mcpServers セクションにマージ
        jq --argjson new_servers "$mcp_servers" \
           '.mcpServers = (.mcpServers // {}) * $new_servers' \
           "$HOME/.claude.json" > "$HOME/.claude.json.tmp"

        mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
        echo "MCP サーバー設定をマージしました"
      fi
    fi
  fi
}

# ----- 実行 -----

RAN=""
for _entry in "${TARGETS[@]}"; do
  _target="${_entry%%:*}"
  target_enabled "$_target" || continue
  # ターゲット名のハイフンは関数名では使えないのでアンダースコアに寄せる
  "target_${_target//-/_}"
  RAN="$RAN $_target"
done

echo ""
echo "実行したターゲット:$RAN"

if [ "$CONFLICT_COUNT" -gt 0 ]; then
  echo "" >&2
  echo "未解決の衝突 $CONFLICT_COUNT 件 (下記は変更していません):" >&2
  printf '%s' "$CONFLICT_LIST" >&2
  echo "--force でマージ結果 / dotfiles 側を採用、--keep で既存維持のまま正常終了できます" >&2
  exit 1
fi

echo "done!"
