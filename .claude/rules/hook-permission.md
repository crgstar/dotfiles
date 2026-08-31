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

- 「デフォ allow + 危険なパターンだけ hook で ask/deny 格上げ」→ PreToolUse（実例: `escalate-unsafe-bash.sh`。`find -exec`/`-delete`・非 localhost 宛て `curl`・dotfiles 外の skills スクリプト実行を ask に格上げ。`--self-test` あり / `pr-comment-signature.sh`。後述）
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
- 上記により、無人実行でモデルに書き込み・送信をさせる設計は避け、**モデルは stdout で結果を返しドライバ（claude 外のスクリプト）が副作用を実行する**構成に倒す（例: `reflect` の outbox パターン。`.claude/skills-global/reflect/run-headless.sh`）

## segment-allow.sh の safe-prefix 自動同期

`gh api ... | jq ...` のような複合コマンドは、Claude Code が `&&`/`||`/`;`/`|` で分割して各セグメントごとに静的 allow を判定する。1 つでも未許可セグメントがあると全体 ask に倒れるため、PermissionRequest hook (`.claude/hooks/segment-allow.sh`) が全セグメントを safe-prefix リストと照合し、すべて safe かつ **hook が責務を負う対象 (`gh api` / `git -C`) を 1 つ以上含む**ときだけ allow を返す。

safe-prefix リスト (`~/.claude/hooks/segment-allow.prefixes`) は `setup.sh` が `permissions.allow` から自動生成する:

- `Bash(cmd)` → `cmd` (exact)
- `Bash(cmd *)` → `cmd` と `cmd *` の 2 行。**bare 側を落とさないこと**: Claude Code の静的 allow は `Bash(head *)` で引数なしの `head` も通す（2026-08 実測）が、bash glob の `head *` は「空白 + 1 文字以上」を要求して bare に一致しない。bare を落とすと hook だけが静的 allow より狭くなり、`gh api ... | head` のようにパイプ末尾へ引数なしで置いた道具 (`head` / `cat` / `sort` / `uniq` / `pwd` 等) が未知セグメント扱いになって、コマンド全体が ask に落ちる
- **auto mode の分類器が通すコマンドも allow に書く**: auto mode 下では `cd` / `awk` / `basename` のように allow 外でも確認なしで通るものがある (2026-08 実測)。だが safe-prefix は `permissions.allow` からしか生成されないので hook には未知セグメントに見え、`cd <path> && gh api ...` だけが ask に落ちる。足してよいのはコマンド実行もファイル書き込みも持たないものだけ (`cd` は可。`awk` は `system()` / `> file` を持つので不可。`sed` と同様に hook 側の構造判定を書くまで allow には載せない)
  - 判定基準は「実行と書き込みを持たないか」だけでは足りない。**他の hook がパス解決に使う前提を壊さないか**も見る。`cd` は自身は無害だが後続セグメントの相対パスの意味を変えるので、`escalate-unsafe-bash.sh` が `bash */.claude/skills/*` の実体を `readlink -f` で確かめる判定と噛み合わず、`cd <第三者ディレクトリ> && bash ./.claude/skills/<name>/<file>` が「dotfiles 製スキル」と誤判定されて素通りしていた。`lib/bash-safety.sh` 側で「`cd` を含むコマンド内の相対パスは解決不能として ask」に倒して塞いである
