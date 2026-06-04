---
name: auq-web
description: >
  AskUserQuestion を超えた表現力で、Claude が書いた freeform HTML
  (表 / コードブロック / 図 / SVG / 段階的な解説) を本文に持つ確認画面を
  ブラウザで開き、選択肢 + 自由コメント + 並べ替えを構造化 JSON で受け取る。
  「choose A / B」のような単純な確認には AskUserQuestion で十分だが、
  本文が 3 行を超える / 比較表が要る / before/after の差分を見せたい /
  SVG や JS の図を貼りたい / 複数の質問を 1 画面で答えてほしい場面では
  必ずこちらを優先すること。「表で見せたい」「コード比較で選んでほしい」
  「図で示してから聞きたい」「並び順を決めてほしい」「複数まとめて確認したい」
  といった文脈で AskUserQuestion を選びかけたら、まず auq-web を検討する。
  本文は Claude が直接 HTML として書く。受け取り口は固定スキーマ
  (single / multi / rank + 自由コメント) で構造化されているので、答えは
  raw JSON でそのまま使えばよい。
---

# auq-web

ブラウザ上の質問画面を 1-shot で立ち上げ、ユーザの回答 (raw JSON) を受け取る。

## いつ使うか

AskUserQuestion (組み込みツール) は 1 行問いには素直だが、**質問本文に表現力を
持たせられない**。desc が 1 行で済まない (比較表・before/after コード・SVG/JS 図・
段階的な背景説明) か、複数問・rank が要るときは auq-web。1 行問いは AskUserQuestion。
迷ったら auq-web。

## 全体フロー

HTML 本文を Claude が直接書き `/tmp` に Write → `auq-web` を background 起動
(listen 後にブラウザ自動オープン) → 完了通知を受けたら `BashOutput` の末尾 1 行
JSON を読む。各ステップの詳細は後述。

`server.py` は **POST /answer を受けたら自分で graceful shutdown する**ため、
background プロセスの「完了通知 = ユーザが回答を出した瞬間」になる。
Monitor で polling する必要はない。

## ステップ詳細

### 1. HTML を組み立てる

入力フォーマットの全体像はこう (詳細は `references/input-format.md`):

```html
<script type="application/auq+json">
{ "$auq": "meta", "repo": "<repo 名>", "timeoutSec": 300 }
</script>

<script type="application/auq+json">
{
  "id": "q1",
  "title": "質問の見出し",
  "kind": "single",
  "options": [
    { "value": "a", "label": "選択肢 A", "hint": "短い補足" },
    { "value": "b", "label": "選択肢 B" }
  ],
  "allowOther": true
}
</script>

<p>ここに desc HTML を自由に書く。<table>, <pre><code>, <svg>, <script> なんでも。</p>
```

要点だけ:

- `<script type="application/auq+json">` のみが metadata 扱い。それ以外の
  `<script>` (`text/javascript` や `application/json`) は **desc にそのまま流れる**
  ので、SVG 描画用の JS や chart-data の埋め込みも自由
- 1 個目の auq script は省略可能な **meta** (`{ "$auq": "meta", ... }`)
- 2 個目以降が question (1 件以上、上限なし)
- 各 question script の **直後から次の auq script まで** が `descHtml`
- **meta と最初の question の間には空白/コメント以外を置けない**。状況説明 HTML を
  冒頭に出したい場合は **最初の question script を先に置き、その直後に desc を書く**
  (meta を省略してもよい)
- desc に `</script>` の文字列を含めたい時は **HTML エンティティ**
  (`&lt;/script&gt;`) で書く

#### desc は **素のタグだけ書けば dark theme に馴染む**

`server/index.html` 側に default stylesheet を持たせてあるので、書き手は
`<table>` `<pre><code>` `<blockquote>` `<ul>` `<h2>` `<svg>` などを
**素のまま書けばよい**。inline `style` 属性で配色や padding を毎回書く必要は無い。

```html
<!-- これで OK. 配色や枠線は default で当たる -->
<h2>判断材料</h2>
<table>
  <thead><tr><th>候補</th><th>所要</th></tr></thead>
  <tbody>
    <tr><td>Python</td><td>~50 行</td></tr>
    <tr><td>Bun</td><td>~20 行</td></tr>
  </tbody>
</table>
<blockquote>原則: 呼び出し側に install を強いない</blockquote>
<p class="warn">⚠ 既存タブを閉じてから再実行してください</p>
```

主要なブロック要素・テキスト要素と `<svg>` は素のまま書けば当たる。簡易 callout は
`<p class="note|warn|danger|ok">`。レイアウト固有の調整 (列幅 `<col>` / `colspan` 等)
は inline `style` で上書きしてよいが、**毎回フルで配色を書かない** が原則。使えるタグの
全リストは `references/input-format.md` §9。

