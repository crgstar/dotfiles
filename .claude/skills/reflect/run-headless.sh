#!/bin/bash
# 無人 reflect ドライバ (launchd: com.crgstar.reflect が夜間起動)。
# queue.jsonl を 1 件ずつ直列処理し、ヘッドレス claude に /reflect --auto を
# 実行させ、stdout のマーカーをパースして issue 投稿・保留保存・朝サマリ追記を行う。
#
# 権限設計 (outbox パターン): ヘッドレスの claude には書き込み権限を一切与えず、
# 結果はマーカー付き stdout だけで受け取る。gh api POST・ファイル保存・再送は
# すべてこのスクリプト (claude の外) が担う。悪性 transcript がモデルを操っても
# 投稿先・API 形はここに固定されていて変えられない。
#
# 環境変数 (すべて検証用の上書き口。通常は未設定でよい):
#   REFLECT_STATE_DIR  状態ディレクトリ (default: ~/.local/state/reflect)
#   REFLECT_CLAUDE_BIN claude 実体 (default: ~/.local/bin/claude)
#   REFLECT_INBOX      朝サマリの追記先 (default: ~/dotfiles/.local/reflect-inbox.md)
#   REFLECT_ISSUE_REPO issue 投稿先 (default: crgstar/dotfiles)
#   REFLECT_MODEL      ヘッドレスのモデル (default: sonnet)
#   REFLECT_TIMEOUT    claude 1 件あたりの上限秒 (default: 3600)
#   REFLECT_DRY_RUN    1 なら gh api POST せずログに出すだけ

set -u

STATE_DIR="${REFLECT_STATE_DIR:-$HOME/.local/state/reflect}"
QUEUE="$STATE_DIR/queue.jsonl"
PROCESSING="$STATE_DIR/processing.jsonl"
DONE="$STATE_DIR/done"
HOLD="$STATE_DIR/hold"
OUTBOX="$STATE_DIR/outbox"
ATTEMPTS="$STATE_DIR/attempts"
LOG="$STATE_DIR/run.log"
INBOX="${REFLECT_INBOX:-$HOME/dotfiles/.local/reflect-inbox.md}"
CLAUDE_BIN="${REFLECT_CLAUDE_BIN:-$HOME/.local/bin/claude}"
ISSUE_REPO="${REFLECT_ISSUE_REPO:-crgstar/dotfiles}"
MODEL="${REFLECT_MODEL:-sonnet}"
TIMEOUT_SEC="${REFLECT_TIMEOUT:-3600}"
DOTFILES_DIR="$HOME/dotfiles"
# why 2 回で打ち切り: 同じ transcript で毎晩失敗し続けると token を無限に燃やす。
# 2 回失敗した entry は hold に落として人間判断に回す
MAX_ATTEMPTS=2

# why PATH を明示: launchd 起動時の PATH は /usr/bin:/bin 系の最小構成で、
# gh (homebrew) や claude (~/.local/bin) が見えない
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin"

mkdir -p "$STATE_DIR" "$HOLD" "$OUTBOX" "$(dirname "$INBOX")"
exec >>"$LOG" 2>&1

# why stderr 出力: post_issue 等は $(...) で stdout を捕まえられるので、
# stdout に log を混ぜると戻り値 (issue URL) に混入する
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# 多重起動ガード (launchd の catch-up と手動実行の重なり防止)。
# why PID 生存判定: 経過時間だけで stale と断ずると、claude のハング等で
# 長時間残っている「生きた」ドライバから lock を奪い、同じ queue を
# 二重処理して issue を重複投稿してしまう
LOCK="$STATE_DIR/lock"
if [ -d "$LOCK" ]; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    log "既に実行中 (pid=$lock_pid)。終了"
    exit 0
  fi
  log "stale lock を除去 (pid=${lock_pid:-記録なし} は生存していない)"
  rm -rf "$LOCK"
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "lock 取得競合。終了"
  exit 0
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

