# auq-web 入力フォーマット詳細

SKILL.md の補足。Claude が HTML 本文を組み立てる時の正確な仕様。

## 1. 全体構造

入力は **HTML fragment** (`<!DOCTYPE>`/`<html>`/`<body>` 不要)。
中に `<script type="application/auq+json">` の JSON ブロックを混ぜる。

- 1 個目 (任意): `{ "$auq": "meta", ... }` — 全体メタデータ
- 2 個目以降 (1 件以上、上限なし): question — 質問定義
- 各 question script の **直後 〜 次の auq script (or EOF) まで** が `descHtml`

```
[meta script]                     ← 任意
[question 1 script]
  desc html...                    ← q1 の descHtml
[question 2 script]
  desc html...                    ← q2 の descHtml
...
```

## 2. MIME type の見分け方

| `<script>` の `type` | 解釈 |
|---|---|
| `application/auq+json` | metadata (case-insensitive、前後空白許容) |
| `application/json` (任意 id) | desc にそのまま流す |
| `text/javascript` / 省略 / `module` | desc にそのまま流す |

**`application/auq+json; charset=...` のようにパラメータを付けると 400**。
純粋な MIME type のみ。

## 3. 構造化規約

1. **トップレベル** の `<script type="application/auq+json">` のみ metadata 扱い。
   `<svg>` 内など入れ子の同 type は desc としてそのまま流れる
2. 1 個目に `{ "$auq": "meta", ... }` と書けば全体 meta
3. それ以降のトップレベル auq script は **新しい question** (1 件以上、上限なし)
4. 入力先頭〜最初の auq script の間 / meta と最初の question の間は
   **空白 / 改行 / BOM / HTML コメント のみ許容**。それ以外は 400
5. **meta は常に別 script**。1 質問でも meta 統合の shorthand は無し
6. metadata script の本文は **純 JSON のみ** (trailing comma / コメント /
   CDATA / HTML エンティティ 不可)
7. **desc 領域は通常の HTML として解釈される**。`<` `&` を表示したい時は
   `&lt;` `&amp;` で書く。`</script>` の文字列を中に入れたい時は必ず
   `&lt;/script&gt;` でエスケープする (素のまま書くと HTML パーサが
   auq script の終端と区別できず壊れる)
8. **識別子 (`question.id` / `options[].value` / `items[].id`) は
   answer payload にそのまま出る**。後で読んだ時に意味が分かるよう、
   意味のある short snake_case で書く (`a` `b` `c` ではなく
   `python` `bun` `server` `template` のように)

## 4. meta オブジェクト

```json
{
  "$auq": "meta",
  "repo": "auq-web",
  "timeoutSec": 300
}
```

| field | 型 | 必須 | 説明 |
|---|---|---|---|
| `$auq` | `"meta"` | ◎ | meta 識別子 |
| `repo` | string | × | 画面 header に表示される文字列 |
| `timeoutSec` | int | × | 応答待ち上限。既定 300。0 で無制限 |

## 5. question (kind = single | multi)

```json
{
  "id": "q1",
  "kind": "single",
  "title": "ライブラリは Python で固める方針で OK?",
  "options": [
    { "value": "python", "label": "Python で固める", "hint": "依存ゼロ" },
    { "value": "bun",    "label": "Bun で書く",    "hint": "brew install bun" }
  ],
  "allowOther": true
}
```

| field | 型 | 必須 | 説明 |
|---|---|---|---|
| `id` | string | ◎ | `^[a-zA-Z0-9_]+$`。question 間で重複禁止 |
| `kind` | `"single"` \| `"multi"` | ◎ | |
| `title` | string | ◎ | 見出し |
| `options` | array | ◎ | 2 件以上 |
| `options[].value` | string | ◎ | answer に出る識別子。同一 question 内で重複禁止。意味のある short snake_case で |
| `options[].label` | string | ◎ | UI に出る本文。**plain text として扱われる** (HTML タグはエスケープして表示) |
| `options[].hint` | string | × | サブテキスト。同上 plain text |
| `allowOther` | bool | × | Other 行を出す。既定 `false` |

## 6. question (kind = rank)

```json
{
  "id": "q3",
  "kind": "rank",
  "title": "実装の優先順位を並べてください",
  "items": [
    { "id": "server",   "label": "Python サーバ実装", "hint": "http.server で 1-shot" },
    { "id": "template", "label": "HTML テンプレ確定", "hint": "mockup を骨にする" }
  ]
}
```

| field | 型 | 必須 | 説明 |
|---|---|---|---|
| `id`, `kind`, `title` | 同上 | ◎ | |
| `items` | array | ◎ | 2 件以上 |
| `items[].id` | string | ◎ | answer の ranking 配列に出る識別子。重複禁止。意味のある short snake_case で |
| `items[].label` | string | ◎ | UI に出る本文。**plain text として扱われる** |
| `items[].hint` | string | × | サブテキスト。同上 plain text |

## 7. 入力例

### 7.1 1 質問 + 表

