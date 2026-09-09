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
  "cmux-pill:cmux のサイドバーピル塗り替え常駐 (launchd)"
  "prefixes:segment-allow.prefixes を permissions.allow から再生成 (claude-settings の後)"
  "mcp:mcp/ 配下のヘルパーをリンクし、settings.local/<env>.json の mcpServers を ~/.claude.json へマージ"
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
  --self-test     設定を一切書き換えず、safe-prefix の派生規則だけを検証して終了
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
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "エラー: --only にターゲットが指定されていません" >&2; exit 1; }
      ONLY_TARGETS="$2"; shift 2 ;;
    --only=*)
      ONLY_TARGETS="${1#--only=}"; shift ;;
    --list)
      list_targets; exit 0 ;;
    --self-test)
      # why ここで実行しないでフラグに倒す: 検証関数は下の方で定義されるので、
      #     パース時点ではまだ未定義。定義がすべて済んでから呼ぶ。
      SELF_TEST=1; shift ;;
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
  link_file "$DOTFILES_DIR/.claude/skills-global/reflect/extract/reflect-extract.mjs" \
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
  link_file "$DOTFILES_DIR/.claude/skills-global/docbase-mermaid/SKILL.md" \
            "$HOME/.claude/skills/docbase-mermaid/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/reflect/SKILL.md" \
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
  link_file "$DOTFILES_DIR/.claude/skills-global/baton/SKILL.md" \
            "$HOME/.claude/skills/baton/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/read-baton/SKILL.md" \
            "$HOME/.claude/skills/read-baton/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/add-dir-manager/SKILL.md" \
            "$HOME/.claude/skills/add-dir-manager/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/add-dir-manager/scripts/addir.sh" \
            "$HOME/.claude/skills/add-dir-manager/scripts/addir.sh"
  link_file "$DOTFILES_DIR/.claude/skills-global/skill-md-guide/SKILL.md" \
            "$HOME/.claude/skills/skill-md-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/claude-md-guide/SKILL.md" \
            "$HOME/.claude/skills/claude-md-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/claude-md-guide/references/anti-patterns.md" \
            "$HOME/.claude/skills/claude-md-guide/references/anti-patterns.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/claude-md-guide/references/examples.md" \
            "$HOME/.claude/skills/claude-md-guide/references/examples.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/explain/SKILL.md" \
            "$HOME/.claude/skills/explain/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/explain/assets/template.html" \
            "$HOME/.claude/skills/explain/assets/template.html"
  link_file "$DOTFILES_DIR/.claude/skills-global/write-shared-docs/SKILL.md" \
            "$HOME/.claude/skills/write-shared-docs/SKILL.md"
  # why: unslop は日本語向けの翻案で、英語の文章は原典 reference-en.md に送り返す。
  #      SKILL.md 単体を配ると英語側の行き先が解決できず、判定が宙に浮く。
  link_file "$DOTFILES_DIR/.claude/skills-global/unslop/SKILL.md" \
            "$HOME/.claude/skills/unslop/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/unslop/reference-en.md" \
            "$HOME/.claude/skills/unslop/reference-en.md"
  # why: memory-guide は memory-guide-gate.sh (PreToolUse) の deny 理由文が
  #      名指しで起動を促す先。リンクが無いとモデルは案内どおり呼べず、
  #      差し戻しに応じる手段が無くなる。tidy-memory は判定・書式の正本として
  #      memory-guide を Read する側なので、片方だけ配ると手順が成立しない。
  link_file "$DOTFILES_DIR/.claude/skills-global/memory-guide/SKILL.md" \
            "$HOME/.claude/skills/memory-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/tidy-memory/SKILL.md" \
            "$HOME/.claude/skills/tidy-memory/SKILL.md"

  # why: sentinel (多角レビュー) は入口スキル comment-scrutiny / implementation-review /
  #      test-design-guide に fan-out し、それらと sentinel 自身が
  #      shared/review-severity.md を共通参照する。スキル単体では完結しないので
  #      依存スキルと共有定義をまとめて配線する。evals は skill-creator 用の dev 資産。
  link_file "$DOTFILES_DIR/.claude/skills-global/sentinel/SKILL.md" \
            "$HOME/.claude/skills/sentinel/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/sentinel/evals/evals.json" \
            "$HOME/.claude/skills/sentinel/evals/evals.json"
  link_file "$DOTFILES_DIR/.claude/skills-global/comment-scrutiny/SKILL.md" \
            "$HOME/.claude/skills/comment-scrutiny/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/implementation-review/SKILL.md" \
            "$HOME/.claude/skills/implementation-review/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/implement-from-wireframe/SKILL.md" \
            "$HOME/.claude/skills/implement-from-wireframe/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/test-design-guide/SKILL.md" \
            "$HOME/.claude/skills/test-design-guide/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/shared/review-severity.md" \
            "$HOME/.claude/skills/shared/review-severity.md"

  # why: PR レビューの投稿・返信フロー。どちらも返信/指摘本文の末尾に署名を必須と
  #      しており、PreToolUse hook (pr-comment-signature.sh) が「スキルを経由せず
  #      gh api を直接叩いた投稿」を ask に格上げしてこの規定を担保する。
  #      hook 側だけ dotfiles にあってスキル本体が外に残ると、規定の出典が
  #      公開リポから読めなくなるので揃えて管理する。
  link_file "$DOTFILES_DIR/.claude/skills-global/review-comment/SKILL.md" \
            "$HOME/.claude/skills/review-comment/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/respond-to-pr-review/SKILL.md" \
            "$HOME/.claude/skills/respond-to-pr-review/SKILL.md"

  # why: respond-to-pr-review の Phase 2 が採否判定と修正実装をこの 2 スキルへ
  #      委譲する。委譲先が dotfiles 外にあると setup.sh を通した他マシンで
  #      参照が解決できず手順が成立しないので、委譲元と揃えて管理する。
  #      evals は実データ (レビュー対象の差分・判定結果) を含むので取り込まず
  #      .agents 側に残す。sentinel も evals/evals.json だけを管理しているのと同じ扱い。
  link_file "$DOTFILES_DIR/.claude/skills-global/review-verdict/SKILL.md" \
            "$HOME/.claude/skills/review-verdict/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/review-fix/SKILL.md" \
            "$HOME/.claude/skills/review-fix/SKILL.md"

  # why: この 2 スキルの evals はレビュー対象の実データ (差分・判定結果・レビュー原本) を
  #      含むので dotfiles には置かない。実体はローカルの ~/.agents/skills/<name>/evals に
  #      残したまま、スキルルート配下へディレクトリごと symlink して SKILL.md と同じ階層に
  #      見せる (evals.json がスキルルート基準で evals/README.md 等を参照するため)。
  #      公開リポの作業ツリーに実データを一切置かない形なので、誤コミットが構造的に起きない
  #      (dotfiles 内に置いて .gitignore で除く形だと add -f や記述漏れで入り得る)。
  #      非公開データなので新しいマシンには無い。その場合は黙ってスキップし SKILL.md だけ配る。
  local agents_skills_dir="$HOME/.agents/skills"
  local review_skill
  for review_skill in review-verdict review-fix; do
    [ -d "$agents_skills_dir/$review_skill/evals" ] || continue
    link_file "$agents_skills_dir/$review_skill/evals" \
              "$HOME/.claude/skills/$review_skill/evals"
  done

  # why: jj の操作規律そのものは第三者製の jujutsu スキル (~/.claude/skills/jujutsu、
  #      dotfiles 管理外) に委譲しており、本スキルは「PR 差分を change の列に切り直す」
  #      工程だけを持つ。委譲先が無いマシンでは前半の規律が読めないので、
  #      jujutsu を入れてから使う。
  link_file "$DOTFILES_DIR/.claude/skills-global/jj-restack-pr/SKILL.md" \
            "$HOME/.claude/skills/jj-restack-pr/SKILL.md"

  # ----- auq-web skill -----
  # why: auq-web は SKILL.md/references (Claude が読むテキスト) を他スキルと同じく
  #   dotfiles で管理し、server 実体は別リポ (auq-web) に置く分割構成。
  #   run.sh は server に sibling 依存するので、リポを単一の正として PATH に通す。
  # 旧構成 (~/.claude/skills/auq-web が repo/skill へのディレクトリ symlink) からの移行:
  #   ファイル単位 link に切り替えるため、残っていれば dir-symlink を除去する。
  [ -L "$HOME/.claude/skills/auq-web" ] && rm "$HOME/.claude/skills/auq-web"
  link_file "$DOTFILES_DIR/.claude/skills-global/auq-web/SKILL.md" \
            "$HOME/.claude/skills/auq-web/SKILL.md"
  link_file "$DOTFILES_DIR/.claude/skills-global/auq-web/references/input-format.md" \
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
    link_file "$DOTFILES_DIR/.claude/skills-global/create-pr/SKILL.md" \
              "$HOME/.claude/skills/create-pr/SKILL.md"
    link_file "$DOTFILES_DIR/.claude/skills-global/beat-copilot/SKILL.md" \
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
  link_file "$DOTFILES_DIR/.claude/hooks/prefer-jq-over-python.sh" \
            "$HOME/.claude/hooks/prefer-jq-over-python.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/memory-guide-gate.sh" \
            "$HOME/.claude/hooks/memory-guide-gate.sh"
  link_file "$DOTFILES_DIR/.claude/hooks/cd-outside-workspace-gate.sh" \
            "$HOME/.claude/hooks/cd-outside-workspace-gate.sh"
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