extract_block() { # $1=タグ名 stdin=claude 出力。マーカー行の間だけを出す
  # why 状態機械: ブロック本文に引用された別タグの開始マーカー (SKILL.md の
  # 例示を含む transcript 等) を新規ブロック開始として拾うと、HOLD に隔離した
  # 内容の一部を OUTBOX として投稿しうる。「最初に開いたブロックが閉じるまで、
  # 他の開始マーカーは本文扱い」にして構造を一意にする
  awk -v tag="$1" '
    inblk == "" && /^<<<REFLECT-(OUTBOX|HOLD|SUMMARY)$/ { inblk = substr($0, 4); next }
    inblk != "" && $0 == inblk ">>>" { inblk = ""; next }
    inblk == "REFLECT-" tag { print }
  '
}

post_issue() { # $1=outbox ファイル (1 行目 "title: ...", 2 行目以降が本文)。成功で issue URL を出力
  local f="$1" title body_file url rc
  title=$(head -n1 "$f" | sed 's/^title: //')
  [ -n "$title" ] || { log "outbox の title が空: $f"; return 1; }
  if [ "${REFLECT_DRY_RUN:-}" = "1" ]; then
    log "DRY_RUN: issue 投稿をスキップ ($f: $title)"
    echo "(dry-run)"
    return 0
  fi
  body_file=$(mktemp "${TMPDIR:-/tmp/}reflect-body-XXXXXX")
  tail -n +2 "$f" >"$body_file"
  url=$(gh api --method POST "/repos/$ISSUE_REPO/issues" \
    -f title="$title" -F body=@"$body_file" --jq .html_url)
  rc=$?
  rm -f "$body_file"
  [ $rc -eq 0 ] && echo "$url"
  return $rc
}

inbox_append() { # $1=見出し行 stdin=本文
  {
    echo ""
    echo "## $1"
    echo ""
    cat
  } >>"$INBOX"
}

attempts_of() {
  local c
  c=$(grep -cF "$1" "$ATTEMPTS" 2>/dev/null)
  echo "${c:-0}"
}
mark_done() { echo "$1" >>"$DONE"; }

log "=== run 開始 (model=$MODEL repo=$ISSUE_REPO dry_run=${REFLECT_DRY_RUN:-0}) ==="

