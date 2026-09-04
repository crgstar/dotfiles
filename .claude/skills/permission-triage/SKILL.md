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

## 1. まず実行して、確認が出ることを見る

切り分けを始める前に、問題のコマンドをそのまま 1 度実行する。ユーザが拒否すれば、
その拒否自体が「確認が出る」ことの証拠になり、コマンドは実行されない。

確認が出ずに通ったら切り分けは要らない。「確認が出た」という前提の方を疑う。

## 2. 判定を実測で再現する

推測しない。問題のコマンドを実際に hook へ流す。複数の hook が同時に絡むので、
どれが確認を出しているかは流さないと分からない。

コマンドは原文をファイルへ貼り、組み立て直さない。文字列連結や引用符の書き換えで前半の
セグメントが落ちても出力は自然に見えるので、別のコマンドを検査したまま結論を出してしまう。

確認ダイアログや会話ログからのコピーで行頭に枠線 (`│`) が付いていても、そのままでよい。
下記の `jq -Rr sub` が落とす。ただし枠内で折り返された改行は残るので、元が 1 行なら手で 1 行に戻す。

```bash
set -e
cd "$(git rev-parse --show-toplevel)"
[ -f .claude/settings.merged.json ] || { echo "settings.merged.json が無い。先に ./setup.sh <env>"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp/}perm-XXXXXX")
cat > "$TMP/raw.txt" <<'CMD_EOF'
<問題のコマンドをそのまま貼る>
CMD_EOF
jq -Rr 'sub("^[ \t]*│ ?";"")' < "$TMP/raw.txt" > "$TMP/cmd.txt"
jq -Rs --arg cwd "$PWD" '{tool_name:"Bash",tool_input:{command:(sub("\n$";""))},cwd:$cwd,session_id:"triage"}' \
  < "$TMP/cmd.txt" > "$TMP/in.json"
echo "検査対象:"; cat "$TMP/cmd.txt"; echo "----"
jq -r '(.hooks.PreToolUse[]?, .hooks.PermissionRequest[]?) | select(.matcher=="Bash") | .hooks[]?.command' \
  .claude/settings.merged.json | sort -u |
while read -r h; do
  printf '%-34s ' "$(basename "${h##* }")"
  eval "$h" < "$TMP/in.json" |
    jq -rc '.hookSpecificOutput | (.permissionDecision // .decision.behavior // "{}")' 2>/dev/null ||
    echo "(hook が異常終了。判定不能)"
done
echo "TMP=$TMP"
```

JSON の組み立てに python を使わない。python は許可リストに無いので、切り分け用のコマンド自身が
確認に落ちて手が止まる。

出力した「検査対象」が問題のコマンドと一字一句同じか確かめてから、判定を読む。

返り値の読み方:

- `{}` — その hook は判定を放棄し、静的ルールに委ねた
- `allow` — その hook が通した。確認は出ない
- `ask` — その hook が止めた。**ダイアログが出て人間の手が止まる**
- `deny` — その hook が止めた。**ダイアログは出ず、理由がモデルへ返って書き直しになる**

`ask` と `deny` は「止めた」点は同じでも、手が止まるかどうかが違う。目的が「毎回聞かれるのを
止めたい」なら、この区別が打ち手を決める。理由の全文が要るときは
`eval "$h" < "$TMP/in.json"` を単独で叩く。

`rm` の切り分けだけは `session_id` に実セッションの値が要る (scratchpad の実パスと照合するため)。

## 3. 全 hook が `{}` なら静的ルールを見る

hook が誰も判定していないので、確認の有無は許可リストだけで決まる。該当パターンを直接探す。

```bash
cd "$(git rev-parse --show-toplevel)"
jq -r '.permissions.ask[]?'   .claude/settings.merged.json | grep -i '<コマンド名>' || echo "(ask に該当なし)"
jq -r '.permissions.allow[]?' .claude/settings.merged.json | grep -i '<コマンド名>' || echo "(allow に該当なし)"
```

- **ask にある** → 明示的に止められている
- **allow にある** → そもそも確認に落ちない。「確認が出た」という前提の方を疑う
- **どちらにも無い** → 許可リストに未収載なので既定で確認になる

## 4. セグメント単位で切り分ける

複合コマンドは `;` `&&` `||` `|` と**改行**で分割されて 1 つずつ判定され、1 つでも許可されない
セグメントがあると全体が確認に落ちる。セグメントを削りながら 2 を繰り返し、原因を 1 つに絞る。
区切りがまったく無い単一行コマンドならこの手順は飛ばす。

