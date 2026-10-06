#!/usr/bin/env bash
# Backlog MCP サーバー (stdio) を、接続先ドメインと API キーを Keychain から読んで起動する。
# why: mcpServers の env に書くと公開リポの dotfiles に値が載る。シェルの環境変数に置くと
#      Claude Code が起動する全子プロセスへ配られ、env の出力からモデルのコンテキストへ流入しうる。
#      ここで読めば値は Backlog サーバーのプロセスにだけ渡る
# 登録: security add-generic-password -U -s backlog-mcp -a domain -w '<space>.backlog.com'
#       security add-generic-password -U -s backlog-mcp -a api-key -w
#       (API キーは -w を末尾に置いて対話入力する。引数で渡すとシェル履歴と ps に残る)
set -euo pipefail

read_keychain() {
  # why: stderr は捨てない。キーチェーンのロックやアクセス拒否でも空が返るので、
  #      「未登録」の案内だけだと原因を取り違える。security の理由文を MCP ログに残す
  security find-generic-password -s backlog-mcp -a "$1" -w || true
}

domain="$(read_keychain domain)"
api_key="$(read_keychain api-key)"

if [[ -z "$domain" || -z "$api_key" ]]; then
  # why: stdout は MCP の JSON-RPC 経路なので、案内は stderr に出す
  echo "backlog-mcp: Keychain に service=backlog-mcp の domain / api-key がありません" >&2
  exit 1
fi

export BACKLOG_DOMAIN="$domain" BACKLOG_API_KEY="$api_key"
# why: 版を固定しないと npx が起動のたびに最新版を取得して実行する
exec npx -y backlog-mcp-server@0.20.5
