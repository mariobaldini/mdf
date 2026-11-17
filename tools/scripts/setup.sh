#!/bin/sh
. "$(dirname -- "$0")/common.sh"

# Install supported Linux build tools and fetch pinned source dependencies.
if [ "$ZIG" != zig ] && ! command -v "$ZIG" >/dev/null 2>&1; then
    printf 'The requested compiler does not exist: %s\n' "$ZIG" >&2
    exit 1
fi
sh tools/scripts/install-packages.sh
if [ "$ZIG" = zig ] && { ! command -v zig >/dev/null 2>&1 || [ "$(zig version)" != "$MDF_ZIG_VERSION" ]; }; then
    ZIG=$(python3 tools/scripts/fetch-zig.py)
fi
export ZIG
check_tools
printf '%s\n' 'Fetching pinned application dependencies...'
python3 tools/scripts/fetch-frontend.py
offline_graph_check
check_frontend_cache
printf '%s\n' 'Setup complete. Run make build.'
