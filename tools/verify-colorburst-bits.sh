#!/bin/bash
# Check the colorburst-specific bits of a running VM guest.
#
#   tools/verify-colorburst-bits.sh <vm-id>
#
# Covers, in order:
#   * the per-installation device id: minted on an installed boot, and what
#     update_engine actually puts on the wire;
#   * the build-host hostname, which must appear nowhere in the image;
#   * "Apps & games" (the MALL system web app), which must not be installed;
#   * Gallery, which must be our viewer rather than upstream's blank mock.
set -u
ID="${1:?usage: verify-colorburst-bits.sh <vm-id>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G() { "$DIR/tools/vm-instance.sh" ssh "$ID" "$@" 2>/dev/null; }

echo "===== device id ====="
G 'ls -la /var/lib/colorburst/ 2>&1; echo "id: $(cat /var/lib/colorburst/device-id 2>/dev/null || echo NONE)"'
echo "-- upstart job ran?"
G 'grep -a colorburst-device-id /var/log/messages | tail -3'
echo "-- is this boot removable (should be no for an installed disk)?"
G '. /usr/share/misc/chromeos-common.sh; if rootdev_removable; then echo REMOVABLE; else echo FIXED; fi; echo "rootdev: $(rootdev -s -d 2>/dev/null)"'

echo
echo "===== what update_engine sends ====="
# Force a check and read the request it wrote to its log.
G 'update_engine_client --check_for_update >/dev/null 2>&1; sleep 6;
   grep -a -o "colorburst_device_id=\"[^\"]*\"" /var/log/update_engine.log | tail -2;
   grep -a -o "hardware_class=\"[^\"]*\"" /var/log/update_engine.log | tail -1;
   grep -a -c "colorburst_device_id" /var/log/update_engine.log'

echo
# The build host's username and hostname must not leak into the image. Compute
# them on this machine rather than hardcoding a name, so the check is correct
# for whoever built the image (a unique, non-empty alternation for grep -E).
LEAK_ID="$(printf '%s\n' "$(id -un)" "$(hostname -s 2>/dev/null)" "$(hostname 2>/dev/null)" | awk 'NF' | sort -u | paste -sd'|')"
echo "===== build-host identity ($LEAK_ID) must not appear ====="
G "grep -a DEVSERVER /etc/lsb-release; hits=\$(grep -rilE '$LEAK_ID' /etc /usr/share/misc /usr/sbin/ectool 2>/dev/null | head -5);
   if [ -n \"\$hits\" ]; then echo \"LEAK: \$hits\"; else echo 'no build-host identity leaked (good)'; fi"

echo
echo "===== Apps & games (MALL swa) must be absent ====="
G 'grep -a -c "hlkibhljafkcdegnpfbghfpanocdocai" /home/chronos/"Local State" 2>/dev/null || echo 0;
   ls /home/chronos/user/Extensions 2>/dev/null | head -5'

echo
echo "===== Gallery bundle is ours, not the blank mock ====="
# The viewer's strings are compiled into the resource pak; the upstream mock
# has none of them.
G 'for p in /opt/google/chrome/resources.pak /opt/google/chrome/chromeos_media_app_bundle_resources.pak; do
     [ -f "$p" ] && echo "$p: $(strings -a "$p" | grep -c "Chưa mở tệp nào\|No file open")";
   done 2>/dev/null;
   ls -la /opt/google/chrome/*.pak 2>/dev/null | head -8'
