################################################################################
#
# pcsx2-lightgun
#
# LightGun Edition fork of PCSX2 with MameHooker integration for recoil
# and light gun effects via Hook of the Reaper.
# Source lives at: /home/matt/pcsx2-lightgun-src (symlink, no spaces)
#
################################################################################

PCSX2_LIGHTGUN_VERSION = local
PCSX2_LIGHTGUN_SITE = $(BR2_EXTERNAL_BATOCERA_PATH)/.hotr-sources/pcsx2-lightgun-src
PCSX2_LIGHTGUN_SITE_METHOD = local
PCSX2_LIGHTGUN_LICENSE = GPLv3
PCSX2_LIGHTGUN_LICENSE_FILE = COPYING.GPLv3
PCSX2_LIGHTGUN_SUPPORTS_IN_SOURCE_BUILD = NO

PCSX2_LIGHTGUN_EMULATOR_INFO = pcsx2-lightgun.pcsx2-lightgun.core.yml
$(eval $(call register,pcsx2-lightgun.emulator.yml))

PCSX2_LIGHTGUN_DEPENDENCIES += alsa-lib ecm fmt freetype host-clang host-libcurl kddockwidgets
PCSX2_LIGHTGUN_DEPENDENCIES += libaio libbacktrace libcurl libgtk3 libpcap libpng libsamplerate
PCSX2_LIGHTGUN_DEPENDENCIES += libsoundtouch plutosvg portaudio qt6base qt6svg qt6tools
PCSX2_LIGHTGUN_DEPENDENCIES += rapidyaml shaderc sdl3 webp wxwidgets xorgproto yaml-cpp zlib

# Use clang for performance (same as upstream pcsx2)
PCSX2_LIGHTGUN_CONF_OPTS += -DCMAKE_C_COMPILER=$(HOST_DIR)/bin/clang
PCSX2_LIGHTGUN_CONF_OPTS += -DCMAKE_CXX_COMPILER=$(HOST_DIR)/bin/clang++
PCSX2_LIGHTGUN_CONF_OPTS += -DCMAKE_EXE_LINKER_FLAGS="-lm -lstdc++"

PCSX2_LIGHTGUN_CONF_OPTS += -DCMAKE_BUILD_TYPE=Release
PCSX2_LIGHTGUN_CONF_OPTS += -DBUILD_SHARED_LIBS=OFF
PCSX2_LIGHTGUN_CONF_OPTS += -DENABLE_TESTS=OFF
PCSX2_LIGHTGUN_CONF_OPTS += -DUSE_SYSTEM_LIBS=AUTO
# The following flag is misleading and *needed* ON to avoid doing -march=native
PCSX2_LIGHTGUN_CONF_OPTS += -DDISABLE_ADVANCE_SIMD=ON

ifeq ($(BR2_PACKAGE_XORG7),y)
    PCSX2_LIGHTGUN_CONF_OPTS += -DX11_API=ON
else
    PCSX2_LIGHTGUN_CONF_OPTS += -DX11_API=OFF
endif

ifeq ($(BR2_PACKAGE_BATOCERA_WAYLAND),y)
    PCSX2_LIGHTGUN_CONF_OPTS += -DWAYLAND_API=ON
else
    PCSX2_LIGHTGUN_CONF_OPTS += -DWAYLAND_API=OFF
endif

ifeq ($(BR2_PACKAGE_HAS_LIBGL),y)
    PCSX2_LIGHTGUN_CONF_OPTS += -DUSE_OPENGL=ON
else
    PCSX2_LIGHTGUN_CONF_OPTS += -DUSE_OPENGL=OFF
endif

ifeq ($(BR2_PACKAGE_BATOCERA_VULKAN),y)
    PCSX2_LIGHTGUN_CONF_OPTS += -DUSE_VULKAN=ON
else
    PCSX2_LIGHTGUN_CONF_OPTS += -DUSE_VULKAN=OFF
endif

define PCSX2_LIGHTGUN_INSTALL_TARGET_CMDS
    # Install binary renamed to coexist with upstream pcsx2
    $(INSTALL) -m 0755 -D $(@D)/buildroot-build/bin/pcsx2-qt \
        $(TARGET_DIR)/usr/pcsx2-lightgun/bin/pcsx2-lightgun-qt
    cp -pr $(@D)/bin/resources $(TARGET_DIR)/usr/pcsx2-lightgun/bin/
    cp -pr $(@D)/buildroot-build/bin/translations $(TARGET_DIR)/usr/pcsx2-lightgun/bin/
    # use our SDL config
    rm -f $(TARGET_DIR)/usr/pcsx2-lightgun/bin/resources/game_controller_db.txt

    # MameOutputSender — must live next to the binary so PCSX2 can find it,
    # and also in /usr/bin for standalone use.
    $(INSTALL) -m 0755 \
        $(PCSX2_LIGHTGUN_PKGDIR)/MameOutputSender \
        $(TARGET_DIR)/usr/pcsx2-lightgun/bin/MameOutputSender
    $(INSTALL) -m 0755 \
        $(PCSX2_LIGHTGUN_PKGDIR)/MameOutputSender \
        $(TARGET_DIR)/usr/bin/MameOutputSender
endef

define PCSX2_LIGHTGUN_TEXTURES
    mkdir -p $(TARGET_DIR)/usr/pcsx2-lightgun/bin/resources/textures
    cp -pr $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/emulators/pcsx2/textures/ \
        $(TARGET_DIR)/usr/pcsx2-lightgun/bin/resources/
endef

define PCSX2_LIGHTGUN_PATCHES
    mkdir -p $(TARGET_DIR)/usr/share/batocera/datainit/bios/ps2
    $(HOST_DIR)/bin/curl -L \
        https://github.com/PCSX2/pcsx2_patches/releases/download/latest/patches.zip -o \
        $(TARGET_DIR)/usr/share/batocera/datainit/bios/ps2/patches.zip
endef

define PCSX2_LIGHTGUN_CROSSHAIRS
    mkdir -p $(TARGET_DIR)/usr/pcsx2-lightgun/bin/resources/crosshairs
    cp -pr $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/emulators/pcsx2/crosshairs/ \
        $(TARGET_DIR)/usr/pcsx2-lightgun/bin/resources/
endef

PCSX2_LIGHTGUN_POST_INSTALL_TARGET_HOOKS += PCSX2_LIGHTGUN_TEXTURES
PCSX2_LIGHTGUN_POST_INSTALL_TARGET_HOOKS += PCSX2_LIGHTGUN_PATCHES
PCSX2_LIGHTGUN_POST_INSTALL_TARGET_HOOKS += PCSX2_LIGHTGUN_CROSSHAIRS

$(eval $(cmake-package))
$(eval $(emulator-info-package))
