#!/usr/bin/env bash
# Hands out isolated VM instances so several agents can each have their own
# machine without stepping on each other.
#
#   tools/vm-instance.sh alloc <owner>      # claim a free id, print its env
#   tools/vm-instance.sh list               # who holds what
#   tools/vm-instance.sh boot <id>          # start it (backgrounded)
#   tools/vm-instance.sh ssh <id> [cmd...]  # ssh in (test key, no prompts)
#   tools/vm-instance.sh stop <id>          # kill the VM, keep the disk
#   tools/vm-instance.sh release <id>       # kill it AND wipe the workspace
#   tools/vm-instance.sh gc                 # release instances whose VM is gone
#
# Each instance gets:
#   * its own qcow2 overlay over the shared base image -- the 11 GB base is
#     never written, and two instances cannot corrupt each other
#   * its own host ports: SSH 9222+id, VNC 5900+id
#   * its own container (cros-vm-<id>), hence its own netns, so the TAP device
#     and the 192.168.77.x guest address are identical inside every instance
#   * its own workspace chromiumos/.vm/<id>/ (overlay, console log, metadata)
#
# Releasing wipes the workspace, so the next alloc of that id starts from a
# pristine image. Customise an instance by editing its guest, not the base.
#
# RAM is the real limit, not disk: this host has ~30 GB and a comfortable
# ChromeOS guest wants 8 GB. alloc therefore sizes memory by how many
# instances are already live (8 GB alone, 4 GB once several are up) -- 4 GB is
# enough to reach the login screen but has NOT been checked under a full
# session, so lower it further at your own risk.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="$DIR/chromiumos/.vm"
MAX_ID="${CROS_VM_MAX:-5}"
KEY_SRC="$DIR/chromiumos/chromite/ssh_keys/testing_rsa"

vm_container() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "cros-vm-$1"; }

meta() { # meta <id> <key>
    sed -n "s/^$2=//p" "$VMDIR/$1/instance.env" 2>/dev/null
}

ssh_key() { # a 0600 copy, since the repo copy is group-readable
    local k="$VMDIR/.testing_rsa"
    if [ ! -f "$k" ]; then
        mkdir -p "$VMDIR"; cp "$KEY_SRC" "$k"; chmod 600 "$k"
    fi
    echo "$k"
}

cmd_alloc() {
    local owner="${1:?usage: $0 alloc <owner>}" id live=0
    mkdir -p "$VMDIR"
    for i in $(seq 0 $((MAX_ID - 1))); do
        [ -d "$VMDIR/$i" ] && live=$((live + 1))
    done
    for i in $(seq 0 $((MAX_ID - 1))); do
        if mkdir "$VMDIR/$i" 2>/dev/null; then id=$i; break; fi
    done
    if [ -z "${id:-}" ]; then
        echo "no free instance (all $MAX_ID in use); $0 list" >&2
        return 1
    fi
    # First instance gets the full 8 GB; once we are sharing, drop to 4.
    local mem=8192
    [ "$live" -ge 1 ] && mem=4096
    cat > "$VMDIR/$id/instance.env" <<EOF
id=$id
owner=$owner
ssh_port=$((9222 + id))
vnc_port=$((5900 + id))
mem=$mem
since=$(date -Is)
EOF
    echo "instance $id allocated to $owner"
    echo
    echo "  export CROS_VM_ID=$id CROS_VM_MEM=$mem"
    echo "  $0 boot $id            # then wait ~60s for the login screen"
    echo "  $0 ssh $id 'uptime'"
    echo "  $0 release $id         # when done -- wipes the workspace"
}

cmd_boot() {
    local id="${1:?usage: $0 boot <id>}"
    [ -d "$VMDIR/$id" ] || { echo "instance $id not allocated" >&2; return 1; }
    if vm_container "$id"; then echo "instance $id already running" >&2; return 1; fi
    ( cd "$DIR" && CROS_VM_ID="$id" CROS_VM_MEM="$(meta "$id" mem)" \
        nohup ./run-crosvm.sh > "$VMDIR/$id/boot.log" 2>&1 & )
    echo "instance $id booting; log: chromiumos/.vm/$id/boot.log"
}

cmd_ssh() {
    local id="${1:?usage: $0 ssh <id> [cmd...]}"; shift
    local port; port="$(meta "$id" ssh_port)"
    [ -n "$port" ] || { echo "instance $id not allocated" >&2; return 1; }
    SSH_ASKPASS_REQUIRE=never ssh -p "$port" -i "$(ssh_key)" \
        -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=10 root@localhost "$@"
}

cmd_stop() {
    local id="${1:?usage: $0 stop <id>}"
    docker kill "cros-vm-$id" >/dev/null 2>&1 && echo "stopped $id" || echo "$id not running"
}

cmd_release() {
    local id="${1:?usage: $0 release <id>}"
    cmd_stop "$id" >/dev/null 2>&1
    sleep 1
    rm -rf "${VMDIR:?}/$id" && echo "released $id (workspace wiped)"
}

cmd_list() {
    printf '%-4s %-16s %-6s %-6s %-6s %-9s %s\n' ID OWNER SSH VNC MEM STATE DISK
    local found=0
    for d in "$VMDIR"/*/; do
        [ -d "$d" ] || continue
        local id; id="$(basename "$d")"
        case "$id" in .*) continue ;; esac
        found=1
        local state=stopped
        vm_container "$id" && state=running
        local disk="-"
        [ -f "$d/disk.qcow2" ] && disk="$(du -h "$d/disk.qcow2" | cut -f1)"
        printf '%-4s %-16s %-6s %-6s %-6s %-9s %s\n' \
            "$id" "$(meta "$id" owner)" "$(meta "$id" ssh_port)" \
            "$(meta "$id" vnc_port)" "$(meta "$id" mem)" "$state" "$disk"
    done
    [ "$found" = 1 ] || echo "(none allocated)"
}

cmd_gc() {
    for d in "$VMDIR"/*/; do
        [ -d "$d" ] || continue
        local id; id="$(basename "$d")"
        case "$id" in .*) continue ;; esac
        if ! vm_container "$id"; then
            echo "instance $id: no container running"
        fi
    done
    echo "(gc only reports; use 'release <id>' to wipe -- a stopped instance may"
    echo " still hold state someone wants)"
}

case "${1:-list}" in
    alloc)   shift; cmd_alloc "$@" ;;
    boot)    shift; cmd_boot "$@" ;;
    ssh)     shift; cmd_ssh "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    release) shift; cmd_release "$@" ;;
    list)    shift; cmd_list "$@" ;;
    gc)      shift; cmd_gc "$@" ;;
    *) sed -n '2,30p' "$0"; exit 1 ;;
esac
