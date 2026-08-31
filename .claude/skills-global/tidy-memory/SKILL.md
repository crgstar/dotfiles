---
name: tidy-memory
disable-model-invocation: true
description: |
  Claude Code のプロジェクト別永続メモリ（memory/ 配下の *.md と MEMORY.md 索引）を
  棚卸しして圧縮するスキル。
---

メモリの残す / 消す / 書き直すの判定と書式は `memory-guide` スキルに従う（着手前に Read する）。本スキルはその基準を既存メモリ全体へ一括適用する工程を持つ。

- 対象はシステムプロンプトに記載されたメモリディレクトリの絶対パス（MEMORY.md の親ディレクトリ）。個別メモリの本文はセッションに注入されないので、glob で列挙してディスクから読む
- サブエージェントに委譲するのは Phase 1 の通読・実在確認（読み取り専用）と Phase 3 の執筆（テーマ単位で並列可）。1 コンテキストに収まる小規模なら自分でやってよい。Phase 2 のバックアップ・Phase 3 の削除・Phase 4 の検証は委譲せず自分で実行する（破壊操作とそのガードを委譲先の解釈に委ねない）
- **Phase 2 のバックアップが成功するまで、自分も委譲先も書き込みをしない**（原本が失われるため）
- 一括適用ならではの追加規則:
  - 記述内容の陳腐化（事実との乖離）は削除理由にしない。Phase 1 の確認結果に合わせて現状へ書き直す対象
  - Phase 1 の「迷った点」と基準で決めきれない判定は、自分で裁かずユーザに裁定を仰ぐ（単発の保存と違い、一括削除は誤判定の被害が大きい）
  - 件数の目標・下限は置かない。件数は判定の結果であって目標ではない
  - memory-guide のリネーム規定と同じ理由で、自分で編集できない参照元に名指しされたメモリは吸収・削除せずファイルを残す（中身の書き直しは可）

## Phase 1: 棚卸し

委譲する場合は、読み取り専用であることを委譲プロンプトにも明記する（委譲先には本スキルの冒頭方針が届かないため）。

- 全メモリ + MEMORY.md を通読する
- 本文が名指しする外部実体（worktree・ブランチ・tag・PR・スキルの実体パス・コード・行番号）を 1 件ずつ実在確認する。「まだ直っていない」とあるバグは現行コードを読む、「スキルに反映済み」は当該 SKILL.md を grep する。名前の見た目で実体の種類を決めつけない（worktree 風の名前が製品側リソース名のこともある）
- 削除・統合の判定に入る前に、残す内容が属する場面（ツール・作業種別・機能群）の一覧を作り、既存の分割を所与とせず全ファイルを 1 場面 1 ファイルへ割り付け直す。ファイルごとの keep/delete 判定から始めると、削除を生き残った小ファイルの統合検討が素通りする
- 出力: 場面マップ（場面一覧 + 各場面への割り付け）/ 削除候補（裏取り理由込み）/ 統合候補（残す名 + 吸収元 + 要旨）/ 陳腐化した記述（確認結果と現状）/ 迷った点（独立セクションで）。「現状維持」は場面マップで単独場面に割り付いたファイルだけに許す

## Phase 2: バックアップ

出力された `$B` のパスは Phase 3 の削除ブロックで使うので控えておく。

```bash
M=<メモリディレクトリ絶対パス>; M="${M%/}"
[ -d "$M" ] && [ -f "$M/MEMORY.md" ] || { echo "abort: $M がメモリディレクトリでない"; exit 1; }
B="$(dirname "$M")/memory-backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$M" "$B" || { echo "abort: backup failed"; exit 1; }
echo "backup: $(find "$B" -type f | wc -l | tr -d ' ') files -> $B"
```

## Phase 3: 全展開

