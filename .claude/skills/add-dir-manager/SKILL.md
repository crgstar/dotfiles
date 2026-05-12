---
name: add-dir-manager
description: |
  Claude Code の additionalDirectories (--add-dir / settings の追加ワーキングディレクトリ) を
  複数リポにまたがって安全に管理するスキル。一覧表示・パスの追加・削除・sibling グループの
  一括クロスリンクに対応する。各リポの .claude/settings.local.json に対して jq で atomic に
  merge し、既存の permissions / hooks / outputStyle 等は壊さない。
  「add-dir の状況」「additionalDirectories を確認」「クロスリンク」「sibling リポを互いに
  見えるようにして」「kcinfra-* / kcmanagement-* / kcapps-* に一律で add-dir」「X リポに
  /path/to/Y を追加」「Z リポから kcinfra-private を外して」「グループ一括セットアップ」
  などのリクエストで使用する。複数リポに settings.local.json を手で書き換えるのは jq merge
  を毎回再発明することになり self-exclusion ミスも起きやすいので、これらの文脈ではこのスキル
  を必ず使うこと。単発のクロスリポ Read permission 追加など別の意図ではなく、
  additionalDirectories (add-dir) の管理が文脈に含まれる場合に発動する。
---

# add-dir-manager

Claude Code の追加ワーキングディレクトリ (`additionalDirectories` settings key) を複数リポ
にまたがって安全に管理するためのスキル。Claude Code の `--add-dir` フラグおよび
`additionalDirectories` 設定の永続化版を扱う。

## なぜこのスキルが必要か

`additionalDirectories` を複数リポに展開する作業には以下の落とし穴がある:

- **正しいスキーマパス**: 設定キーは `.permissions.additionalDirectories` の位置にあり、
  トップレベルの `.additionalDirectories` ではない（バイナリ内のエラーメッセージで
  `permissions.additionalDirectories` と明示されている）。トップレベルに置くと Claude Code
  起動時に自動正規化されて `.permissions.` 配下に移動されるため、見かけ上は動くが、書き込み
  時点では効いていない期間が生じる。スクリプトは最初から正しい位置に書く。
- **既存設定の保護**: 既に `permissions.allow` / `hooks` / `outputStyle` 等が書かれている
  settings.local.json を雑に上書きすると別機能が壊れる。jq merge が必須。
- **書き込み先の判断**: 絶対パスはマシン固有なので、commit 対象の `settings.json` ではなく
  gitignore 対象の `settings.local.json` に書くべき。これを毎回考えるのは無駄。
- **self-exclusion**: グループでクロスリンクするとき、各リポは「自分を除いた他全部」を持つ
  必要があり、手作業だと取りこぼしやすい。
- **CLAUDE.md ロードの opt-in 性**: 追加ディレクトリの `CLAUDE.md` はデフォルトでは読まれず、
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` 環境変数の opt-in。この事実を意識せず
  add-dir すると「コンテキストが汚れる」と誤認されやすい。

これらを毎回手で書き直すのは時間の無駄かつバグの温床。スクリプトに固めることで、Claude は
オーケストレーションだけに集中できる。

## スキーマ参照

設定ファイル (`.claude/settings.local.json`) における `additionalDirectories` の正しい位置:

```json
{
  "permissions": {
    "allow": ["..."],
    "deny": ["..."],
    "additionalDirectories": [
      "/absolute/path/to/dir1",
      "/absolute/path/to/dir2"
    ]
  }
}
```

トップレベルの `.additionalDirectories` は無効（harness が自動正規化する）。スクリプトを
書き換える際は必ず `.permissions.additionalDirectories` のパスを使うこと。

## バンドルスクリプト

`scripts/addir.sh` がすべての per-repo 操作を担う。Claude は **グロブ展開とユーザ確認だけを
担当し**、ファイル操作はこのスクリプトに任せること。

```
addir.sh list <repo-path>...                    # 各リポの additionalDirectories を表示
addir.sh add <repo-path> <new-dir>...            # 指定パスを追加 (idempotent / dedup / sort)
addir.sh remove <repo-path> <removed-dir>...     # 指定パスを削除 (空になればキーごと削除)
addir.sh group-setup <member-path>...            # 各メンバーに他メンバー全員を追加 (self-exclusion 自動)
```

スクリプト共通の保証:
- 引数の path は**絶対パス**でなければならない (グロブ展開は Claude 側で済ませる)
- `.claude/settings.local.json` が無ければ新規作成 (`.claude/` 含めて作る)
- 既存の他キー (`permissions`, `hooks`, `outputStyle`, ...) は完全保持
- add / group-setup は `unique` で重複排除 + ソートされた配列に正規化
- remove で残数 0 になった場合は `additionalDirectories` キーごと削除 (空配列を残さない)

## ワークフロー

ユーザの依頼が来たら以下の順で処理する:

### Step 1. モードを判定

| ユーザの言い回し例 | モード |
|---|---|
| 「add-dir の状況」「現在の構成は」「一覧で見せて」 | `list` |
| 「X に Y を追加」「全 kcinfra-* に Z を足して」 | `add` |
| 「X から Y を外して」「Z を削除」 | `remove` |
| 「kcinfra-* グループを一括クロスリンク」「sibling を互いに見えるように」 | `group-setup` |

### Step 2. 対象リポを解決 (グロブ展開)

Bash で `ls -d <glob>` 等を使って絶対パスのリストに変換する。

```bash
ls -d /Users/kumazaki/projects/kcinfra-*
```

検証:
- 期待した数のリポが見つかったか
- リポでないもの (ファイル等) が混ざっていないか

### Step 3. 確認 (write 系のみ)

- **list**: 確認なしで即実行
- **add / remove**: 対象リポ数が 1 つなら確認なし、複数なら **AskUserQuestion で確認**
- **group-setup**: 必ず **AskUserQuestion で確認** (副作用が広範のため)

確認の文言例:
> 以下 8 リポの settings.local.json を更新します。
> - kcinfra-kcdev, kcinfra-kclocal, kcinfra-kcmanagement-prd, ...
> 各リポに「自分以外の 7 リポ」を additionalDirectories として追加します。
> よろしいですか？

### Step 4. スクリプト実行

```bash
SKILL=/Users/kumazaki/.claude/skills/add-dir-manager
bash $SKILL/scripts/addir.sh group-setup \
  /Users/kumazaki/projects/kcinfra-kcdev \
  /Users/kumazaki/projects/kcinfra-kclocal \
  ...