色の視覚比較サンプル（カラースウォッチ等）を desc に載せる場合、背景色を明示する（例: `<div style="background:#fff;padding:8px">`）。dark / light どちらの環境で見るかで実色が変わるため。

読者が知らない可能性のある用語は desc 冒頭で定義する（後から読み返さずに済む）。`<table>` 2列で十分。

**比較対象が 2 つなら左右に並べる**。縦積みより視線移動が短く、行ごとの差分が一目で
分かるため。比較軸を行にできるなら素の `<table>` の 2 列 (左右の見出しに対象名) が一番楽。
before/after コードや SVG などセルに収まらないリッチな本文は
`<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">` で左右に置く。

`kind` は 3 種類:

- `single`: ラジオ。`options[]` で `value`/`label`/`hint?`、`allowOther?`
- `multi`: チェックボックス。同上
- `rank`: ドラッグ並び替え。`items[]` で `id`/`label`/`hint?`

`options[].value` (single/multi) と `items[].id` (rank) は **answer payload に
そのまま出る識別子**。後で読んだ時に意味が分かるよう、`a` `b` `c` ではなく
**意味のある short snake_case** (`python` `bun` `server` `template` 等) で書く。

`label` / `hint` は UI に出る本文だが **plain text として扱われる**
(HTML タグはエスケープして表示される)。リッチに見せたいテキスト整形
(コードフォント・強調・改行) は desc 側に書くこと。

### 2. /tmp に書き出す

HTML は **ファイル経由を既定**にする。理由:

- Bash の heredoc + `run_in_background` の組合せは動くが、HTML 内に shell が
  解釈しうる文字 (バッククォート / `$` / 連続 quote / heredoc 終端と被るトークン)
  を入れた時の事故が一番多いカテゴリ。`Write` ツールに渡せばこの懸念ゼロ
- 大きい本文 (SVG や code-block を含む) でも素直

```
Write ツールで /tmp/auq-web-current.html に HTML を書く
```

固定 path を使う理由: port 7777 が固定で並行起動を許していないので、tmp ファイル
も並行衝突しない。short random を毎回考えなくていい上、デバッグ時も
`cat /tmp/auq-web-current.html` で「直近 Claude が組み立てた HTML」を再現できる。

短い (1 質問 + 数行 desc) かつ shell-safe と判断できれば heredoc も可:

```bash
auq-web --port 7777 <<'AUQ_EOF'
<script type="application/auq+json">{ "$auq": "meta" }</script>
<script type="application/auq+json">{ "id":"q1","kind":"single","title":"...","options":[...]}</script>
<p>...</p>
AUQ_EOF
```

迷ったらファイル経由。

#### 起動前 dry-run (任意, 推奨)

書いた HTML が parse を通るか / 各 question にどんな id・descLen が割り当たるか を
**サーバを起動せずに** 確認できる:

```bash
auq-web --validate --input /tmp/auq-web-current.html
# OK: {"ok": true, "questions": [{"id":"q1","kind":"single","descLen":312,...}, ...]}
# NG: {"ok": false, "error": "<失敗理由>"}  → error を読んで input を直す
```

exit 0 / 1 で成否が判定できる。`{"ok": true, ...}` の `descLen` が想定外に小さい・
0 になっていたら desc HTML が意図した question に紐づいていない。複雑な HTML
(複数質問 + SVG + 大きい比較表) を初めて書く時は **起動前に 1 回 validate して
から `Bash run_in_background` する** とイテレーションが速い。

### 3. server を background 起動

Bash ツールを **`run_in_background: true`** で呼ぶ:

```bash
auq-web \
  --port 7777 \
  --input /tmp/auq-web-current.html
```

(`auq-web` は PATH 上に置かれた `run.sh` への symlink。run.sh は auq-web リポ内の
`server/server.py` を realpath で解決して起動する薄い wrapper。引数はそのまま `server.py` に渡る)

戻り値の **shell ID を控えておくこと**。step 5 の `BashOutput` で使う。

`server.py` の挙動 (重要):

- 起動時に入力 HTML をパース → 検証 → render
- listen 開始後に `webbrowser.open(url)` を呼んで **ブラウザを自動オープン**
  (macOS: `open`, Linux: `xdg-open`, Windows: `start`)
- パース失敗時:
  - **`--input` 指定時**: server は起動して **ブラウザに 200 で赤いエラー画面**
    を返す。入力ファイルを修正してリロードすれば再 parse される (server 再起動不要)。
    stderr にも警告が出る。書き手が `--validate` を回し忘れた時の救済になる
  - **stdin 経由**: stderr に詳細を出して exit 1 (再読込不可能なため確定エラー)