- `Bash(cmd:*)` → `cmd` と `cmd *` の 2 行 (Claude Code の `:*` セマンティクス)
- `Bash(cmd sub *)` / `Bash(cmd sub:*)` → 多語サブコマンドにも対応 (`git status *` / `gh pr view *` 等)。こちらも bare (`git status`) と starred の 2 行
- 除外: 内部に `*` や `/` を含む複合パターン (`cat */.mirugit/*`) と、単語が `-` で始まるパターン (`xargs -n1 ls *` / `xargs -0 grep *`) — bash glob として 1 セグメント照合できない・抽出正規表現の単語形に合わないので hook の責務外 (`gh api ... | xargs ...` は ask に落ちる)
- `gh api` だけは hook 側で書き込みフラグの有無を判定する特別扱い（静的 allow には載せない）。argv をトークン分割し `-X* / --method* / -f* / -F* / --field* / --raw-field* / --input*` のどの prefix も含まないと確認できたときだけ safe とする（long form `--field` や連結形 `-XDELETE` / `-Ftitle=x` を正規表現では取りこぼすため、prefix 判定に倒している）
- `gh api graphql` はさらに別扱い。参照クエリでも本文を `-f query=...` で渡すので上のフラグ判定では必ず ask に落ちるため、「セグメント全体に `mutation` が現れない」ことを条件に safe とする（GraphQL の書き込みは mutation operation 限定で、キーワード省略の shorthand `{...}` は spec 上 query 固定なので、この 1 語で読み書きを判別できる）。値を検査できない `--input` / `-F key=@file` / `-F key=@-` と、判定面を増やす `--method` は引き続き unsafe。`__type(name:"Mutation")` のような参照も巻き添えで ask になるが、false positive は安全側なので許容する
- `split_segments` が分割するのは `&&` / `||` / `;` / `|` / **クォート外の改行**。bash では改行はコマンド区切りそのものなので、区切らないと複数行コマンドが 1 セグメントに潰れ、下記のクォート外改行チェックに当たって中身が何であれ ask に落ちていた。分割してから 1 行ずつ白名簿を通す方が判定は精密になる（緩むのではなく、各行が個別に照合される）
- `split_segments` は NUL 区切りで返す。`-f query='<改行>...'` のようにセグメント自身が改行を含むケースがあり、改行区切りだと呼び出し側の `read -r` が 1 セグメントを分割してクエリ本文の断片を「未知のコマンド」と誤判定するため
- **クォート外の `\` は「次の 1 文字ごと持ち越す」**。`split_segments` と `has_unsafe_metachar` の両方で同じ扱いをすること。片方だけだと穴が開く:
  - `split_segments` 側で持ち越さないと、行継続 `\<改行>` を区切りと誤読し、実際には 1 コマンドの引数だったトークンが独立セグメントとして白名簿に照合されて素通りする
  - `has_unsafe_metachar` 側で読み飛ばさないと、`\"` / `\'` が擬似的なクォート区間を開き、その内側の `& > < ( )` が「クォート内だから安全」と誤判定される。`echo \"a&rm -rf ~` は bash では `echo "a` を background 実行して `rm -rf ~` を走らせるが、これで `echo *` に一致して allow になっていた
  - 行継続 `\<改行>` だけは例外で、`has_unsafe_metachar` が unsafe に倒す（セグメント内に残った改行が「実 bash では 1 コマンド」の目印なので、素通しせず ask へ送る）
- `sed` も `gh api` と同じ hook 側の特別扱い（静的 allow には載せない）。glob 照合では `sed -n '60,90p'` と `sed -i '' 's/x/y/' file` を区別できず、`Bash(sed -n *)` に絞っても `sed -n -i.bak ...` が同じ glob に一致するため。判定はブラックリストではなくホワイトリストで、**`-n`（`--quiet` / `--silent`）と「数値アドレス + `p`」のスクリプト 1 個、および入力ファイル名だけ**で構成されるときのみ safe とする。`-i` / `-I` はもちろん、スクリプト本文に隠れる `w file`・`s///w file`（任意ファイルへの書き出し）と GNU sed の `e`・`s///e`（シェルコマンド実行。BSD には無い）も、この文法では文字として現れる余地が無いので構造的に排除される。フラグを見るブラックリストだと後者を素通りさせ、実装・版が変わるたびに穴が開く
  - `-E` / `-u` のように単体では無害なフラグも受理しない。引数を取るフラグ（BSD の `-i` は拡張子、`-e` はスクリプト、`-l` は BSD では引数なしだが GNU では数値を取る）が混ざると「次のトークンは何か」の解釈が実装で食い違うため、`-n` 以外を落として arity の解釈自体を不要にしている
  - GNU sed の `--sandbox`（`e`/`w`/`r` を実行前に拒否する）は BSD sed に無いので当てにできない
  - 最終行を表す `$` は `60,$p` の形で許可（シングルクォート内なのでクォート外の `$` を弾く判定とは衝突しない）。正規表現アドレス `/re/p` は区切り文字変更やエスケープの解釈が必要で「w / e が現れない」を機械的に言えないため対象外
  - **クォート内に改行を含むセグメントは無条件で unsafe**。`tokenize_quoted` は改行入りトークンでも出力を改行区切りにするので、`sed -n '1,5p<改行>w /tmp/x'` が「スクリプト `1,5p`」+「入力ファイル名 `w /tmp/x`」の 2 トークンに割れ、実際には sed の `w`（任意ファイルへの書き出し）や GNU の `e`（シェルコマンド実行）が allow で通ってしまう。`is_safe_gh_graphql` が mutation 判定をトークン化に依存させないのと同じ罠
