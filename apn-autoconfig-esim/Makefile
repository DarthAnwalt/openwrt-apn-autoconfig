include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-esim
PKG_VERSION:=0.15.3
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

include $(INCLUDE_DIR)/package.mk

define Package/apn-autoconfig-esim
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Read-only eUICC and slot inventory
  # The LPA is a hard dependency because every read goes through it, and it is
  # this project's own pinned build rather than the official lpac package: the
  # official one takes secrets only in argv and disables TLS verification
  # unconditionally. See docs/upstream-esim-review.md.
  #
  # curl and ca-bundle are the HTTPS side of the bridge, which is this
  # project's request and not the LPA's. jsonfilter reads the LPA's own result
  # document; the bridge loop itself parses no JSON through a fork.
  DEPENDS:=+uci +jsonfilter +apn-autoconfig-modem +apn-autoconfig-lpac +curl +ca-bundle
  PKGARCH:=all
endef

define Package/apn-autoconfig-esim/description
 Publishes what each SIM slot of each modem holds, which eUICC is in it,
 whether it can be reached right now and, when it cannot, what would have to
 change. It owns the transport that makes those answers real: the stdio bridge
 between the pinned LPA and a card, driven by code that has already resolved
 one unambiguous target, proved who owns the modem and taken the locks.

 Strictly read-only in this release. No profile is downloaded, enabled,
 disabled, renamed or deleted, and no slot is ever changed by any path -- an
 eUICC in an inactive slot is reported as requiring a slot change and that is
 the whole of the answer. See docs/esim-contract-v1.md.

 An endpoint the backend could not read reports that it could not read it, with
 a reason from a fixed list. It never reports an empty profile list, an absent
 eUICC or a false capability as a way of filling a gap.
endef

define Package/apn-autoconfig-esim/conffiles
/etc/config/apn-autoconfig-esim
endef

define Build/Compile
endef

define Package/apn-autoconfig-esim/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/apn-autoconfig-esim
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/apn-autoconfig-esim/LICENSE
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/apn-autoconfig-esim $(1)/usr/sbin/apn-autoconfig-esim
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/apn-autoconfig-esim $(1)/etc/config/apn-autoconfig-esim
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-query $(1)/usr/libexec/apn-autoconfig-esim-query
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-control $(1)/usr/libexec/apn-autoconfig-esim-control
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-esim-action $(1)/usr/libexec/apn-autoconfig-esim-action
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
