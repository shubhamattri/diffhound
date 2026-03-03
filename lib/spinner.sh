#!/bin/bash
# diffhound — spinner utilities
# Provides terminal spinner for long-running operations

_spinner_pid=""
_is_tty() { [ -t 2 ]; }

spinner_start() {
  local msg="${1:-Working...}"
  if _is_tty; then
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
      i=0
      while true; do
        printf "\r  \033[36m${frames[$((i % 10))]}\033[0m ${msg}   " >&2
        sleep 0.1
        i=$((i + 1))
      done
    ) &
    _spinner_pid=$!
  else
    printf "  » %s\n" "$msg" >&2
    _spinner_pid=""
  fi
}

spinner_stop() {
  local status="${1:-done}"
  if [ -n "$_spinner_pid" ]; then
    kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    printf "\r  \033[32m✓\033[0m %-40s\n" "$status" >&2
  else
    printf "  ✓ %s\n" "$status" >&2
  fi
}

spinner_fail() {
  local msg="${1:-failed}"
  if [ -n "$_spinner_pid" ]; then
    kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    printf "\r  \033[31m✗\033[0m %-40s\n" "$msg" >&2
  else
    printf "  ✗ %s\n" "$msg" >&2
  fi
}