- さらに全セグメント共通で、クォート外に `& $ \` ( ) < >`・改行（行継続 `\<改行>` で持ち越されたもの。素の改行は上記のとおり分割済み）が現れたら prefix が何であれ unsafe に倒す（`&`・`$()`・バッククォート・リダイレクト等は末尾 glob の prefix 照合をすり抜けるため）。例外は 2 つ:
  - `gh api ... > /tmp/...` への保存（実運用で多用するため。リダイレクト先が /tmp 配下リテラルのときのみ）
  - 単語として現れる副作用の無いリダイレクト（`2>&1` の fd 複製と、`2>/dev/null` / `1>/dev/null` / `&>/dev/null` / `>/dev/null` の出力破棄）。ファイル生成もコマンド実行も伴わず、`/dev/null` は書き込みが常に捨てられる特殊デバイスなのでリダイレクト先の変動もない。単語境界を要求するので `&>file` / `2>file` / `>&1` / `2>/dev/nullx` / `12>/dev/null` は従来通り検出される。空白入り（`2>& 1` / `2> /dev/null`。bash では合法）と、他のファイルリダイレクトとの併用は読み飛ばさず ask に落ちる

### git -C の構造判定 (`is_safe_git_c`)

`git -C <path> <サブコマンド>` は静的 allow に載せない。`Bash(git -C * status)` の `*` は
コマンド文字列全体に対する glob なので空白をまたぎ、
`git -C /tmp -c core.fsmonitor='任意コマンド' status` にも一致してしまう
(`core.fsmonitor` は status / diff / fetch / ls-files が index を更新する際に、
`diff.external` は diff 実行時に、いずれも無条件で起動される。2026-08 実測)。
Claude Code 自身も起動時に該当ルールを「サブコマンドより前のワイルドカードは
差し込まれたオプションごと承認する」と警告する。パスを実値に固定しない限り
glob では表現できないため、hook 側の構造判定に倒している。

allow を返す条件は、トークン分割した結果が下記すべてを満たすとき:

- 先頭トークンが素の `git` (`/usr/bin/git` / `command git` / `sudo git` は対象外)
- 続くトークンが `-C` ＋ パスの **1 組だけ**。`-C` より前に何か来る形 (`git -c ... -C ...`)、
  パス位置がオプションの形 (`git -C -c ...`)、連結形 (`-C/path`)、`-C` が 2 組はすべて落ちる
- サブコマンドが `status` / `log` / `diff` / `show` / `branch` / `fetch` / `remote` / `blame` /
  `rev-parse` / `ls-files` / `check-ignore` / `worktree` のいずれか。
  `stash` は直後が `list` のときだけ (引数なしの `git stash` は変更の退避＝書き込みのため)。
  **この集合は「読み取り専用」ではない** — `fetch` は ref/object を、`branch -D` は ref を、
  `remote add` / `worktree add`・`remove` はリポジトリ構成を書き換える。それでも通すのは
  `-C` なし版が静的 allow に載っているからで、追加の基準は「読み取り専用か」ではなく
  「`-C` なし版が静的 allow にあるか」
- クォート内に改行を含むセグメントは無条件で unsafe (`is_safe_sed` と同じ理由。
  `tokenize_quoted` の出力が改行区切りなのでトークン境界がずれ、サブコマンド位置を誤読する)

