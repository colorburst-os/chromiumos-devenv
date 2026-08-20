# chromite patches

Un-upstreamed changes to the ChromeOS build tooling (`chromite`) that colorburst
carries but does not maintain as a fork repo. Apply them to a chromite checkout
before building:

    ./apply.sh /path/to/chromiumos/chromite

Mirrors the `platform2-patches/` mechanism, but targets the synced `chromite`
tree instead of `src/platform2`.

## Patches
- **dlc-factory-install-crostini-0001.patch** — adds `termina-dlc`,
  `termina-tools-dlc` and `edk2-ovmf-dlc` to chromite's factory-install
  allowlist (`chromite/lib/dlc_allowlist.py:DLC_FACTORY_INSTALL`). Required so
  the overlay-colorburst override ebuilds for those DLCs (which set
  `DLC_FACTORY_INSTALL=true`) are accepted by `build_dlc`. The allowlist is
  enforced twice: at ebuild build time (`EbuildParams.VerifyDlcParameters`) and
  at image build time (`dlc_lib.IsFactoryInstallAllowed`); an un-allowlisted DLC
  raises `DLC=<id> is not allowed to be factory installed`.

  This is the build-tooling half of baking Crostini's "Linux development
  environment" into the release image so it installs entirely from local
  storage. The overlay half lives in
  `chromiumos/src/overlays/overlay-colorburst/chromeos-base/{termina-dlc,
  termina-tools-dlc,edk2-ovmf-dlc}`, which flip `DLC_FORCE_OTA` →
  `DLC_FACTORY_INSTALL`. Rationale: the colorburst update server serves only the
  OS payload, not DLCs, so the upstream OTA delivery path for termina can never
  succeed on our fleet.
