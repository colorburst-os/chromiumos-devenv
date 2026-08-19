#!/bin/bash
# On-device regression battery for the colorburst UniKey Vietnamese IME.
#
# For every Telex input in tools/telex-words.txt this:
#   1. switches ash to the Vietnamese Telex IME,
#   2. types the input with real evdev keystrokes (tools/telex-inject.py, the
#      ONLY way to reach ash's IME -- CDP injects downstream of it),
#   3. reads the committed text back over CDP from a contenteditable, and
#   4. diffs it against the bamboo-core oracle (Go, MIT, HOST-SIDE only -- never
#      in-process; its Go runtime trips Chromium's seccomp filter).
#
# bamboo is a *reference*, not ground truth: its spell-checker mangles
# non-Vietnamese words (congas -> conga-acute) exactly like the old rule-based
# engine, whereas UniKey's autoNonVnRestore keeps them. So D4/en lines are
# reported as EXPECTED-DIVERGENCE (UniKey more correct), not failures.
#
# Prereqs: a booted+logged-in VM owned by $CROS_SESSION_OWNER with an
# example.com tab and an os-settings tab open, tools/telex-oracle built
# (go build ./tools/telex-oracle), tone style classic (device default).
#
# Usage: CROS_SESSION_OWNER=imetail tools/telex-regression.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="$(cd "$HERE/.." && pwd)"
VM="$HERE/vm-session.sh"
CDP="$HERE/cdp.py"
WORDS="$HERE/telex-words.txt"
ORACLE="$HERE/telex-oracle/telex-oracle"
EXT=_comp_ime_jhffeifommiaekmbkkjlpmilogcfdohp
TELEX="${EXT}vkd_vi_telex"
STYLE="${STYLE:-1}"   # oracle tone style: 1=classic (device default), 0=modern
KEYDELAY="${KEYDELAY:-70}"

# CDP port = 9229 + instance id for this owner.
ID="$($VM status 2>/dev/null | awk '/^instance/{print $2}')"
PORT=$((9229 + ID))

[ -x "$ORACLE" ] || { echo "build the oracle first: (cd $HERE/telex-oracle && go build -o telex-oracle .)"; exit 1; }

# Stage the injector on the guest.
cat "$HERE/telex-inject.py" | $VM shell 'cat > /tmp/telex-inject.py' >/dev/null 2>&1

setime()  { $VM eval -t os-settings "new Promise(r=>chrome.inputMethodPrivate.setCurrentInputMethod('$1',()=>r(1)))" >/dev/null 2>&1; }
prep()    { python3 "$CDP" --port "$PORT" --target example.com send Page.bringToFront >/dev/null 2>&1
            $VM eval -t example.com 'var t=document.getElementById("ce");if(!t){t=document.createElement("textarea");t.id="ce";t.style.cssText="position:fixed;top:0;left:0;width:700px;height:200px;z-index:99999";document.body.appendChild(t);}t.value="";t.focus();' >/dev/null 2>&1
            sleep 0.35; }
# base64-stage tokens so punctuation survives host->ssh->guest quoting.
finj()    { local b; b="$(printf '%s' "$1" | base64 -w0)"
            $VM shell "echo $b | base64 -d > /tmp/tk.txt; python3 /tmp/telex-inject.py --key-delay $KEYDELAY --file /tmp/tk.txt" >/dev/null 2>&1; }
readval() { $VM eval -t example.com 'document.getElementById("ce").value.trim()' 2>/dev/null | tail -1 | sed 's/^"//;s/"$//'; }

inputs=(); tags=()
while read -r inp tag _; do
  [ -z "${inp:-}" ] && continue
  case "$inp" in \#*) continue;; esac
  [ "${tag:-}" = "skip" ] && continue
  inputs+=("$inp"); tags+=("${tag:-vn}")
done < "$WORDS"

# Oracle expectations (batch).
mapfile -t expected < <(for inp in "${inputs[@]}"; do echo "$STYLE $inp"; done | "$ORACLE")

setime "$TELEX"
match=0; diverge=0; fail=0; n=${#inputs[@]}
printf '%-12s %-6s %-14s %-14s %s\n' INPUT TAG DEVICE ORACLE VERDICT
for i in "${!inputs[@]}"; do
  prep; finj "${inputs[$i]} SPACE"
  dev="$(readval)"; exp="${expected[$i]:-}"; tag="${tags[$i]}"
  if [ "$dev" = "$exp" ]; then verdict=match; match=$((match+1))
  elif [ "$tag" = "D4" ] || [ "$tag" = "en" ]; then verdict="EXPECTED-DIVERGENCE(unikey-keeps)"; diverge=$((diverge+1))
  else verdict="**MISMATCH**"; fail=$((fail+1)); fi
  printf '%-12s %-6s %-14s %-14s %s\n' "${inputs[$i]}" "$tag" "$dev" "$exp" "$verdict"
done
echo "----"
echo "words=$n  oracle-match=$match  expected-divergence=$diverge  unexpected-mismatch=$fail"
