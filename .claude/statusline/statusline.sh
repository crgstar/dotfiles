#!/usr/bin/env bash
# Claude Code の statusLine ラッパ。
# why: statusLine に登録できるコマンドは 1 つだけなので、RunCat Neo 用スナップショットの
#      書き出しと端末表示 (ccstatusline) をここで束ねる。stdin の JSON は 1 度しか読めない
#      ため、一旦変数に受けてから両者へ配る。
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

payload=$(cat)

# why: スナップショット生成 (python3 不在・書き込み失敗を含む) が転けても端末表示は落とさない。
#      失敗しても RunCat のカードが古いまま残るだけで、統計行は従来どおり出る。
#      runcat-statusline.py は上流サンプルのまま置いてあり (上流更新をそのまま取り込めるように)、
#      モデル名を stdout に出すのでここで捨てる。
printf '%s' "$payload" | "$SCRIPT_DIR/runcat-statusline.py" >/dev/null 2>&1 || true

printf '%s' "$payload" | npx -y ccstatusline@latest
