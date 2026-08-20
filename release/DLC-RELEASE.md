# Serving Crostini's DLCs over the colorburst Omaha server

`termina-dlc`, `termina-tools-dlc`, and `edk2-ovmf-dlc` used to be
factory-installed into stateful. On this plain-ext4 (non-LVM) board that copy
lives only in stateful, is never written by OTA, and does not survive
powerwash — so a powerwashed or OTA-updated device would fail to start Crostini
with "update ChromeOS to install Linux". The durable fix is to serve these
DLCs from the update server on demand, exactly like any other DLC-over-Omaha
payload. This runbook covers generating, signing, and publishing them.

The runtime path is already correct: with no factory image present,
dlcservice → update_engine → our Omaha server. update_engine forms the DLC
appid as `{OS_APPID}_<dlc_id>` (`omaha_request_params.cc:353`,
`GetAppId() + "_" + dlc_id`) and asks for a normal DLC payload. Today the
server returns `noupdate` for those appids; after this runbook it returns a
real `ok` manifest.

## Pieces

- `release/gen-dlc-payloads.sh` — unsigned DLC payloads + hashes (run me)
- `release/sign-dlc-on-yubikey.sh` — YubiKey slot-9C signing (run yourself)
- `release/publish-dlcs.sh` — upload + merge into `releases.json` (run yourself)
- `update-server/worker.js` — already extended to answer DLC apps; **must be
  `wrangler deploy`-ed once** for the DLC path to go live (see step 4)

Signature format, key, and slot are identical to the OS payload: a DLC payload
is verified on-device with the same `/usr/share/update_engine/
update-payload-key.pub.pem` (update_engine `payload_verifier.cc` /
`delta_performer.cc` have no DLC-specific path). Slot 9C, RSASSA-PKCS1-v1_5
over the SHA-256 digest — see `sign-on-yubikey.sh` for the rationale.

## 1. Generate the unsigned payloads (in the build container)

```bash
cd ~/develop/colorburst-os/chromium-os
release/gen-dlc-payloads.sh 2026.32.7        # all three DLCs for OS 2026.32.7
# or a subset:  release/gen-dlc-payloads.sh 2026.32.7 edk2-ovmf-dlc
```

Reads each DLC's `dlc.img` + `imageloader.json` from the board sysroot
(`/build/colorburst/build/rootfs/dlc/<id>/package/`) and, per DLC, runs the
paygen DLC recipe (`paygen_payload_lib.py:613-627,878-911`):

```
delta_generator --major_version=2 \
  --partition_names=dlc/<dlc_id>/<dlc_package> \
  --new_partitions=<dlc.img> --out_file=<payload>
delta_generator --in_file=<payload> --signature_size=256 \
  --out_hash_file=payload_hash.bin --out_metadata_hash_file=metadata_hash.bin
```

The partition name **must** be the 3-token `dlc/<dlc_id>/<dlc_package>` form —
update_engine rejects anything else (`boot_control_chromeos.cc:227-242`). The
whole `dlc.img` is the single "new partition" (no root/kernel extraction).

Output per DLC: `chromiumos/ota-release/<os-version>/dlc/<dlc_id>/` with
`<dlc_id>-<dlc_version>-full.bin` (+`.json`), `payload_hash.bin`,
`metadata_hash.bin`, `INSTRUCTIONS.txt`. The `.json` `appid` is set to
`{OS_APPID}_<dlc_id>` (delta_generator can't know it; paygen injects it the
same way at `paygen_payload_lib.py:1166`).

*(Validated: `edk2-ovmf-dlc` generates cleanly this way; the payload's file
sha256 matches its `.json` `sha256_hex` decoded from base64.)*

## 2. Sign on the YubiKey (needs the token + PIN + two touches per DLC)

```bash
release/sign-dlc-on-yubikey.sh chromiumos/ota-release/2026.32.7
```

For each DLC it signs `payload_hash.bin` and `metadata_hash.bin` in slot 9C,
reinserts the detached signatures with
`delta_generator --payload_signature_file/--metadata_signature_file`, verifies
the signed payload against the public key
(`delta_generator --public_key=…` — the same check update_engine performs), and
writes `<dlc_id>-<dlc_version>-full-signed.bin` (+`.json`, now carrying the
reinserted `metadata_size` and base64 `metadata_signature`).

## 3. Publish (upload to R2 + merge `releases.json`)

