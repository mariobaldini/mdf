#!/bin/sh
. "$(dirname -- "$0")/common.sh"

printf '%s\n' 'Checking build requirements (the first run after make clean can take a while)...'

if ! check_tools; then
    printf '%s\n' 'Run make setup after installing Make.' >&2
    exit 1
fi
offline_graph_check
check_frontend_cache
printf 'Requirements satisfied: GNU Make, Zig %s, Wayland development tools, and pinned local dependencies.\n' "$MDF_ZIG_VERSION"
