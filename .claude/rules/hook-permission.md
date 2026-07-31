# Claude Code の hook permission 仕様

`.claude/hooks/segment-allow.sh` を始めとする permission 関連 hook の挙動と運用ルール。
hook を新規追加・改修するとき、`permissions.allow` を触るときに参照する。

## hook の種類

- **PreToolUse**: 全ツール呼出で発火。allow を ask / deny に「厳しくする」方向のみ有効。静的 `ask` を `allow` に緩めることはできない
- **PostToolUse**: ツール呼出完了後に発火。結果の後処理・ログ記録などに使う。permission 決定には関与しない
- **PermissionRequest**: 静的 `ask` が確定した瞬間にだけ発火。**`ask` を `allow` に緩める唯一の方法**（ask を答える役）。**ヘッドレス (`claude -p`) では発火しない**（公式明記。2026-07 確認）
- **Stop**: Claude がターンを終了した直後に発火。セッション終了通知など副作用に使う。permission 決定には関与しない
- **SessionEnd**: セッション終了直後に発火する副作用 hook（ブロック不可）。入力 JSON は `session_id` / `transcript_path`（絶対パス）/ `cwd` / `reason`。matcher に reason（`clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other`）を指定できる。**ヘッドレスでも発火する**（reason: `prompt_input_exit`）ので、hook からヘッドレス claude を起動する構成では自己ループ防止の除外ガードが要る（例: `reflect-enqueue.sh` の `REFLECT_HEADLESS`）
  - reason=`resume` は**対話中の `/resume` 切替で「離脱する側」のライブセッション**に発火する（hooks.md の Reason 表 "Session switched via interactive /resume"。CHANGELOG v2.1.79 の修正エントリも同前提）。resume される側は SessionStart（source=`resume`）
  - resume は新セッションを作らず**同一 session-id・同一 jsonl に追記**して続く（2026-07 実測）。つまり reason=`resume` 時点の transcript は「その会話の最終版」とは限らず、後日同じ id のまま伸びうる
- PreToolUse / PermissionRequest の両者で `deny` は返せるが、静的 `deny` は hook 発火前に終了するため緩められない

## 典型パターン

- 「デフォ allow + 危険なパターンだけ hook で ask/deny 格上げ」→ PreToolUse（実例: `escalate-unsafe-bash.sh`。`find -exec`/`-delete`・非 localhost 宛て `curl`・dotfiles 外の skills スクリプト実行を ask に格上げ。`--self-test` あり）
- 「デフォ ask + 安全なパターンだけ hook で allow に素通し」→ PermissionRequest（実例: `segment-allow.sh` / `scratchpad-rm-allow.sh`）

hook handler には `if` フィールドで permission rule 構文の絞り込みを書ける（`"if": "Bash(rm *)"`）。1 handler に 1 ルールだけで `&&`/リスト構文は無い（複数条件は handler を分ける）。マッチしないときはプロセスを起動しないので、同じ matcher に用途別の handler を並べてよい。ただしコマンドがパースできないと fail open（`if` を無視して起動）するため、hook 側の判定は `if` に依存せず単独で完結させる。

## 応答 JSON の形式（はまりポイント）