# 1) 前回投稿に失敗した outbox の再送
for f in "$OUTBOX"/*.md; do
  [ -f "$f" ] || continue
  if url=$(post_issue "$f"); then
    log "outbox 再送成功: $f -> $url"
    inbox_append "$(date '+%Y-%m-%d') 再送 $(basename "$f" .md)" <<<"issue: $url"
    rm -f "$f"
  else
    log "outbox 再送失敗 (次回また試す): $f"
  fi
done

# 2) queue を processing に切り出して直列処理。
# why rename 方式: 処理中も SessionEnd hook は queue へ append し続ける。
# 「読み終わってから圧縮結果を mv で書き戻す」方式は読了〜mv の間の append を
# 黙って消す race があるため、先に queue 自体を atomic rename で切り出し、
# 以後 queue には触らない (リトライ分だけ追記する)
if [ -f "$PROCESSING" ]; then
  # 前回クラッシュの残骸。queue に戻して合流 (done フィルタが二重処理を防ぐ)
  log "前回の processing 残骸を queue へ戻す"
  cat "$PROCESSING" >>"$QUEUE"
  rm -f "$PROCESSING"
fi

if [ ! -f "$QUEUE" ]; then
  log "queue なし"
else
  mv "$QUEUE" "$PROCESSING"

  # why fd 3: ループ内の claude / gh が stdin を継承すると processing 本体を
  # 食い進めてしまうので、読み出しを専用 fd に隔離する
  while IFS= read -r entry <&3; do
    [ -n "$entry" ] || continue
    sid=$(jq -r '.session_id // empty' <<<"$entry" 2>/dev/null)
    if [ -z "$sid" ]; then
      # 不正 JSON を残すと永遠に再処理も破棄もされないので、ログに残して捨てる
      log "不正な queue 行を破棄: $entry"
      continue
    fi
    path=$(jq -r '.path // empty' <<<"$entry")
    cwd=$(jq -r '.cwd // empty' <<<"$entry")
    grep -qF "$sid" "$DONE" 2>/dev/null && continue

    if [ ! -f "$path" ]; then
      log "$sid: transcript 消失 ($path)。done 扱い"
      mark_done "$sid"
      continue
    fi

    log "$sid: 処理開始 ($path)"
    # why cd $DOTFILES_DIR: ヘッドレスでは cwd + additionalDirectories (~/.claude)
    # だけが読める。dotfiles を cwd にすると SKILL.md 群と transcript
    # (~/.claude/projects/) の両方が追加権限なしで読める。
    # why perl alarm: macOS に timeout(1) がない。ハングすると lock を握ったまま
    # 翌晩以降も塞ぐので上限必須 (SIGALRM で claude ごと落とす)
    out=$(cd "$DOTFILES_DIR" && REFLECT_HEADLESS=1 \
      perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT_SEC" \
      "$CLAUDE_BIN" -p "/reflect --auto $path" \
      --permission-mode dontAsk --model "$MODEL" </dev/null 2>>"$LOG")
    rc=$?

    if [ $rc -ne 0 ]; then
      echo "$sid" >>"$ATTEMPTS"
      if [ "$(attempts_of "$sid")" -ge "$MAX_ATTEMPTS" ]; then
        log "$sid: claude 失敗 (exit=$rc) が $MAX_ATTEMPTS 回目。hold へ"
        printf '%s\n' "$out" >"$HOLD/$sid-error.txt"
        # why ブレース必須: 直後が全角文字だと bash が変数名境界を誤認識する
        inbox_append "$(date '+%Y-%m-%d') $sid" <<<"処理失敗 x${MAX_ATTEMPTS}。hold/$sid-error.txt を確認"
        mark_done "$sid"
      else
        log "$sid: claude 失敗 (exit=$rc)。queue へ戻して次回リトライ"
        printf '%s\n' "$entry" >>"$QUEUE"
      fi
      continue
    fi

    summary=$(extract_block SUMMARY <<<"$out")
    if [ -z "$summary" ]; then
      # マーカーなし = スキルが指示に従えていない。誤投稿より保留に倒す
      log "$sid: SUMMARY マーカーなし (パース不能)。hold へ"
      printf '%s\n' "$out" >"$HOLD/$sid-parse-error.txt"
      inbox_append "$(date '+%Y-%m-%d') $sid" <<<"出力がパース不能。hold/$sid-parse-error.txt を確認"
      mark_done "$sid"
      continue
    fi

    status_line=""
    hold_block=$(extract_block HOLD <<<"$out")
    outbox_block=$(extract_block OUTBOX <<<"$out")
    if [ -n "$hold_block" ]; then
      # §6 の契約で HOLD と OUTBOX は排他。両方来たら全体を保留に倒す
      # (監査で止めた内容の取りこぼし投稿を防ぐ)
      {
        printf '%s\n' "$hold_block"
        if [ -n "$outbox_block" ]; then
          printf '\n--- 同時に返された OUTBOX (契約違反のため投稿していない) ---\n%s\n' "$outbox_block"
        fi
      } >"$HOLD/$sid.md"
      log "$sid: 監査保留 -> hold/$sid.md"
      status_line="監査保留: hold/$sid.md"
    elif [ -n "$outbox_block" ]; then
      printf '%s\n' "$outbox_block" >"$OUTBOX/$sid.md"
      if url=$(post_issue "$OUTBOX/$sid.md"); then
        log "$sid: issue 投稿成功 -> $url"
        rm -f "$OUTBOX/$sid.md"
        status_line="issue: $url"
      else
        log "$sid: issue 投稿失敗。outbox に保持し次回再送"
        status_line="issue 投稿失敗 (outbox 再送待ち)"
      fi
    fi

    {
      printf '%s\n' "$summary"
      [ -n "$status_line" ] && printf '\n%s\n' "$status_line"
    } | inbox_append "$(date '+%Y-%m-%d') $sid ($cwd)"
    mark_done "$sid"
    log "$sid: 完了"
  done 3<"$PROCESSING"

  rm -f "$PROCESSING"
fi

log "=== run 終了 ==="
