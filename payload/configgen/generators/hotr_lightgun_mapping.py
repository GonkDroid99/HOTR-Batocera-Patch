from __future__ import annotations

"""Shared HOTR light-gun semantic -> SDL translation.

Batocera normalizes physical gun buttons to a global logical layout:
trigger, action/offscreen, start, select, sub1/sub2/sub3 and d-pad.
HOTR keeps those user-facing meanings, but translates them to the SDL
controller exposed while a supported gun is in HOTR joystick mode.

The RS3 Reaper table below is verified from the Batocera 43.1/HOTR test
hardware for Button0/1/2/3/5, Hat0 and Axis0/1. Stick press is represented by
Button4 in the current RS3 HOTR layout and remains overrideable/disableable in ES.
"""

from dataclasses import dataclass


BUTTON_LOGICAL = (
    "default",
    "trigger",
    "action",
    "start",
    "select",
    "sub1",
    "sub2",
    "sub3",
    "up",
    "down",
    "left",
    "right",
    "disabled",
)


@dataclass(frozen=True)
class SDLBinding:
    kind: str
    value: str


# Batocera global light-gun semantics -> RS3 SDL joystick-mode controls.
# trigger = physical trigger
# action  = rear/thumb reload/offscreen button
# start   = front-left
# select  = front-right
# sub1    = palm
# sub2    = stick press
RS3_REAPER: dict[str, SDLBinding] = {
    "trigger": SDLBinding("button", "0"),
    "action": SDLBinding("button", "1"),
    "start": SDLBinding("button", "2"),
    "select": SDLBinding("button", "5"),
    "sub1": SDLBinding("button", "3"),
    "sub2": SDLBinding("button", "4"),
    "up": SDLBinding("hat", "North"),
    "down": SDLBinding("hat", "South"),
    "left": SDLBinding("hat", "West"),
    "right": SDLBinding("hat", "East"),
}


# Other Batocera guns are intentionally not guessed here. Their normal Batocera
# mouse/key normalization is documented, but HOTR needs their *SDL-mode* layout.
# Add a table only after its SDL buttons/axes have been measured.
GUN_LAYOUTS = {
    "rs3_reaper": RS3_REAPER,
}


def detected_layout_name(gun=None) -> str:
    """Return the HOTR SDL layout for a detected gun.

    At present RS3 is the verified SDL-mode device. The fallback remains RS3 so
    existing RS3 installs continue to work when Batocera's guns list is empty or
    uses a generic calibrated name.
    """
    if gun is not None:
        name = str(getattr(gun, "name", "")).lower()
        if "retro shooter" in name or "rs3" in name or "3a-3h" in name:
            return "rs3_reaper"
    return "rs3_reaper"


def _logical(system, key: str, default: str) -> str:
    value = str(system.config.get(key, "default") or "default").lower()
    if value == "default":
        return default
    if value not in BUTTON_LOGICAL:
        return default
    return value


def logical_for(system, emulator: str, player: int, action: str, default: str) -> str:
    return _logical(system, f"hotr_{emulator}_p{player}_{action}", default)


def _binding(layout_name: str, logical: str) -> SDLBinding | None:
    if logical == "disabled":
        return None
    return GUN_LAYOUTS.get(layout_name, RS3_REAPER).get(logical)


def pcsx2_button(layout_name: str, sdl_index: int, logical: str) -> str | None:
    bind = _binding(layout_name, logical)
    if bind is None:
        return None
    prefix = f"SDL-{sdl_index}"
    if bind.kind == "button":
        return f"{prefix}/JoyButton{bind.value}"
    if bind.kind == "hat":
        return f"{prefix}/Hat0{bind.value}"
    return None


def duckstation_button(layout_name: str, sdl_index: int, logical: str) -> str | None:
    bind = _binding(layout_name, logical)
    if bind is None:
        return None
    prefix = f"SDL-{sdl_index}"
    if bind.kind == "button":
        return f"{prefix}/Button{bind.value}"
    if bind.kind == "hat":
        # DuckStation accepts SDL DPad names for controller hats.
        return f"{prefix}/DPad{bind.value}"
    return None


def pcsx2_relative_axes(sdl_index: int, x_mode: str, y_mode: str) -> dict[str, str]:
    prefix = f"SDL-{sdl_index}"
    result: dict[str, str] = {}
    if x_mode != "disabled":
        invert = x_mode == "inverted"
        result["guncon2_RelativeLeft"] = f"{prefix}/{'+' if invert else '-'}JoyAxis0"
        result["guncon2_RelativeRight"] = f"{prefix}/{'-' if invert else '+'}JoyAxis0"
    if y_mode != "disabled":
        invert = y_mode == "inverted"
        result["guncon2_RelativeUp"] = f"{prefix}/{'+' if invert else '-'}JoyAxis1"
        result["guncon2_RelativeDown"] = f"{prefix}/{'-' if invert else '+'}JoyAxis1"
    return result


def duckstation_relative_axes(sdl_index: int, x_mode: str, y_mode: str) -> dict[str, str]:
    prefix = f"SDL-{sdl_index}"
    result: dict[str, str] = {}
    if x_mode != "disabled":
        invert = x_mode == "inverted"
        result["RelativeLeft"] = f"{prefix}/{'+' if invert else '-'}Axis0"
        result["RelativeRight"] = f"{prefix}/{'-' if invert else '+'}Axis0"
    if y_mode != "disabled":
        invert = y_mode == "inverted"
        result["RelativeUp"] = f"{prefix}/{'+' if invert else '-'}Axis1"
        result["RelativeDown"] = f"{prefix}/{'-' if invert else '+'}Axis1"
    return result


def axis_mode(system, emulator: str, player: int, axis: str) -> str:
    value = str(system.config.get(f"hotr_{emulator}_p{player}_aim_{axis}", "normal") or "normal").lower()
    return value if value in ("normal", "inverted", "disabled") else "normal"
