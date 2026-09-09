---
name: jj-restack-pr
argument-hint: '[PR番号] (省略時は current branch から検知)'
description: |
  PR の差分を jj の change に切り直し、review しやすい単位の列に積み上げるスキル。
  「PR の差分を change に切り直して」「レビューしやすい単位で積み上げて」
  「PR の差分を層に分けて」「この PR の差分を積み直して」等のリクエストで使う。
  PR 番号や PR URL と、change・積み上げ・切り直しが同時に出てきたら発動する。
  対象外: bookmark を付けて push したり PR を作る作業、新規 PR の作成 (create-pr の領分)、
  指摘の投稿 (review-comment)、レビュー対応の修正 (respond-to-pr-review)、
  fork からの PR、jj workspace でないリポジトリ。
---

# jj で PR 差分を review 単位の change に積み直す

jj の操作規律 (preflight・非対話・書き換えの手順) は `jujutsu` スキルに従う。
本スキルは「PR の差分を change の列に作り直す」工程だけを扱い、**ローカルに change の列ができた
時点で終わる**。bookmark・push・PR 作成には進まない。

元の PR のコミットは一切触らない。分岐点の上に新しい change を積むだけなので、
やり直すときは作った change を `jj abandon` すれば元の状態に戻る。

**Bash 呼び出し間でシェル変数は消える。** Phase 2 以降のブロックは、冒頭で `PR` / `FORK` /
`HEAD_OID` に Phase 1 が出力した実値を書き写す。`gh` / `jj` を再実行して計算し直さない。

## 1. 対象を確定する

```bash
PR=''   # 番号を渡されていれば '' を番号に置き換える。空のままなら次行で検知
PR=${PR:-$(gh pr view --json number -q .number)}
jj root > /dev/null || exit 1
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)
HEAD_REF=$(gh pr view "$PR" --json headRefName -q .headRefName)
HEAD_OID=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
[ -n "$BASE" ] && [ -n "$HEAD_REF" ] && [ -n "$HEAD_OID" ] \
  || { echo "PR 情報を取得できません"; exit 1; }
[ "$(gh pr view "$PR" --json isCrossRepository -q .isCrossRepository)" = "false" ] \
  || { echo "fork からの PR は対象外 (remote 追加が別作業)"; exit 1; }
jj git fetch -b "$BASE" -b "$HEAD_REF"
jj log --no-graph -r "$HEAD_OID" -T 'commit_id.short()' \
  || { echo "PR head がローカルに無い"; exit 1; }
FORK=$(jj log --no-graph -r "fork_point(\"$BASE@origin\" | \"$HEAD_OID\")" -T 'commit_id.short() ++ "\n"')
case "$FORK" in
  '')           echo "fork point を取得できません"; exit 1 ;;
  *[!0-9a-f]*)  echo "fork point が一意に定まりません (criss-cross merge)"; exit 1 ;;
esac
[ -n "$(jj log --no-graph -r "\"$FORK\" & ::\"$BASE@origin\"" -T 'commit_id.short()')" ] \
  || { echo "fork point が base の祖先になっていません。base の履歴が書き換わった可能性"; exit 1; }
echo "PR=$PR BASE=$BASE HEAD_REF=$HEAD_REF HEAD_OID=$HEAD_OID FORK=$FORK"
```

`FORK` は base の先頭ではなく分岐点。base が進んでいると差分に base 側の変更が混ざるため。

## 2. 層を決めてプランを承認してもらう

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
jj diff --from "$FORK" --to "$HEAD_OID" --stat
jj diff --from "$FORK" --to "$HEAD_OID"
jj log -r "$FORK..$HEAD_OID"
```

**diff は全文を読む。** `--stat` では 1 ファイル内に複数の層が混在しているかが分からない。

**検証コマンドをここでユーザに確定させる** (`npm test` / `cargo test` 等)。
この直後の判定と Phase 5 の各層検証の両方で使う。

**検証コマンドが無いリポジトリでは、この直後の判定と Phase 5 の各層検証を飛ばす。**
Phase 5 の内容不変の検証は検証コマンドを使わないので必ず行う。
飛ばしたことと「各層が単体で通ることは確認できていない」ことを完了時に伝える。

積み直しが不要なケースを先に外す。**元が 2 コミット以上あって、既に各コミット単位で通るなら
触る意味がない。** `jj log` の見た目で判断しない。依存順序の誤りは diff を読んでも分からないため。
元が 1 コミットのときはこの判定にかけない (自明に通るが、層に割る価値はそれとは別)。

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
if [ "$(jj log --no-graph -r "$FORK..$HEAD_OID" -T '"\n"' | wc -l)" -ge 2 ]; then
  jj run --ignore-changes -r "$FORK..$HEAD_OID" -- <検証コマンド> \
    && { echo "元の履歴が既に全コミットで通る。積み直す理由をユーザに確認してから再開"; exit 1; }
fi
```

**消費される側から順に積む。** 生成物 → 型・スキーマ・契約 → 実装 → テスト → 呼び出し側・画面 → 無関係な混入。

- **「関連がある」は同居理由にならない。** 同居が正当なのは「そのファイルを外すと型チェックかテストが壊れる」場合だけ
- **生成物の判定はファイル名でなく「人間がその diff を手で書いたか」。** 判断がつかなければユーザに確認する。
  lockfile は変更元の設定ファイルと同居させてよい。同居させた層のメッセージにも生成元コマンドを書く
