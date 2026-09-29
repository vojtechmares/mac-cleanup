#!/usr/bin/env bash
# Find reclaimable disk space: node_modules, Claude Code tmp dirs, Go and
# Node.js package manager caches. Deletes them with --prune.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALL_SECTIONS=node_modules,claude-tmp,go,caches

usage() {
  cat <<EOF
Usage: $(basename "$0") [--prune] [--exclude PATTERN]... [--root DIR]...
                      [--older-than DAYS] [--only SECTIONS]

Sections:
  node_modules  node_modules dirs under the roots (default: ~/work)
  claude-tmp    Claude Code session tmp dirs in /private/tmp/claude-$(id -u)
  go            Go module cache and build cache
  caches        npm, pnpm, yarn and bun caches

Options:
  --prune            delete what is listed (default is a dry run)
  --exclude PATTERN  keep paths matching PATTERN (substring, or glob if it
                     contains * ? [); repeatable or comma-separated
  --root DIR         where to look for node_modules; repeatable (default: ~/work)
  --older-than DAYS  only prune node_modules and claude-tmp entries inactive for
                     at least DAYS days (default: 1). Claude tmp entries active
                     in the last hour are always kept.
  --only SECTIONS    comma-separated subset of: $ALL_SECTIONS
  -h, --help         show this help

node_modules of projects referenced by a running process (command line or
working directory) are always kept.
EOF
}

ROOTS=()
OLDER_THAN=1
ONLY=$ALL_SECTIONS
while (($#)); do
  case $1 in
    --prune) PRUNE=1 ;;
    --exclude) add_exclude "${2:?--exclude needs a pattern}"; shift ;;
    --exclude=*) add_exclude "${1#*=}" ;;
    --root) ROOTS+=("${2:?--root needs a directory}"); shift ;;
    --root=*) ROOTS+=("${1#*=}") ;;
    --older-than) OLDER_THAN=${2:?--older-than needs a number of days}; shift ;;
    --older-than=*) OLDER_THAN=${1#*=} ;;
    --only) ONLY=${2:?--only needs a list of sections}; shift ;;
    --only=*) ONLY=${1#*=} ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
((${#ROOTS[@]})) || ROOTS=("$HOME/work")
[[ $OLDER_THAN =~ ^[0-9]+$ ]] || die "--older-than must be a whole number of days"
for s in ${ONLY//,/ }; do
  [[ ,$ALL_SECTIONS, == *,$s,* ]] || die "unknown section: $s (valid: $ALL_SECTIONS)"
done

enabled() { [[ ,$ONLY, == *,$1,* ]]; }

NOW=$(date +%s)
CUTOFF=$((NOW - OLDER_THAN * 86400))
GRAND_TOTAL=0

# Command lines and working directories of all running processes, used to
# keep anything that is in use.
PROC_REFS=$(
  ps -axww -o command=
  lsof -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
)

# in_use DIR - true if a running process references DIR or anything below it.
in_use() {
  grep -qF -e "$1/" <<<"$PROC_REFS" || grep -qxF -e "$1" <<<"$PROC_REFS"
}

# git_index DIR - print the git index file of the repo or worktree containing DIR.
git_index() {
  local d=$1 gitdir
  while [[ $d != / && -n $d ]]; do
    if [[ -d $d/.git ]]; then
      echo "$d/.git/index"
      return
    elif [[ -f $d/.git ]]; then
      gitdir=$(sed -n 's/^gitdir: //p' "$d/.git")
      [[ $gitdir == /* ]] || gitdir=$d/$gitdir
      echo "$gitdir/index"
      return
    fi
    d=${d%/*}
  done
}

# print_row SIZE_KB AGE_DAYS PATH FLAGS
print_row() {
  printf '  %8s  %5s  %s%s\n' "$(human_kb "$1")" "${2}d" "$(tilde "$3")" "$4"
}

# section_total LABEL COUNT KB
section_total() {
  printf '  %s%d to prune, %s%s\n' "$C_BOLD" "$2" "$(human_kb "$3")" "$C_RESET"
  GRAND_TOTAL=$((GRAND_TOTAL + $3))
}

prune_node_modules() {
  header "node_modules in ${ROOTS[*]/#$HOME/\~}"
  local -a dirs rows targets=()
  local d project size age flags total=0 count=0 last
  local -A SIZE

  mapfile -d '' dirs < <(
    $FIND "${ROOTS[@]}" -type d -name .git -prune -o -type d -name node_modules -prune -print0 2>/dev/null
  )
  if ((${#dirs[@]} == 0)); then
    note "  none found"
    return
  fi
  note "  sizing ${#dirs[@]} directories..."
  while IFS=$'\t' read -r size d; do
    SIZE[$d]=$size
  done < <(printf '%s\0' "${dirs[@]}" | xargs -0 -P8 -n4 $DU -sk 2>/dev/null)

  printf '  %8s  %5s  %s\n' SIZE IDLE PROJECT
  mapfile -t rows < <(
    for d in "${dirs[@]}"; do printf '%s\t%s\n' "${SIZE[$d]:-0}" "$d"; done | sort -rn
  )
  for row in "${rows[@]}"; do
    size=${row%%$'\t'*} d=${row#*$'\t'}
    project=${d%/node_modules}
    last=$(mtime "$project" "$project/package.json" "$project/package-lock.json" \
      "$project/pnpm-lock.yaml" "$project/yarn.lock" "$project/bun.lock" "$project/bun.lockb" \
      "$d" "$d/.modules.yaml" "$d/.package-lock.json" "$(git_index "$project")")
    age=$(age_days "$last")
    if is_excluded "$d"; then
      flags=" ${C_GREEN}[excluded]${C_RESET}"
    elif in_use "$project"; then
      flags=" ${C_GREEN}[in use]${C_RESET}"
    elif ((last > CUTOFF)); then
      flags=" ${C_DIM}[recent]${C_RESET}"
    else
      flags=''
      targets+=("$d")
      total=$((total + size))
      count=$((count + 1))
    fi
    print_row "$size" "$age" "$project" "$flags"
  done
  note "  IDLE = days since last install, lockfile or git index change."
  note "  pnpm clones files from its store on APFS, so actual freed space can be lower."
  section_total node_modules "$count" "$total"

  if ((PRUNE)); then
    for d in "${targets[@]}"; do run rm -rf -- "$d"; done
  fi
}

prune_claude_tmp() {
  local base
  base=/private/tmp/claude-$(id -u)
  header "Claude Code tmp dirs in $base"
  if [[ ! -d $base ]]; then
    note "  none found"
    return
  fi
  local -a units rows targets=()
  local u p size last age flags total=0 count=0
  local floor=$((NOW - 3600))
  ((CUTOFF < floor)) && floor=$CUTOFF

  # A unit is a session dir (<project-slug>/<session>) or a loose top-level entry.
  for p in "$base"/* "$base"/.[!.]*; do
    [[ -e $p ]] || continue
    if [[ -d $p && ${p##*/} == -* ]]; then
      for u in "$p"/* "$p"/.[!.]*; do [[ -e $u ]] && units+=("$u"); done
    else
      units+=("$p")
    fi
  done

  printf '  %8s  %5s  %s\n' SIZE IDLE ENTRY
  mapfile -t rows < <(
    for u in "${units[@]}"; do
      size=$($DU -sk -- "$u" 2>/dev/null | cut -f1)
      last=$($FIND "$u" -exec $STAT -f %m {} + 2>/dev/null | sort -rn | head -1)
      printf '%s\t%s\t%s\n' "${size:-0}" "${last:-0}" "$u"
    done | sort -rn
  )
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r size last u <<<"$row"
    age=$(age_days "$last")
    if is_excluded "$u"; then
      flags=" ${C_GREEN}[excluded]${C_RESET}"
    elif [[ ${u#"$base"/} =~ ^(bundled-skills|bash-edit-diff|cache-break-state-.*)$ ]]; then
      flags=" ${C_GREEN}[claude internal]${C_RESET}"
    elif in_use "$u"; then
      flags=" ${C_GREEN}[in use]${C_RESET}"
    elif ((last > floor)); then
      flags=" ${C_DIM}[recent]${C_RESET}"
    else
      flags=''
      targets+=("$u")
      total=$((total + size))
      count=$((count + 1))
    fi
    print_row "$size" "$age" "${u#"$base"/}" "$flags"
  done
  note "  IDLE = days since the newest file inside was modified."
  section_total claude-tmp "$count" "$total"

  if ((PRUNE)); then
    for u in "${targets[@]}"; do run rm -rf -- "$u"; done
    # Drop project dirs left empty.
    for p in "$base"/-*/; do rmdir -- "$p" 2>/dev/null && note "+ rmdir $p"; done
  fi
  return 0
}

# cache_row NAME PATH CMD... - list a cache dir; with --prune run CMD.
# Prints nothing when PATH does not exist. CMD is skipped for excluded caches.
cache_row() {
  local name=$1 path=$2 size
  shift 2
  [[ -n $path && -d $path ]] || return 0
  size=$($DU -sk -- "$path" 2>/dev/null | cut -f1)
  if is_excluded "$name" "$path"; then
    printf '  %8s  %-18s %s %s[excluded]%s\n' "$(human_kb "$size")" "$name" "$(tilde "$path")" "$C_GREEN" "$C_RESET"
    return 0
  fi
  printf '  %8s  %-18s %s\n' "$(human_kb "$size")" "$name" "$(tilde "$path")"
  CACHE_TOTAL=$((CACHE_TOTAL + size))
  CACHE_COUNT=$((CACHE_COUNT + 1))
  ((PRUNE)) && run "$@"
  return 0
}

prune_go() {
  header "Go caches"
  if ! command -v go >/dev/null; then
    note "  go not installed"
    return
  fi
  CACHE_TOTAL=0 CACHE_COUNT=0
  cache_row go-modcache "$(go env GOMODCACHE)" go clean -modcache
  cache_row go-build "$(go env GOCACHE)" go clean -cache
  section_total go "$CACHE_COUNT" "$CACHE_TOTAL"
}

prune_caches() {
  header "Node.js package manager caches"
  CACHE_TOTAL=0 CACHE_COUNT=0
  if command -v npm >/dev/null; then
    # Only _cacache - _npx holds packages of running npx processes (MCP servers).
    cache_row npm "$(npm config get cache 2>/dev/null)/_cacache" npm cache clean --force
  fi
  if command -v pnpm >/dev/null; then
    local store old
    store=$(pnpm store path 2>/dev/null)
    cache_row pnpm-store "$store" pnpm store prune
    # Stores of older pnpm versions (v3, v10, ...) next to the current one.
    if [[ -n $store ]]; then
      for old in "${store%/*}"/v*; do
        [[ $old != "$store" ]] && cache_row "pnpm-store-${old##*/}" "$old" rm -rf -- "$old"
      done
    fi
    cache_row pnpm-metadata "$HOME/Library/Caches/pnpm" rm -rf -- "$HOME/Library/Caches/pnpm"
  fi
  if command -v yarn >/dev/null; then
    cache_row yarn "$(yarn cache dir 2>/dev/null)" yarn cache clean
  fi
  if command -v bun >/dev/null; then
    cache_row bun "$HOME/.bun/install/cache" bun pm cache rm
  fi
  note "  pnpm store prune only removes packages no project links to - more after node_modules cleanup."
  section_total caches "$CACHE_COUNT" "$CACHE_TOTAL"
}

enabled node_modules && prune_node_modules
enabled claude-tmp && prune_claude_tmp
enabled go && prune_go
enabled caches && prune_caches

printf '\n%sTotal to prune: %s%s\n' "$C_BOLD" "$(human_kb "$GRAND_TOTAL")" "$C_RESET"
dry_run_footer
