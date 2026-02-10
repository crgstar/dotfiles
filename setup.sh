#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_ENV="${1:-}"

MERGE_TOOL="${MERGE_TOOL:-code --wait --diff}"

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
      > "$DOTFILES_DIR/.claude/settings.merged.json"

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

link_file "$DOTFILES_DIR/.claude/skills/docbase-mermaid/SKILL.md" \
          "$HOME/.claude/skills/docbase-mermaid/SKILL.md"

echo ""
echo "done!"
