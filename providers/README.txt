The apn-autoconfig provider database, published for reuse.

  providers.tsv        the database; its own header records the format, the
                       version and the exact upstream revisions it was built
                       from
  NOTICE               attribution for the AOSP and GNOME MBPI sources, and
                       the changes made to them
  Apache-2.0.txt       the licence of the AOSP-derived portion
  MBPI-CC-PDDC.txt     the dedication covering the GNOME MBPI portion

Keep these four together when you redistribute the data: the Apache licence
asks that a recipient be given the licence and the notices, not a link to them.

This directory and the existing raw GitHub URL are permanent supported
addresses for format 2. Existing consumers do not have to migrate:
https://raw.githubusercontent.com/DarthAnwalt/openwrt-apn-autoconfig/main/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv

The data here comes from the provider package in the signed feed. For signed,
versioned updates, install apn-autoconfig-providers from the feed.
