#!/usr/bin/env bash
# List running Node.js/Bun/Deno dev servers and stop them with --prune.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--prune] [--exclude PATTERN]... [--timeout SECS]

Lists Node.js/Bun/Deno dev servers - processes that listen on a TCP port or
run a dev command (vite, next, astro, wrangler, ...) - with their whole
process tree. Editor language servers, MCP servers and app-bundled runtimes
are listed separately for information and are never stopped.

Options:
  --prune            stop the listed dev servers (SIGTERM, SIGKILL after timeout)
  --exclude PATTERN  keep dev servers whose command or working directory
                     matches PATTERN (substring, or glob if it contains * ? [);
                     repeatable or comma-separated
  --timeout SECS     seconds to wait before SIGKILL (default: 5)
  -h, --help         show this help
EOF
}

TIMEOUT=5
while (($#)); do
  case $1 in
    --prune) PRUNE=1 ;;
    --exclude) add_exclude "${2:?--exclude needs a pattern}"; shift ;;
    --exclude=*) add_exclude "${1#*=}" ;;
    --timeout) TIMEOUT=${2:?--timeout needs a value}; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# Executables that count as the Node.js family (plus workerd, spawned by wrangler/vite).
FAMILY_RE='^(node|nodejs|bun|deno|workerd|npm|npx|pnpm|yarn|tsx|ts-node|nodemon)$'
# Long-running tooling that is not a dev server - never stopped.
TOOLING_RE='(^|/)applications/|application support|mcp|language-server|languageserver|tsserver|typingsinstaller|-lsp|--stdio|eslint_d|prettierd'
# Commands that look like a dev server even without a listening port (yet).
DEV_RE='(^|[ /])(vite|next|nuxt|astro|remix|wrangler|webpack|webpack-dev-server|nodemon|storybook|react-scripts|parcel|turbo|ts-node-dev|http-server|live-server|serve)(\.m?js)?( |$)|[ :](dev|serve|start|watch|preview)( |$)'

declare -A PPID_OF ETIME_OF RSS_OF CMD_OF CHILDREN PORTS
while read -r pid ppid etime rss cmd; do
  PPID_OF[$pid]=$ppid ETIME_OF[$pid]=$etime RSS_OF[$pid]=$rss CMD_OF[$pid]=$cmd
  CHILDREN[$ppid]+=" $pid"
done < <(ps -axww -o pid=,ppid=,etime=,rss=,command=)

