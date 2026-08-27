APN_PROVIDER_PACKAGE_DIR:=$(dir $(lastword $(MAKEFILE_LIST)))
include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-providers
PKG_VERSION:=$(strip $(shell cat '$(APN_PROVIDER_PACKAGE_DIR)VERSION'))
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0 AND CC-PDDC
PKG_LICENSE_FILES:=licenses/Apache-2.0.txt licenses/MBPI-CC-PD.txt
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

include $(INCLUDE_DIR)/package.mk

define Package/apn-autoconfig-providers
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Provider and APN database for APN Auto-Config
  PKGARCH:=all
endef

define Package/apn-autoconfig-providers/description
 Generated worldwide mobile provider and APN profiles for apn-autoconfig.
 The database can be upgraded independently from the program and LuCI.
endef

define Build/Compile
endef

define Package/apn-autoconfig-providers/install
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig/providers.tsv \
		$(1)/usr/share/apn-autoconfig/providers.tsv
endef

$(eval $(call BuildPackage,apn-autoconfig-providers))