# cmux.json (JSONC) の automation.socketControlMode を読む。ファイルは書き換えない。
# 出力: 値 / "" (セクションはあるがキーが無い) / __missing_section__ / __unreadable__
#
# why 末尾カンマも落とす: cmux が生成するテンプレートは `"schemaVersion": 1,` の
#   直後に `}` が来る形で、JSONC では合法だが json.loads は拒否する。落とさないと
#   parse 失敗 → 現在値が読めない → 「キー無し」と誤判定して二重挿入しうる
#
# why セクション有無と値の有無を別の答えで返す: automation には socketPassword /
#   portBase 等の兄弟キーがあり、「セクションはあるが socketControlMode だけ無い」
#   が普通に起こる。これを「キー無し」と一括すると開き波括弧の直後に 2 つ目の
#   "automation" を挿入してしまい、JSON の後勝ちで挿入側が丸ごと無効化される
#   (= 何も効いていないのに「設定しました」と出る)
cmux_read_socket_mode() {
  python3 -c '
import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
raw = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
try:
    data = json.loads(raw)
except Exception:
    print("__unreadable__")
    sys.exit(0)
# 挿入して安全なのは「トップレベルが object で automation キー自体が無い」ときだけ。
# それ以外の想定外の形 (トップレベルが object でない / automation が object でない) は
# 挿入位置を保証できないので触らせない
if not isinstance(data, dict):
    print("__unreadable__")
    sys.exit(0)
if "automation" not in data:
    print("__missing_section__")
    sys.exit(0)
section = data["automation"]
if not isinstance(section, dict):
    print("__unreadable__")
    sys.exit(0)
print(section.get("socketControlMode") or "")
' "$1" 2>/dev/null || echo "__unreadable__"
}