```html
<script type="application/auq+json">
{ "$auq": "meta", "repo": "auq-web", "timeoutSec": 300 }
</script>

<script type="application/auq+json">
{
  "id": "q1",
  "title": "ライブラリを Python で固める方針で OK?",
  "kind": "single",
  "options": [
    { "value": "python", "label": "Python で固める", "hint": "macOS 標準" },
    { "value": "bun",    "label": "Bun で書く",    "hint": "brew install bun" }
  ],
  "allowOther": true
}
</script>

<p>auq-web の起動部分は <strong>呼び出し側に追加 install をさせない</strong>
のが理想です。</p>

<table>
  <tr><th>言語</th><th>事前準備</th><th>1-shot 行数</th></tr>
  <tr><td>Python</td><td>不要 (macOS 標準)</td><td>~50</td></tr>
  <tr><td>Bun</td><td>brew install bun</td><td>~20</td></tr>
</table>
```

### 7.2 複数質問 + rank

```html
<script type="application/auq+json">
{ "$auq": "meta", "repo": "auq-web" }
</script>

<script type="application/auq+json">
{
  "id": "q1", "kind": "single", "title": "言語選択",
  "options": [
    { "value": "py", "label": "Python" },
    { "value": "bn", "label": "Bun" }
  ]
}
</script>
<p>判断材料の表をここに...</p>

<script type="application/auq+json">
{
  "id": "q2", "kind": "rank", "title": "実装順を並べて",
  "items": [
    { "id": "server",   "label": "サーバ実装" },
    { "id": "template", "label": "テンプレ確定" },
    { "id": "skill",    "label": "Skill 配信" }
  ]
}
</script>
<p>上から「先に着手」の順。</p>
```

### 7.3 desc に SVG + データ JSON + JS

```html
<script type="application/auq+json">
{ "$auq": "meta", "repo": "auq-web" }
</script>

<script type="application/auq+json">
{ "id": "q1", "kind": "single", "title": "Chart 確認",
  "options": [
    { "value": "ok", "label": "問題なし" },
    { "value": "ng", "label": "見直す" }
  ]
}
</script>

<p>下のグラフを見てから選んでください。</p>

<svg id="chart" width="400" height="160"></svg>

<script type="application/json" id="chart-data">
{ "labels": ["A","B","C"], "values": [10, 20, 15] }
</script>

<script>
  // application/auq+json 以外なので desc にそのまま流れて実行される
  const d = JSON.parse(document.getElementById('chart-data').textContent);
  drawChart('chart', d);
</script>
```

### 7.4 desc にコード例として `</script>` を含めたい時

**HTML エンティティで escape する** のが唯一の正解 (生 `</script>` は HTML
パーサが script を早期 close するため):

```html
<script type="application/auq+json">
{ "$auq": "meta" }
</script>

<script type="application/auq+json">
{ "id": "q1", "kind": "single", "title": "...", "options": [...] }
</script>

<p>2 通りの書き方を比較してください。</p>
<pre><code>&lt;script type="module"&gt;
  import { foo } from './foo.js';
&lt;/script&gt;</code></pre>
```

## 8. answer payload 形式

POST `/answer` に向けて画面 JS が送る payload。`server.py` はこれを stdout に
そのまま 1 行 JSON で書き出す。

```json
{
  "event": "answer",
  "timedOut": false,
  "elapsedSec": 263,
  "answers": {
    "q1": { "kind": "single", "selected": "python", "comment": "" },
    "q2": { "kind": "multi",  "selected": ["a","c"], "comment": "..." },
    "q3": { "kind": "rank",   "ranking": ["server","template"], "comment": "" }
  }
}
```

`allowOther: true` で Other が選ばれた場合:

- `kind: "single"`: `selected: "__other__"` + `otherText: "<自由入力>"`
- `kind: "multi"`:  `selected` に `"__other__"` を含み + `otherText: "<自由入力>"`

reject (ユーザが拒否ボタンで閉じた) の場合:

```json
{ "event": "reject", "timedOut": false, "elapsedSec": 12 }
```

timeout の場合 (実装時に確定):

```json
{ "event": "answer", "timedOut": true, "elapsedSec": 300, "partialAnswers": {...} }
```

## 9. desc で使えるタグ

desc 領域は `server/index.html` の default stylesheet が当たるので、素のタグを
書けば dark theme に馴染む (inline `style` で毎回配色を書かない)。正本は index.html。

サポートタグ: `h1`-`h6` / `p` / `strong` / `em` / `small` / `mark` / `a` /
`ul` / `ol` / `li` / `blockquote` / `hr` / `code` / `pre` / `kbd` / `table` /
`thead` / `tbody` / `tr` / `th` / `td` / `img` / `figure` / `svg` / `figcaption` /
`details` / `summary`。

簡易 callout: `<p class="note">` / `<p class="warn">` / `<p class="danger">` /
`<p class="ok">` (色付き left-border + 薄い背景)。

列幅 `<col>` や特定セルの `colspan` などレイアウト固有の調整は inline `style` で
上書きしてよい (通常の HTML として動く)。
