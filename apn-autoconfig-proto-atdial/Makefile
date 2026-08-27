include $(TOPDIR)/rules.mk

PKG_NAME:=apn-autoconfig-proto-atdial
PKG_VERSION:=0.15.3
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=DarthAnwalt
PKG_URL:=https://github.com/DarthAnwalt/openwrt-apn-autoconfig

include $(INCLUDE_DIR)/package.mk

define Package/apn-autoconfig-proto-atdial
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=netifd protocol for AT-dialed modems with no control channel
  DEPENDS:=+apn-autoconfig-modem +sms-tool +jsonfilter \
	+kmod-usb-net-rndis +kmod-usb-net-cdc-ether +kmod-usb-net-cdc-ncm
  PKGARCH:=all
endef

define Package/apn-autoconfig-proto-atdial/description
 netifd protocol `apn_atdial` for modems that expose no cdc-wdm control
 channel, such as a Fibocom FM350-GL in RNDIS composition. Their data path is
 an ordinary usbnet interface, so the host defines and activates the PDP
 context over an AT port and configures the address the modem reports; the
 modem serves no DHCP. Port resolution, identity and control-owner arbitration
 stay in apn-autoconfig-modem, and netifd remains the bearer owner. The Intel
 XMM path used by Fibocom L850/L860 is implemented but has not been validated
 on hardware; see docs/atdial-contract-v1.md.
endef

define Build/Compile
endef

define Package/apn-autoconfig-proto-atdial/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/apn-autoconfig-proto-atdial
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/apn-autoconfig-proto-atdial/LICENSE
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/lib/netifd/proto/apn_atdial.sh $(1)/lib/netifd/proto/apn_atdial.sh
	$(INSTALL_DIR) $(1)/usr/share/apn-autoconfig-proto-atdial
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-proto-atdial/atdial.sh \
		$(1)/usr/share/apn-autoconfig-proto-atdial/atdial.sh
	$(INSTALL_DATA) ./files/usr/share/apn-autoconfig-proto-atdial/quirks \
		$(1)/usr/share/apn-autoconfig-proto-atdial/quirks
endef

# Deliberately no service action of any kind.
#
# netifd reads /lib/netifd/proto/*.sh only when it starts, so this protocol is
# on disk and unknown to netifd until the network is restarted — and a restart
# takes every interface down for a moment. Doing that here would reach routers
# whose administrator is not present, is not expecting an interruption, and may
# be reachable only through the interfaces being restarted, including during an
# update that has nothing to do with modems.
#
# The restart therefore belongs to provisioning, where a user is configuring
# this modem and waiting for it; apn-autoconfig-modem performs it there, after
# reporting it, and verifies the registration afterwards. Until then a section
# on this protocol reports `available: false`, which is honest and reversible.
#
# An upgrade needs nothing at all: netifd spawns the handler from disk for every
# setup and teardown, so new dial logic takes effect at the next bring-up. Only
# the registration and the option schema wait for a restart.
define Package/apn-autoconfig-proto-atdial/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
exit 0
endef

define Package/apn-autoconfig-proto-atdial/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Scratch only. Never the AT port locks: that namespace is shared with
# apn-autoconfig-modem and apn-autoconfig-qmi, and a lock there may belong to a
# live operation in either of them. A stale one is already reclaimed by the
# live-owner check at the next attempt.
rm -f /tmp/apn-atdial.*.reply /tmp/apn-atdial.*.timeout 2>/dev/null
rm -f /tmp/apn-atdial-plmn.* /tmp/apn-atdial-auth.* 2>/dev/null
# Sections using this protocol are deliberately left alone. netifd owns the
# bearer, the section is the administrator's configuration, and removing a
# package is not a statement about which modem they want.
exit 0
endef

$(eval $(call BuildPackage,apn-autoconfig-proto-atdial))