# cmux の automation socket を launchd 常駐から使える状態にする。
#
# why setup.sh が触る: 既定の cmuxOnly は「cmux ターミナル内で起動したプロセス」
#   しか socket に通さないので、launchd 起動の watcher は必ず拒否される。しかも
#   拒否応答はプレーンテキストで返り、CLI 側が JSON として解釈して
#   "JSON text did not start with array or object" になるため原因が分からない。
#   新しいマシンで踏み直す前提の罠なので、配線と同じ場所で面倒を見る。
#
# why 丸ごと書き直さない: cmux.json は JSONC で、初期状態はコメントアウトされた
#   設定例が本体 (6KB 超) を占める。jq / python で parse → dump すると
#   そのコメントが全部消える (実際に消した)。automation セクションごと無いときだけ
#   開き波括弧の直後へテキストとして挿入し、他の行には触らない。
#
# why 既存の別値は上書きしない: off / password を意図して選んでいる場合に
#   黙って緩めることになる。警告と手順の提示だけに留めて判断を残す。
cmux_enable_automation_socket() {
  local config="$HOME/.config/cmux/cmux.json"
  local want="automation"
  # why 手順はファイルと GUI で案内する: cmux-settings はスキル同梱スクリプトで
  #   PATH に無い (実測)。実行できないコマンドを案内すると詰まる
  local how_to="      $config の automation.socketControlMode を \"$want\" にする"
  local how_to2="      (GUI なら Settings > Automation の socket control mode を Automation mode)"

  if [ ! -f "$config" ]; then
    echo "警告: $config が無いため socketControlMode を設定できません"
    echo "      cmux を一度起動してから ./setup.sh <env> --only cmux-pill を再実行してください"
    return
  fi

  local current
  current="$(cmux_read_socket_mode "$config")"

  if [ "$current" = "$want" ]; then
    return
  fi

  # why parse できないファイルには触らない: どのキーが既にあるか分からない状態で
  # 挿入すると、二重定義になって「後勝ち」で意図と違う値が効きうる。
  # なおテキスト上の "socketControlMode" 有無は判定に使わない —
  # テンプレートはコメントで設定例を並べており、コメント内の 1 語に反応してしまう
  if [ "$current" = "__unreadable__" ]; then
    echo ""
    echo "警告: $config の automation.socketControlMode を判定できませんでした。"
    echo "      launchd 起動の cmux-pill-watcher を動かすには手動で設定してください:"
    echo "$how_to"
    echo "$how_to2"
    echo ""
    return
  fi

  # why セクションがあるのにキーだけ無い場合も触らない: 既存 automation の中へ
  # テキスト挿入するには内側の波括弧位置と既存キーの末尾カンマを正しく扱う必要があり、
  # コメント付き JSONC で機械的に当てられない。挿入位置を誤ると設定ごと壊す
  if [ "$current" = "__missing_section__" ]; then
    : # セクションごと無い = 開き波括弧の直後に足しても二重定義にならない (下で挿入)
  elif [ -z "$current" ]; then
    echo ""
    echo "警告: $config に automation セクションはありますが socketControlMode がありません。"
    echo "      既存セクションを壊さないため自動では追記しません。手動で設定してください:"
    echo "$how_to"
    echo "$how_to2"
    echo ""
    return
  else
    echo ""
    echo "警告: cmux の automation.socketControlMode が '$current' です。"
    echo "      この値では launchd 起動の cmux-pill-watcher は socket に接続できません"
    echo "      (既定の cmuxOnly も同じ)。意図的な設定を上書きしないので手動で変えてください:"
    echo "$how_to"
    echo "$how_to2"
    echo ""
    return
  fi

  # why 書き換えの前に警告する: 何をされたか事後に知るのでは遅い。非対話実行
  #   (Claude / CI) でもログの並びが「これから緩める」→「緩めた」になるので、
  #   途中で失敗した場合も「緩めようとした」ことが残る
  echo ""
  echo "警告: cmux の automation.socketControlMode を '$want' に設定します。"
  echo "      これは cmux の socket 接続制限を既定 (cmuxOnly) から緩めます。同じ macOS"
  echo "      ユーザーで動く任意のプロセスが cmux を操作できるようになります"
  echo "      (cmux send でターミナルに文字を送れるため、実質的に任意コマンド実行の"
  echo "      経路が開きます)。socket ファイル自体は 0600 のままで他ユーザーは触れません。"
  echo "      緩めたくない場合はこの後 $config を編集して automation.socketControlMode を"
  echo "      消してください (または cmuxOnly に戻す)。その場合 cmux-pill-watcher は"
  echo "      動かなくなります (ログに接続エラーが出ます)"
  echo ""

  # why 書き換え前に .bak: 全文書き戻し (open(path,"w")) なので途中で失敗すると
  # 6KB のテンプレートごと失う。cmux 自身のエージェント向け手順も
  # 「編集前にタイムスタンプ付き .bak を取れ」と明示している (cmux docs settings)
  local backup="$config.$(date +%Y%m%d%H%M%S).bak"
  cp "$config" "$backup"

  # automation セクションごと無い: 開き波括弧の直後に挿入する。sed ではなく python なのは、
  # 「最初の { の直後だけ」を 1 回で当てるため
  if python3 -c '
import sys
path, want = sys.argv[1], sys.argv[2]
raw = open(path).read()

# why 素朴な検索ではなく状態機械: 最初に現れる { はコメントや文字列の中に
#   あることがある (テンプレートは設定例をコメントで並べる)。そこへ挿入すると
#   ファイルを壊すので、コード部分の { だけを探す
i, n = 0, len(raw)
pos = None
while i < n:
    c = raw[i]
    if c == "/" and i + 1 < n and raw[i + 1] == "/":
        i = raw.find("\n", i)
        if i == -1:
            break
    elif c == "/" and i + 1 < n and raw[i + 1] == "*":
        end = raw.find("*/", i + 2)
        i = n if end == -1 else end + 2
    elif c == "\"":
        i += 1
        while i < n:
            if raw[i] == "\\":
                i += 2
                continue
            if raw[i] == "\"":
                break
            i += 1
        i += 1
    elif c == "{":
        pos = i + 1
        break
    else:
        i += 1
if pos is None:
    sys.exit(1)
block = "\n  \"automation\": {\n    \"socketControlMode\": \"%s\"\n  }," % want
open(path, "w").write(raw[:pos] + block + raw[pos:])
' "$config" "$want"; then
    # why 書いた結果をもう一度読む: 全文書き戻しなので、挿入位置の判定を誤ると
    #   cmux が読めない JSON を置いたまま「設定しました」と出てしまい、
    #   動かない原因が設定ファイル側にあることに気づけない
    if [ "$(cmux_read_socket_mode "$config")" != "$want" ]; then
      cp "$backup" "$config"
      echo "警告: $config への socketControlMode 挿入が壊れた結果になったため元に戻しました"
      echo "      手動で設定してください:"
      echo "$how_to"
      echo "$how_to2"
      return
    fi
    # why 書いたら reload する: 起動中の cmux は cmux.json をメモリに持っており、
    #   ファイルを書くだけでは socket の受け入れ判定が変わらない。この直後に
    #   bootstrap する watcher が旧 mode (cmuxOnly) で拒否され続け、
    #   「設定しました」と出ているのに動かない状態になる
    # why PATH 依存にしない: target_cmux_pill の存在確認は PATH か
    #   /Applications 実体のどちらかで通るので、裸の `cmux` が無い経路がある
    local cmux_bin
    cmux_bin="$(command -v cmux 2>/dev/null || echo "/Applications/cmux.app/Contents/Resources/bin/cmux")"
    if "$cmux_bin" reload-config >/dev/null 2>&1; then
      : # 反映済み
    else
      echo "注意: cmux reload-config に失敗しました。cmux を再起動すると反映されます"
    fi
    # why 事後は 1 行だけ: 内容は書き換え前の警告で出している。同じ文を 2 度出すと
    #   どちらが実際の結果なのか読み取れなくなる
    echo "cmux: automation.socketControlMode を '$want' に設定しました (バックアップ: $backup)"
  else
    # why 戻す: python が途中で落ちると書きかけの全文が残りうる。.bak を残すだけでは
    #   cmux が壊れた設定を読み続ける
    cp "$backup" "$config"
    echo "警告: $config への socketControlMode 挿入に失敗しました (手動で設定してください)"
    echo "$how_to"
    echo "$how_to2"
  fi
}

