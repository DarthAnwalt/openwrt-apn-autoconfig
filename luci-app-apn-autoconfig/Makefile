include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-apn-autoconfig
PKG_VERSION:=0.6.0_alpha1
PKG_RELEASE:=10
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=DarthAnwalt

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-apn-autoconfig
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for APN Auto-Config
  DEPENDS:=+luci-base +apn-autoconfig
  PKGARCH:=all
endef

define Package/luci-app-apn-autoconfig/description
 Status, safe background actions and configuration for apn-autoconfig.
endef

define Build/Compile
endef

define Package/luci-app-apn-autoconfig/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-app-apn-autoconfig
	$(INSTALL_DATA) ./LICENSE \
		$(1)/usr/share/licenses/luci-app-apn-autoconfig/LICENSE
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/network
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/network/apn-autoconfig.js \
		$(1)/www/luci-static/resources/view/network/apn-autoconfig.js
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-apn-autoconfig.json \
		$(1)/usr/share/luci/menu.d/luci-app-apn-autoconfig.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json
endef

$(eval $(call BuildPackage,luci-app-apn-autoconfig))
