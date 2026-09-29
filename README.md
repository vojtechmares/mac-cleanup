# mac-cleanup

Scripts to find and reclaim resources on a macOS dev machine: stale dev servers, `node_modules`, Go and Node.js package manager caches, Claude Code tmp dirs and Docker leftovers.

Every script is a **dry run by default** - it only prints what it found. Pass `--prune` to perform the destructive action.

## Requirements

- macOS
- bash 4+ (`brew install bash`)
- `docker`, `go`, `npm`, `pnpm`, `yarn`, `bun` - each is optional, sections for missing tools are skipped

## Common flags

| Flag | Description |
| --- | --- |
| `--prune` | perform the cleanup instead of a dry run |
| `--exclude PATTERN` | keep matching items; repeatable or comma-separated |
| `-h`, `--help` | show usage |

A pattern containing glob characters (`*`, `?`, `[`) is matched against the whole string, anything else as a substring. For example `--exclude platform` keeps anything with `platform` in its path or command, `--exclude '*/coding-owl/website'` keeps only that exact directory.

Set `NO_COLOR=1` to disable colored output.

## dev-servers.sh

Lists Node.js/Bun/Deno dev servers - processes listening on a TCP port or running a dev command (`vite`, `next`, `astro`, `wrangler`, ...) - together with their whole process tree, working directory, uptime, memory and ports. Orphaned processes (reparented to PID 1) are marked.

Editor language servers, MCP servers and app-bundled runtimes are listed separately for information and are never stopped.

```sh
./dev-servers.sh                             # list
./dev-servers.sh --prune --exclude platform  # stop everything except platform
```

| Flag | Description |
| --- | --- |
| `--exclude PATTERN` | matched against the command lines and working directory |
| `--timeout SECS` | seconds between SIGTERM and SIGKILL (default: 5) |

## disk-cleanup.sh

Reports and removes reclaimable disk space in four sections:

- `node_modules` - `node_modules` dirs under the roots (default: `~/work`), including Claude Code worktrees
- `claude-tmp` - Claude Code session tmp dirs in `/private/tmp/claude-<uid>`
- `go` - Go module cache (`go clean -modcache`) and build cache (`go clean -cache`)
- `caches` - npm cache, pnpm store (`pnpm store prune`), stores of older pnpm versions, pnpm metadata cache, yarn and bun caches

```sh
./disk-cleanup.sh                                    # full report
./disk-cleanup.sh --only node_modules --older-than 30
./disk-cleanup.sh --prune --exclude mares.cz,go-modcache
```

| Flag | Description |
| --- | --- |
| `--exclude PATTERN` | matched against paths and cache names (`go-modcache`, `go-build`, `npm`, `pnpm-store`, ...) |
| `--root DIR` | where to look for `node_modules`; repeatable (default: `~/work`) |
| `--older-than DAYS` | only prune `node_modules` and Claude tmp entries idle for at least DAYS days (default: 1) |
| `--only SECTIONS` | comma-separated subset of `node_modules,claude-tmp,go,caches` |

Always kept:

- `node_modules` of projects referenced by a running process (command line or working directory)
- Claude tmp entries active in the last hour and Claude Code internal files (`bundled-skills`, `bash-edit-diff`, `cache-break-state-*`)

Project idle time is derived from the newest of: install time, `package.json`, lockfiles and the git index. pnpm clones files from its store on APFS, so the space actually freed by removing `node_modules` can be lower than reported. Run the `caches` section after `node_modules` so `pnpm store prune` can drop the packages no longer linked by any project.

## docker-cleanup.sh

Lists containers, images, build cache, custom networks and unused volumes. With `--prune` it:

1. stops running containers and removes all containers
2. removes all images not used by a kept container
3. removes the whole build cache
4. removes unused custom networks
5. removes unused volumes - only with `--volumes`, as they may hold data

```sh
./docker-cleanup.sh
./docker-cleanup.sh --prune --exclude 'python:*,build-cache'
./docker-cleanup.sh --prune --volumes --exclude mysql-data
```

| Flag | Description |
| --- | --- |
| `--exclude PATTERN` | matched against container names and images, image `repo:tag` or ID, network and volume names; `build-cache` keeps the build cache |
| `--volumes` | also remove unused volumes |

Excluding a container also keeps its image.