**サブコマンドより後ろのオプションは検査しない。** `--upload-pack` (任意コマンド実行)・
`--output` (任意パス書き込み)・`--ext-diff` はいずれも危険だが、`-C` を含まない
`Bash(git diff *)` / `Bash(git fetch *)` でも同様に通る (実測)。ここだけ絞ると同じ操作が
`-C` の有無で通ったり通らなかったりする二重基準になるので、`-C` なし版と同水準に揃えている。
後ろ側を締めるなら allow → ask の格上げ側 (PreToolUse の `escalate-unsafe-bash.sh`) の担当。
なお git は設定によるフック機構を持つため、リポジトリ自身の `.git/config` に
`diff.external` を書けばオプション無しの `git diff` でも任意コマンドが走る。
permission ルールでこの経路は閉じられない。

### ヘッドレスで必要な `git -C` は実パスで allow に残す

PermissionRequest hook はヘッドレスで発火しない。`reflect` は
`claude -p --permission-mode dontAsk` で動き `git -C ~/dotfiles ls-files ...` を実行するため、
`Bash(git -C ~/dotfiles ls-files *)` だけ `settings.local/common.json` の allow に残している
(パスが実値なので Claude Code の警告対象にもならない)。同種の必要が出たら、
ワイルドカードではなく実パスで足すこと。

ただしこの allow はパスの**表記**に一致するので、`reflect/SKILL.md` が
`git -C ~/dotfiles ...` と書いている限りでしか当たらない。SKILL.md 側の表記を
絶対パスや `$HOME/dotfiles` に変えると、ヘッドレスでは hook も効かず黙って
スキル列挙が落ちる。片方を変えるときはもう片方も揃えること。

### 同じ hook を複数の `if` で登録する

`if` は 1 handler に 1 ルールしか書けないので、`segment-allow.sh` は
`Bash(gh api *)` と `Bash(git -C *)` の 2 handler で登録している。
対象を増やすときは handler を足す (`if` に `&&` やリストは書けない)。

### メンテ手順

- 新たに `gh api ... | <cmd> ...` を素通ししたい → `Bash(<cmd> *)` を allow に追加 → `./setup.sh <env>` で prefix 再生成
- `git -C` で新たなサブコマンドを通したい → `is_safe_git_c` のホワイトリストに追加 (静的 allow ではなく hook 側)
- hook ロジック側の self-test: `bash .claude/hooks/segment-allow.sh --self-test`
- 派生規則側の self-test: `./setup.sh --self-test` (設定は書き換えない)。hook 側の self-test は SAFE_PREFIXES を自前で手書きしており実際の派生結果を見ないので、この 2 本は別物として両方回す。片方だけだと「hook だけが静的 allow より狭い」状態が緑で通る

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

## pr-comment-signature.sh の格上げ条件

`respond-to-pr-review` / `review-comment` は返信・指摘の末尾に「空行 + Claude Code の署名」を必須としているが、スキルを経由せず `gh api` を直接叩くと規定を踏まずに投稿できてしまう。PreToolUse hook (`.claude/hooks/pr-comment-signature.sh`) が、コメント本文を送る `gh api` 呼び出しで署名を確認できないときだけ ask に格上げする。判定できないケース（本文ファイルを解決できない・入力 JSON を解釈できない）は pass ではなく ask に倒す。

対象とする投稿経路（**どれか 1 つでも落とすと一番よく使う経路が素通りする**）:

- REST: パスに `/comments` / `/replies` / `/reviews` を含み、かつ本文フィールドを渡している呼び出し。本文フィールドは `body=` だけでなく PENDING レビューを作る `-F 'comments[][body]=...'` のようなネスト形も拾う（`review-comment` の既定の投稿経路がこの形）
- GraphQL: `gh api graphql` で `mutation` と `body` を含む呼び出し（既存 PENDING レビューへ追記する `addPullRequestReviewThread` 等）。REST のパス判定に掛からないので別経路で見る。参照クエリは `mutation` が無いので対象外

`-F` / `--field` の `body=@file` だけがファイル参照なので、解決したファイルの中身を 1 件ずつ検査する（連結して見ると「どれか 1 つに署名があれば通る」抜けができる）。`-f` / `--raw-field` は `@` を展開せずリテラル `@path` を本文として送るため、ファイル参照として除外せずコマンド文字列側の署名確認に回す。

`gh api` 以外の投稿経路（`gh pr comment` / `gh pr review` / `gh issue comment`）は現状カバーしていない。

self-test: `bash .claude/hooks/pr-comment-signature.sh --self-test`