1. 委譲するなら事前に設計書（テーマ / 吸収元 / 要旨 / 旧→新のリンク対応）を scratchpad に書いて執筆者が自己完結で書ける形にし、委譲プロンプトで memory-guide を Read させる（基準を転記すると drift する）
2. 統合・リネームで消える旧ファイル名は、memory-guide のリネーム規定に従い作業リポジトリ側（CLAUDE.md / CLAUDE.local.md 等）も grep して参照元を更新する。Phase 4 の機械検証はメモリディレクトリ内しか見ない
3. 旧ファイルの削除は次の 2 段で行う。最終ファイル一覧（MEMORY.md 含む、1 行 1 ファイル名）を keep.txt として scratchpad に書いてから:

```bash
M=<メモリディレクトリ絶対パス>; M="${M%/}"
B=<Phase 2 で出力されたバックアップ絶対パス>
K=<keep.txt 絶対パス>
[ -f "$B/MEMORY.md" ] || { echo "abort: バックアップが不正"; exit 1; }
[ -s "$K" ] && grep -qx 'MEMORY.md' "$K" || { echo "abort: keep.txt が不正"; exit 1; }
find "$M" -maxdepth 1 -name '*.md' -exec basename {} \; | grep -vxFf "$K"   # 削除予定一覧
```

削除予定一覧が設計書の削除予定と件数・中身とも一致することを自分で確認してから:

```bash
M=<メモリディレクトリ絶対パス>; M="${M%/}"
B=<Phase 2 で出力されたバックアップ絶対パス>
K=<keep.txt 絶対パス>
[ -f "$B/MEMORY.md" ] || { echo "abort: バックアップが不正"; exit 1; }
[ -s "$K" ] && grep -qx 'MEMORY.md' "$K" || { echo "abort: keep.txt が不正"; exit 1; }
find "$M" -maxdepth 1 -name '*.md' -exec basename {} \; | grep -vxFf "$K" \
  | while read -r f; do rm "$M/$f" && echo "removed: $f"; done
```

4. MEMORY.md を全面再生成する。索引行の書式はシステムプロンプトのメモリ指示が正本（Phase 4 の grep は索引の行頭 `- [` とクロスリンクの `[[ ]]` に依存する）

## Phase 4: 検証と完了報告

```bash
M=<メモリディレクトリ絶対パス>; M="${M%/}"
[ -d "$M" ] && [ -f "$M/MEMORY.md" ] || { echo "abort: $M が不正"; exit 1; }
files=$(find "$M" -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' | wc -l | tr -d ' ')
[ "$files" -ge 1 ] || { echo "NG: メモリが 0 件"; exit 1; }
NG=$(mktemp)
idx=$(grep -c '^- \[' "$M/MEMORY.md")
[ "$idx" -eq "$files" ] || echo "索引 $idx 行 / 実ファイル $files 件" >> "$NG"
grep -o '([^)]*\.md)' "$M/MEMORY.md" | tr -d '()' \
  | while read -r f; do [ -f "$M/$f" ] || echo "索引が指す $f が無い"; done >> "$NG"
find "$M" -maxdepth 1 -name '*.md' -exec basename {} \; \
  | while read -r f; do [ "$f" = MEMORY.md ] || grep -qF "($f)" "$M/MEMORY.md" || echo "$f が索引に無い"; done >> "$NG"
find "$M" -maxdepth 1 -name '*.md' -exec grep -ho '\[\[[^]]*\]\]' {} + \
  | tr -d '[]' | sort -u \
  | while read -r l; do [ -f "$M/$l.md" ] || echo "未解決リンク $l"; done >> "$NG"
[ -s "$NG" ] && { echo "verify NG:"; cat "$NG"; exit 1; }
echo "verify OK"
```

NG が出たら該当ファイル・索引を直して再実行する（原本が要るときは `$B` から個別に復元する）。

機械検証の後、残った全ファイルを読み直し、日本語として意味が取れない箇所（作業中の会話でしか通じない略語・造語・説明のない識別子）を洗ってユーザに報告し、合意された分を直す。

完了報告にはバックアップのパスを含め、しばらく運用して問題なければユーザ側で削除してよい旨を添える。
