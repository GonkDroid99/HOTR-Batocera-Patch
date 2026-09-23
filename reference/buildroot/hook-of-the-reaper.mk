################################################################################
#
# hook-of-the-reaper
#
# Light gun bridge daemon: receives MAME/emulator TCP signals on port 8000
# and drives recoil/reload/lights on serial/USB light guns.
#
# Source lives at: /home/matt/hook-of-the-reaper-src (symlink, no spaces)
#
################################################################################

HOOK_OF_THE_REAPER_VERSION = local
HOOK_OF_THE_REAPER_SITE = /home/matt/hook-of-the-reaper-src
HOOK_OF_THE_REAPER_SITE_METHOD = local
HOOK_OF_THE_REAPER_LICENSE = GPLv3
HOOK_OF_THE_REAPER_SUPPORTS_IN_SOURCE_BUILD = NO

HOOK_OF_THE_REAPER_DEPENDENCIES = qt6base qt6serialport qt6multimedia hidapi
# xdotool and xorg-app-xprop (for xprop) are used by the window-management scripts
# (S35hookofthereaper and HookOfTheReaper.sh) to minimize/raise the HOTR window.
# Both are standard Buildroot packages; scripts degrade gracefully if absent.

HOOK_OF_THE_REAPER_CONF_OPTS += -DCMAKE_BUILD_TYPE=Release
HOOK_OF_THE_REAPER_CONF_OPTS += -DBUILD_SHARED_LIBS=OFF
HOOK_OF_THE_REAPER_CONF_OPTS += -DQT_DEFAULT_MAJOR_VERSION=6

define HOOK_OF_THE_REAPER_INSTALL_TARGET_CMDS
    $(INSTALL) -D -m 0755 $(@D)/buildroot-build/HookOfTheReaper \
        $(TARGET_DIR)/usr/bin/hook-of-the-reaper

    # Data files: HOTR resolves paths relative to /usr/bin on Batocera (overlayfs)
    mkdir -p $(TARGET_DIR)/usr/bin/data
    cp -r $(@D)/data/. $(TARGET_DIR)/usr/bin/data/

    # DefaultLG: per-game signal configs used by HOTR to drive recoil/reload effects
    mkdir -p $(TARGET_DIR)/usr/bin/defaultLG
    cp -r $(@D)/defaultLG/. $(TARGET_DIR)/usr/bin/defaultLG/

    # udev rules for light gun USB device access
    $(INSTALL) -D -m 0644 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/99-hotr.rules \
        $(TARGET_DIR)/etc/udev/rules.d/99-hotr.rules

    # Override retroshooter-guns' ID_INPUT_JOYSTICK=0 suppression for RS3 guns
    # in gamepad/SDL mode so DuckStation LightGun Edition can enumerate them via SDL.
    # Must sort after 99-retroshooter-guns.rules (j > g alphabetically).
    $(INSTALL) -D -m 0644 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/99-retroshooter-joystick-override.rules \
        $(TARGET_DIR)/etc/udev/rules.d/99-retroshooter-joystick-override.rules

    # Auto-config script — detects connected guns and writes lightguns.hor/playersAss.hor on boot
    $(INSTALL) -D -m 0755 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/hotr-autoconfig.py \
        $(TARGET_DIR)/usr/bin/hotr-autoconfig

    # Init script — starts HOTR on boot, minimizes window so ES stays in front
    $(INSTALL) -D -m 0755 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/S35hookofthereaper \
        $(TARGET_DIR)/etc/init.d/S35hookofthereaper

    # ES Ports launchers — copied to /userdata/roms/ports/ on first boot via datainit
    # 1. Hook of the Reaper      — open UI: raises running engine or starts fresh
    $(INSTALL) -D -m 0755 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/HookOfTheReaper.sh \
        $(TARGET_DIR)/usr/share/batocera/datainit/roms/ports/HookOfTheReaper.sh
    # 2. HOTR Rescan Guns        — auto-detect all guns, restart engine silently
    $(INSTALL) -D -m 0755 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/controllers/guns/hook-of-the-reaper/HookOfTheReaperRescan.sh \
        $(TARGET_DIR)/usr/share/batocera/datainit/roms/ports/HookOfTheReaperRescan.sh

endef

$(eval $(cmake-package))
