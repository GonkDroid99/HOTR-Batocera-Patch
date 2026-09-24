################################################################################
#
# duckstation-lightgun
#
# LightGun Edition fork of DuckStation with GunCon/Gun4IR/MameHooker support.
# Source lives at: /home/matt/duckstation-lightgun-src (symlink, no spaces)
#
################################################################################

DUCKSTATION_LIGHTGUN_VERSION = local
DUCKSTATION_LIGHTGUN_SITE = $(BR2_EXTERNAL_BATOCERA_PATH)/.hotr-sources/duckstation-lightgun-src
DUCKSTATION_LIGHTGUN_SITE_METHOD = local
DUCKSTATION_LIGHTGUN_LICENSE = GPLv2
DUCKSTATION_LIGHTGUN_SUPPORTS_IN_SOURCE_BUILD = NO

DUCKSTATION_LIGHTGUN_DEPENDENCIES += fmt boost ffmpeg libcurl ecm stenzek-shaderc
DUCKSTATION_LIGHTGUN_DEPENDENCIES += qt6base qt6tools qt6svg libbacktrace cpuinfo
DUCKSTATION_LIGHTGUN_DEPENDENCIES += spirv-cross libsoundtouch webp host-clang
DUCKSTATION_LIGHTGUN_DEPENDENCIES += duckstation-common

DUCKSTATION_LIGHTGUN_EMULATOR_INFO = duckstation-lightgun.duckstation.core.yml

# Use clang for performance (same as upstream duckstation)
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DCMAKE_C_COMPILER=$(HOST_DIR)/bin/clang
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DCMAKE_CXX_COMPILER=$(HOST_DIR)/bin/clang++
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DCMAKE_EXE_LINKER_FLAGS="-no-pie -lm -lstdc++"

DUCKSTATION_LIGHTGUN_CONF_OPTS += -DCMAKE_BUILD_TYPE=Release
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DBATOCERA=ON
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DBUILD_SHARED_LIBS=FALSE
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DBUILD_QT_FRONTEND=ON
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DSHADERC_INCLUDE_DIR=$(STAGING_DIR)/stenzek-shaderc/include
DUCKSTATION_LIGHTGUN_CONF_OPTS += -DSHADERC_LIBRARY=$(STAGING_DIR)/stenzek-shaderc/lib/libshaderc_shared.so

ifeq ($(BR2_PACKAGE_BATOCERA_WAYLAND),y)
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_WAYLAND=ON
    DUCKSTATION_LIGHTGUN_DEPENDENCIES += qt6wayland
else
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_WAYLAND=OFF
endif

ifeq ($(BR2_PACKAGE_XORG7),y)
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_X11=ON
else
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_X11=OFF
endif

ifeq ($(BR2_PACKAGE_VULKAN_HEADERS)$(BR2_PACKAGE_VULKAN_LOADER),yy)
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_VULKAN=ON
    DUCKSTATION_LIGHTGUN_DEPENDENCIES += vulkan-headers vulkan-loader
else
    DUCKSTATION_LIGHTGUN_CONF_OPTS += -DENABLE_VULKAN=OFF
endif

define DUCKSTATION_LIGHTGUN_INSTALL_TARGET_CMDS
    mkdir -p $(TARGET_DIR)/usr/bin
    mkdir -p $(TARGET_DIR)/usr/lib
    mkdir -p $(TARGET_DIR)/usr/share/duckstation-lightgun

    # Install Qt binary; rename to duckstation-lightgun-qt to coexist with upstream
    if [ -f $(@D)/buildroot-build/bin/duckstation-qt ]; then \
        $(INSTALL) -m 0755 $(@D)/buildroot-build/bin/duckstation-qt \
            $(TARGET_DIR)/usr/bin/duckstation-lightgun-qt; \
    fi
    if [ -f $(@D)/buildroot-build/bin/duckstation-nogui ]; then \
        $(INSTALL) -m 0755 $(@D)/buildroot-build/bin/duckstation-nogui \
            $(TARGET_DIR)/usr/bin/duckstation-lightgun-nogui; \
    fi
    cp -R $(@D)/buildroot-build/bin/resources \
        $(TARGET_DIR)/usr/share/duckstation-lightgun/
    rm -f $(TARGET_DIR)/usr/share/duckstation-lightgun/resources/gamecontrollerdb.txt

    # MameOutputSender — Python bridge: receives DuckStation's MameHooker signals
    # (via Unix named pipes) and forwards them to Hook of the Reaper (TCP 8000).
    # Replaces the .NET MameOutputSender which cannot run on Batocera.
    $(INSTALL) -m 0755 \
        $(BR2_EXTERNAL_BATOCERA_PATH)/package/batocera/emulators/duckstation-lightgun/MameOutputSender \
        $(TARGET_DIR)/usr/bin/MameOutputSender
endef

define DUCKSTATION_LIGHTGUN_TRANSLATIONS
    mkdir -p $(TARGET_DIR)/usr/share/duckstation-lightgun
    cp -R $(@D)/buildroot-build/bin/translations \
        $(TARGET_DIR)/usr/share/duckstation-lightgun/
endef

define DUCKSTATION_LIGHTGUN_TRANSLATIONS_DIR
    mkdir -p $(@D)/buildroot-build/bin/resources
endef

DUCKSTATION_LIGHTGUN_POST_INSTALL_TARGET_HOOKS += DUCKSTATION_LIGHTGUN_TRANSLATIONS
DUCKSTATION_LIGHTGUN_POST_CONFIGURE_HOOKS = DUCKSTATION_LIGHTGUN_TRANSLATIONS_DIR

$(eval $(cmake-package))
$(eval $(emulator-info-package))