改行も区切りなので、複数行コマンドは見た目が 1 コマンドでも複数セグメントに割れる。
改行を `;` に置き換えるだけで結果が変わることがある。

## 5. 設定を緩める前に、書き方を疑う

原因セグメントを消しても同じ結果を得られないか先に考える。不要な `cd`、cwd に依存しない
指定への置き換え、python を jq に替える、で済むなら設定は変えない。許可を広げるのは
取り消しにくいため。

## 6. 原因の層で手を入れる場所が変わる

- **コマンドの書き方** → 書き換えて終わり
- **`permissions.ask` に明示** → 許可リストでは解除できない。PermissionRequest hook に
  判定を足して allow を返す (既存 hook の対象を広げるのが第一手)
- **許可リストに未収載で、通してよいもの** → `permissions.allow` に追加し `./setup.sh <env>` で再生成
- **許可リストに未収載で、通すべきでないもの** → PreToolUse hook で deny を返し、代替の書き方を
  理由に添えてモデルに書き直させる。ダイアログが出ないので手が止まらない。
  理由に代替コマンドを書いたら、**その代替コマンド自身が同じ判定で止まらないか**を確かめ、
  素通しになることを self-test に固定する。塞がれていると案内どおり書き直しても同じ差し戻しに戻る
- **hook の構造判定が未対応** → hook 側のホワイトリストを広げる (静的 allow ではなく hook 側)

## 7. 変更する前に、影響を実ログで測る

見積もりを口で言わない。過去のセッションログから実際のコマンドを取り出して数える。

```bash
LOG=$(mktemp -d "${TMPDIR:-/tmp/}permlog-XXXXXX")
ls -t ~/.claude/projects/*/*.jsonl | head -400 > "$LOG/sessions.txt"
jq -j 'select(.type=="assistant") | .message.content[]?
       | select(.type=="tool_use" and .name=="Bash") | .input.command
       | select(test("<対象パターン>")) | (., "@@@SPLIT@@@")' \
  $(cat "$LOG/sessions.txt") 2>/dev/null > "$LOG/all.txt"
mkdir -p "$LOG/cmds"
awk -v dir="$LOG/cmds" 'BEGIN{RS="@@@SPLIT@@@"} length($(0))>0 { f=dir"/c"NR".txt"; printf "%s", $(0) > f; close(f) }' "$LOG/all.txt"
ls "$LOG/cmds" | wc -l
```

区切りに NUL を使わない。ツール入力の検証で制御文字として弾かれる。
awk のレコード参照は `$(0)` と書く。括弧を外した形は、スキルをスラッシュコマンドで起動したとき引数に展開されて潰れる。

取り出したコマンドを変更前後の hook それぞれに流し、判定が変わった件数を数える。変更前の hook は
`git show HEAD:<path> > <同じディレクトリ>/<name>.old.sh` で取り出す。`lib/` を相対で解決するので
別の場所に置くと動かない (取り出しに失敗しても hook は静かに空を返すだけなので、
比較の前に旧版が単体で判定を返すことを確かめる)。

- **緩める変更** → 新たに通る件数と中身。そのパターンを許可したとき何が成立するかを
  既存の `permissions.allow` と突き合わせて挙げ、ユーザに示してから変更する
- **締める変更 (deny を足す)** → 新たに止まる件数と中身。1 件ずつ開いて誤検知が無いか確かめる。
  文字列に出てくるだけで実行されないもの (heredoc の中身、検索パターンの一部) が紛れやすい

数えた結果が見積もりと食い違ったら、見積もりの方を捨てる。

## 8. 変更したら検証する

- hook を触ったら `bash .claude/hooks/<name>.sh --self-test`。共有ライブラリを触ったなら、
  それを source する hook すべての self-test も回す
- 許可リストを触ったら `./setup.sh <env>` の後に 2 を再実行し、allow が返ることを確認する
- 7 で取り出したコマンド群に再度当て、件数と中身が意図どおりか確かめる
- 最後に 1 をもう一度やる。実際に実行して、確認が出ない (または狙いどおり差し戻される) ことを見る

## 説明は前提から

原因を言う前に、確認を出しうる静的ルール・hook・分類器の 3 層と、層ごとに違う発火条件を示す。
層が決まらないと 6 の手を入れる場所も決まらない。
