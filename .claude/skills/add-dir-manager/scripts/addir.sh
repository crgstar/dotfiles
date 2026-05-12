#!/bin/bash
# additionalDirectories management for Claude Code's .claude/settings.local.json
# Per-repo atomic operations: list / add / remove / group-setup
# Higher-level orchestration (glob expansion, confirmation) belongs to the caller.

set -euo pipefail

SUBCMD="${1:-}"
shift || true

usage() {
  cat >&2 <<'EOF'
Usage:
  addir.sh list <repo-path>...
    Print current additionalDirectories (and a short summary of permissions/hooks) for each repo.

  addir.sh add <repo-path> <new-dir>...
    Add new-dirs to <repo-path>'s additionalDirectories. Idempotent, deduplicated,
    sorted. Creates .claude/settings.local.json (and .claude/) if absent.

  addir.sh remove <repo-path> <removed-dir>...
    Remove removed-dirs from <repo-path>'s additionalDirectories. If the resulting
    array is empty, the additionalDirectories key is deleted entirely.

  addir.sh group-setup <member-path>...
    For each member, add all other members to its additionalDirectories
    (self-exclusion is automatic). Equivalent to N invocations of `add` with
    the right `others` list.

Notes:
  - All paths must be absolute (the caller is responsible for resolving globs).
  - permissions, hooks, outputStyle, and other existing keys are preserved.
EOF
  exit 64
}

[ -z "$SUBCMD" ] && usage

settings_path_for() {
  printf '%s/.claude/settings.local.json' "$1"
}

ensure_settings() {
  # Why: creating the parent dir + an empty JSON file lets the same jq merge
  # path handle both "first time" and "update" without branching.
  local repo="$1"
  local path
  path="$(settings_path_for "$repo")"
  mkdir -p "$(dirname "$path")"
  [ -f "$path" ] || printf '%s\n' '{}' > "$path"
  printf '%s\n' "$path"
}

list_one() {
  local repo="$1"
  local path
  path="$(settings_path_for "$repo")"
  printf '=== %s ===\n' "$repo"
  if [ ! -f "$path" ]; then
    printf '  (no .claude/settings.local.json)\n'
    return
  fi
  local dirs perms hooks other_keys
  # Schema: additionalDirectories is under .permissions (per Claude Code binary
  # error path "permissions.additionalDirectories"). Top-level placement is
  # auto-corrected by the harness on load, but we write to the correct path
  # ourselves to avoid relying on that.
  dirs="$(jq -r '.permissions.additionalDirectories // [] | .[]' "$path" 2>/dev/null || true)"
  if [ -z "$dirs" ]; then
    printf '  additionalDirectories: (none)\n'
  else
    printf '  additionalDirectories:\n'
    printf '%s\n' "$dirs" | sed 's/^/    - /'
  fi
  perms="$(jq -r '.permissions.allow // [] | length' "$path" 2>/dev/null || printf '0')"
  hooks="$(jq -r '.hooks // {} | keys | length' "$path" 2>/dev/null || printf '0')"
  other_keys="$(jq -r 'keys - ["permissions","hooks"] | join(", ")' "$path" 2>/dev/null || true)"
  printf '  permissions.allow: %s items / hooks: %s events' "$perms" "$hooks"
  [ -n "$other_keys" ] && printf ' / other keys: %s' "$other_keys"
  printf '\n'
}

add_to_one() {
  local repo="$1"; shift
  local path
  path="$(ensure_settings "$repo")"
  local tmp
  tmp="$(mktemp)"
  # --slurpfile loads the existing JSON as $cur[0]; --args makes the remaining
  # positionals available as $ARGS.positional. unique gives sort+dedup.
  # The key lives at .permissions.additionalDirectories; we set .permissions if absent.
  jq --null-input --slurpfile cur "$path" \
     '($cur[0].permissions.additionalDirectories // []) + $ARGS.positional | unique as $merged
      | ($cur[0].permissions // {}) as $perms
      | $cur[0] | .permissions = ($perms + {additionalDirectories: $merged})' \
     --args -- "$@" > "$tmp"
  mv "$tmp" "$path"
  printf 'updated: %s\n' "$path"
}

remove_from_one() {
  local repo="$1"; shift
  local path
  path="$(settings_path_for "$repo")"
  if [ ! -f "$path" ]; then
    printf 'skipped (no settings file): %s\n' "$repo" >&2
    return
  fi
  local tmp
  tmp="$(mktemp)"
  jq --null-input --slurpfile cur "$path" \
     '($cur[0].permissions.additionalDirectories // []) - $ARGS.positional as $remaining
      | if ($remaining | length) == 0
        then $cur[0] | del(.permissions.additionalDirectories)
        else ($cur[0].permissions // {}) as $perms
             | $cur[0] | .permissions = ($perms + {additionalDirectories: $remaining})
        end' \
     --args -- "$@" > "$tmp"
  mv "$tmp" "$path"
  printf 'updated: %s\n' "$path"
}

group_setup() {
  local members=("$@")
  local self other others
  for self in "${members[@]}"; do
    others=()
    for other in "${members[@]}"; do
      [ "$other" = "$self" ] || others+=("$other")
    done
    if [ ${#others[@]} -gt 0 ]; then
      add_to_one "$self" "${others[@]}"
    fi
  done
}

case "$SUBCMD" in
  list)
    [ $# -ge 1 ] || usage
    for repo in "$@"; do list_one "$repo"; done
    ;;
  add)
    [ $# -ge 2 ] || usage
    repo="$1"; shift
    add_to_one "$repo" "$@"
    ;;
  remove)
    [ $# -ge 2 ] || usage
    repo="$1"; shift
    remove_from_one "$repo" "$@"
    ;;
  group-setup)
    [ $# -ge 2 ] || usage
    group_setup "$@"
    ;;
  *)
    usage
    ;;
esac
