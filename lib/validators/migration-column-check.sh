#!/usr/bin/env bash
# migration-column-check.sh — DROP findings that claim a column is missing
# from a named migration file when the column literal actually exists in
# that file.
#
# Driven by PR #7145 v0.5.6 review: 2 BLOCKING findings hallucinated migration
# columns ("no `file_path` column ... grep got zero hits" — column was on line
# 26 of the migration the finding itself named). This validator runs the
# verification the LLM claimed to run.
#
# Trigger conditions (BOTH must hold):
#   1. WHAT names a migration filename matching \d{14}_[a-z_]+\.ts
#   2. WHAT contains a "no `<col>` column" / "no `<col_a>` or `<col_b>` columns"
#      / "missing `<col>` column" pattern with at least one snake_case identifier
#
# Action:
#   - For each named column, grep the migration file at conventional path
#     ($DIFFHOUND_REPO/services/api/migrations/<filename>) for the column
#     literal in column-defining contexts (string-quoted, possibly preceded
#     by .text/.string/.uuid/.jsonb/.integer/.timestamp/.boolean/.date/.float
#     /.decimal/.text/.bigint/.binary).
#   - If at least one named column is found in the migration → DROP.
#     LLM's "no X column" claim is contradicted by visible evidence.
#
# False-drop guard: only drops on POSITIVE evidence (column literal present).
# If migration file isn't readable, can't be located, or no columns matched,
# the finding passes through unchanged.
#
# Pipeline placement: BEFORE citation-discipline, AFTER ref-exists. The drop
# is high-confidence enough to short-circuit citation/severity checks for
# obvious hallucinations.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Common location for monorepo-style projects. If the conventional path is
# wrong for a given consumer, the validator no-ops (file-not-found) rather
# than producing false drops.
MIGRATIONS_DIR="${DIFFHOUND_MIGRATIONS_DIR:-$DIFFHOUND_REPO/services/api/migrations}"

# Snake-case identifier pattern. Conservative — must start with letter, contain
# at least one underscore (so we don't false-trigger on bare nouns). Two-word
# minimum keeps the column-name regex from matching ordinary English words like
# "the" or "column".
SNAKE_RE='[a-z][a-z0-9]*(_[a-z0-9]+)+'

block=""
what=""
header_prefix=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_drop_block() {
  local reason="$1"
  printf '[migration-column-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Gemini-mitigation (v0.5.7 peer review): if WHAT contains absence wording,
  # this is a finding ABOUT a deletion/removal — the column literal will
  # appear in the rollback (down()) and other context, not as a live
  # definition. Don't drop. Mirrors ref-exists.sh's ABSENCE_WORDS exemption.
  local ABSENCE_WORDS='deleted|removed|dropped|drops the|drop the|after .* drops|removes the|no longer (defined|present|exists)|was renamed|has been (deleted|removed|renamed|dropped)'
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; block=""; what=""; header_prefix=""; return
  fi

  # Need both a migration filename and a "no <col> column" assertion.
  local migration
  migration=$(printf '%s' "$what" | grep -oE '[0-9]{14}_[a-z_]+\.ts' | head -1 || true)
  if [ -z "$migration" ]; then
    _emit_block; block=""; what=""; header_prefix=""; return
  fi

  # Extract column candidates from "no `<X>` column" / "no `<X>` or `<Y>`
  # columns" / "missing `<X>` column" / "no <X>_<Y> column" patterns.
  # Both backticked and bare snake_case forms are matched — LLMs vary.
  local cols
  cols=$(printf '%s' "$what" \
    | grep -oE "(no|missing)\s+\`?${SNAKE_RE}\`?(\s+(or|and|,)\s+\`?${SNAKE_RE}\`?)*\s+(column|field)" \
    | grep -oE "$SNAKE_RE" \
    | sort -u || true)

  if [ -z "$cols" ]; then
    # Fall back: any backticked snake_case identifier near the migration name.
    cols=$(printf '%s' "$what" \
      | grep -oE "\`${SNAKE_RE}\`" \
      | tr -d '`' \
      | sort -u || true)
    if [ -z "$cols" ]; then
      _emit_block; block=""; what=""; header_prefix=""; return
    fi
  fi

  # Resolve migration file. If not present, no-op (can't verify, don't drop).
  local mig_path="$MIGRATIONS_DIR/$migration"
  if [ ! -f "$mig_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; return
  fi

  local found=""
  while IFS= read -r col; do
    [ -z "$col" ] && continue
    # Match column literal as a string in column-definition contexts.
    # Examples we want to match (from real migrations):
    #   table.text("file_path").notNullable()
    #   t.jsonb("settled_tab").nullable()
    #   table.string("name", 255)
    #   .references("id").inTable("orgs")  -- skip references; only count primary defs
    # Use a conservative regex: <table>.<typeFn>(<quote><col><quote>
    if grep -qE "[._]\s*(text|string|uuid|jsonb|json|integer|bigint|smallint|timestamp|timestamps|boolean|date|datetime|float|decimal|binary|increments|enum|specificType|tsvector)\s*\(\s*[\"']${col}[\"']" "$mig_path"; then
      found="${found}${col} "
    fi
  done <<< "$cols"

  if [ -n "$found" ]; then
    _drop_block "column(s) [${found% }] exist in $migration; claim contradicted"
    block=""; what=""; header_prefix=""
    return
  fi

  _emit_block; block=""; what=""; header_prefix=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      # Aggregate WHAT — sometimes the migration name and column names are
      # on the same WHAT line, but other validators have shown WHAT can span.
      what="${what}${line} "
      ;;
    EVIDENCE:*|IMPACT:*|OPTIONS:*)
      block+="$line"$'\n'
      # Migration filename / column claims sometimes sit in EVIDENCE too.
      what="${what}${line} "
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_check_and_emit
