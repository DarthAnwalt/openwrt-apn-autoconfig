include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig
PKG_VERSION:=0.7.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT AND Apache-2.0
PKG_LICENSE_FILES:=LICENSE data/licenses/Apache-2.0.txt data/licenses/MBPI-CC-PD.txt
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

include $(INCLUDE_DIR)/package.mk

define Package/apn-autoconfig
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Automatic APN selection for ModemManager
  DEPENDS:=+ca-bundle +curl +modemmanager +netifd +ubus +uci +kmod-button-hotplug
  PKGARCH:=all
endef

define Package/apn-autoconfig/description
 POSIX-shell mobile profile detection and testing helper for OpenWrt
 ModemManager. It matches SIM identity against a worldwide local TSV database,
 verifies real Internet access, caches successful profiles per ICCID and safely
 rolls back failures.
endef

define Package/apn-autoconfig/conffiles
/etc/config/apn-autoconfig
endef

define Build/Compile
endef

define Package/apn-autoconfig/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/apn-autoconfig $(1)/usr/sbin/apn-autoconfig
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig/providers.tsv $(1)/usr/share/apn-autoconfig/providers.tsv
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/apn-autoconfig $(1)/etc/config/apn-autoconfig
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/apn-autoconfig $(1)/etc/init.d/apn-autoconfig
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-boot $(1)/usr/libexec/apn-autoconfig-boot
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-action $(1)/usr/libexec/apn-autoconfig-action
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-query $(1)/usr/libexec/apn-autoconfig-query
	$(INSTALL_BIN) ./files/usr/libexec/apn-autoconfig-control $(1)/usr/libexec/apn-autoconfig-control
	$(INSTALL_DIR) $(1)/etc/hotplug.d/button
	$(INSTALL_BIN) ./files/etc/hotplug.d/button/50-apn-autoconfig $(1)/etc/hotplug.d/button/50-apn-autoconfig
endef

# A real removal restores the mobile profile baseline first. A failed reset aborts
# deinstallation, leaving the package available for diagnosis and retry.
define Package/apn-autoconfig/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/init.d/apn-autoconfig ]; then
	/etc/init.d/apn-autoconfig stop >/dev/null 2>&1 || :
	/etc/init.d/apn-autoconfig disable >/dev/null 2>&1 || :
fi
if [ -x /usr/sbin/apn-autoconfig ]; then
	/usr/sbin/apn-autoconfig reset || {
		echo "APN reset failed; apn-autoconfig was not removed." >&2
		echo "Restore the APN manually or fix the interface, then retry apk del." >&2
		exit 1
	}
fi
action_state_dir="$$(uci -q get apn-autoconfig.main.action_state_dir 2>/dev/null || printf '%s' /tmp/apn-autoconfig-action)"
case "$${action_state_dir}" in
	/tmp/*) rm -rf "$${action_state_dir}" "$${action_state_dir}.start-lock" ;;
	*) echo "Runtime action state outside /tmp was not removed: $${action_state_dir}" >&2 ;;
esac
exit 0
endef

# Runtime cache and baseline are not package payload files, so remove them
# explicitly after a successful deinstallation. This project deliberately
# removes its UCI configuration too, including apk conflict remnants.
define Package/apn-autoconfig/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -rf /etc/apn-autoconfig
rm -f /etc/config/apn-autoconfig \
	/etc/config/apn-autoconfig.apk-new \
	/etc/config/apn-autoconfig.apk-old
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig))
