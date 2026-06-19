#!/usr/bin/env bash
# PostToolUse hook: MCP ツールのエラー時に ToolSearch を促す
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

if [[ "$TOOL_NAME" != mcp__* ]]; then
  echo '{}'
  exit 0
fi

# tool_output の構造が確定していないため両方のフォーマットに対応
IS_ERROR=$(printf '%s' "$INPUT" | jq -r '
  if (.tool_error // null) != null then "true"
  elif (.tool_output | type) == "object" and (.tool_output.isError // .tool_output.is_error // false) then "true"
  else "false"
  end
')

if [[ "$IS_ERROR" == "true" ]]; then
  jq -n --arg tool "$TOOL_NAME" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("MCP tool \"" + $tool + "\" returned an error. Before retrying, verify parameter names: ToolSearch query=\"select:" + $tool + "\"")
    }
  }'
else
  echo '{}'
fi
