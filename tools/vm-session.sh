#!/usr/bin/env bash
# One entry point from "no VM" to "a browser window I can drive".
#
#   tools/vm-session.sh up [image]      # alloc + boot + wait for ssh + CDP tunnel
#   tools/vm-session.sh oobe [name] [pw]# click through OOBE to a logged-in session
#   tools/vm-session.sh open <url>      # open a real browser tab, print its target
#   tools/vm-session.sh eval [-t SUB] <js>
#   tools/vm-session.sh screenshot <out.png> [-t SUB]
#   tools/vm-session.sh shell <cmd...>  # run a command in the guest
#   tools/vm-session.sh status | targets | list
#   tools/vm-session.sh down            # stop the VM, keep the disk
#   tools/vm-session.sh reset           # wipe and come back up, pre-OOBE
#   tools/vm-session.sh release         # stop + wipe, free the instance
#
# The usual full run:
#   tools/vm-session.sh up && tools/vm-session.sh oobe
#   tools/vm-session.sh open https://example.com
#   tools/vm-session.sh eval -t example.com 'document.title'
#   tools/vm-session.sh screenshot /tmp/s.png
#   tools/vm-session.sh release
#
# Ownership and idempotence
#   Every instance is tagged with an owner ($CROS_SESSION_OWNER, default
#   "agent"). `up` reuses this owner's instance if it already has one, so it is
#   safe to run twice; it never touches an instance owned by somebody else.
#   Pick your own owner if two agents share the host.
#
# Ports (instance id N)
#   ssh 9222+N, VNC 5900+N, CDP 9229+N on the host -> 9229 in the guest.
#
# Traps this script already handles for you, documented so you don't undo them:
#   * CROS_VM_SCSI=1 is mandatory on the colorburst (reven) board: its 6.12
#     kernel has virtio_blk as a module and we boot noinitrd, so a --block root
#     disk hangs forever at "Waiting for root device /dev/vda3".
#   * CROS_VM_RAW=1 (the default here) copies the base image to a raw writable
#     disk instead of a qcow2 overlay, whose backing-file reads EOF-fault.
#     Costs ~7 GB of disk and ~1 min per instance; set CROS_VM_RAW=0 to trade
#     that for the qcow2 flakiness.
#   * The `latest` image symlink often points at a RELEASE build, which has no
#     chromiumos_test_image.bin (no ssh, no test keys). `up` resolves to the
#     newest *test* image instead unless you name one.
#   * The SSH tunnel is tracked by pidfile. Never `pkill -f 9229:127.0.0.1:9229`
#     -- the pattern matches the shell that runs it and kills your own session.
#   * A VM boots as removable media, so /var/lib/colorburst/device-id is
#     legitimately absent in a VM. Don't chase it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMDIR="$DIR/chromiumos/.vm"
VMI="$DIR/tools/vm-instance.sh"
OWNER="${CROS_SESSION_OWNER:-agent}"
CDP="$DIR/tools/cdp.py"

die() { echo "vm-session: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------- instance --

meta() { sed -n "s/^$2=//p" "$VMDIR/$1/instance.env" 2>/dev/null; }
smeta() { sed -n "s/^$2=//p" "$VMDIR/$1/session.env" 2>/dev/null; }

find_instance() { # id of this owner's instance, if any
    local d id
    for d in "$VMDIR"/*/; do
        [ -d "$d" ] || continue
        id="$(basename "$d")"
        case "$id" in .*) continue ;; esac
        [ "$(meta "$id" owner)" = "$OWNER" ] && { echo "$id"; return 0; }
    done
    return 1
}

need_instance() {
    ID="$(find_instance)" || die "no instance owned by '$OWNER'; run: $0 up"
    SSH_PORT="$(meta "$ID" ssh_port)"
    CDP_PORT=$((9229 + ID))
}

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "cros-vm-$1"; }

gssh() { "$VMI" ssh "$ID" "$@"; }

# Newest *test* image: `latest` is frequently a release build with no test
# image in it, and a release image has neither sshd keys nor the test tooling.
resolve_image() {
    local want="${1:-${CROS_VM_IMAGE:-}}"
    if [ -n "$want" ]; then
        [ -f "$want" ] || die "image not found: $want"
        readlink -f "$want"; return
    fi
    local base="$DIR/chromiumos/src/build/images/${CROS_BOARD:-colorburst}"
    local latest="$base/latest/chromiumos_test_image.bin"
    if [ -f "$latest" ]; then readlink -f "$latest"; return; fi
    local newest
    newest="$(ls -t "$base"/*/chromiumos_test_image.bin 2>/dev/null | head -1)"
    [ -n "$newest" ] || die "no chromiumos_test_image.bin under $base"
    echo "!! $base/latest has no test image (release build?); using the newest one" >&2
    readlink -f "$newest"
}

