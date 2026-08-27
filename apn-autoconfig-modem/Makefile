include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-modem
PKG_VERSION:=0.15.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

include $(INCLUDE_DIR)/package.mk

define Package/apn-autoconfig-modem
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Modem inventory, identity and control-owner arbitration
  DEPENDS:=+ubus +uci +jsonfilter +sms-tool
  PKGARCH:=all
endef

define Package/apn-autoconfig-modem/description
 POSIX-shell modem-control foundation for apn-autoconfig. Provides read-only
 modem inventory with stable hardware identity independent of volatile
 device names, explicit ModemManager/direct-control ownership state and a
 serialized per-modem operation coordinator. It does not implement APN
 policy, network provisioning, MBIM profile mutation or eSIM lifecycle; see
 docs/modem-contract-v1.md. Optional runtime backends (uqmi, sms-tool,
 mmcli) are detected, not required, so capability stays truthful.
endef

define Package/apn-autoconfig-modem/conffiles
/etc/config/apn-autoconfig-modem
endef

define Build/Compile
endef

define Package/apn-autoconfig-modem/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/apn-autoconfig-modem
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/apn-autoconfig-modem/LICENSE
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/apn-autoconfig-modem $(1)/usr/sbin/apn-autoconfig-modem
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/apn-autoconfig-modem $(1)/etc/config/apn-autoconfig-modem
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/apn-autoconfig-modem $(1)/etc/init.d/apn-autoconfig-modem
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) ./files/etc/hotplug.d/usb/50-apn-autoconfig-modem $(1)/etc/hotplug.d/usb/50-apn-autoconfig-modem
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-modem-boot $(1)/usr/libexec/apn-autoconfig-modem-boot
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-modem-action $(1)/usr/libexec/apn-autoconfig-modem-action
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-modem-query $(1)/usr/libexec/apn-autoconfig-modem-query
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-modem-control $(1)/usr/libexec/apn-autoconfig-modem-control
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-modem-inhibit $(1)/usr/libexec/apn-autoconfig-modem-inhibit
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig-modem
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-modem/quirks $(1)/usr/share/apn-autoconfig-modem/quirks
endef

# A live installation must discover hardware that was already present before
# the package existed. Offline image construction remains inert.
define Package/apn-autoconfig-modem/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/init.d/apn-autoconfig-modem ]; then
	/etc/init.d/apn-autoconfig-modem enable >/dev/null 2>&1 || exit 1
	/etc/init.d/apn-autoconfig-modem restart >/dev/null 2>&1 || exit 1
fi
exit 0
endef

# Removal restores administrative state only; discovery is read-only, so
# there is no netifd or profile baseline for this package to roll back.
define Package/apn-autoconfig-modem/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/init.d/apn-autoconfig-modem ]; then
	/etc/init.d/apn-autoconfig-modem stop >/dev/null 2>&1 || :
	/etc/init.d/apn-autoconfig-modem disable >/dev/null 2>&1 || :
fi
exit 0
endef

define Package/apn-autoconfig-modem/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Runtime state is ephemeral, but never remove a live operation lock during an
# uninstall. Clean regular registry files and provably stale locks only.
#
# Sections this package created are deliberately left in place: netifd owns the
# bearer, so they keep working after removal. Only their bookkeeping goes.
for state_file in /var/run/apn-autoconfig-modem/modems/*.tsv; do
	[ -f "$${state_file}" ] && rm -f "$${state_file}"
done
for state_file in /var/run/apn-autoconfig-modem/provisioning/*.tsv; do
	[ -f "$${state_file}" ] && rm -f "$${state_file}"
done
# AT port resolution cache. Regular state owned solely by this package, so it
# goes by exact prefix; the AT port *locks* deliberately do not, because that
# namespace is shared with apn-autoconfig-qmi and a stale one is already
# reclaimed by its live-owner check at the next attempt.
for state_file in /var/run/apn-autoconfig-modem/at-ports/port.* \
	/var/run/apn-autoconfig-modem/at-ports/selected.* \
	/var/run/apn-autoconfig-modem/at-ports/identity.* \
	/var/run/apn-autoconfig-modem/at-ports/imei.*; do
	[ -f "$${state_file}" ] && rm -f "$${state_file}"
done
rmdir /var/run/apn-autoconfig-modem/modems 2>/dev/null || :
rmdir /var/run/apn-autoconfig-modem/provisioning 2>/dev/null || :
rmdir /var/run/apn-autoconfig-modem/at-ports 2>/dev/null || :
rmdir /var/run/apn-autoconfig-modem 2>/dev/null || :
for lock_path in /var/lock/apn-autoconfig-modem.*; do
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
rm -f /etc/config/apn-autoconfig-modem \
	/etc/config/apn-autoconfig-modem.apk-new \
	/etc/config/apn-autoconfig-modem.apk-old
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig-modem))
