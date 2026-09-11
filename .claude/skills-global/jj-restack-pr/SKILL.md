---
name: jj-restack-pr
argument-hint: '[PR番号] (省略時は current branch から検知)'
description: |
  PR の差分を jj の change に切り直し、review しやすい単位の列に積み上げるスキル。
  「PR の差分を change に切り直して」「レビューしやすい単位で積み上げて」
  「PR の差分を層に分けて」「この PR の差分を積み直して」
  「前提から順に読めるように並べ直して」等のリクエストで使う。
  PR 番号や PR URL と、change・積み上げ・切り直しが同時に出てきたら発動する。
  対象外: push や PR 作成 (create-pr の領分)、
  指摘の投稿 (review-comment)、レビュー対応の修正 (respond-to-pr-review)、
  fork からの PR。
---

# jj で PR 差分を review 単位の change に積み直す

jj の操作規律 (preflight・非対話・書き換えの手順) は `jujutsu` スキルに従う。
本スキルは「PR の差分を change の列に作り直す」工程だけを扱い、**列に bookmark を付けた時点で
終わる**。push・PR 作成には進まない。

元の PR のコミットは一切触らない。分岐点の上に新しい change を積むだけなので、
やり直すときは作った change を `jj abandon` すれば元の状態に戻る。

**Bash 呼び出し間でシェル変数は消える。** Phase 2 以降のブロックは、冒頭で `PR` / `BASE` /
`FORK` / `HEAD_OID` に Phase 1 が出力した実値を書き写す。`gh` / `jj` を再実行して計算し直さない。

## 目的を先に確定する

依頼は 2 通りある。**どちらかを Phase 2 に入る前にユーザの言葉から判定する。**
選び違えると、以降の層数の判定も分割の粒度も全部ずれるため。

- **最小構成** — 「レビュー単位に割って」だけのとき。同じ変更を最も少ない change に整理する
- **読み順** — 「前提から順に」「ストーリーを考えて」「量はどんなに多くてもよい」等が出たとき。
  読み手が上から 1 つずつ読んで詰まらない列を作る。change 数は制約にしない

## colocated リポジトリでの書き換えは 1 件ずつ掃除する

`.git` と `.jj` が同居するリポジトリでは、列の途中の change を書き換えるたびに git HEAD の
取り込みが走り、**書き換え前のスタックが `wip/detached-*` bookmark 付きで visible に戻って
change-id が divergent になる**。divergent になった change は `jj describe -r <change-id>` が
エラーで止まるため、describe や rebase をまとめて流すと途中で止まる。

**該当するのは Phase 5 の並べ替え・畳み込みと、Phase 4 で作り直すときの `jj abandon`。**
Phase 3 は列の末尾に積むだけなので要らない。**書き換えを 1 件ごとに次で挟む。**
復活したスタックは自分が作った重複コピーなので捨ててよい (元の PR と base は revset で除外している)。

```bash
BASE=<Phase 1 の実値>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
jj bookmark list | sed -n 's|^\(wip/[^:]*\):.*|\1|p' | while read -r b; do jj bookmark delete "$b"; done
jj abandon -r "\"$FORK\":: & ~::@ & ~::\"$HEAD_OID\" & ~::\"$BASE@origin\""
```

掃除が要ったかどうかに関わらず、Phase 4 の検証前に `change_id` の重複が 0 件であることを確認する。

## レビューが並走しているときの制約

別セッションや diff ビューアがこの列をレビュー中なら、指摘は change-id で紐付けられている。
**change-id が壊れる操作 (`jj squash` / `jj split` / 差分の作り直し) をしたら、どの change に
何をしたかを伝える。** 紐付けの張り直しがレビュー側の作業になるため。
describe・rebase・順序の入れ替えは change-id が残るので連絡は要らない。

**Phase 7 でブランチを付ける前にも伝えて返事を待つ。** detached HEAD 前提で表示を絞っている
ツールだと、列が画面から消えることがある。

## 1. 対象を確定する

