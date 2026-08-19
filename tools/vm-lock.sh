#!/usr/bin/env bash
# DEPRECATED -- superseded by tools/vm-instance.sh.
#
# This used to serialise access to a single shared VM. Instances are now
# isolated (own qcow2 overlay, own ports, own container), so several can run
# at once and there is nothing to serialise. Use:
#
#   tools/vm-instance.sh alloc <owner>   instead of  vm-lock.sh acquire <owner>
#   tools/vm-instance.sh release <id>    instead of  vm-lock.sh release <owner>
#   tools/vm-instance.sh list            instead of  vm-lock.sh status
#
# Kept as a shim so older notes and running agents don't break.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "vm-lock.sh is deprecated; use tools/vm-instance.sh (VMs are isolated now)." >&2

case "${1:-status}" in
    acquire) shift; exec "$DIR/vm-instance.sh" alloc "$@" ;;
    release) shift
             # Old callers pass an owner, not an id. Map it back.
             owner="${1:-}"
             for d in "$DIR/../chromiumos/.vm"/*/; do
                 [ -d "$d" ] || continue
                 id="$(basename "$d")"
                 if [ "$(sed -n 's/^owner=//p' "$d/instance.env" 2>/dev/null)" = "$owner" ]; then
                     exec "$DIR/vm-instance.sh" release "$id"
                 fi
             done
             echo "no instance owned by '$owner'" >&2; exit 0 ;;
    *)       exec "$DIR/vm-instance.sh" list ;;
esac
