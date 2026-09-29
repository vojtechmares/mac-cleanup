#!/usr/bin/env bash
# List Docker containers, images, build cache, networks and volumes; with
# --prune stop running containers and remove everything that is not excluded.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--prune] [--exclude PATTERN]... [--volumes]

Lists what can be cleaned up in Docker. With --prune it:
  1. stops running containers and removes all containers
  2. removes all images not used by a kept container
  3. removes the whole build cache
  4. removes unused custom networks
  5. removes unused volumes - only with --volumes, as they may hold data

Options:
  --prune            perform the cleanup (default is a dry run)
  --exclude PATTERN  keep containers (name or image), images (repo:tag or ID),
                     networks and volumes (name) matching PATTERN (substring,
                     or glob if it contains * ? [); repeatable or
                     comma-separated. Use "build-cache" to keep the build cache.
  --volumes          also remove unused volumes
  -h, --help         show this help
EOF
}

VOLUMES=0
while (($#)); do
  case $1 in
    --prune) PRUNE=1 ;;
    --exclude) add_exclude "${2:?--exclude needs a pattern}"; shift ;;
    --exclude=*) add_exclude "${1#*=}" ;;
    --volumes) VOLUMES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

command -v docker >/dev/null || die "docker not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"

keep() { printf ' %s[%s]%s' "$C_GREEN" "$1" "$C_RESET"; }

header "Containers"
STOP=() REMOVE=()
containers=0
declare -A KEPT_IMAGE_IDS=()
while IFS=$'\t' read -r id name image state status; do
  [[ -z $id ]] && continue
  containers=$((containers + 1))
  flags=''
  [[ $state == running ]] && flags=" ${C_YELLOW}[running]${C_RESET}"
  if is_excluded "$name" "$image"; then
    flags+=$(keep excluded)
    KEPT_IMAGE_IDS[$(docker inspect --format '{{.Image}}' "$id")]=1
  else
    [[ $state == running ]] && STOP+=("$id")
    REMOVE+=("$id")
  fi
  printf '  %-12s  %-30s  %-40s  %s%s\n' "$id" "$name" "$image" "$status" "$flags"
done < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}')
((containers)) || note "  none"
printf '  %s%d to stop, %d to remove%s\n' "$C_BOLD" "${#STOP[@]}" "${#REMOVE[@]}" "$C_RESET"

header "Images"
RMI=()
while IFS=$'\t' read -r id repo tag size created; do
  [[ -z $id ]] && continue
  short=${id#sha256:}
  short=${short:0:12}
  ref="$repo:$tag"
  [[ $repo == '<none>' ]] && ref=$short
  if is_excluded "$ref" "$short"; then
    flags=$(keep excluded)
  elif [[ -n ${KEPT_IMAGE_IDS[$id]:-} ]]; then
    flags=$(keep "used by kept container")
  else
    flags=''
    RMI+=("$ref")
  fi
  printf '  %8s  %-14s  %s%s\n' "$size" "$created" "$ref" "$flags"
done < <(docker image ls --no-trunc --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}')
((${#RMI[@]})) || note "  none to remove"
printf '  %s%d to remove%s\n' "$C_BOLD" "${#RMI[@]}" "$C_RESET"

header "Build cache"
BUILD_CACHE=1
cache=$(docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' | awk -F'\t' '$1 == "Build Cache" { print $2 " (" $3 " reclaimable)" }')
if is_excluded build-cache; then
  BUILD_CACHE=0
  printf '  %s%s\n' "$cache" "$(keep excluded)"
else
  printf '  %s\n' "$cache"
fi

header "Custom networks"
NETS=()
while IFS=$'\t' read -r id name; do
  [[ -z $id ]] && continue
  flags=''
  if is_excluded "$name"; then flags=$(keep excluded); else NETS+=("$name"); fi
  printf '  %s%s\n' "$name" "$flags"
done < <(docker network ls --filter type=custom --format '{{.ID}}\t{{.Name}}')
((${#NETS[@]})) || note "  none"

header "Unused volumes"
VOLS=()
declare -A VOL_SIZE
while IFS=$'\t' read -r name size; do
  [[ -n $name ]] && VOL_SIZE[$name]=$size
done < <(docker system df -v --format $'{{range .Volumes}}{{.Name}}\t{{.Size}}\n{{end}}')
while read -r name; do
  [[ -z $name ]] && continue
  if is_excluded "$name"; then
    flags=$(keep excluded)
  elif ((!VOLUMES)); then
    flags=$(keep "needs --volumes")
  else
    flags=''
    VOLS+=("$name")
  fi
  printf '  %8s  %s%s\n' "${VOL_SIZE[$name]:-?}" "$name" "$flags"
done < <(docker volume ls -qf dangling=true)
((${#VOLS[@]} || VOLUMES)) || note "  volumes may hold data (databases...) - pass --volumes to remove them"

header "Summary"
docker system df

if ((PRUNE)); then
  header "Pruning"
  ((${#STOP[@]})) && run docker stop "${STOP[@]}"
  ((${#REMOVE[@]})) && run docker rm "${REMOVE[@]}"
  # One at a time, so a single image in use doesn't block the rest.
  for ref in "${RMI[@]}"; do run docker rmi "$ref" || warn "could not remove $ref"; done
  ((BUILD_CACHE)) && run docker builder prune -af
  for net in "${NETS[@]}"; do run docker network rm "$net" || warn "could not remove network $net"; done
  ((${#VOLS[@]})) && run docker volume rm "${VOLS[@]}"
  header "After"
  docker system df
fi
dry_run_footer