```bash
PR=''   # 番号を渡されていれば '' を番号に置き換える。空のままなら次行で検知
PR=${PR:-$(gh pr view --json number -q .number)}
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)
HEAD_REF=$(gh pr view "$PR" --json headRefName -q .headRefName)
HEAD_OID=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
[ -n "$BASE" ] && [ -n "$HEAD_REF" ] && [ -n "$HEAD_OID" ] \
  || { echo "PR 情報を取得できません"; exit 1; }
[ "$(gh pr view "$PR" --json isCrossRepository -q .isCrossRepository)" = "false" ] \
  || { echo "fork からの PR は対象外 (remote 追加が別作業)"; exit 1; }
jj root > /dev/null \
  || { echo "jj repo でない。colocate 化するかユーザに確認してから jj git init --colocate"; exit 1; }
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
`BASE` は Phase 2 以降でも使う (base ブランチが `main` でないことがある。掃除の revset に要る)。

**上のガードで止まったら、いずれも終了してユーザに差し戻す。** jj repo でないときは colocate 化の
可否を聞き、断られたら終わる (git だけではこの工程はできない)。base が force-push されていたら、
PR を base に追随させるのが先。

**`jj git init --colocate` 直後は commit の author が空になる。** 積み終えたら
`jj config set --repo user.name` / `user.email` を git 側の設定と同じ値で入れ、
`jj metaedit --update-author -r "$FORK..@-"` で付け直す。

## 2. 読む順を決めてプランを承認してもらう

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
jj diff --from "$FORK" --to "$HEAD_OID" --stat
jj diff --from "$FORK" --to "$HEAD_OID"
jj log --no-graph -r "$FORK..$HEAD_OID" -T 'description ++ "\n"'
gh pr view "$PR" --json body -q .body
```

**diff は全文を読む。** `--stat` では 1 ファイル内に複数の層が混在しているかが分からない。
**元のコミットメッセージ本文と PR 本文も全部読む。** Phase 6 で書く本文の材料はここにしかなく、
無ければ捏造せず 1 行で済ませることになるため。

**検証コマンドをここでユーザに確定させる** (`npm test` / `cargo test` 等)。
この直後の判定と Phase 4 の各層検証の両方で使う。

**検証コマンドが無いリポジトリでは、この直後の判定と Phase 4 の各層検証を飛ばす。**
Phase 4 の内容不変の検証は検証コマンドを使わないので必ず行う。
飛ばしたことと「各層が単体で通ることは確認できていない」ことを完了時に伝える。

積み直しが不要なケースを先に外す。**最小構成の依頼で、元が 2 コミット以上あって、既に各コミット
単位で通るなら触る意味がない。** `jj log` の見た目で判断しない。依存順序の誤りは diff を読んでも
分からないため。元が 1 コミットのときと、読み順の依頼のときはこの判定にかけない。

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
MODE=<minimal | reading>
if [ "$MODE" = minimal ] && [ "$(jj log --no-graph -r "$FORK..$HEAD_OID" -T '"\n"' | wc -l)" -ge 2 ]; then
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

読み順の依頼では、さらに次を守る。

- **プランを章に分ける。1 章 = 読み手が 1 つの主題として読む範囲** (1 つのリソース、1 つの共通土台)。
  この章が Phase 6 の prefix になるので、章の切り方がそのまま読み口になる
- **1 つの章の中では同じ並びを繰り返す** (契約 → 実装 → テスト → 呼び出し側 等)。
  章をまたいでも同じリズムだと、2 章目以降は差分だけ見れば済む
- **1 つの章しか使わない前提は、共通土台の章ではなくその章の先頭に置く。**
  「何のために要るのか」が直後の change で回収されるため
- **同形のリソースが並ぶときは、1 つを単独の章にし、残りは 1 つの章にまとめる。**
  手本を読めば残りは置換だけなので、残りは 1 章に何本入っていても読む負荷が増えない

**1 ファイルに複数の層の変更が混在していたら、次の三択をユーザに出す。**
非対話で使える `jj split` は path 単位までなので、split では hunk を割れない。

- (a) **最終状態から中間状態を手で作って積む** (推奨。Phase 3 参照。層分けの精度を落とさずに済む)
- (b) そのファイルを丸ごとどちらか一方の層に寄せる (層分けの精度を落とす)
- (c) ユーザが手元で hunk を分けてから再開する

リネームは旧パスと新パスで 1 単位。リネームと同時に内容も変わっていて別の層に属するなら、
それもこの三択に載せる。

層の数が決まったら先に進めるか判定する。

```bash
LAYERS=<プランの層数>
MODE=<minimal | reading>
# 下限はモードに関わらず効く。上限は最小構成だけ
[ "$LAYERS" -ge 2 ] || { echo "層が 1 つ。分割の実益がないので終了"; exit 1; }
[ "$MODE" = reading ] || [ "$LAYERS" -le 5 ] \
  || { echo "最小構成で層が 6 つ以上。ブランチ自体が破綻しているのでユーザに差し戻す"; exit 1; }
```