```

### Step 5. 結果サマリ

ユーザに以下を報告する:

- **何ファイル更新したか** (script 出力の `updated: <path>` 行数)
- **各リポの新しい additionalDirectories** (`list` を再実行した結果のテーブル)
- **gitignore 確認**: 対象ファイルが gitignore されているか (`git check-ignore -v <file>`)
- **適用タイミング**: 「次回 Claude 起動時から有効。今のセッションには反映されない」を毎回明記

### Step 6. CLAUDE.md ロードについての案内 (必要に応じて)

ユーザが「追加した先のリポの CLAUDE.md も読んでほしい」と言った場合のみ案内する。デフォルト
では opt-in なので、シェル rc に以下を追加する必要がある:

```bash
export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
```

このスキル自体は env var の設定変更を**行わない**。ユーザに任せる。

## 操作例

### 例 1: list

ユーザ「kcinfra-* の add-dir 状況を教えて」

```bash
# Step 2
REPOS=$(ls -d /Users/kumazaki/projects/kcinfra-*)
# Step 4
bash ~/.claude/skills/add-dir-manager/scripts/addir.sh list $REPOS
```

スクリプト出力をそのまま整形してユーザに見せる。

### 例 2: add (単一リポ)

ユーザ「kcinfra-kcdev に /Users/kumazaki/projects/kcapps-foo を追加して」

```bash
bash ~/.claude/skills/add-dir-manager/scripts/addir.sh add \
  /Users/kumazaki/projects/kcinfra-kcdev \
  /Users/kumazaki/projects/kcapps-foo
```

対象 1 リポなので確認不要。実行後に新しい additionalDirectories を表示。

### 例 3: add (複数リポ)

ユーザ「全 kcinfra-* に /Users/kumazaki/projects/kcapps-foo を足して」

確認 → 各リポについてループで `add` を呼ぶ:

```bash
for repo in /Users/kumazaki/projects/kcinfra-*; do
  bash ~/.claude/skills/add-dir-manager/scripts/addir.sh add \
    "$repo" /Users/kumazaki/projects/kcapps-foo
done
```

### 例 4: remove

ユーザ「kcinfra-kcprd から kcinfra-private を外して」

```bash
bash ~/.claude/skills/add-dir-manager/scripts/addir.sh remove \
  /Users/kumazaki/projects/kcinfra-kcprd \
  /Users/kumazaki/projects/kcinfra-private
```

### 例 5: group-setup

ユーザ「kcapps-* グループを一括クロスリンクして」

```bash
MEMBERS=$(ls -d /Users/kumazaki/projects/kcapps-*)
# 確認 → 実行
bash ~/.claude/skills/add-dir-manager/scripts/addir.sh group-setup $MEMBERS
```

各 member に「自分以外の member 全員」が追加される (self-exclusion 自動)。

## エッジケース

- **対象リポが 0 件**: グロブにマッチしなかった場合、ユーザに「該当無し」を返し、勝手にパスを
  推測したり似たリポ群を提案したりしない。
- **`.claude/settings.json` (commit 対象) との衝突**: ユーザが明示的に「commit 対象に書きたい」と
  言わない限り、settings.local.json のみを編集する。settings.json を編集したいと言われた場合は
  「絶対パスはマシン固有なので team 共有には不向き」と一度警告する。
- **既に追加済みの dir を add**: 警告せず黙って no-op。スクリプトが idempotent。
- **存在しないリポへの操作**: `.claude/settings.local.json` の作成は repo dir が存在することを
  前提とする。`ls -d` でグロブを expand すれば存在しないものは消えるため、通常は問題なし。
  個別パスを直接渡されて存在しない場合は Bash 側でエラーを拾ってユーザに報告する。

## やらないこと

- `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` の env var 設定変更 (シェル rc 操作は別領域)
- ユーザの commit 対象 `settings.json` への書き込み (明示要求がなければ)
- `--add-dir` CLI フラグや tmux 起動スクリプトの自動生成 (本スキルは永続設定が対象)
- 一貫性 audit (A↔B の片方向欠落検出など) — 当初スコープに含めない
- 名前付きグループの永続化 (`groups.json` のような状態管理) — その都度コマンドで member を
  指定する設計
