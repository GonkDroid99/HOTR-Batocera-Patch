# Batocera system payload

Active files copied by the installer are:

- `hotr-autoconfig.py`
- `99-hotr.rules`
- `99-retroshooter-joystick-override.rules`

The `HookOfTheReaper*.sh` files in this directory are legacy reference
scripts. They are not installed by the current `install.sh`; current runtime
and port scripts live under `scripts/`.

Sinden compatibility is optional. Run `scripts/patch-batocera-sinden.sh apply`
only when Sinden support is needed; use `remove` to restore the backed-up stock
Batocera helpers.