# Listening TCP ports per pid.
pid=''
while read -r line; do
  case $line in
    p*) pid=${line#p} ;;
    n*) port=${line##*:}; [[ " ${PORTS[$pid]:-} " == *" $port "* ]] || PORTS[$pid]+=" $port" ;;
  esac
done < <(lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null)

is_family() {
  local exe=${1%% *}
  [[ ${exe##*/} =~ $FAMILY_RE || $exe == */node_modules/.bin/* ]]
}

is_tooling() { [[ ${1,,} =~ $TOOLING_RE ]]; }

is_candidate() {
  local cmd=${CMD_OF[$1]}
  is_family "$cmd" && ! is_tooling "$cmd" && [[ -n ${PORTS[$1]:-} || $cmd =~ $DEV_RE ]]
}

# descendants PID - print all descendant pids, depth first.
descendants() {
  local c
  for c in ${CHILDREN[$1]:-}; do
    echo "$c"
    descendants "$c"
  done
}

proc_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; }

# pretty_cmd CMD - shorten executable and node_modules paths for display.
pretty_cmd() {
  local -a words out
  local w s i=0
  read -ra words <<<"$1"
  for w in "${words[@]}"; do
    if ((i++ == 0)); then
      w=${w##*/}
    elif [[ $w == */node_modules/* ]]; then
      w=${w##*/node_modules/}
    fi
    out+=("$(tilde "$w")")
  done
  s="${out[*]}"
  ((${#s} > 110)) && s="${s:0:107}..."
  printf '%s' "$s"
}

# Never touch this script or its ancestors.
declare -A SELF
p=$$
while [[ -n $p && $p != 0 && $p != 1 ]]; do SELF[$p]=1; p=${PPID_OF[$p]:-}; done

# Roots: dev server candidates without a candidate ancestor.
declare -A IN_TREE
ROOTS=()
for pid in "${!CMD_OF[@]}"; do
  [[ -n ${SELF[$pid]:-} ]] && continue
  is_candidate "$pid" || continue
  p=${PPID_OF[$pid]} nested=0
  while [[ -n $p && $p != 0 && $p != 1 ]]; do
    if is_candidate "$p"; then nested=1; break; fi
    p=${PPID_OF[$p]:-}
  done
  ((nested)) || ROOTS+=("$pid")
done
mapfile -t ROOTS < <(printf '%s\n' "${ROOTS[@]}" | sort -n)

header "Dev servers"
TARGETS=()
total_rss=0 count=0
for root in "${ROOTS[@]}"; do
  [[ -z $root ]] && continue
  tree=("$root")
  mapfile -t -O 1 tree < <(descendants "$root")
  cwd=$(proc_cwd "$root")
  ports='' rss=0 match=("$cwd")
  for p in "${tree[@]}"; do
    IN_TREE[$p]=1
    ports+=${PORTS[$p]:-}
    rss=$((rss + ${RSS_OF[$p]:-0}))
    match+=("${CMD_OF[$p]}")
  done
  ports=$(tr ' ' '\n' <<<"$ports" | sed '/^$/d' | sort -nu | paste -sd' ' -)

  flags=''
  [[ ${PPID_OF[$root]} == 1 ]] && flags+=" ${C_YELLOW}[orphan]${C_RESET}"
  if is_excluded "${match[@]}"; then
    flags+=" ${C_GREEN}[excluded]${C_RESET}"
  else
    TARGETS+=("${tree[@]}")
    total_rss=$((total_rss + rss))
    count=$((count + 1))
  fi

  printf '%s%s%s  up %s  mem %s  ports: %s%s\n' "$C_BOLD" "$(tilde "${cwd:-?}")" "$C_RESET" \
    "${ETIME_OF[$root]}" "$(human_kb "$rss")" "${ports:-none}" "$flags"
  for p in "${tree[@]}"; do
    printf '  %7s  %s\n' "$p" "$(pretty_cmd "${CMD_OF[$p]}")"
  done
done
((${#ROOTS[@]})) || note "none found"

header "Other Node.js processes (info only)"
found=0
while read -r pid; do
  [[ -n ${IN_TREE[$pid]:-} || -n ${SELF[$pid]:-} ]] && continue
  is_family "${CMD_OF[$pid]}" || continue
  flag=''
  [[ ${PPID_OF[$pid]} == 1 ]] && flag=" ${C_YELLOW}[orphan]${C_RESET}"
  printf '  %7s  up %-12s %7s  %s%s\n' "$pid" "${ETIME_OF[$pid]}" "$(human_kb "${RSS_OF[$pid]}")" \
    "$(pretty_cmd "${CMD_OF[$pid]}")" "$flag"
  found=1
done < <(printf '%s\n' "${!CMD_OF[@]}" | sort -n)
((found)) || note "none found"

printf '\n%d dev server tree(s) to stop, %d process(es), %s memory\n' \
  "$count" "${#TARGETS[@]}" "$(human_kb "$total_rss")"

if ((PRUNE && ${#TARGETS[@]})); then
  run kill -TERM "${TARGETS[@]}" 2>/dev/null
  for ((i = 0; i < TIMEOUT * 4; i++)); do
    alive=()
    for p in "${TARGETS[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
    ((${#alive[@]})) || break
    sleep 0.25
  done
  if ((${#alive[@]})); then
    warn "still running after ${TIMEOUT}s, sending SIGKILL: ${alive[*]}"
    run kill -KILL "${alive[@]}" 2>/dev/null
  fi
fi
dry_run_footer