target_cmux_pill() {
  # why ここでも本体をリンクする: plist が指す ~/.local/bin/cmux-pill-watcher は
  # target_bin が張るので、--only cmux-pill 単独だと exec できない job を
  # 登録してしまう。link_file は冪等なので通常実行では skip が 1 行増えるだけ
  link_file "$DOTFILES_DIR/bin/cmux-pill-watcher" \
            "$HOME/.local/bin/cmux-pill-watcher"
  mkdir -p "$HOME/.local/state/cmux-pill"
  # why 毎回 bootout→bootstrap: plist 変更を launchd に反映させる最短手順。
  # 未ロード時の bootout 失敗は無視してよい
  launchctl bootout "gui/$(id -u)/com.crgstar.cmux-pill" 2>/dev/null || true
  # why cmux 未導入なら登録しない: watcher は cmux CLI が無いと即 exit するので、
  # KeepAlive=true の常駐 job だと ThrottleInterval ごとに永久に再起動し、
  # ローテーションの無い watcher.log を延々と伸ばす
  if ! command -v cmux >/dev/null 2>&1 \
     && [ ! -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]; then
    # why plist も外す: LaunchAgents 配下の plist はログイン時に launchd が
    # 自動ロードするので、bootout しただけでは次のログインで復活する。
    # cmux を消した後もこの job が残ると、上のとおり永久再起動でログが伸びる
    if [ -L "$HOME/Library/LaunchAgents/com.crgstar.cmux-pill.plist" ]; then
      rm -f "$HOME/Library/LaunchAgents/com.crgstar.cmux-pill.plist"
      echo "撤去: cmux CLI が無いため com.crgstar.cmux-pill.plist を外しました"
    fi
    echo "スキップ: cmux CLI が無いため com.crgstar.cmux-pill は登録しません"
    return
  fi
  # why 登録の直前: cmux があると確認できてから触る。cmux 未導入のマシンで
  # 設定だけ緩めるのは無意味に権限を開けるだけ
  cmux_enable_automation_socket
  link_file "$DOTFILES_DIR/launchd/com.crgstar.cmux-pill.plist" \
            "$HOME/Library/LaunchAgents/com.crgstar.cmux-pill.plist"
  if launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.crgstar.cmux-pill.plist" 2>/dev/null; then
    echo "launchd: com.crgstar.cmux-pill を登録しました (常駐)"
  else
    echo "警告: com.crgstar.cmux-pill の launchctl bootstrap に失敗しました"
  fi
}