- 実装とテストは別の層。例外は、実装変更で既存テストが壊れて同時修正が要る場合だけ (プランの備考に理由を書く)
- **実装同士が依存していたら実装を複数の層に割る。** import を実測し、依存される側を先に置く
- 1 つの関心が複数の層にまたがってよい。**層の数が分割の単位数**で、関心の数とは一致しない

**1 ファイルに複数の層の変更が混在していたら停止し、次の二択をユーザに出す。**
非対話で使える `jj split` は path 単位までなので、こちら側では hunk を割らない。

- (a) そのファイルを丸ごとどちらか一方の層に寄せる (層分けの精度を落とす)
- (b) ユーザが手元で hunk を分けてから再開する

リネームは旧パスと新パスで 1 単位。リネームと同時に内容も変わっていて別の層に属するなら、
それもこの二択に載せる。

層の数が決まったら先に進めるか判定する。

```bash
LAYERS=<プランの層数>
[ "$LAYERS" -ge 2 ] || { echo "層が 1 つ。分割の実益がないので終了"; exit 1; }
[ "$LAYERS" -le 5 ] || { echo "層が 6 つ以上。ブランチ自体が破綻しているのでユーザに差し戻す"; exit 1; }
```

プラン表 (順 / 層 / メッセージ案 / 対象 path / 依存の根拠) を提示し、承認を取ってから Phase 3 へ進む。
**この承認が Phase 3〜5 全体の唯一のチェックポイント。** 以降は個別確認なしで連続実行する。
Phase 5 の検証が落ちてプランを直したときは、直した内容で改めて承認を取る。

## 3. 1 つの change に平らにする

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
jj new "$FORK" \
  && jj restore --from "$HEAD_OID" \
  && jj describe -m "restack 作業用 (Phase 4 で分割する)" \
  && jj diff --from "$FORK" --to @ > "${TMPDIR:-/tmp/}jj-restack-$PR.before.diff"
```

## 4. 層に切る

プランの下の層から順に、path を指定して切り出す。選んだ path が親、残りが子になる。

```bash
jj split <層 1 の path...> -m "<層 1 のメッセージ>"
jj split <層 2 の path...> -m "<層 2 のメッセージ>"
jj describe -m "<最後の層のメッセージ>"
```

最後の層は残りなので split せず `jj describe` で名前を付ける。
途中で `jj log -r "$FORK..@"` を見て、プランどおりの順序になっているか確認する。

- **判定基準は「その層の意図を 1 つの文で言い切れるか」。** 言い切れず `+` や「、」で並べたく
  なったら層分けが誤っている。Phase 2 に戻して直す
- 生成物の層は**メッセージに生成元コマンドを明記する** (例: `依存パッケージ X を追加 (npm install X)`)。
  後から手書きか生成かを疑わずに済むため
- 本文は元の PR 説明とコミットメッセージから拾う。**元に無い情報を捏造しない。**
  材料が無ければ 1 行だけでよい
- **リネームは旧パスと新パスの両方を path に含める。** 作業ツリーは既に最終状態なので、
  片方だけ指定すると削除と追加が別の層に割れる
- prefix や書式はリポジトリの既存のコミットメッセージ規約に合わせる

## 5. 内容が変わっていないことを検証する

```bash
PR=<番号>
FORK=<Phase 1 の実値>
jj diff --from "$FORK" --to @ > "${TMPDIR:-/tmp/}jj-restack-$PR.after.diff"
diff -u "${TMPDIR:-/tmp/}jj-restack-$PR.before.diff" \
        "${TMPDIR:-/tmp/}jj-restack-$PR.after.diff" \
  || { echo "積み直しで内容が変わりました。jj op log を確認して復旧してください"; exit 1; }
jj log --no-graph -r "$FORK..@ & empty()" -T 'change_id.short() ++ "\n"' | grep . \
  && { echo "空の層があります。その層の path 指定が何も選べていません。Phase 4 をやり直す"; exit 1; }
jj log -r "$FORK..@" -T 'change_id.short() ++ "  " ++ description.first_line() ++ "\n"'
```

**この 2 つの検証を飛ばさない。** path 指定の取りこぼしは静かに起きる。
`jj split` は path が 1 つも当たらなくても成功して空の change を作り、総量は変わらないので、
前後 diff の比較では出ず `empty()` 側でしか検出できない。

各層が単体で通ることも確認する。

```bash
PR=<番号>
FORK=<Phase 1 の実値>
jj run --ignore-changes -r "$FORK..@" -- <Phase 2 で確定した検証コマンド> \
  || { echo "この層で失敗。依存順序を Phase 2 から見直す"; exit 1; }
```

**`Failed revision:` に出るのは失敗が現れた層で、原因の層とは限らない。**
その層より下の層の割り当てを疑う (本来そこに要るファイルが下の層に残っている等)。

立て直しは、積んだ change を捨てて Phase 3 からやり直す。

```bash
PR=<番号>
FORK=<Phase 1 の実値>
jj abandon -r "$FORK..@"
```

**各層が通っても依存順序が正しいとは限らない。** 検証コマンドがその層を通してしまう誤りは
表に出ないので、完了報告で「順序を検証した」と言い切らない。

検証が通ったら、積み上がった change の列を提示して終了する。この先どうするかはユーザが決める。
