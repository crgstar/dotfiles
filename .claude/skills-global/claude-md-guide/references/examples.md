# CLAUDE.md good / bad 例

各行が「Claude がコードから推測できない情報」かどうかを判定するための実例集。
添削/レビュー時、削除候補かどうかに迷ったらこの表に照らす。

## 削除候補（コードから推測可能 / 既に他で言われている）

| Bad | なぜ削除 |
|---|---|
| `- TypeScript で書かれている` | `package.json` / `tsconfig.json` から自明 |
| `- src/ にコンポーネントがある` | `git ls-files` / glob で自明 |
| `- インデントは 2 スペース` | Prettier / EditorConfig が強制 |
| `- コメントは why を優先` | Claude Code のシステムプロンプトに同等指示あり |
| `- バックエンドは Go` | `go.mod` から自明 |
| `- node_modules はコミット禁止` | `.gitignore` が一次情報 |
| `- 生成された .merged.json は gitignore 済み` | `.gitignore` を見れば分かる |

## 圧縮候補（情報量に対して冗長）

```
Before:
- .zshrc は全環境共通の zsh 設定
- zshrc.local/<env>.zsh は環境別の追加設定
- .zshrc の末尾で ~/.zshrc.local を source する構成

After:
- ~/.zshrc.local は zshrc.local/<env>.zsh へのシンボリックリンク。
  ./setup.sh <env> で張られ、env 判定にも使う (readlink ~/.zshrc.local)
```

3 行 → 1 行。`.zshrc` を読めば構造は自明な部分を削り、setup.sh を読まないと
分からない「リンクされる」「env 判定に使う」の 2 点に絞る。

## 擬似見出し → Markdown 見出しへの昇格

```
Before:
典型パターン:
- パターン A
- パターン B

応答 JSON の形式（はまりポイント）:
- ...

After:
### 典型パターン

- パターン A
- パターン B

### 応答 JSON の形式（はまりポイント）

- ...
```

擬似見出し（末尾コロン付きの段落タイトル）は目には見出しに見えるが、
Markdown 構造としては段落のままで、TOC 生成・折りたたみ・アウトライン抽出が
効かない。`###` / `####` に昇格すると構造として扱える。

## IMPORTANT の乱用緩和

```
Before:
- IMPORTANT: 配列フィールドはマージ時に結合される
- IMPORTANT: ルール変更時は毎回 ./setup.sh を実行する

After:
- 配列フィールドはマージ時に結合される
- IMPORTANT: ルール変更時は毎回 ./setup.sh を実行する
```

2 つ並べると重要度が薄まる。一方は「マージの仕組み（知識）」、
もう一方は「実行を忘れると壊れる行動ルール」。後者が本物の IMPORTANT。

## 残すべきもの（コードから推測不能）

| Good | なぜ残す |
|---|---|
| `- 並行処理時は LockManager (~/path/locks.go) 経由で取得。raw mutex 禁止` | アーキ制約。コードを読むだけでは禁止理由が分からない |
| `- API 呼び出しはページコンポーネントからのみ` | アーキ規約。複数 hook/util から呼ばれるのを防ぐ意図 |
| `- ブランチ名は feature/<issue-id>-<slug>` | 慣習。リポ内のコードを読んでも見えない |
| `- 環境変数 FOO_BAR を設定する必要がある` | 実行時前提。Makefile / docker-compose を全部読まないと辿れない |
| `- IMPORTANT: マイグレーション後は ./scripts/seed.sh を実行` | 手順上の罠。漏らすと開発環境が壊れる |
| `- hook 応答 JSON は PreToolUse と PermissionRequest で形式が違う` | Claude Code 内部仕様。リポを読んでも分からない |

## 「迷ったら user に聞く」サイン

以下のような行は機械的に削らず、`AskUserQuestion` で意図を確認する:

- 「明示的に書きたかった注意喚起」: 例 `生成ファイルはコミット禁止` のように
  .gitignore で済むはずだが「うっかり add しないための保険」として残している可能性
- 「個人スタンス系」: 例 `急がず楽しく仕事する` のような行動・トーン指示。
  ノイズに見えるが本人の意図が背後にあることが多い
- 「全プロジェクト共通の方針」: 例 `CQS/CQRS を意識` のような設計原則。
  該当リポでは使わなくても、個人グローバルに置きたい意図かもしれない
