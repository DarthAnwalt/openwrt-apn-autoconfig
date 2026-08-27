include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-lpac
# A vendored dependency keeps an upstream-derived source version plus a
# downstream package revision, per docs/architecture.md. This is lpac 2.3.0 with
# this project's patches, not a release of the suite, so it does not carry the
# suite version and is deliberately not checked against it.
PKG_VERSION:=2.3.0
PKG_RELEASE:=1

PKG_SOURCE:=lpac-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/estkme-group/lpac/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=661dffbd1e9e5732dab4a0bb0a9837d4906c8c66bd748bda262fe3e8d3e420f6
PKG_BUILD_DIR:=$(BUILD_DIR)/lpac-$(PKG_VERSION)

# The tree is not "GPLv3", and it is not what the official OpenWrt package
# declares either. REUSE.toml at this commit is authoritative and the per-file
# matrix is in docs/upstream-esim-review.md: AGPL-3.0-only for src/, driver/ and
# utils/, LGPL-2.1-only (dual with a commercial licence) for euicc/, and MIT for
# the vendored cJSON, the vendored dlfcn-win32, the build system and the
# QMI/MBIM drivers, which carry inline SPDX headers overriding the directory
# annotation. AGPL-3.0-only is the strongest term in the tree, so complying with
# it complies with the rest; what the matrix changes is which notices this
# package must reproduce.
PKG_LICENSE:=AGPL-3.0-only AND LGPL-2.1-only AND MIT
PKG_LICENSE_FILES:=LICENSES/AGPL-3.0-only.txt LICENSES/LGPL-2.1-only.txt LICENSES/MIT.txt \
	LICENSES/LicenseRef-ESTKME-Commercial.txt LICENSES/CC0-1.0.txt REUSE.toml
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/apn-autoconfig-lpac
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Pinned, namespaced LPA runtime for apn-autoconfig
  URL:=https://github.com/estkme-group/lpac
  # Deliberately no PROVIDES:=lpac and deliberately no conflict with it. This
  # package installs beside the official one, in either order, and neither
  # removal breaks the other.
endef

define Package/apn-autoconfig-lpac/description
 The eUICC LPA this project depends on, pinned to lpac 2.3.0 by source hash and
 carrying four reviewable downstream patches, with a launcher that decides
 whether the LPA may run at all.

 It is a private build because the official OpenWrt lpac package fails three
 requirements this project had already accepted: secrets reach it only through
 argv, its curl backend disables TLS certificate verification unconditionally
 with no way to re-enable it, and its AT backend cannot parse the Fibocom
 FM350-GL's AT+CCHO reply. The comparison that decided this is
 docs/upstream-esim-review.md.

 Nothing here replaces, provides or overwrites the official lpac, /usr/bin/lpac
 or /usr/lib/lpac. Both packages may be installed at once.

 The build ships the AT and stdio APDU backends and the stdio HTTP backend only.
 The stdio APDU backend needs a patch to work at all: upstream treats a
 successfully sent request as an error, so its connect fails before a single
 reply is read.
 The curl HTTP backend is not built, so this binary opens no socket and the
 HTTPS request is made by the caller with verification on; the uqmi APDU backend
 is not built, because it passes every APDU through the argv of a child process.
endef

# What is built, and what is deliberately not.
#
# LPAC_DYNAMIC_DRIVERS stays off, which is also what the official package does:
# the drivers are linked in and there is no plugin directory. That is the whole
# of this package's answer to OpenWrt stripping RUNPATH — there is nothing to
# discover, so discovery cannot fail. The fork that turns dynamic drivers on
# acquired the problem and then had to write a loader patch for it.
CMAKE_OPTIONS += \
	-DLPAC_WITH_APDU_PCSC=OFF \
	-DLPAC_WITH_APDU_AT=ON \
	-DLPAC_WITH_APDU_QMI=OFF \
	-DLPAC_WITH_APDU_QMI_QRTR=OFF \
	-DLPAC_WITH_APDU_MBIM=OFF \
	-DLPAC_WITH_APDU_GBINDER=OFF \
	-DLPAC_WITH_HTTP_CURL=OFF

