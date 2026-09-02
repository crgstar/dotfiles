# dotfiles

Claude Code の設定ファイル・スキル、およびシェル設定を管理する dotfiles リポジトリ。

## セットアップ

```bash
./setup.sh [home|work]                # 環境名は省略可。省略すると各設定の base のみがリンクされ、common.json や環境別ファイルとのマージは行われない
./setup.sh <env> --only skills,hooks  # 一部だけ再配線。ターゲット一覧は ./setup.sh --list
```

- `jq` が必要（設定のマージに使用）
- 非対話（Claude / CI から実行）では、衝突があっても止まらず全ターゲットを走り切る。衝突ごとにその場で差分を表示し、最後に未解決の一覧を出して exit 1 する。`--force` でマージ結果 / dotfiles 側を採用（既存は `.bak`）、`--keep` で既存維持のまま正常終了

## 設定の仕組み

setup.sh は環境 (`home`/`work`) を指定すると、以下の設定をそれぞれ base + 環境別ファイルでマージし、生成物を `~/.claude/` 等へシンボリックリンクする。環境未指定時は各設定の base のみが直接リンクされる（マージは行われない）。

### Claude Code の settings.json

- `.claude/settings.json` — 全環境共通の設定（ベース）
- `.claude/settings.local/common.json` — 全ローカル env 共通の追加層
- `.claude/settings.local/<env>.json` — 環境別の追加設定
- `.claude/settings.local.json` — このリポジトリ固有のプロジェクト設定
- `~/projects/claude-spinner-verbs-japanese/spinner-verbs.json` — dotfiles 外の別リポにある spinner 語彙データ。存在するときだけ `spinnerVerbs` キーのみを抽出して common の後ろに挟む（無ければ黙って省略）
- setup.sh が jq で `base → common → (spinner) → <env>` の順にマージして `.claude/settings.merged.json` に書き出し、`~/.claude/settings.json` にシンボリックリンク
- 配列フィールド（permissions.allow 等）はマージ時に結合される（上書きではない）
- IMPORTANT: `permissions.ask` など「対話セッション専用」の設定は base ではなく **common.json** に置く。base はクラウド routine がクローン先で project 設定として直読みするため、base に ask を置くと routine が `git push` 等で承認待ちに止まる。routine は setup.sh を通らず base だけ読むので、common 経由なら routine は ask 無し（自律実行）・ローカルは ask 維持を両立できる（Claude Code は配列スコープを union するので上位から ask を消せない＝base から除くのが唯一の手段）

### CLAUDE.md

- `.claude/CLAUDE.md` — 全環境共通の user 向け global instructions
- `.claude/CLAUDE.local/<env>.md` — 環境別の追加指示
- 両方が揃うと setup.sh が結合して `.claude/CLAUDE.merged.md` に書き出し、`~/.claude/CLAUDE.md` にシンボリックリンク。`<env>.md` が無ければ `.claude/CLAUDE.md` を直接リンク

### Ghostty config

- `ghostty/config` — 全環境共通のベース設定
- `ghostty/config.local/<env>` — 環境別の追加設定
- 両方が揃うと setup.sh が結合して `ghostty/config.merged` に書き出し、`~/.config/ghostty/config` にシンボリックリンク。`config.local/<env>` が無ければ `ghostty/config` を直接リンク

### MCP サーバー設定

- `.claude/settings.local/<env>.json` の `mcpServers` を、setup.sh が jq で `~/.claude.json` の `mcpServers` に直接マージする（他の3つと異なりシンボリックリンクではなく `~/.claude.json` そのものを上書き。conflict 確認ダイアログもなし）
- マージはサーバ単位の**置換**（jq の `+`）。dotfiles 側のエントリが唯一の正で、そこから消したフィールドは `~/.claude.json` からも消える。再帰マージ（`*`）だとキーを足せても消せず、削除したはずの設定が残り続けるため
- `.claude/mcp/` 配下のスクリプトは `~/.claude/mcp/` にリンクされる。トークン等を環境変数ではなく接続時に生成する `headersHelper` の実体を置く場所（環境変数だと Claude Code が起動する全子プロセスへ配られ、`env` の出力からモデルのコンテキストへ流入しうる）

- IMPORTANT: ルールや設定を追加・削除した場合は毎回 `./setup.sh <env>` を実行してマージ結果を更新する
  - 2回目以降は `basename "$(readlink ~/.zshrc.local)" .zsh` で現在の env を判定できる
  - 初回（`~/.zshrc.local` が未作成）はユーザーに `home` / `work` を確認する

