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
  target=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1 || true)
  if [[ -z "$target" ]]; then
    echo "no jsonl under $proj_dir" >&2
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
         | select(.type=="tool_use" and (.id as $id | $ids | index($id) != null))
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
