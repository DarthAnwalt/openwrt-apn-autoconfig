include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-modem
PKG_VERSION:=0.10.0
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
  DEPENDS:=+ubus +uci
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
rm -rf /var/run/apn-autoconfig-modem /var/lock/apn-autoconfig-modem*
rm -f /etc/config/apn-autoconfig-modem \
	/etc/config/apn-autoconfig-modem.apk-new \
	/etc/config/apn-autoconfig-modem.apk-old
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig-modem))
