#!/bin/sh
# The production UI uses FLTK; native Zig remains an explicit evaluation target.
export MDF_REFERENCE=1
exec sh "$(dirname -- "$0")/build-reference.sh" "$@"