- POST /answer を 1 度受けたら **JSON 1 行を stdout に書いて exit 0**
- port 7777 が衝突していたら詳細メッセージを stderr に出して exit 1

headless/ssh で自動オープンを抑制したいときは `--no-open`。`webbrowser.open` が
失敗した時は stderr に手動で開く URL が出るので、それをユーザに見せる。

#### draft auto-save

入力中の draft は画面 JS が自動保持する (タブクラッシュ・誤閉じ・長考 timeout で
入力が消える事故を減らす)。通常運用では意識不要。クラッシュ復旧用にファイルへ
永続化したいときだけ `--draft-out <path>`。

#### スナップショット出力 (`--static <path>`)

`--static <path> --input <html>` は server を起動せず render 済み HTML を 1 ファイル
吐いて exit する (閲覧専用、回答は取れない)。出した画面を Slack/docbase に貼る・
archive する用途。通常運用 (回答受け取り) には使わない。

ユーザへの案内 (1 行で良い):
**「ブラウザで質問画面を開きました。回答後、自動で閉じます」**

### 4. background 完了を待つ

`run_in_background: true` で起動した shell は、**プロセス exit 時に harness が
完了通知を送ってくれる**。Claude 側は polling 不要。

待っている間は、関連の作業 (ドキュメント整理 / 別ブランチ確認 / 次の段の準備等)
を進めてよい。ユーザは自分のペースでブラウザに向かって回答を組み立てている。

### 5. stdout から answer JSON を取る

完了通知を受けたら、控えておいた shell ID で `BashOutput` を読む。
**stdout の末尾 1 行が JSON** (server.py が `json.dumps(...) + "\n"` で 1 度だけ書く)。

`stderr` に "auq-web listening on http://..." 等のログが混ざるが、stdout には
JSON 1 行しか出ないので、stdout を strip して json.loads で読めばよい。

server が exit 1 で落ちた場合: stderr に詳細メッセージ (パースエラー /
port 衝突 等) が出ているので、それをユーザに見せる。

### 6. answer を使う

返る JSON の正本は `references/input-format.md` §8 (`event` / `answers[<id>]` /
`__other__` / `partialAnswers` の形)。呼び出し側のスタンスだけ:

- **raw JSON のまま使う**。要約せず `answers["q1"].selected` 等で直接参照する方が
  ループバックが速い
- `event: "reject"` (ユーザが拒否ボタンで閉じた) は「やめた」の意思表示。続けて
  勝手に判断せず、どうするか改めて確認する
- `timedOut: true` は時間切れで `partialAnswers` が同梱される (詳細は §8)

## 失敗時の対処

| 症状 | 対処 |
|---|---|
| ブラウザで「❌ auq-web: input parse failed」の赤い画面 | 入力 HTML の parse 失敗。画面の `<pre>` に詳細あり。/tmp/auq-web-current.html を Edit で修正 → ブラウザでリロードで復帰 (server 再起動不要) |
| background プロセスが exit 1 で即落ち | stderr (BashOutput) を読む。port 衝突 / index.html 不在 / heredoc(stdin) 経路の parse 失敗 が候補 |
| port 7777 衝突メッセージ | 前の auq-web タブが残っている可能性大。「画面を閉じてから再実行してください」とユーザに伝える |
| ブラウザで真っ白 | server stderr に listening log は出ているか確認。出ているなら 200 でレンダー済み (HTML が空 desc で見えにくいだけ) |
| `event: "reject"` | 続行を勝手に判断せず、ユーザに改めて意図を確認する |

## ファイル配置

```
auq-web リポ (~/projects/auq-web/): server 実体と起動 entry
├── server/
│   ├── server.py            ← 起動対象
│   └── index.html / parser.py / wire.py
└── skill/run.sh             ← ~/.local/bin/auq-web に link される wrapper

dotfiles (~/dotfiles/.claude/skills/auq-web/): スキル本文 (他スキルと同じ管理)
├── SKILL.md                 ← この file
└── references/input-format.md
```

配線は dotfiles の `setup.sh` が貼る (手動 `ln -s` は不要):

```bash
# SKILL.md / references を他スキルと同じく ~/.claude/skills/auq-web/ へ link
link_file .../skills/auq-web/SKILL.md                 ~/.claude/skills/auq-web/SKILL.md
link_file .../skills/auq-web/references/input-format.md ~/.claude/skills/auq-web/references/input-format.md
# run.sh を PATH に通す → `auq-web` で呼べる
link_file ~/projects/auq-web/skill/run.sh             ~/.local/bin/auq-web
```

`server.py` は **stdlib のみ** で動くので追加 install 不要 (macOS 標準 Python3)。
