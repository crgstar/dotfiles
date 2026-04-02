#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_ENV="${1:-}"

MERGE_TOOL="${MERGE_TOOL:-code --wait --diff}"

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
  read -rp "  選択 [n/k/m/s]: " choice

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
      read -rp "  この内容でよいですか？ [y/n]: " confirm

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
    ln -sf "$src" "$dest"

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
      read -rp "  選択 [d/e/m/s]: " choice

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
          read -rp "  この内容でリンクしますか？ [y/n]: " confirm

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

# ----- Shell -----

link_file "$DOTFILES_DIR/.zshrc" \
          "$HOME/.zshrc"

if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/zshrc.local/$HOST_ENV.zsh" ]; then
  link_file "$DOTFILES_DIR/zshrc.local/$HOST_ENV.zsh" \
            "$HOME/.zshrc.local"
fi

# ----- Claude Code -----

# 環境別設定のマージ
if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" ]; then
  echo "環境: $HOST_ENV"

  if command -v jq &> /dev/null; then
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

      [.[0], .[1]] | merge_with_arrays
    ' \
      "$DOTFILES_DIR/.claude/settings.json" \
      "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" \
      > "$DOTFILES_DIR/.claude/settings.merged.json.tmp"

    safe_overwrite "$DOTFILES_DIR/.claude/settings.merged.json.tmp" \
                   "$DOTFILES_DIR/.claude/settings.merged.json"

    link_file "$DOTFILES_DIR/.claude/settings.merged.json" \
              "$HOME/.claude/settings.json"

    echo "設定をマージしました: settings.json + settings.local/$HOST_ENV.json"
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

# CLAUDE.md の結合（共通 + 環境別）
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

link_file "$DOTFILES_DIR/.claude/skills/docbase-mermaid/SKILL.md" \
          "$HOME/.claude/skills/docbase-mermaid/SKILL.md"

# MCP サーバー設定のマージ
if [ -f "$HOME/.claude.json" ] && command -v jq &> /dev/null; then
  if [ -n "$HOST_ENV" ] && [ -f "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" ]; then
    # $HOST_ENV.json から mcpServers を抽出
    MCP_SERVERS=$(jq '.mcpServers // {}' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json")

    if jq -e '.mcpServers | length > 0' "$DOTFILES_DIR/.claude/settings.local/$HOST_ENV.json" &> /dev/null; then
      echo ""
      echo "MCP サーバー設定をマージしています..."

      # .claude.json の mcpServers セクションにマージ
      jq --argjson new_servers "$MCP_SERVERS" \
         '.mcpServers = (.mcpServers // {}) * $new_servers' \
         "$HOME/.claude.json" > "$HOME/.claude.json.tmp"

      mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
      echo "MCP サーバー設定をマージしました"
    fi
  fi
fi

echo ""
echo "done!"
