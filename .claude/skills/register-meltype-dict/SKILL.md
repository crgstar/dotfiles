---
name: register-meltype-dict
description: >-
  Mac の日本語入力 Meltype のユーザー辞書 (userdict.txt) に単語を登録するスキル。
  「Meltype に辞書登録して」「Meltype に単語を登録」「〇〇 を Meltype の辞書に入れて」
  「読み 単語 を辞書に書いて」等で使う。
  対象外: Meltype の更新・インストール (meltype-update の領分)、Windows 版、macOS 標準のユーザ辞書の編集。
argument-hint: "[読み] [単語]"
arguments: [yomi, word]
---

# Meltype 辞書登録

Mac 版に登録画面は無い。仕様の正本は `yksr-melt/Meltype` の `mac/README.md`「ユーザー辞書」節。

1. 読み `$yomi`・単語 `$word` が空や曖昧ならユーザに確かめる。読みはひらがなに揃える
2. 同じ読みが既にあれば止まり、上書きか追加かを確かめる (同じ読みが並ぶと順位が読めなくなるため)
3. 追記して、区切りがタブ 1 つかを確かめる

```bash
F="$HOME/Library/Application Support/Meltype/userdict.txt"
[ -d "$(dirname "$F")" ] || { echo "Meltype 未インストール"; exit 1; }
grep -n "^$yomi	" "$F" 2>/dev/null && { echo "既存の読みあり"; exit 1; }
printf '%s\t%s\n' '$yomi' '$word' >> "$F"
cat -t "$F" | tail -n 3
```

4. 反映は `pkill -x Meltype` のあと、ユーザに入力ソースを選び直してもらう (Claude からは切り替えられない)
