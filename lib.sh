# shellcheck shell=bash
# Shared helpers for the cleanup scripts. Source it, don't run it.

if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4+ required (brew install bash)" >&2
  exit 1
fi

# BSD tools by absolute path - GNU coreutils may shadow them in PATH.
# shellcheck disable=SC2034 # used by the scripts sourcing this file
DU=/usr/bin/du STAT=/usr/bin/stat FIND=/usr/bin/find

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
  C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
fi

PRUNE=0
EXCLUDES=()

header() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# add_exclude "a,b" - append comma-separated patterns to EXCLUDES.
add_exclude() {
  local IFS=, p
  for p in $1; do [[ -n $p ]] && EXCLUDES+=("$p"); done
  return 0
}

# is_excluded STRING... - true if any exclude pattern matches any STRING.
# Patterns containing glob characters (* ? [) are matched as globs against
# the whole string, anything else as a substring.
is_excluded() {
  local p s
  for p in "${EXCLUDES[@]}"; do
    [[ $p == *[*?[]* ]] || p="*$p*"
    for s in "$@"; do
      # shellcheck disable=SC2053 # intentional glob match
      [[ $s == $p ]] && return 0
    done
  done
  return 1
}

# human_kb KIB - format a size in KiB as a short human-readable string.
human_kb() {
  awk -v k="${1:-0}" 'BEGIN {
    split("K M G T", u, " "); i = 1
    while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf(i == 1 ? "%d%s" : "%.1f%s", k, u[i])
  }'
}

# tilde PATH - replace $HOME prefix with ~.
tilde() { printf '%s' "${1/#$HOME/\~}"; }

# run CMD... - print the command, then execute it.
run() {
  printf '%s+ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  "$@"
}

# mtime PATH... - newest modification time (epoch seconds) of the given paths
# that exist; 0 when none exist.
mtime() {
  local p t max=0
  for p in "$@"; do
    [[ -e $p ]] || continue
    t=$($STAT -f %m -- "$p" 2>/dev/null) || continue
    ((t > max)) && max=$t
  done
  echo "$max"
}

# age_days EPOCH - whole days since EPOCH.
age_days() { echo $(( ($(date +%s) - $1) / 86400 )); }

dry_run_footer() {
  if ((PRUNE)); then
    printf '\n%sDone.%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '\n%sDry run - nothing changed.%s Re-run with --prune to apply.\n' "$C_BOLD" "$C_RESET"
  fi
}
