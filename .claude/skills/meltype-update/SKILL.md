---
name: meltype-update
description: >-
  Mac に入れた日本語入力 Meltype (yksr-melt/Meltype の公式配布 zip 版) を最新リリースへ更新・新規インストールするスキル。
  「Meltype を更新して」「Meltype の新しい版を入れて」「Meltype をアップデート」「Meltype を入れて」等で使う。
  更新後に日本語にならない・入力ソースに Meltype が重複して並ぶ、といった更新起因の不調の復旧にも使う。
  対象外: Windows / Linux 版、ソースからビルドしている環境 (mac/update.sh の領分)、
  Homebrew tap で入れた別系統の Mac 版、Meltype の設定やユーザー辞書の編集。
---

# Meltype 更新

公式手順は `yksr-melt/Meltype` の `mac/README.md`。迷ったらそちらを読む。
更新はせず不調の復旧だけなら「日本語にならないとき」へ直行する。
コード中の `<scratchpad>` はセッションの scratchpad の絶対パスに、`<latest>` は手順 1 で出た latest に置き換える。

## 1. 版を比べる

```bash
app="$HOME/Library/Input Methods/Meltype.app"
cur=none   # 未インストールでも exit しないのは、新規インストールも同じ手順で入れるため
[ -d "$app" ] && cur=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
latest=$(gh release view -R yksr-melt/Meltype --json tagName --jq .tagName | sed 's/^v//')
[ -n "$latest" ] || { echo "最新版を取得できない"; exit 1; }
echo "installed=$cur latest=$latest"
[ "$cur" != "$latest" ] || { echo "最新版"; exit 0; }
```

## 2. 取得して確かめる

`~/Downloads` は TCC でこのセッションから触れないので、scratchpad に新しいディレクトリを切って落とす。

```bash
latest=<latest>
d="<scratchpad>/meltype-$latest"; m="$d/x/Meltype-mac"
mkdir -p "$d" && gh release download "v$latest" -R yksr-melt/Meltype -p "Meltype-$latest-mac.zip" -D "$d" --clobber \
  && unzip -oq "$d/Meltype-$latest-mac.zip" -d "$d/x" || exit 1
[ "$(plutil -extract CFBundleIdentifier raw "$m/Meltype.app/Contents/Info.plist")" = io.github.yksr-melt.inputmethod.Meltype ] || exit 1
[ "$(plutil -extract CFBundleShortVersionString raw "$m/Meltype.app/Contents/Info.plist")" = "$latest" ] || exit 1
codesign --verify --deep --strict "$m/Meltype.app" || exit 1   # 署名は ad-hoc が正常
```

ガードで止まったら、そこで中断してユーザに報告する。
実行前に `install.sh` と、そこから呼ばれる同梱スクリプトを読む。`~/Library/Input Methods` への配置と入力ソースの登録・起動・選択以外のこと（外部への通信・sudo・ほかの場所への書き込み）をしていたら、実行せずユーザに見せる。

## 3. インストール

入力ソースが切り替わることをユーザに一言伝えてから実行する。

```bash
latest=<latest>
d="<scratchpad>/meltype-$latest"; m="$d/x/Meltype-mac"
bash "$m/install.sh"
```

`Meltype input server did not become ready` 以外のエラーで終わったら、手順 4 の `lsregister -u` だけ実行し、展開物は残したまま止めてユーザに報告する。
`Meltype input server did not become ready` で終わっても、`pgrep -x Meltype` でプロセスが居れば成功している（macOS が先に起動した Meltype と衝突しただけ）。
このとき Meltype を `pkill` / `launchctl remove` しない。止めると macOS が起動し直さず、入力ソースの登録も消えて日本語が打てなくなる。
プロセスが居なければ、手順 4 を済ませてから「日本語にならないとき」へ進む。
exit 0 で「まだ入力ソースとして有効になっていません。ログアウト…」と出ても、ログアウトを頼まず手順 4 へ進む。install.sh は入力ソースを選択済みで、打てるかは手順 5 で確かめるため。

## 4. 展開物を消す

展開した `Meltype.app` が残ると macOS が入力ソースとして登録し、重複の原因になる。

```bash
latest=<latest>
d="<scratchpad>/meltype-$latest"; m="$d/x/Meltype-mac"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$m/Meltype.app"
trash "$d"
```

`lsregister -u` が `-10814` を出すのは、外す対象が無いという意味なので無視してよい。

## 5. 確認

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
  | grep -E '^path:' | grep -i meltype        # Input Methods の 1 件だけ
swift .claude/skills/meltype-update/scripts/input-sources.swift count   # Meltype の入力ソース件数。1 が正常 (新規インストール直後は 2 でも可)
plutil -extract CFBundleShortVersionString raw "$HOME/Library/Input Methods/Meltype.app/Contents/Info.plist"
```

版が latest でなければ、止めてユーザに報告する。
`Input Methods` 以外のパスが出たら `lsregister -u` で外す。そのパスが `~/Downloads` 配下なら、Finder でゴミ箱へ移すようユーザに頼む。

最後にユーザに日本語を打ってもらう。
新規インストール直後は `count` が 2 でも、打てれば手を入れない。

## 日本語にならないとき

順に試し、各段で打ってもらう。

1. `swift .claude/skills/meltype-update/scripts/input-sources.swift reselect`（ABC に切り替えてから Meltype に戻し、接続を張り直す）
2. `pgrep -x Meltype` が空なら、ユーザにログアウト → ログインしてもらう
3. まだ打てない、または更新時に `count` が 1 にならないなら、ユーザにシステム設定のキーボード → 入力ソースで Meltype を全部外し、「+」から入れ直してもらう