```bash
release/publish-dlcs.sh chromiumos/ota-release/2026.32.7
```

For each signed DLC it:
- cross-checks the file sha256 against the `.json` and refuses if unsigned or
  the appid isn't `{OS_APPID}_<dlc_id>`;
- uploads the signed payload to
  `r2://colorburst-updates/dlcs/<dlc_id>/<version>/<name>` via the R2 S3 API
  (`curl --aws-sigv4`), the same route `publish.sh` uses for the OS payload —
  **the wrangler build here rejects `r2 object put --file`, so S3 is the
  reliable path for every object, including `releases.json`**;
- **GETs the current `releases.json` and only adds/replaces the top-level
  `dlcs` key**, so the OS `stable`/`*-channel` tracks are preserved, then PUTs
  it back;
- asks the live server, as a device installing each DLC, and confirms the
  response points at the freshly-uploaded payload.

Storage layout and schema: see `update-server/README.md`. The `dlcs.<dlc_id>`
entry carries `version` (imageloader version, used for both the R2 path and the
`<manifest version>`), `payload`, `size`, `sha256_hex` (hex), `metadata_size`,
`metadata_signature` (base64), `is_delta`.

## 4. Deploy the worker (once)

The worker in this repo already answers DLC apps, but the running Worker must
be redeployed for it to take effect:

```bash
cd ~/develop/colorburst-os/update-server
export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=...
npx wrangler deploy
```

The OS response path is unchanged (a plain OS update check is byte-for-byte
identical), so this deploy is safe for existing devices.

## 5. End-to-end verification

`publish-dlcs.sh` already runs the live check. To verify by hand, simulate an
on-demand DLC install (platform app with no `<updatecheck>` + a DLC app on
`0.0.0.0`):

```bash
APPID='{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}'
curl -sS -X POST --data-binary @- https://update.colorburst.net/update <<EOF | xmllint --format -
<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" updater="ChromeOSUpdateEngine" installsource="ondemandupdate" ismachine="1">
  <os version="Indy" platform="Chrome OS" sp="0.0.0_x86_64"></os>
  <app appid="${APPID}" version="0.0.0.0" track="stable-channel" board="colorburst"></app>
  <app appid="${APPID}_termina-dlc" version="0.0.0.0" track="stable-channel" board="colorburst">
    <updatecheck></updatecheck>
  </app>
</request>
EOF
```

Expect the `${APPID}` app to be `updatecheck status="noupdate"` and the
`${APPID}_termina-dlc` app to be `status="ok"` with a `<url codebase=
"https://dl.colorburst.net/dlcs/termina-dlc/<version>/">`, a `<package
name= size= hash_sha256=>`, and a `<action event="postinstall" MetadataSize=
MetadataSignatureRsa= IsDeltaPayload="false">`.

On a real device: powerwash (or flash + boot without factory DLCs), then
`sudo -u chronos dlcservice_util --install --id=termina-dlc`, or just start
Crostini. Watch `/var/log/update_engine.log` — the DLC download and the
`DownloadOperationExecuted` / signature-verified lines should appear, and the
DLC should mount. If update_engine logs `kOmahaResponseInvalid`, re-check the
manifest fields against `update-server/worker.js`'s `appDlcUpdate` — a
malformed DLC response fails silently on the device.

## Fields update_engine actually requires (so a wrong response is caught early)

Verified against `omaha_parser_xml.cc` / `omaha_request_action.cc`:

- `<updatecheck status="ok">` — DLC `noupdate` is tolerated (skips the DLC)
- `<urls><url codebase=…>` — non-empty (`omaha_request_action.cc:335`)
- `<manifest version=…>` — cosmetic for DLC installs; a mismatch vs the
  platform app version is only a `LOG(WARNING)` (`omaha_request_action.cc:655`)
- `<packages><package name= size= hash_sha256=>` — name non-empty, `size` > 0,
  `hash_sha256` non-empty (`omaha_request_action.cc:325-365`); `fp` optional;
  **`required=` is NOT parsed** (kept only for parity with the OS manifest)
- `<actions><action event="postinstall" MetadataSize= MetadataSignatureRsa=
  IsDeltaPayload=>` — the postinstall action is mandatory
  (`omaha_request_action.cc:661`); these three are colon-joined lists indexed
  per package (one value each for a single-package DLC)

The payload hash comes solely from `<package hash_sha256>` — there is no
per-`<action>` hash attribute in this codebase.
