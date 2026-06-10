---
name: baton
description: 現在の会話を引き継ぎ書に圧縮し、別の Claude セッションが続きを再開できるようにする。引数なしまたは「次セッションの焦点」を渡すと会話全体を引き継ぎ、先頭トークンが `partial` のときは続くテキストを「引き継ぐ範囲」として、その塊だけを切り出す。`/baton` の明示呼出で起動。
argument-hint: "[partial <引き継ぐ範囲>] | <次セッションの焦点>"
disable-model-invocation: true
---

会話を要約した引き継ぎ書を Write ツールでファイルに書き込む。

## 保存先

1. HOME は環境冒頭の primary working directory から取り出す (例: primary が `/Users/foo/repo` なら HOME は `/Users/foo`)。
2. baton dir を決める:
   - 既定: `<HOME>/.local/state/baton`
   - フォールバック: `<HOME>/.claude/settings.json` の `permissions.additionalDirectories` に `~/.local/state/baton` が無ければ `<primary working dir>/.local/baton`
3. ctx は `git rev-parse --show-toplevel 2>/dev/null || pwd` の出力の末尾セグメント。
4. stamp は `date +%Y%m%d-%H%M%S` の出力。
5. file_path:
   - 通常: `<baton_dir>/baton-<ctx>-<stamp>.md`
   - partial: `<baton_dir>/baton-partial-<ctx>-<stamp>.md`
6. Write ツールに `file_path` をリテラル絶対パスで渡し、本文を `content` で直接書く。`~` / `$HOME` / コマンド置換は使わない。

## 本文

PRD・plan・ADR・issue・commit・diff など、既に他の成果物に書かれている内容は本文に転写しない。パスや URL で参照する。

未検証の進捗・完了状態は断定形で書かない。受け手がそのまま信じると実態との食い違いが生じるため、確認が必要な状態は「未確認」と明記するか確認手段を添える。セッション内ツール（タスク管理等）の登録内容はタスク内容ごと引き継ぎ書に記録し「再登録が必要」と明示する。

引数があり先頭トークンが `partial` でないときは、引数を「次セッションの焦点」として扱い、それに合わせてドキュメントを整える。

引数の先頭トークンが `partial` のときは、続く自由テキストを「引き継ぐ範囲」の記述として扱う。範囲外の文脈は書かない（次エージェントが自分のスコープ外に手を出すのを防ぐため）。範囲が曖昧なら書き出す前に確認する。