# ------------------------------------------------------------------ waiting --

# wait_for <seconds> <label> <cmd...> -- poll until cmd succeeds
wait_for() {
    local timeout="$1" label="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    echo "vm-session: timed out after ${timeout}s waiting for $label" >&2
    return 1
}

# ------------------------------------------------------------------- tunnel --

tunnel_pidfile() { echo "$VMDIR/$ID/cdp-tunnel.pid"; }

tunnel_alive() {
    local pf; pf="$(tunnel_pidfile)"
    [ -f "$pf" ] || return 1
    local pid; pid="$(cat "$pf")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    # It must actually be our ssh, not a recycled pid.
    grep -qa 'ssh' "/proc/$pid/comm" 2>/dev/null
}

tunnel_up() {
    tunnel_alive && return 0
    local key="$VMDIR/.testing_rsa"
    [ -f "$key" ] || { cp "$DIR/chromiumos/chromite/ssh_keys/testing_rsa" "$key"; chmod 600 "$key"; }
    SSH_ASKPASS_REQUIRE=never ssh -N -p "$SSH_PORT" -i "$key" \
        -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ExitOnForwardFailure=yes -o LogLevel=ERROR \
        -o ServerAliveInterval=15 \
        -L "$CDP_PORT:127.0.0.1:9229" root@localhost \
        </dev/null >"$VMDIR/$ID/cdp-tunnel.log" 2>&1 &
    # The redirect matters: a backgrounded ssh that inherits our stdout keeps
    # the caller's pipe open forever, so `vm-session.sh up | tail` would appear
    # to hang long after the script exited.
    echo $! > "$(tunnel_pidfile)"
    sleep 1
    tunnel_alive || die "CDP tunnel failed to start"
}

# Kill only OUR tunnel, by pid. `pkill -f "9229:127.0.0.1:9229"` matches the
# shell running the pkill and takes your session with it.
tunnel_down() {
    local pf; pf="$(tunnel_pidfile)"
    [ -f "$pf" ] || return 0
    local pid; pid="$(cat "$pf")"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$pf"
}

cdp_ok() { curl -sf --max-time 5 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null; }

# Chrome ships no debugging port. Add one via a bind mount over
# /etc/chrome_dev.conf (rootfs is read-only) and restart the UI. tmpfs-backed,
# so it evaporates on reboot -- which is fine, nothing here reboots the guest.
enable_cdp() {
    if gssh 'mount | grep -q "on /etc/chrome_dev.conf "' 2>/dev/null; then
        log "CDP flags already bind-mounted in the guest"
    else
        log "enabling remote debugging in the guest (restart ui)"
        gssh 'cp /etc/chrome_dev.conf /tmp/cdc
              printf "%s\n" "--remote-debugging-port=9229" "--remote-allow-origins=*" \
                            "--enable-oobe-test-api" >> /tmp/cdc
              mount --bind /tmp/cdc /etc/chrome_dev.conf
              restart ui </dev/null >/dev/null 2>&1' >/dev/null \
            || die "could not enable remote debugging"
    fi
    wait_for 180 "chrome to listen on guest 9229" guest_cdp_listening \
        || die "chrome never opened 9229 (check: $VMI ssh $ID 'tail /var/log/ui/ui.LATEST')"
}

# The guest's bash is built without /dev/tcp, and there is no `ss`. 240D is
# 9229 in the hex-port column of /proc/net/tcp.
guest_cdp_listening() {
    gssh 'grep -q ":240D" /proc/net/tcp' >/dev/null 2>&1
}

