include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-esim
PKG_VERSION:=0.16.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT AND Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

# A private mbedTLS, statically linked into this package's ES9+ client and into
# nothing else. The source version and hash are pinned and updated with
# applicable upstream security fixes, independently of firmware upgrades.
# It carries exactly one reviewable compatibility patch.
#
# Why a copy exists at all: an SM-DP+ may send the GSMA CI root inside its own
# TLS chain, and two of the three live Consumer servers measured do. Stock
# mbedTLS cannot parse that root -- its certificatePolicies extension is
# critical and names a policy mbedTLS does not know -- and the SSL layer parses
# the peer chain with the ordinary parser before any authmode is consulted. So
# such a server is unreachable with verification and equally unreachable
# without it, and the relaxed parser mbedTLS offers applications cannot be
# reached from inside a handshake. See docs/work-items/P3-es9-trust-anchor.md.
#
# This is not the rejected libcurl-gnutls move. Nothing else links this copy,
# no system library is replaced, and every other package's TLS is untouched.
MBEDTLS_VERSION:=3.6.7
MBEDTLS_HASH:=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
MBEDTLS_NAME:=mbedtls-$(MBEDTLS_VERSION)

include $(INCLUDE_DIR)/package.mk

# After the include, because PKG_BUILD_DIR does not exist before it.
MBEDTLS_DIR:=$(PKG_BUILD_DIR)/$(MBEDTLS_NAME)

define Download/mbedtls
  URL:=https://github.com/Mbed-TLS/mbedtls/releases/download/$(MBEDTLS_NAME)
  FILE:=$(MBEDTLS_NAME).tar.bz2
  HASH:=$(MBEDTLS_HASH)
endef
$(eval $(call Download,mbedtls))

define Package/apn-autoconfig-esim
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Bounded eUICC inventory and guarded profile management
  # The LPA is a hard dependency because every read goes through it, and it is
  # this project's own pinned build rather than the official lpac package: the
  # official one takes secrets only in argv and disables TLS verification
  # unconditionally. See docs/upstream-esim-review.md.
  #
  # The narrow HTTPS bridge carries its own statically linked mbedTLS, so this
  # package has no TLS runtime dependency at all and replaces no provider. It
  # loads the system web roots -- hence ca-bundle -- and the packaged Consumer
  # CI roots.
  DEPENDS:=+uci +jsonfilter +apn-autoconfig-modem +apn-autoconfig-lpac +ca-bundle
endef

define Package/apn-autoconfig-esim/description
 Publishes what each SIM slot of each modem holds, which eUICC is in it,
 whether it can be reached right now and, when it cannot, what would have to
 change. It owns the transport that makes those answers real: the stdio bridge
 between the pinned LPA and a card, driven by code that has already resolved
 one unambiguous target, proved who owns the modem and taken the locks.

 Supported endpoints can download, rename, enable and disable profiles, switch
 supported SIM slots, and process pending notifications. Deletion requires an
 explicit expiring plan and confirmation for one disabled, unused profile.
 Existing profiles are never deleted as cleanup or rollback. Operations prove
 physical card identity and coordinate bounded access with the modem owner.

 An endpoint the backend could not read reports that it could not read it, with
 a reason from a fixed list. It never reports an empty profile list, an absent
 eUICC or a false capability as a way of filling a gap.
endef

define Package/apn-autoconfig-esim/conffiles
/etc/config/apn-autoconfig-esim
endef

