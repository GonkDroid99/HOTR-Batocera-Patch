# Batocera system payload

Active files copied by the installer are:

- `hotr-autoconfig.py`
- `99-hotr.rules`
- `hotr-sinden-broker.py` and `hotr-sinden-worker-launch` when the optional
  Sinden HOTR recoil broker is enabled.

The `HookOfTheReaper*.sh` files in this directory are legacy reference
scripts. They are not installed by the current `install.sh`; current runtime
and port scripts live under `scripts/`.

Sinden support has two independent optional pieces:

- `scripts/patch-batocera-sinden.sh` is the Batocera 43 detection workaround.
- `scripts/patch-batocera-sinden-hotr.sh` hooks the native helper to the HOTR
  broker and restores the backed-up stock helper with `remove`.