- PreToolUse: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny"|"ask"}}`
- PermissionRequest: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"..."}}}`
- PostToolUse: `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"モデルに注入するメッセージ"}}` / 結果を差し替えるときは `"updatedToolOutput":{...}`
- 素通ししたい（判定せず静的ルールに任せる）ときはいずれも `{}` を返す

## 複数ワイルドカードパターンの末尾 ` *` は空にマッチしない

`Bash(git -C * diff *)` のように `*` を 2 つ以上含むパターンは素の glob として評価され、末尾の ` *` が「スペース + 1 文字以上」を要求する。そのため末尾引数なしの `git -C /path diff` にはマッチせず ask に落ちる（`git -C /path diff --stat` は通る。2026-06 実測）。単一ワイルドカードの `Bash(git status *)` 形式では公式ドキュメント通り bare `git status` にもマッチするので、この問題は複数ワイルドカード時のみ。対策として bare 実行があり得る `git -C` 系サブコマンドには末尾 ` *` なしの版 (`Bash(git -C * diff)` 等) を allow に併記している。starred 版と重複に見えるが消さないこと。

## ヘッドレス (`claude -p` + `dontAsk`) の permission 実測（2026-07）

無人実行の permission 設計で `--settings` / `--allowedTools` に頼る前に読む:

- **`ask` は scope を跨いで `allow` に勝つ**。user settings の `ask: Bash(gh api *)` は、`--settings` でコマンド完全一致の allow を渡しても `dontAsk` 下で自動拒否される（配列 union で ask は消せない）。PermissionRequest hook も `-p` では発火しないため、**静的 ask に入っている操作をヘッドレスで通す方法はない**
- **パス限定のファイルルールはマッチしない**。`Write(//abs/**)` / `Write(~/**)` / `Write(/abs/**)` のどれも `--settings` / `--allowedTools` 経由で効かなかった（パス指定なしの `Write` だけは効く）。パスを絞った書き込み許可は現状組めない
- 上記により、無人実行でモデルに書き込み・送信をさせる設計は避け、**モデルは stdout で結果を返しドライバ（claude 外のスクリプト）が副作用を実行する**構成に倒す（例: `reflect` の outbox パターン。`.claude/skills/reflect/run-headless.sh`）

## segment-allow.sh の safe-prefix 自動同期

`gh api ... | jq ...` のような複合コマンドは、Claude Code が `&&`/`||`/`;`/`|` で分割して各セグメントごとに静的 allow を判定する。1 つでも未許可セグメントがあると全体 ask に倒れるため、PermissionRequest hook (`.claude/hooks/segment-allow.sh`) が全セグメントを safe-prefix リストと照合し、すべて safe かつ `gh api` を 1 つ以上含むときだけ allow を返す。

safe-prefix リスト (`~/.claude/hooks/segment-allow.prefixes`) は `setup.sh` が `permissions.allow` から自動生成する:

- `Bash(cmd)` → `cmd` (exact)
- `Bash(cmd *)` → `cmd *`
- `Bash(cmd:*)` → `cmd` と `cmd *` の 2 行 (Claude Code の `:*` セマンティクス)
- `Bash(cmd sub *)` / `Bash(cmd sub:*)` → 多語サブコマンドにも対応 (`git status *` / `gh pr view *` 等)
- 除外: 内部に `*` や `/` を含む複合パターン (`git -C * status *`, `xargs -n* ls *`, `cat */.mirugit/*`) — bash glob として 1 セグメント照合できないので hook の責務外
- `gh api` だけは hook 側で書き込みフラグの有無を判定する特別扱い（静的 allow には載せない）。argv をトークン分割し `-X* / --method* / -f* / -F* / --field* / --raw-field* / --input*` のどの prefix も含まないと確認できたときだけ safe とする（long form `--field` や連結形 `-XDELETE` / `-Ftitle=x` を正規表現では取りこぼすため、prefix 判定に倒している）
- `gh api graphql` はさらに別扱い。参照クエリでも本文を `-f query=...` で渡すので上のフラグ判定では必ず ask に落ちるため、「セグメント全体に `mutation` が現れない」ことを条件に safe とする（GraphQL の書き込みは mutation operation 限定で、キーワード省略の shorthand `{...}` は spec 上 query 固定なので、この 1 語で読み書きを判別できる）。値を検査できない `--input` / `-F key=@file` / `-F key=@-` と、判定面を増やす `--method` は引き続き unsafe。`__type(name:"Mutation")` のような参照も巻き添えで ask になるが、false positive は安全側なので許容する
- `split_segments` は NUL 区切りで返す。`-f query='<改行>...'` のようにセグメント自身が改行を含むケースがあり、改行区切りだと呼び出し側の `read -r` が 1 セグメントを分割してクエリ本文の断片を「未知のコマンド」と誤判定するため
- さらに全セグメント共通で、クォート外に `& $ \` ( ) < >`・改行が現れたら prefix が何であれ unsafe に倒す（`&`・`$()`・バッククォート・リダイレクト等は末尾 glob の prefix 照合をすり抜けるため）。例外は 2 つ:
  - `gh api ... > /tmp/...` への保存（実運用で多用するため。リダイレクト先が /tmp 配下リテラルのときのみ）
  - 単語として現れる `2>&1`（fd 複製だけで副作用が無く、`gh api ... 2>&1 | head` の形で多用する）。単語境界を要求するので `&>file` / `2>file` / `>&1` は従来通り検出される。`2>& 1`（空白入り。bash では合法）と、`2>&1` とファイルリダイレクトの併用は読み飛ばさず ask に落ちる

### メンテ手順

- 新たに `gh api ... | <cmd> ...` を素通ししたい → `Bash(<cmd> *)` を allow に追加 → `./setup.sh <env>` で prefix 再生成
- hook ロジック側の self-test: `bash .claude/hooks/segment-allow.sh --self-test`

## scratchpad-rm-allow.sh の許可条件

`Bash(rm *)` は `settings.local/common.json` の `permissions.ask` にあり、union される ask は allow で消せない。scratchpad（`/private/tmp/claude-<uid>/<project-slug>/<session-id>/scratchpad`）配下の一時ファイル削除だけを人間ゲート無しで通すため、PermissionRequest hook (`.claude/hooks/scratchpad-rm-allow.sh`) が下記すべてを満たすときだけ allow を返す。1 つでも欠けたら `{}` を返して静的 ask に委ねる。

- コマンド全体が文字白名簿 `[A-Za-z0-9_./*?,+=:@ -]` のみ。クォート・`$`・バッククォート・`&&`/`;`/`|`/`&`・リダイレクト・改行・`~` はこの 1 本で落ちる（複合コマンドも同時に排除されるので、segment-allow.sh のような分割・トークナイズを持たずに済む）
- 入力 JSON の `tool_name` が `Bash`（`if` はコマンドをパース不能なとき fail open するので hook 側でも確かめる）
- 先頭トークンが素の `rm`（`command rm` / `/bin/rm` / `sudo rm` は対象外）
- フラグは `-[rRfvdi]+` の連結短縮形と `--` のみ。未知フラグがあれば ask
- 全オペランドが `^/private/tmp/claude-<実行ユーザの uid>/[^/]+/<hook 入力の session_id>/scratchpad/[^/].*` にマッチ。相対パスは cwd を確定できないので対象外
- パス成分がドットで始まらない（`..` はもちろん `.?` / `.*` も拒否。白名簿が `.` `?` `*` を通すので、リテラルの `..` が無くても展開時に `../..` になり prefix 照合をすり抜ける。`.` 始まりの成分は `?` / `*` にマッチしないため、`/.` を封じれば展開後も scratchpad 内に閉じる。bash 5.2+ の globskipdots や zsh は `..` を展開しないが、macOS 同梱の `/bin/bash` 3.2 は展開するのでシェル任せにしない）
- scratchpad ルート自体は対象外（`/[^/].*` を要求）。ルートが消えると以降の一時ファイル書き込みが軒並み失敗するため

`session_id` を実パスに埋めるので、並行して動く別セッションや別 uid の scratchpad は allow されない。scratchpad のパス規約が将来変わっても照合が外れて ask に落ちるだけで、安全側に倒れる。

self-test: `bash .claude/hooks/scratchpad-rm-allow.sh --self-test`
