#!/bin/bash
# Read the guest's account state after walking the OOBE local-account flow.
# Usage: local-account-check.sh <vm-id>
set -u
ID="${1:?usage: local-account-check.sh <vm-id>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G() { "$DIR/tools/vm-instance.sh" ssh "$ID" "$@" 2>/dev/null; }

echo "===== session ====="
G 'dbus-send --system --print-reply --dest=org.chromium.SessionManager \
   /org/chromium/SessionManager \
   org.chromium.SessionManagerInterface.RetrieveActiveSessions 2>&1 | tail -6'
echo "===== cryptohome mounted ====="
G 'cryptohome --action=is_mounted'
echo "===== vault + auth factors ====="
G 'for d in /home/.shadow/*/; do
     [ -d "$d/auth_factors" ] || continue
     echo "$d"; ls "$d/auth_factors"
   done'
echo "===== Local State: KnownUsers / LoggedInUsers / UserType ====="
G 'python3 - <<PY 2>/dev/null || grep -o "\"KnownUsers\":\[[^]]*\]" "/home/chronos/Local State"
import json
d=json.load(open("/home/chronos/Local State"))
for k in ("KnownUsers","LoggedInUsers","UserType","UserDisplayName","UserDisplayEmail","OAuthTokenStatus","UserForceOnlineSignin","LastLoggedInRegularUser"):
    if k in d: print(k, "=", json.dumps(d[k]))
PY'
echo "===== integrity marker (must be ABSENT after signup) ====="
G 'grep -o "incomplete_login_user_account[^,]*" "/home/chronos/Local State" || echo "no integrity marker (good)"'
echo "===== oobe completed / device owned ====="
G 'ls -la /home/chronos/.oobe_completed 2>&1; ls /var/lib/devicesettings/ 2>&1'
echo "===== chrome log: crashes, gaia, local account ====="
G 'grep -aiE "local-account|LocalAccount|device-local account|Online login forced|CHECK failed|NOTREACHED|Check failed" \
     /var/log/chrome/chrome 2>/dev/null | tail -30'
echo "===== crash reports ====="
G 'ls -la /var/spool/crash/ 2>&1 | tail -10'
