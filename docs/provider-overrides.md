# Manual provider override provenance

`data/providers-overrides.tsv` is limited to corrections that are backed by an
operator-controlled public source or a documented real-network test. Operator
configuration values are factual references; copying descriptive text or page
layout is neither necessary nor permitted.

| Profile | Evidence | Last verified |
| --- | --- | --- |
| lifecell Ukraine, `internet` | Official lifecell roaming settings: https://roaming.lifecell.ua/en/; live roaming test described in `README.md` | 2026-07-17 |
| Kaufland Mobil, `internet.telekom` | Live WH3000 Pro test with a Kaufland Mobil SIM on the Telekom network, described in `README.md` | 2026-07-16 |
| Telekom Germany, `internet.telekom` | Telekom support documentation: https://telekomhilft.telekom.de/conversations/mobilfunk/liste-aller-telekom-mobilfunk-zugangspunkte-apns/66871edc4ae73561dae48c96; same live Telekom-network test | 2026-07-18 |
| Vodafone Germany, `web.vodafone.de` | Vodafone configuration guide: https://www.vodafone.de/featured/article/vodafone-apn-einstellungen-178757; local SIMon mobile/Vodafone test setup described in `README.md` | 2026-07-18 |

Before changing or adding a row, record the source URL or test conditions and
date here. Prefer the operator's own site. A community post alone should be
corroborated by a live test or another operator-controlled source.
