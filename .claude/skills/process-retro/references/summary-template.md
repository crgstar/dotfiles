# process-retro §4 サマリ出力フォーマット

実行末尾に stdout へ必ず出すフォーマット (日本語)。Routine が残す唯一の痕跡なので、「走ったが変更が無かった」と「そもそも走らなかった」を区別できる形で出す。

```text
process-retro 実行サマリ (<YYYY-MM-DD HH:MM:SS>)

受信 issue: <N> 件 (overflow=<true|false>)
処理結果:
  - accept (コミット済): <A> 件
  - reject: <B> 件 (内訳: R1=<x>, R2=<x>, ...)
  - conflict: <C> 件
  - parse-error: <D> 件 (issue 単位)

指摘ごとの詳細:
  issue #<N> 指摘 <n>: <accept|reject|conflict|parse-error>
    対象:    .claude/skills/<target>/SKILL.md | —
    sanitize: <ok|leaked|—>
    commit:  <sha> | —
  ...

ブランチ: <branch_name> (base=<base>) — <commit_count> commits — <pushed to origin | push-failed (<reason>) | created and deleted>
失敗カウント: comment-failed=<x>, close-failed=<x>, commit-failed=<x>
```

## 注記

- `commit_count == 0` のときは「作成して削除」と明示する
- `overflow=true` のときは末尾に「50 件上限到達: 残りは次回の実行で処理」を添える