プラン表 (順 / 層 / メッセージ案 / 対象 path / 依存の根拠) を提示し、承認を取ってから Phase 3 へ進む。
**この承認が Phase 3〜7 全体の唯一のチェックポイント。** 以降は個別確認なしで連続実行する。
Phase 4 の検証が落ちてプランを直したときは、直した内容で改めて承認を取る。
**読み順モードではプランを HTML で見せる** (保存先とビューアは `CLAUDE.md` の規約に従う)。
表が縦に長いと地の文では読み合わせが往復するため。

## 3. 下から順に積む

分岐点の上に空の change を作り、プランの下の層から順に最終状態を取り込んで確定していく。
`jj split` で上から割るのではなく下から積むのは、**hunk 混在ファイルの中間状態を途中に混ぜられる**
ため。全層を積み終えた時点で作業ツリーの残差が空になる。

```bash
PR=<番号>
FORK=<Phase 1 の実値>
HEAD_OID=<Phase 1 の実値>
jj new "$FORK" -m "restack 作業用" \
  && jj diff --from "$FORK" --to "$HEAD_OID" --git > "${TMPDIR:-/tmp/}jj-restack-$PR.before.diff"
# 各層: 最終状態を丸ごと取る層
jj restore --from "$HEAD_OID" <層の path...> && jj commit -m "<層のメッセージ>"
# 各層: hunk 混在ファイルを含む層は、その 1 ファイルだけ中間状態を書いて置く
cp <中間状態ファイル> <対象 path> && jj commit -m "<層のメッセージ>"
```

**中間状態は最終状態から作る。** 最終ファイルを `jj file show -r "$HEAD_OID" <path>` で取り、
まだ入っていない hunk の行を落としたものを層ごとに用意する。**行番号は最終ファイルを
行番号付きで読んでから決める** (目算しない)。落とす行の選び方を誤っても Phase 4 の
byte 一致で必ず出る。
**そのファイルにとって最後の層は、中間状態を書かず `jj restore --from "$HEAD_OID"` で当てる。**
手で書いた最終状態が 1 文字でもずれると byte 一致が落ちるため。

- **判定基準は「その層の意図を 1 つの文で言い切れるか」。** 言い切れず `+` や「、」で並べたく
  なったら層分けが誤っている。Phase 2 に戻して直す
- **リネームは旧パスと新パスの両方を path に含める。** 片方だけ指定すると削除と追加が別の層に割れる
- 途中で `jj log -r "$FORK..@"` を見て、プランどおりの順序になっているか確認する

## 4. 内容が変わっていないことを検証する

```bash
PR=<番号>
FORK=<Phase 1 の実値>
jj diff --stat   # 残差。空でなければ積み残しがある
jj diff --from "$FORK" --to @ --git > "${TMPDIR:-/tmp/}jj-restack-$PR.after.diff"
diff -u "${TMPDIR:-/tmp/}jj-restack-$PR.before.diff" \
        "${TMPDIR:-/tmp/}jj-restack-$PR.after.diff" \
  || { echo "積み直しで内容が変わりました。jj op log を確認して復旧してください"; exit 1; }
jj log --no-graph -r "$FORK..@ & empty()" -T 'change_id.short() ++ "\n"' | grep . \
  && { echo "空の層があります。その層の path 指定が何も選べていません。Phase 3 をやり直す"; exit 1; }
for c in $(jj log --no-graph -r "$FORK..@-" -T 'change_id.short() ++ "\n"'); do
  [ "$(jj log --no-graph -r "change_id($c)" -T '"\n"' | wc -l)" -gt 1 ] && echo "divergent: $c"
done
```

**この検証を飛ばさない。** path 指定の取りこぼしは静かに起きる。
取りこぼした path はどこかの層に必ず残るので総量は変わらず、前後 diff の比較では出ない。
`empty()` と残差の両方で見る。

各層が単体で通ることも確認する。**`jj run` は隔離した working copy で実行するので、
git 管理外の依存物が無い。** 本体からリンクする wrapper 越しに走らせる。リンクするのは
そのリポジトリで `.gitignore` されている依存物ディレクトリ (`node_modules` / `vendor` /
`target` 等。無いエコシステムならリンク行を消す)。
`--ignore-errors` は付けない (失敗が `jj run` の exit code に出なくなる)。