# ----------------------------------------------------------------- commands --

cmd_up() {
    local img; img="$(resolve_image "${1:-}")" || exit 1
    local t0=$SECONDS
    if ID="$(find_instance)"; then
        log "reusing instance $ID (owner $OWNER)"
    else
        "$VMI" alloc "$OWNER" >/dev/null || die "alloc failed"
        ID="$(find_instance)" || die "alloc did not produce an instance"
        log "allocated instance $ID"
    fi
    SSH_PORT="$(meta "$ID" ssh_port)"; CDP_PORT=$((9229 + ID))
    cat > "$VMDIR/$ID/session.env" <<EOF
image=$img
cdp_port=$CDP_PORT
EOF
    log "image: $img"
    if running "$ID"; then
        log "instance $ID already running"
    else
        log "booting (CROS_VM_SCSI=1 CROS_VM_RAW=${CROS_VM_RAW:-1}); first boot copies ~7 GB"
        # run-crosvm.sh exec's a foreground `docker run` that lives for the VM's
        # whole lifetime. It MUST be fully detached -- its own session, no
        # inherited stdin/stdout -- or this script stays blocked waiting on it
        # (and, when run as `vm-session.sh up | tail`, never closes the pipe).
        ( cd "$DIR" && CROS_VM_ID="$ID" CROS_VM_MEM="$(meta "$ID" mem)" \
            CROS_VM_SCSI=1 CROS_VM_RAW="${CROS_VM_RAW:-1}" CROS_VM_IMAGE="$img" \
            setsid ./run-crosvm.sh </dev/null > "$VMDIR/$ID/boot.log" 2>&1 & )
        disown 2>/dev/null || true
    fi
    wait_for "${CROS_UP_TIMEOUT:-600}" "ssh on port $SSH_PORT" \
        "$VMI" ssh "$ID" true || {
            echo "--- last 20 lines of console ---" >&2
            tail -20 "$VMDIR/$ID/console.log" 2>&1 >&2
            die "guest never answered ssh (see $VMDIR/$ID/{boot,console}.log)"
        }
    log "ssh is up ($((SECONDS - t0))s)"
    enable_cdp
    tunnel_up
    wait_for 60 "CDP on host port $CDP_PORT" cdp_ok || die "tunnel is up but CDP does not answer"
    log "ready in $((SECONDS - t0))s"
    cmd_status
}

cmd_status() {
    need_instance
    local state=stopped; running "$ID" && state=running
    echo "instance   $ID  (owner $OWNER, $state)"
    echo "ssh        $VMI ssh $ID <cmd>      # host port $SSH_PORT"
    echo "cdp        http://127.0.0.1:$CDP_PORT   (tunnel $(tunnel_alive && echo up || echo down))"
    echo "vnc        $((5900 + ID))"
    echo "image      $(smeta "$ID" image)"
    echo "console    $VMDIR/$ID/console.log"
}

cmd_oobe() {
    need_instance
    tunnel_up
    local t0=$SECONDS
    python3 "$DIR/tools/oobe_walk.py" --port "$CDP_PORT" \
        --name "${1:-alex}" --password "${2:-colorburst-test-1}" || exit 1
    log "OOBE took $((SECONDS - t0))s; asserting post-conditions"
    oobe_assert "${1:-alex}"
}

# The three things that distinguish "signed in" from "the UI merely stopped
# showing screens": a live session, a local-password auth factor on the vault,
# and no half-created-account marker left in Local State.
oobe_assert() {
    local fail=0 out
    out="$(gssh 'dbus-send --system --print-reply --dest=org.chromium.SessionManager \
        /org/chromium/SessionManager \
        org.chromium.SessionManagerInterface.RetrieveSessionState' 2>/dev/null)"
    if echo "$out" | grep -q '"started"'; then echo "  ok   session started"
    else echo "  FAIL session state: $(echo "$out" | tr -d '\n')"; fail=1; fi

    out="$(gssh 'ls /home/.shadow/*/auth_factors 2>/dev/null' 2>/dev/null)"
    if echo "$out" | grep -q 'local-password'; then
        echo "  ok   auth factor: $(echo "$out" | tr '\n' ' ')"
    else echo "  FAIL no local-password auth factor (got: $(echo "$out" | tr '\n' ' '))"; fail=1; fi

    if gssh 'grep -q incomplete_login_user_account "/home/chronos/Local State"' 2>/dev/null; then
        echo "  FAIL incomplete_login_user_account marker present"; fail=1
    else echo "  ok   no incomplete_login_user_account marker"; fi

    [ "$fail" = 0 ] || die "OOBE post-conditions failed"
    echo "logged in as '$1'"
}