define Package/apn-autoconfig-lpac/install
	# Namespaced below this project's own libexec. Nothing lands in /usr/bin or
	# /usr/lib, where the official package keeps a wrapper and a binary; one of
	# those is a file where a replacement wants a directory, and a package that
	# tried to take it over would have to delete the other package's binary.
	$(INSTALL_DIR) $(1)/usr/libexec/apn-autoconfig-lpac
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/lpac $(1)/usr/libexec/apn-autoconfig-lpac/lpac
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-lpac/lpac-run \
		$(1)/usr/libexec/apn-autoconfig-lpac/lpac-run

	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig-lpac
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-lpac/at-apdu-models \
		$(1)/usr/share/apn-autoconfig-lpac/at-apdu-models

	# The complete corresponding source, and the exact patches applied to it.
	# The pinned archive is 173 KB; carrying it is what makes the AGPL
	# obligation discharged by the package itself rather than by a promise made
	# somewhere else, and it is what lets the APK inspection check the claim
	# instead of trusting it.
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig-lpac/source
	$(INSTALL_DATA) $(DL_DIR)/$(PKG_SOURCE) $(1)/usr/share/apn-autoconfig-lpac/source/$(PKG_SOURCE)
	$(INSTALL_DATA) ./patches/0001-profile-download-accept-the-download-parameters-on-a.patch \
		$(1)/usr/share/apn-autoconfig-lpac/source/
	$(INSTALL_DATA) ./patches/0002-driver-at-accept-a-bare-decimal-AT-CCHO-response.patch \
		$(1)/usr/share/apn-autoconfig-lpac/source/
	$(INSTALL_DATA) ./patches/0003-driver-at-stop-closing-logical-channels-this-process.patch \
		$(1)/usr/share/apn-autoconfig-lpac/source/
	$(INSTALL_DATA) ./patches/0004-driver-at-bound-every-read-with-a-deadline-and-notic.patch \
		$(1)/usr/share/apn-autoconfig-lpac/source/
	$(INSTALL_DATA) ./patches/0005-driver-stdio-treat-a-sent-request-as-success.patch \
		$(1)/usr/share/apn-autoconfig-lpac/source/

	$(INSTALL_DIR) $(1)/usr/share/licenses/apn-autoconfig-lpac
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSES/AGPL-3.0-only.txt \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/AGPL-3.0-only.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSES/LGPL-2.1-only.txt \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/LGPL-2.1-only.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSES/MIT.txt \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/MIT.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSES/LicenseRef-ESTKME-Commercial.txt \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/LicenseRef-ESTKME-Commercial.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSES/CC0-1.0.txt \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/CC0-1.0.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/REUSE.toml \
		$(1)/usr/share/licenses/apn-autoconfig-lpac/REUSE.toml
	$(INSTALL_DATA) ./NOTICE $(1)/usr/share/licenses/apn-autoconfig-lpac/NOTICE
endef

# No service, no hotplug rule, no boot action, and nothing that touches a modem.
#
# This package installs a program and a launcher. Every decision about which
# modem may be opened belongs to a caller that has resolved one, and a package
# script runs on routers whose administrator is not present — which is exactly
# where an unprompted card probe would be least welcome.
define Package/apn-autoconfig-lpac/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
exit 0
endef

define Package/apn-autoconfig-lpac/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# The runtime directory is deliberately left alone. It holds one directory per
# running invocation, each containing a FIFO that invocation is reading from, and
# a live operation's channel must not be removed underneath it. /var/run is
# tmpfs, so anything genuinely stale is gone at the next boot, and the traps in
# lpac-run remove each directory as its own invocation ends.
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig-lpac))