```bash
cat > "${TMPDIR:-/tmp/}jj-restack-verify.sh" <<'EOF'
#!/bin/sh
cd "$JJ_WORKSPACE_ROOT" || exit 1
[ -e <依存物ディレクトリ> ] || ln -s <本体の絶対パス>/<依存物ディレクトリ> <依存物ディレクトリ>
<Phase 2 で確定した検証コマンド>
EOF
chmod +x "${TMPDIR:-/tmp/}jj-restack-verify.sh"
jj run --ignore-changes -j 4 -r "$FORK..@-" -- "${TMPDIR:-/tmp/}jj-restack-verify.sh" \
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

## 5. 1 change ずつ読んで成立するか洗う

検証コマンドが通っても「上から 1 つずつ読める」ことは保証されない。**次の 3 つを機械的に洗う。**
どれも読み手が実際に詰まって初めて分かる類で、目視では取りこぼすため。

各 change の自分自身の diff (`jj diff -r <change>`) を層ごとに書き出してから当てる。

- **定義前参照** — この PR で新設された識別子を追加行から拾い、初出の change と宣言の change を
  比べる。**テスト名・コメント・docstring も対象**。「渡さない場合」を先に見るテストが、
  そのオプション名を宣言より前に持ち出す形で紛れ込む
- **対になるテストの分断** — テスト名の先頭にある被検対象でグルーピングし、同じ対象が
  複数の change に散っていないか見る。あるオプションの表と裏が別 change に割れていると
  「なぜ片方だけなのか」で必ず止まる
- **コピペ関係** — コメント行を除いた追加行の識別子・文字列・数値をプレースホルダに正規化した
  「骨格」を作り、先行する全 change と突き合わせる

**解消は順序の入れ替えを最優先する。** 畳む・分けるは、順序では直せないとき
(対になるテストの分断など) に限る。

## 6. 読み口を付ける

**説明本文は 1〜3 行付ける。** 材料は Phase 2 で読んだ元の PR 説明とコミットメッセージ本文。
**元に無い情報を捏造しない。** タイトル以上に言うことがなければ 1 行のままでよい。
prefix や書式、gitmoji はリポジトリの既存のコミットメッセージ規約に合わせる。
生成物の層はメッセージに生成元コマンドを明記する (後から手書きか生成かを疑わずに済むため)。

読み順モードでは、タイトル先頭に**章立ての prefix** (`A-1` `A-2` `B-1` …) を付ける。
アルファベットは Phase 2 で決めた章、数字はその中の順。序数で「8 番目」と指すより安定した
参照子になり、順序を変えても食い違わない。

Phase 5 で測ったコピペ関係は、prefix の直後に出す。読み飛ばせる箇所が一覧で分かるため。

- `[=X]` / `[~X]` — change 全体が X の同形 (`=` は機械的置換のみ、`~` は実質差分あり)
- `[=X *N]` / `[~X *N]` — `*N` は**その change の内部に同形が N 本**。`=` / `~` はその N 本が X と同形か
- `[*N]` — 内部に N 本あるが、外部に雛形がない

X は**直近の祖先**を指す。系列の一番古いもの (雛形そのもの) には付けない。
本文には「雛形: X と同形で、違うのは〜」を 1 行足し、**差分だけを書く**。
**一致率などの測定値は本文に書かない** (陳腐化する。読み手の関心は差分がどこかであって数値ではない)。

change を 1 つずつ読むと引っかかるが内容は変えられない箇所 (先取りしたテスト名等) は、
**本文に「留意:」として残す**。読み手が同じ疑問で止まるのを防ぐため。

## 7. 列に名前を付けて git 側から見えるようにする

detached HEAD のままだと、`git status` も Claude Code のセッション開始時の表示も
「現在のブランチ = HEAD」としか言わない。**別のセッションがこの列を名前で指せず取り違える。**
元の PR のブランチ名に `-splitted` を付けた名前にする。

**このスキルの中で jj を動かす最後の操作にする。** git HEAD を付け替えたあとに jj が `@-` を
動かすと、jj が HEAD を detached に戻す (実測)。

```bash
HEAD_REF=<Phase 1 の実値>
jj bookmark set "$HEAD_REF-splitted" -r @-   # 無ければ作り、あれば動かす
git checkout "$HEAD_REF-splitted"            # git HEAD をブランチに乗せる
git -C . status -sb | head -1                # "## <ブランチ名>" が出れば成功
```

**この `git checkout` は `jujutsu` スキルの「jj repo で raw git を使わない」の唯一の例外。**
git HEAD をブランチに付け替える操作が jj のコマンドに無いため。
bookmark は remote を追跡しないので、この時点では push されない。

完了報告では、**ブランチ名と、この先 jj で `@` を動かすと HEAD が detached に戻ることを伝える。**

名前を付けたら、積み上がった change の列を提示して終了する。push するかはユーザが決める。