# There is no upstream source for this package itself, so Prepare exists only to
# unpack and patch the vendored TLS library beside the tree's own files.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -C $(PKG_BUILD_DIR) -xjf $(DL_DIR)/$(MBEDTLS_NAME).tar.bz2
	cat $(CURDIR)/mbedtls/*.patch | \
		( cd $(MBEDTLS_DIR) && $(PATCH) -p1 --batch --forward )
	# Installed over upstream's default rather than selected with
	# MBEDTLS_CONFIG_FILE, so the library and the client that links it cannot
	# disagree about which configuration they were built against.
	$(CP) $(CURDIR)/mbedtls/apn-esim-mbedtls-config.h \
		$(MBEDTLS_DIR)/include/mbedtls/mbedtls_config.h
endef

# The vendored library's own include directory is named before $(TARGET_CPPFLAGS)
# so that a system mbedTLS in staging cannot supply a header to a binary that
# links the private archives.
define Build/Compile
	+$(MAKE) -C $(MBEDTLS_DIR)/library static \
		CC="$(TARGET_CC)" AR="$(TARGET_AR)" \
		CFLAGS="$(TARGET_CFLAGS) -ffunction-sections -fdata-sections"
	$(TARGET_CC) -I$(MBEDTLS_DIR)/include $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-std=c11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections \
		-o $(PKG_BUILD_DIR)/apn-autoconfig-esim-http \
		$(CURDIR)/files/usr/libexec/apn-autoconfig-esim-http.c \
		$(TARGET_LDFLAGS) -Wl,--gc-sections \
		$(MBEDTLS_DIR)/library/libmbedtls.a \
		$(MBEDTLS_DIR)/library/libmbedx509.a \
		$(MBEDTLS_DIR)/library/libmbedcrypto.a
	# The QMI UIM transport. No TLS, so none of the vendored library above: it
	# speaks three messages of one service to one card and links nothing but
	# libc.
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-std=c11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections \
		-o $(PKG_BUILD_DIR)/apn-autoconfig-esim-uim \
		$(CURDIR)/files/usr/libexec/apn-autoconfig-esim-uim.c \
		$(TARGET_LDFLAGS) -Wl,--gc-sections
endef

define Package/apn-autoconfig-esim/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/apn-autoconfig-esim
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/apn-autoconfig-esim/LICENSE
	$(INSTALL_DATA) $(MBEDTLS_DIR)/LICENSE \
		$(1)/usr/share/licenses/apn-autoconfig-esim/LICENSE.mbedtls
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/apn-autoconfig-esim $(1)/usr/sbin/apn-autoconfig-esim
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/apn-autoconfig-esim $(1)/etc/config/apn-autoconfig-esim
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/apn-autoconfig-esim-http $(1)/usr/libexec/apn-autoconfig-esim-http
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/apn-autoconfig-esim-uim $(1)/usr/libexec/apn-autoconfig-esim-uim
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-query $(1)/usr/libexec/apn-autoconfig-esim-query
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-control $(1)/usr/libexec/apn-autoconfig-esim-control
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-action $(1)/usr/libexec/apn-autoconfig-esim-action
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-inhibit $(1)/usr/libexec/apn-autoconfig-esim-inhibit
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig-esim/consumer-ci
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-esim/consumer-ci/*.pem \
		$(1)/usr/share/apn-autoconfig-esim/consumer-ci/
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-esim/consumer-ci/manifest.tsv \
		$(1)/usr/share/apn-autoconfig-esim/consumer-ci/manifest.tsv
endef

# No service, no hotplug rule, no boot action, and nothing that touches a modem
# at install time.
#
# This package installs a program. Every decision about which modem may be
# opened belongs to a caller that has resolved one, and a package script runs on
# routers whose administrator is not present -- which is exactly where an
# unprompted card probe would be least welcome. An offline image-root install
# must reach neither a service nor hardware.
define Package/apn-autoconfig-esim/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
exit 0
endef

define Package/apn-autoconfig-esim/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
exit 0
endef

define Package/apn-autoconfig-esim/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Removal stops new work without erasing state a live operation owns. Every
# path below is an exact project-owned name; never a wildcard over a shared
# root and never a recursive delete.
#
# The cache is volatile and derived, so it goes. The bridge run directories are
# deliberately left alone: each holds the FIFOs an invocation is reading from,
# and a live exchange must not have its channel removed underneath it. /var/run
# is tmpfs, so anything genuinely stale is gone at the next boot.
for state_file in /var/run/apn-autoconfig-esim/cache/*; do
	[ -f "$${state_file}" ] && rm -f "$${state_file}"
done
rmdir /var/run/apn-autoconfig-esim/cache 2>/dev/null || :
# The endpoint identity records, on the same terms as the cache: derived, and
# rewritten by the next read that needs them. They hold a handle and a
# four-character suffix, never the identifier those came from, but a removed
# package should not leave a record of which card was in which modem either.
# The `uim` and `bridge` directories below them are *not* touched: each holds
# one subdirectory per running invocation.
for state_file in /var/run/apn-autoconfig-esim/identity/*; do
	[ -f "$${state_file}" ] && rm -f "$${state_file}"
done
rmdir /var/run/apn-autoconfig-esim/identity 2>/dev/null || :
# Delete plans, on the same terms as the locks below: a token authorises
# destroying a subscription, so removal takes them away -- except one a live
# worker is holding, whose name carries that worker's PID.
for plan_file in /var/run/apn-autoconfig-esim/delete/*; do
	[ -f "$${plan_file}" ] || continue
	case "$${plan_file}" in
		*.claimed.*)
			plan_pid="$${plan_file##*.claimed.}"
			case "$${plan_pid}" in
				''|*[!0-9]*) : ;;
				*) kill -0 "$${plan_pid}" 2>/dev/null && continue ;;
			esac
		;;
	esac
	rm -f "$${plan_file}"
done
rmdir /var/run/apn-autoconfig-esim/delete 2>/dev/null || :
rmdir /var/run/apn-autoconfig-esim 2>/dev/null || :
# Locks: exact project-owned names, and only ones whose owner is provably gone.
# A lock held by a live operation is left where it is.
for lock_path in /var/lock/apn-autoconfig-esim.endpoint.*; do
	[ -e "$${lock_path}" ] || continue
	if [ -d "$${lock_path}" ]; then
		lock_pid="$$(cat "$${lock_path}/pid" 2>/dev/null || :)"
	else
		lock_pid="$$(sed -n '1p' "$${lock_path}" 2>/dev/null || :)"
	fi
	case "$${lock_pid}" in
		''|*[!0-9]*) : ;;
		*) kill -0 "$${lock_pid}" 2>/dev/null && continue ;;
	esac
	if [ -d "$${lock_path}" ]; then
		rm -f "$${lock_path}/pid"
		rmdir "$${lock_path}" 2>/dev/null || :
	else
		rm -f "$${lock_path}"
	fi
done
rm -f /etc/config/apn-autoconfig-esim \
	/etc/config/apn-autoconfig-esim.apk-new \
	/etc/config/apn-autoconfig-esim.apk-old
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig-esim))
