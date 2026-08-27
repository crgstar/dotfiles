---
name: permission-triage
description: >
  Bash コマンドの実行時に許可ダイアログ (permission prompt) が出る原因を切り分け、
  恒久的に通せるようにするスキル。「なぜ許可ダイアログが出る」「ask になる理由」
  「毎回聞かれるのを止めたい」「確認が出ないようにして」「このコマンドを許可リストに
  追加して」「permission を通して」のようなリクエストで使う。許可ダイアログ・ask・
  permission prompt・確認が出る、に言及されたら積極的に使うこと。
  対象外: additionalDirectories の管理 (add-dir-manager の領分)、Read/Edit の
  ファイル権限ルール、hook の新規作成そのもの。
---

# 許可ダイアログの切り分け

判定の仕様は [.claude/rules/hook-permission.md](../../rules/hook-permission.md) にある。触る前に読む。
本スキルは切り分けの手順だけを持つ。

## 1. 判定を実測で再現する

推測しない。問題のコマンドを実際に hook へ流す。複数の hook が同時に絡むので、
どれが確認を出しているかは流さないと分からない。

コマンドは原文をファイルへ貼り、組み立て直さない。文字列連結や引用符の書き換えで前半の
セグメントが落ちても出力は自然に見えるので、別のコマンドを検査したまま結論を出してしまう。

```bash
set -e
cd "$(git rev-parse --show-toplevel)"
[ -f .claude/settings.merged.json ] || { echo "settings.merged.json が無い。先に ./setup.sh <env>"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp/}perm-XXXXXX")
cat > "$TMP/cmd.txt" <<'CMD_EOF'
<問題のコマンドをそのまま貼る>
CMD_EOF
python3 -c 'import json,sys,os; print(json.dumps({"tool_name":"Bash","tool_input":{"command":open(sys.argv[1]).read().rstrip("\n")},"cwd":os.getcwd(),"session_id":"triage"}))' "$TMP/cmd.txt" > "$TMP/in.json"
echo "検査対象: $(cat "$TMP/cmd.txt")"
jq -r '(.hooks.PreToolUse[]?, .hooks.PermissionRequest[]?) | select(.matcher=="Bash") | .hooks[]?.command' \
  .claude/settings.merged.json | sort -u |
while read -r h; do printf '%s\n  ' "$h"; eval "$h" < "$TMP/in.json" || echo "(hook が異常終了。判定不能)"; echo; done
echo "TMP=$TMP"
```

出力した「検査対象」が問題のコマンドと一字一句同じか確かめてから、判定を読む。

返り値の読み方:

- `{}` — その hook は判定を放棄し、静的ルールに委ねた
- `allow` — その hook が通した。確認は出ない
- `ask` / `deny` — その hook が止めた。理由が併記される

`rm` の切り分けだけは `session_id` に実セッションの値が要る (scratchpad の実パスと照合するため)。

## 2. 全 hook が `{}` なら静的ルールを見る

hook が誰も判定していないので、確認の有無は許可リストだけで決まる。該当パターンを直接探す。

```bash
cd "$(git rev-parse --show-toplevel)"
jq -r '.permissions.ask[]?'   .claude/settings.merged.json | grep -i '<コマンド名>' || echo "(ask に該当なし)"
jq -r '.permissions.allow[]?' .claude/settings.merged.json | grep -i '<コマンド名>' || echo "(allow に該当なし)"
```

- **ask にある** → 明示的に止められている
- **allow にある** → そもそも確認に落ちない。「確認が出た」という前提の方を疑う
- **どちらにも無い** → 許可リストに未収載なので既定で確認になる

## 3. セグメント単位で切り分ける

複合コマンドは `;` `&&` `||` `|` で分割されて 1 つずつ判定され、1 つでも許可されない
セグメントがあると全体が確認に落ちる。セグメントを削りながら 1 を繰り返し、原因を 1 つに絞る。
区切りが無い単一コマンドならこの手順は飛ばす。

## 4. 設定を緩める前に、書き方を疑う

原因セグメントを消しても同じ結果を得られないか先に考える。不要な `cd`、cwd に依存しない
指定への置き換えで済むなら設定は変えない。許可を広げるのは取り消しにくいため。

## 5. 原因の層で手を入れる場所が変わる

- **コマンドの書き方** → 書き換えて終わり
- **`permissions.ask` に明示** → 許可リストでは解除できない。PermissionRequest hook に
  判定を足して allow を返す (既存 hook の対象を広げるのが第一手)
- **許可リストに未収載** → `permissions.allow` に追加し `./setup.sh <env>` で再生成
- **hook の構造判定が未対応** → hook 側のホワイトリストを広げる (静的 allow ではなく hook 側)

## 6. 緩めるなら、何が新たに通るかを列挙する

そのパターンを許可したとき成立する組み合わせを、既存の `permissions.allow` と突き合わせて挙げ、
ユーザに示してから変更する。前段が 1 つ増えるだけで対象が広がるのは、cwd 依存で副作用を持つ
コマンド (テストランナー・パッケージ実行・ディレクトリ生成) と、相対パスで実体が決まる hook 判定。

## 7. 変更したら検証する

- hook を触ったら `bash .claude/hooks/<name>.sh --self-test`
- 許可リストを触ったら `./setup.sh <env>` の後に 1 を再実行し、allow が返ることを確認する
