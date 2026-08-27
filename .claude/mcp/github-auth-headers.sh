#!/usr/bin/env bash
# GitHub のリモート MCP サーバーへ渡す Authorization ヘッダーを接続時に生成する。
# why: 環境変数に置くと Claude Code が起動する全子プロセスへ配られ、env の出力にも
#      載るのでモデルのコンテキストへ流入しうる。headersHelper なら Claude Code の
#      プロセス内で完結する。GitHub のリモート MCP は OAuth の動的クライアント登録に
#      未対応で Claude Code の OAuth では繋がらないため、トークンを渡す必要がある
set -euo pipefail

# why: gh は Keychain から読み出すだけで、新しいトークンを発行するわけではない
token="$(gh auth token 2>/dev/null || true)"

if [[ -z "$token" ]]; then
  # why: 空文字を渡すと "Bearer " という壊れたヘッダーになり HTTP 400 で原因が
  #      読めない。ヘッダーごと省けば 401 になり認証の問題だと分かる
  echo '{}'
  exit 0
fi

# why: トークンの JSON エスケープを jq に任せて組み立て事故を防ぐ
jq -n --arg t "$token" '{Authorization: ("Bearer " + $t)}'
