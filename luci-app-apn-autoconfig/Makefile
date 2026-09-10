include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-apn-autoconfig
PKG_VERSION:=0.16.0
PKG_RELEASE:=1
# Apache-2.0 arrives with jsQR, which is carried rather than fetched because
# the router this configures may have no internet at all when the page is open.
# See htdocs/luci-static/resources/apn-autoconfig/jsQR.PROVENANCE.txt.
PKG_LICENSE:=MIT AND Apache-2.0
PKG_LICENSE_FILES:=LICENSE htdocs/luci-static/resources/apn-autoconfig/jsQR.LICENSE
PKG_MAINTAINER:=DarthAnwalt

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-apn-autoconfig
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for APN Auto-Config
  DEPENDS:=+luci-base +apn-autoconfig +rpcd-mod-ucode
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
	$(INSTALL_DATA) ./htdocs/luci-static/resources/apn-autoconfig/jsQR.LICENSE \
		$(1)/usr/share/licenses/luci-app-apn-autoconfig/jsQR.LICENSE
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/network
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/network/apn-autoconfig.js \
		$(1)/www/luci-static/resources/view/network/apn-autoconfig.js
	# Read only when somebody chooses a picture to take a code from, never on
	# page load: it is a quarter of a megabyte and the page is measured in
	# hundreds of milliseconds.
	$(INSTALL_DIR) $(1)/www/luci-static/resources/apn-autoconfig
	$(INSTALL_DATA) ./htdocs/luci-static/resources/apn-autoconfig/jsQR.js \
		$(1)/www/luci-static/resources/apn-autoconfig/jsQR.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/apn-autoconfig/jsQR.PROVENANCE.txt \
		$(1)/www/luci-static/resources/apn-autoconfig/jsQR.PROVENANCE.txt
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-apn-autoconfig.json \
		$(1)/usr/share/luci/menu.d/luci-app-apn-autoconfig.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/apn-autoconfig \
		$(1)/usr/share/rpcd/ucode/apn-autoconfig
endef

$(eval $(call BuildPackage,luci-app-apn-autoconfig))
