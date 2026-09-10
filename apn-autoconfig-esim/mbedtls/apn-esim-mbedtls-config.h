/*
 * The smallest mbedTLS that can make an ES9+ request.
 *
 * This configuration is not a general-purpose TLS build and must not be reused
 * as one. It is compiled into apn-autoconfig-esim's own HTTPS client, which
 * makes exactly one kind of request: an HTTPS POST to an SM-DP+, with the peer
 * verified against the packaged GSMA Consumer CI roots and the system web
 * roots. Nothing else links it.
 *
 * What the cipher set is derived from, so a later reader can check it rather
 * than trust it: SGP.22 requires an ES9+ client to support
 * TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 and
 * TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384, and permits the ECDHE_RSA
 * equivalents. All three live Consumer SM-DP+ this project has measured
 * negotiate ECDHE-ECDSA-AES256-GCM-SHA384 over TLS 1.2, or the TLS 1.3
 * equivalent. CBC modes, ChaCha20, static RSA, DHE, PSK and every server-side
 * path are therefore absent, and their absence is a decision rather than an
 * oversight.
 *
 * TLS 1.3 is kept because one of the three servers prefers it, and TLS 1.2 is
 * kept because SGP.22 makes it the mandatory floor.
 */

#ifndef APN_ESIM_MBEDTLS_CONFIG_H
#define APN_ESIM_MBEDTLS_CONFIG_H

/* Certificate validity is checked against the clock, so a router with no time
 * yet refuses rather than accepts. */
#define MBEDTLS_HAVE_TIME
#define MBEDTLS_HAVE_TIME_DATE

#define MBEDTLS_PLATFORM_C
#define MBEDTLS_FS_IO
#define MBEDTLS_ERROR_C
#define MBEDTLS_NET_C

/* Randomness: the platform entropy source plus CTR_DRBG. */
#define MBEDTLS_ENTROPY_C
#define MBEDTLS_CTR_DRBG_C

/* Symmetric: AES-GCM only. */
#define MBEDTLS_AES_C
#define MBEDTLS_GCM_C
#define MBEDTLS_CIPHER_C

/* Digests: SHA-256 and SHA-384, which the required suites and the certificate
 * signatures both use. SHA-224 and SHA-512 come with them. */
#define MBEDTLS_MD_C
/* SHA-1 is here to *read* legacy self-signed roots, not to trust anything
 * signed with it. Measured: without it, 25 of the system bundle's roots fail to
 * parse and `trust` reports them skipped, which silently narrows the
 * compatibility half of the trust set. mbedTLS's default certificate profile
 * still refuses SHA-1 when verifying a chain. */
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA224_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA384_C
#define MBEDTLS_SHA512_C

/* Asymmetric: ECDSA and ECDHE for the mandated suites; RSA because a peer or a
 * system root may be RSA, and because TLS 1.3 uses rsa_pss_rsae signatures. */
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_ECP_C
#define MBEDTLS_ECDH_C
#define MBEDTLS_ECDSA_C
#define MBEDTLS_RSA_C
#define MBEDTLS_PKCS1_V15
#define MBEDTLS_PKCS1_V21
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C

/* Curves: the two the RSP PKI uses, plus x25519 and P-521, which are what a
 * TLS 1.3 peer is most likely to offer beside them. */
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED
#define MBEDTLS_ECP_DP_SECP384R1_ENABLED
#define MBEDTLS_ECP_DP_SECP521R1_ENABLED
#define MBEDTLS_ECP_DP_CURVE25519_ENABLED

/* Encoding and X.509. CRLs are absent because the package neither carries nor
 * fetches one, which is what `apn-autoconfig-esim-query trust` reports. */
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_OID_C
#define MBEDTLS_BASE64_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C

/* TLS: client only, 1.2 and 1.3, with the peer certificate kept so a refusal
 * can say what was wrong with it. */
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_PROTO_TLS1_3
#define MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED

/* TLS 1.3 requires the PSA core and, for its key schedule, HKDF -- from which
 * mbedTLS derives the PSA_WANT_ALG_HKDF_* its own consistency check demands. */
#define MBEDTLS_PSA_CRYPTO_C
#define MBEDTLS_USE_PSA_CRYPTO
#define MBEDTLS_HKDF_C

/* build_info.h includes check_config.h after this file, so the consistency
 * checks run without being invoked here. */

#endif /* APN_ESIM_MBEDTLS_CONFIG_H */