# why: segment-allow.sh の safe-prefix を静的 allow から派生させる。
#   抽出対象:
#     Bash(cmd)         → "cmd" (exact)
#     Bash(cmd *)       → "cmd" と "cmd *" の両方
#     Bash(cmd:*)       → "cmd" と "cmd *" の両方 (Claude Code の :* セマンティクス)
#     Bash(cmd sub *)   → "cmd sub" と "cmd sub *" (`git status *` / `gh pr view *` 等の多語サブコマンド)
#     Bash(cmd sub:*)   → "cmd sub" と "cmd sub *"
#     Bash(cmd sub +helper *) → "cmd sub +helper" と "cmd sub +helper *" (gws の helper 命名規約
#         `+read`/`+append` 等。先頭 cmd には `+` を許さない / 連続 `++` 不可 / sub-word のみ単独 `+` を許す)
#   why ` *` からも bare を派生させる: Claude Code の静的 allow は `Bash(head *)` で
#   引数なしの `head` も通す (実測) が、bash glob の "head *" は「空白 + 1 文字以上」を
#   要求するので bare には一致しない。bare を落とすと hook だけが静的 allow より狭くなり、
#   `gh api ... | head` のようにパイプ末尾へ引数なしで置いた道具 (head / cat / sort /
#   uniq / pwd 等) が未知セグメント扱いになって、コマンド全体が ask に落ちる。
#   why 2 語目以降に `-x` / `--xxx` / `{}` を許す: `Bash(xargs -n1 ls *)` /
#   `Bash(xargs -I{} cat *)` のようなフラグ入りエントリを除外していたため、静的
#   allow には載っているのに hook 白名簿には 1 行も入らず、`gh api ... | xargs -I{} ls`
#   だけが ask に落ちていた (hook が静的 allow より狭い状態)。xargs はオプション解釈が
#   ユーティリティ名で終わるので、末尾 `*` はユーティリティ側の引数にしか当たらず、
#   派生した glob は静的 allow と同じ範囲に収まる。
#   除外対象 (内部に `*` や `/` を含む複合パターンは bash glob として 1 セグメント
#   照合できない。hook の責務外):
#     Bash(cat */.mirugit/*) / Bash(pkill -f mirugit*) / Bash(npx eslint * --no-fix *)
#   静的 allow ⊇ hook 許容範囲 が build-time に保証されるので、2 箇所メンテによる
#   drift を避ける。
# why 抽出プログラムを変数に出す: 生成 (target_prefixes) と検証
#   (run_prefix_self_test) が同じ 1 本を読むようにするため。テスト側に写経すると、
#   写経した方だけを直しても緑のままになり、派生規則の regression を隠す。
PREFIX_DERIVE_JQ='
  .permissions.allow[]?
  | select(type == "string")
  | (capture("^Bash\\((?<cmd>[A-Za-z][A-Za-z0-9_-]*(?: (?:\\+?[A-Za-z][A-Za-z0-9_-]*|-{1,2}[A-Za-z0-9][A-Za-z0-9_{}-]*|\\{\\}))*)(?<suf>:\\*| \\*)?\\)$")? // empty)
  | if .suf then [.cmd, "\(.cmd) *"] else [.cmd] end
  | .[]
'

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
      jq -r "$PREFIX_DERIVE_JQ" "$HOME/.claude/settings.json" | sort -u
    } > "$tmp"
    mv "$tmp" "$out"
    echo "segment-allow safe-prefix を生成しました: $out ($(grep -cv '^#' "$out") 件)"
  fi
}

