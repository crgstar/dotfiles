---
name: baton
description: 現在の会話を引き継ぎ書に圧縮し、別の Claude セッションが続きを再開できるようにする。引数なしまたは「次セッションの焦点」を渡すと会話全体を引き継ぎ、先頭トークンが `partial` のときは続くテキストを「引き継ぐ範囲」として、その塊だけを切り出す。`/baton` の明示呼出で起動。
argument-hint: "[partial <引き継ぐ範囲>] | <次セッションの焦点>"
disable-model-invocation: true
---

会話を要約した引き継ぎ書を書き、`mktemp -t baton-XXXXXX.md`（partial モードでは `mktemp -t baton-partial-XXXXXX.md`）で生成したパスに保存する。

PRD・plan・ADR・issue・commit・diff など、既に他の成果物に書かれている内容は本文に転写しない。パスや URL で参照する。

引数があり先頭トークンが `partial` でないときは、引数を「次セッションの焦点」として扱い、それに合わせてドキュメントを整える。

引数の先頭トークンが `partial` のときは、続く自由テキストを「引き継ぐ範囲」の記述として扱う。範囲外の文脈は書かない（次エージェントが自分のスコープ外に手を出すのを防ぐため）。範囲が曖昧なら書き出す前に確認する。
