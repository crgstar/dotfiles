#!/usr/bin/env bash
# session-feedback extract.sh
#
# Why: surface structured signals from a Claude Code transcript jsonl so the
# session-feedback skill can quote them verbatim. Output is stable plain text
# because the skill reads it directly into the model's context.
#
# Why slurp (-s) everywhere: streaming jq piped into head/tail/wc gets
# SIGPIPE'd under `set -o pipefail`. Slurping once keeps the pipeline simple
# and the exit semantics predictable.

set -euo pipefail

target="${1:-}"
if [[ -z "$target" ]]; then
  proj_dir="$HOME/.claude/projects/$(printf '%s' "$PWD" | tr '/' '-')"
  # Why session-id is the only auto-detection: the project dir accumulates one
  # jsonl per session (dozens of files), so picking by mtime (`ls -t | head -1`)
  # silently grabs the wrong transcript whenever a parallel cmux session or a
  # background routine writes more recently. CLAUDE_CODE_SESSION_ID is set inside
  # the live session and equals this session's jsonl basename -- the only
  # deterministic source of truth. No mtime fallback: guessing wrong is worse
  # than failing loudly, so when the env var is absent we require an explicit $1.
  if [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
    echo "CLAUDE_CODE_SESSION_ID is unset; pass the transcript jsonl path as \$1" >&2
    exit 1
  fi
  target="$proj_dir/$CLAUDE_CODE_SESSION_ID.jsonl"
  if [[ ! -f "$target" ]]; then
    echo "no jsonl for current session: $target" >&2
    exit 1
  fi
fi

if [[ ! -f "$target" ]]; then
  echo "not a file: $target" >&2
  exit 1
fi

printf '# session-feedback extract\n'
printf 'session: %s\n\n' "$target"

# --- session span ----------------------------------------------------------
# user_turns / assistant_turns count only events that contain a text block,
# so tool_result-only user events and tool_use-only assistant events are
# excluded -- this approximates "real conversation turns".
printf '## session span\n'

read -r first_ts last_ts <<< "$(jq -rs '
  [.[] | select(.timestamp != null) | .timestamp] as $ts
  | ($ts[0] // "?") + " " + ($ts[-1] // "?")
' "$target")"
[[ "$first_ts" == "?" ]] && first_ts=""
[[ "$last_ts"  == "?" ]] && last_ts=""

user_turns=$(jq -s '
  [.[]
    | select(.type=="user")
    | select(
        (.message.content | type) == "string"
        or any(.message.content[]?; .type=="text")
      )
  ] | length
' "$target")

assistant_turns=$(jq -s '
  [.[]
    | select(.type=="assistant")
    | select(any(.message.content[]?; .type=="text"))
  ] | length
' "$target")

duration=""
if [[ -n "$first_ts" && -n "$last_ts" ]]; then
  fe=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${first_ts%.*}" "+%s" 2>/dev/null || echo "")
  le=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" "+%s" 2>/dev/null || echo "")
  if [[ -n "$fe" && -n "$le" ]]; then
    sec=$((le - fe))
    duration="$((sec / 60))m $((sec % 60))s"
  fi
fi

printf 'first event: %s\n' "${first_ts:-(unknown)}"
printf 'last event: %s\n' "${last_ts:-(unknown)}"
printf 'duration: %s\n' "${duration:-(unknown)}"
printf 'user turns (with text): %s\n' "$user_turns"
printf 'assistant turns (with text): %s\n' "$assistant_turns"
printf '\n'

# --- skills invoked --------------------------------------------------------
# Only explicit Skill tool_use events are captured. Skills auto-loaded by
# SessionStart hooks (e.g. using-superpowers) do not appear here.
printf '## skills invoked\n'
skills=$(jq -rs '
  [ .[]
    | select(.type=="assistant")
    | .message.content[]?
    | select(.type=="tool_use" and .name=="Skill")
    | .input.skill
      + (if (.input.args // "") == "" then "" else "  (args: " + (.input.args | tostring) + ")" end)
  ]
  | if length == 0 then "(none)"
    else group_by(.)
      | map({n: length, name: .[0]})
      | sort_by(-.n)
      | map("  \(.n)  \(.name)")
      | join("\n")
    end
' "$target")
printf '%s\n\n' "$skills"

# --- permission denied tool uses -------------------------------------------
# Why drop old_string/new_string: a single denied Edit can carry kilobytes
# of diff text that is irrelevant to triage and just burns context. Keep
# only file_path for Edit/Write; pass other tool inputs through as-is.
# Why exclude AskUserQuestion: AUQ rejection is not a permission signal --
# it almost always means Claude asked before gathering the prerequisites.
# Surfaced separately in `## askuserquestion rejections` below.
printf '## permission denied tool uses\n'
denied=$(jq -cs '
  [.[] | select(.type=="user")
        | .message.content[]?
        | select(.type=="tool_result" and .is_error==true)
        | select((.content | tostring) | test("doesn.t want to proceed|tool use was rejected"; "i"))
        | .tool_use_id
  ] as $ids
  | [.[] | select(.type=="assistant")
         | .message.content[]?
         | select(.type=="tool_use"
                  and .name != "AskUserQuestion"
                  and (.id as $id | $ids | index($id) != null))
         | {
             name,
             input: (
               if .name == "Edit" or .name == "Write" then
                 {file_path: .input.file_path}
               elif .name == "NotebookEdit" then
                 {notebook_path: (.input.notebook_path // .input.file_path)}
               else
                 .input
               end
             )
           }
  ]
' "$target")

if [[ "$denied" == "[]" ]]; then
  printf '(none)\n'
else
  jq -c '.[]' <<< "$denied"
fi
printf '\n'

# --- askuserquestion rejections --------------------------------------------
# Why separate section: AskUserQuestion rejection != denial. Most often it
# signals that Claude asked before establishing the premise from primary
# sources (files, git, memory). Surface the original question text /
# options so the skill can diagnose which premise was missing.
printf '## askuserquestion rejections\n'
auq_rej=$(jq -cs '
  [.[] | select(.type=="user")
        | .message.content[]?
        | select(.type=="tool_result" and .is_error==true)
        | select((.content | tostring) | test("doesn.t want to proceed|tool use was rejected"; "i"))
        | .tool_use_id
  ] as $ids
  | [.[] | select(.type=="assistant")
         | .message.content[]?
         | select(.type=="tool_use"
                  and .name == "AskUserQuestion"
                  and (.id as $id | $ids | index($id) != null))
         | {
             questions: [
               .input.questions[]? | {
                 question,
                 header,
                 options: [.options[]? | .label]
               }
             ]
           }
  ]
' "$target")

if [[ "$auq_rej" == "[]" ]]; then
  printf '(none)\n'
else
  jq -c '.[]' <<< "$auq_rej"
fi
printf '\n'

# --- structured question answers -------------------------------------------
# Why: AskUserQuestion / auq-web の回答はツールブロック内にありモデルが読み飛ばし
# やすいので verbatim で surface する (どう分類するかは §1.2 の仕事)。
# Why 出所 (tool_use 名) で判定するか: 回答文を本文に含むだけの tool_result (transcript
# を読む / diff を出す / レビュー出力など) をテキストマッチすると偽の回答が大量に出る。
# tool_use_id を name に突合し、AskUserQuestion の回答だけを拾う (denied 節と同手法)。
# 文言非依存になり "Your questions have been answered" 等の表記揺れも取りこぼさない。
# AskUserQuestion は preview 付きだと回答文字列に改行が混じり、行分割すると 2 問目
# 以降が脱落するので改行を潰して 1 行化する。auq-web の回答は Bash 出力なので、その
# 中から event+answers の JSON 行だけを拾う。
# Why skip is_error=true: rejected AUQ の tool_result は "The user doesn't want
# to proceed..." メタテキストが入り、回答として読むと偽の "answer" になる。拒否は
# `## askuserquestion rejections` で別建てしているので、ここでは除外する。
printf '## structured question answers\n'
qa=$(jq -rs '
  def tr_text: if type=="array" then (map(.text? // "") | join("\n")) else tostring end;
  ( [ .[] | select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use") | {(.id): .name} ] | add // {} ) as $names
  | [ .[] | select(.type=="user") | .message.content[]?
      | select(.type=="tool_result")
      | select(.is_error != true)
      | $names[.tool_use_id] as $tool
      | (.content | tr_text) as $c
      | if $tool == "AskUserQuestion" then ($c | gsub("\n"; " "))
        elif (($tool=="Bash" or $tool=="BashOutput")
              and ($c | test("\"event\"\\s*:\\s*\"answer\".*\"answers\"")))
          then ($c | split("\n")[] | select(test("^\\s*\\{\"event\"\\s*:\\s*\"answer\".*\"answers\"")))
        else empty end
    ]
  | if length==0 then "(none)" else (map("  " + .) | join("\n")) end
' "$target")
printf '%s\n\n' "$qa"
