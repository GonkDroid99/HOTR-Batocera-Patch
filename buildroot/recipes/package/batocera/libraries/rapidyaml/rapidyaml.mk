################################################################################
# rapidyaml - PCSX2 LightGun dependency
################################################################################

RAPIDYAML_VERSION = b56567b0bd24e9ce7beb08d6950a5732f62f6e74
RAPIDYAML_SITE = https://github.com/biojppm/rapidyaml.git
RAPIDYAML_SITE_METHOD = git
RAPIDYAML_GIT_SUBMODULES = YES
RAPIDYAML_INSTALL_STAGING = YES
RAPIDYAML_INSTALL_TARGET = YES

RAPIDYAML_CONF_OPTS += -DBUILD_SHARED_LIBS=ON
RAPIDYAML_CONF_OPTS += -DRYML_BUILD_TESTS=OFF
RAPIDYAML_CONF_OPTS += -DRYML_BUILD_TOOLS=OFF
RAPIDYAML_CONF_OPTS += -DRYML_BUILD_BENCHMARKS=OFF
RAPIDYAML_CONF_OPTS += -DRYML_DEV=OFF

$(eval $(cmake-package))