# 上の派生規則そのものを固定入力で検証する (`./setup.sh --self-test`)。
#
# why 必要か: segment-allow.sh の --self-test は SAFE_PREFIXES を自前で手書きして
#   おり、実際の派生結果を見ていない。両方を手でメンテすると片方だけ直しても緑に
#   なり、「hook だけが静的 allow より狭い」状態 (` *` から bare を派生させ忘れて
#   `gh api ... | head` が ask に落ちる) が素通りする。実際に起きたので、派生側にも
#   テストを置く。
run_prefix_self_test() {
  local fail=0 got want
  local fixture='{"permissions":{"allow":[
    "Bash(env)",
    "Bash(head *)",
    "Bash(mkdir:*)",
    "Bash(git status *)",
    "Bash(gh pr view:*)",
    "Bash(gws sheets +read *)",
    "Bash(cat */.mirugit/*)",
    "Bash(xargs -n1 ls *)",
    "Bash(xargs -0 grep *)",
    "Bash(xargs -I{} echo *)",
    "Bash(xargs -I {} cat *)",
    "Bash(pkill -f mirugit*)",
    "Bash(copilot --help*)",
    "Bash(npx eslint * --no-fix *)",
    "Bash(git -C * diff *)",
    "Read(//x/**)",
    "WebFetch(domain:example.com)"
  ]}}'
  # 期待値は「除外対象は 1 行も出さない」まで含めた完全一致で書く。部分一致だと
  # 除外が壊れて余計な行が増えても気づけない。
  # xargs 系はフラグ入りでも派生させる (静的 allow に載っているので、外すと hook だけが
  # 狭くなる)。単語に glob メタが付く形 (pkill -f mirugit* / copilot --help* /
  # npx eslint * --no-fix * / git -C * diff *) は引き続き 1 行も出さない。
  want="$(printf '%s\n' \
    'env' \
    'gh pr view' \
    'gh pr view *' \
    'git status' \
    'git status *' \
    'gws sheets +read' \
    'gws sheets +read *' \
    'head' \
    'head *' \
    'mkdir' \
    'mkdir *' \
    'xargs -0 grep' \
    'xargs -0 grep *' \
    'xargs -I {} cat' \
    'xargs -I {} cat *' \
    'xargs -I{} echo' \
    'xargs -I{} echo *' \
    'xargs -n1 ls' \
    'xargs -n1 ls *')"
  got="$(printf '%s' "$fixture" | jq -r "$PREFIX_DERIVE_JQ" | sort -u)"

  if [ "$got" = "$want" ]; then
    echo "ok  : safe-prefix 派生 (bare + starred / 除外パターン)"
  else
    echo "FAIL: safe-prefix 派生"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true
    fail=1
  fi

  # allow が無い設定でも落ちないこと (`.permissions.allow[]?` の `?` が要る)。
  if got="$(printf '%s' '{}' | jq -r "$PREFIX_DERIVE_JQ")" && [ -z "$got" ]; then
    echo "ok  : allow 不在でも空を返す"
  else
    echo "FAIL: allow 不在でエラーまたは余計な出力"
    fail=1
  fi

  if [ "$fail" = 0 ]; then
    echo ""
    echo "all tests passed."
    return 0
  fi
  echo ""
  echo "some tests failed."
  return 1
}