## シェル設定の仕組み

- `.zshrc` — 全環境共通の zsh 設定
- `zshrc.local/<env>.zsh` — 環境別の追加設定
- `~/.zshrc.local` は `zshrc.local/<env>.zsh` へのシンボリックリンク。`./setup.sh <env>` で張られ、現在の env 判定にも使う（`readlink ~/.zshrc.local`）
- `.zshrc` の末尾で `~/.zshrc.local` を source する構成

## ファイル追加時の規約

- 設定ファイルは `link_file` 関数でシンボリックリンクする（コピーではない）
- 新しいリンク対象を追加した場合は `setup.sh` の該当する `target_*` 関数に `link_file` の呼び出しを追加する。関数の外に置くと `--only` の部分実行から漏れる
- スキルは用途で置き場所が分かれる。**どちらに置くかで配布範囲が決まる**ので、新規作成時にまず決める
  - **全リポで使うもの** → `.claude/skills-global/<skill-name>/SKILL.md` に置き、`~/.claude/skills/<skill-name>/SKILL.md` へリンクする (user スコープ)
  - **このリポ専用のもの** → `.claude/skills/<skill-name>/SKILL.md` に置き、`link_file` しない (project スコープ)。他リポで発火しても誤検知にしかならないスキルはこちら (例: `permission-triage` — hook や `permissions.allow` を触るのはこのリポだけ)
  - project スキルの置き場所は Claude Code 側が `.claude/skills/` に固定しているので動かせない。分離のために動かせるのは配る側 (`skills-global`) だけ
  - IMPORTANT: `.claude/skills/` にあるものを「`link_file` の書き忘れ」と判断しないこと。そこにあること自体が project 限定の意思表示
- カスタムサブエージェントは `.claude/agents/<name>.md` に配置し、`~/.claude/agents/` へリンクする（user スコープ）。スキルが委譲する隔離処理 (生ログ・秘密の検査) や別コンテキストでのレビューを tools 制限付きで担わせる用途。判定基準は写経せず、呼び出し元 SKILL.md の該当節を Read させる (例: `retro-extractor` / `sanitize-auditor` / `doc-reviewer` / `skill-md-reviewer`)
- 第三者リポのスキルは dotfiles に取り込まず、`~/.local/share/<name>/` に shallow clone してから `link_file` で配る (例: `mattpocock-skills` / `grill-me` / `grill-with-docs`)
  - 例外は「翻案元として逐語で置くファイル」だけ (例: `unslop/reference-en.md`)。1 ファイルのために丸ごと clone すると翻案物と原典が別管理になり、対訳としてずれる。取り込む場合は原典のライセンス表記 (著作権表示 + 許諾文) をファイル冒頭のコメントに丸ごと入れる — 公開リポなので再配布に当たる

## コミット前のサニタイズ

公開リポなので、コミット前に追加・変更差分を `sanitize-auditor` サブエージェントへ点検させ、作業リポ固有情報の漏洩がないか確認する（特に `~/.claude` からの取り込み時）。判定基準は [.claude/rules/sanitize-criteria.md](.claude/rules/sanitize-criteria.md)。

## Claude Code の hook permission

hook 種別 (PreToolUse / PermissionRequest)、応答 JSON 形式、`segment-allow.sh` の safe-prefix 自動同期は [.claude/rules/hook-permission.md](.claude/rules/hook-permission.md) に分離。**hook や `permissions.allow` を触るときは先に必ず読む**。

## setup.sh のコンフリクト対応

`.claude/settings.merged.json` / `.claude/CLAUDE.merged.md` は、セッション中の `/update-config` や動的 allow 追加で既存 merged がソースより先行すると衝突する。TTY では下記の対話プロンプトで停止し、非対話では未解決として報告され exit 1 になる（`--force` / `--keep` で明示すれば止まらない）。

- **順序のみの差分**: 即 `n` で上書き（ソース正）
- **実質的な追加あり**: 先にソースへ還流してから `n`
  - 共通 → `.claude/settings.json` / `.claude/CLAUDE.md`
  - 環境別 → `.claude/settings.local/<env>.json` / `.claude/CLAUDE.local/<env>.md`
- 取りこぼしは `.bak` から復元可能
- **事前検知**: セッション開始時の system-reminder に `<file> was modified` と出ていたら、setup.sh を走らせる前に drift がないかソースを確認する（conflict prompt を 2 回処理する手間を省く）