cmd_open() {
    need_instance; tunnel_up
    local url="${1:?usage: $0 open <url>}"
    python3 "$DIR/tools/oobe_walk.py" --port "$CDP_PORT" --open "$url"
}

cmd_eval() {
    need_instance; tunnel_up
    local target="" expr=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--target) target="$2"; shift 2 ;;
            *) expr="$1"; shift ;;
        esac
    done
    [ -n "$expr" ] || die "usage: $0 eval [-t SUBSTR] <js>"
    if [ -n "$target" ]; then
        "$CDP" --port "$CDP_PORT" --target "$target" eval "$expr"
    else
        "$CDP" --port "$CDP_PORT" eval "$expr"
    fi
}

cmd_targets() { need_instance; tunnel_up; "$CDP" --port "$CDP_PORT" list; }

# Two different pictures, and they are not interchangeable:
#   default  -- the guest's `screenshot` CLI: the real DRM scanout, i.e. the
#               whole desktop, shelf and all. Full guest resolution (4K, ~1 MB).
#   -t SUBSTR-- CDP Page.captureScreenshot on one web contents: no shelf, no
#               window frame, but it works on a page that is not on screen.
cmd_screenshot() {
    need_instance
    local target="" out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--target) target="$2"; shift 2 ;;
            *) out="$1"; shift ;;
        esac
    done
    [ -n "$out" ] || die "usage: $0 screenshot <out.png> [-t SUBSTR]"
    if [ -n "$target" ]; then
        tunnel_up
        "$CDP" --port "$CDP_PORT" --target "$target" screenshot "$out"
    else
        gssh '/usr/local/sbin/screenshot /tmp/vm-session.png 2>/dev/null' >/dev/null \
            || die "guest screenshot failed"
        SSH_ASKPASS_REQUIRE=never scp -q -P "$SSH_PORT" -i "$VMDIR/.testing_rsa" \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
            root@localhost:/tmp/vm-session.png "$out" || die "scp of screenshot failed"
        echo "wrote $out ($(du -h "$out" | cut -f1), full guest scanout)"
    fi
}

cmd_shell() { need_instance; gssh "$@"; }

cmd_down() { need_instance; tunnel_down; "$VMI" stop "$ID"; }

cmd_release() { need_instance; tunnel_down; "$VMI" release "$ID"; }

# Back to a pristine pre-OOBE guest. The disk is a raw copy, so this pays the
# ~7 GB copy again -- there is no snapshot to roll back to.
cmd_reset() {
    local img=""
    if ID="$(find_instance)"; then
        img="$(smeta "$ID" image)"
        SSH_PORT="$(meta "$ID" ssh_port)"; CDP_PORT=$((9229 + ID))
        tunnel_down
        "$VMI" release "$ID"
    fi
    cmd_up "$img"
}

case "${1:-status}" in
    up)         shift; cmd_up "$@" ;;
    oobe)       shift; cmd_oobe "$@" ;;
    open)       shift; cmd_open "$@" ;;
    eval)       shift; cmd_eval "$@" ;;
    targets)    shift; cmd_targets "$@" ;;
    screenshot) shift; cmd_screenshot "$@" ;;
    shell)      shift; cmd_shell "$@" ;;
    status)     shift; cmd_status "$@" ;;
    list)       shift; "$VMI" list ;;
    down)       shift; cmd_down "$@" ;;
    reset)      shift; cmd_reset "$@" ;;
    release)    shift; cmd_release "$@" ;;
    *) sed -n '2,40p' "$0"; exit 1 ;;
esac