target_mcp() {
  # why: mcpServers の headersHelper がこのパスを指すので、設定のマージより先に張る
  link_file "$DOTFILES_DIR/.claude/mcp/github-auth-headers.sh" \
            "$HOME/.claude/mcp/github-auth-headers.sh"

  if [ -f "$HOME/.claude.json" ] && command -v jq &> /dev/null; then
    if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" ]; then
      # $HOST_ENV.json から mcpServers を抽出
      local mcp_servers
      mcp_servers=$(jq '.mcpServers // {}' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json")

      if jq -e '.mcpServers | length > 0' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" &> /dev/null; then
        echo ""
        echo "MCP サーバー設定をマージしています..."

        # .claude.json の mcpServers セクションにマージ。
        # why `+` (サーバ単位の置換) で `*` (再帰マージ) ではない: `*` はキーを
        # 足すだけで消せないので、dotfiles 側からフィールドを削除しても既存
        # ~/.claude.json に古い値が残り続ける。実例として `headers` を
        # `headersHelper` へ移したとき、消えない `Authorization: Bearer ${VAR}` が
        # 未定義の変数を展開して空の Bearer を送り HTTP 400 になる。dotfiles の
        # エントリを唯一の正とし、管理外のサーバ (別ツールが書いたもの) は
        # トップレベルのキーが違うのでそのまま残る。
        jq --argjson new_servers "$mcp_servers" \
           '.mcpServers = (.mcpServers // {}) + $new_servers' \
           "$HOME/.claude.json" > "$HOME/.claude.json.tmp"

        mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
        echo "MCP サーバー設定をマージしました"
      fi
    fi
  fi
}

# ----- 実行 -----

# why リンクより先に返す: --self-test は純粋な検証で、~/.claude 以下を一切触らない。
if [ "$SELF_TEST" = 1 ]; then
  run_prefix_self_test
  exit $?
fi

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
