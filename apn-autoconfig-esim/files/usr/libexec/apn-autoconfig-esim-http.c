/*
 * Narrow ES9+ HTTPS transport for apn-autoconfig-esim.
 *
 * This is intentionally not a general HTTP client: one HTTPS POST, no
 * redirects, no proxy, no cookies, bounded request and response bodies.  The
 * normal path verifies hostname and chain against the union of OpenWrt's web
 * roots and the two packaged live Consumer RSP roots.  The latter contain a
 * critical GSMA certificate policy which mbedTLS does not interpret, so only
 * those exact, sha256-pinned DER objects are parsed with an extension callback.
 * The callback is never used for a certificate received from the peer.
 *
 * Exit codes are part of the shell bridge contract:
 *   60 unknown issuer / chain not rooted in the configured trust set
 *   61 hostname mismatch
 *   62 certificate expired or not yet valid
 *   63 certificate revoked (when a configured CRL reports it)
 *   64 other certificate verification failure
 *   65 local trust store unavailable or invalid
 *   66 the peer's own certificate chain could not be parsed at all
 */

#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include <mbedtls/base64.h>
#include <mbedtls/build_info.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/oid.h>
#include <mbedtls/sha256.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#if defined(MBEDTLS_USE_PSA_CRYPTO)
#include <psa/crypto.h>
#endif

#ifndef SYSTEM_CA_FILE
#define SYSTEM_CA_FILE "/etc/ssl/certs/ca-certificates.crt"
#endif
#ifndef CONSUMER_CA_DIR
#define CONSUMER_CA_DIR "/usr/share/apn-autoconfig-esim/consumer-ci"
#endif
#define MAX_REQUEST_BODY (1024U * 1024U)
#define MAX_RESPONSE_BODY (8U * 1024U * 1024U)
#define MAX_HEADER_BLOCK (32U * 1024U)
#define MAX_FORWARD_HEADERS 32
#define IO_BUFFER 4096
#define EXIT_USAGE_ERROR 2
#define EXIT_TRANSPORT_ERROR 3
#define EXIT_UNTRUSTED 60
#define EXIT_HOSTNAME 61
#define EXIT_TIME 62
#define EXIT_REVOKED 63
#define EXIT_VERIFY_OTHER 64
#define EXIT_TRUST_STORE 65
#define EXIT_CHAIN_UNPARSEABLE 66

/* mbedtls_ssl_get_verify_result() answers this when it has nothing to report:
 * a handshake that ended before verification ran, or one whose session is
 * already gone. Every bit is set, CN_MISMATCH included, so reading it as a set
 * of verdicts turns "nothing is known" into a confident hostname refusal. */
#define VERIFY_RESULT_UNKNOWN 0xFFFFFFFFU

struct anchor_spec {
    const char *key_id;
    const char *name;
    const char *filename;
    unsigned char sha256[32];
};

static const struct anchor_spec anchors[] = {
    {
        "81370f5125d0b1d408d4c3b232e6d25e795bebfb",
        "GSM Association - RSP2 Root CI1",
        CONSUMER_CA_DIR "/81370f5125d0b1d408d4c3b232e6d25e795bebfb.pem",
        { 0x5e,0x3e,0x91,0xfd,0x45,0x43,0x27,0xc3,0xaf,0x5d,0x32,0xa7,0xa7,0x3b,0xbc,0x59,
          0xfe,0x43,0xaa,0x7d,0x85,0xfd,0x32,0xd5,0xdb,0x44,0x42,0x3f,0x80,0xa5,0x6b,0xb3 }
    },
    {
        "4c27967ad20c14b391e9601e41e604ad57c0222f",
        "OISTE GSMA CI G1",
        CONSUMER_CA_DIR "/4c27967ad20c14b391e9601e41e604ad57c0222f.pem",
        { 0x9c,0x9f,0xa2,0xe9,0x46,0x02,0xc2,0x60,0x13,0x71,0x22,0xd9,0x70,0x4d,0x79,0x99,
          0x3a,0x6e,0xf6,0xd0,0x67,0xce,0x09,0x99,0xec,0x2f,0x4c,0x10,0x9d,0xd7,0xa1,0xa2 }
    }
};

struct parsed_url {
    char host[256];
    char port[6];
    char authority[320];
    const char *path;
};

struct tls_stream {
    mbedtls_ssl_context *ssl;
    const unsigned char *prefix;
    size_t prefix_len;
    size_t prefix_pos;
};

static void report_mbedtls(const char *what, int rc)
{
    char detail[128];
    mbedtls_strerror(rc, detail, sizeof(detail));
    fprintf(stderr, "apn-autoconfig-esim-http: %s: %s\n", what, detail);
}

static int read_file(const char *path, size_t limit, unsigned char **out, size_t *out_len)
{
    FILE *fp = NULL;
    struct stat st;
    unsigned char *buf = NULL;
    size_t got;

    if (stat(path, &st) != 0 || st.st_size < 0 || (uintmax_t) st.st_size > limit)
        return -1;
    fp = fopen(path, "rb");
    if (fp == NULL)
        return -1;
    buf = malloc((size_t) st.st_size + 1U);
    if (buf == NULL) {
        fclose(fp);
        return -1;
    }
    got = fread(buf, 1, (size_t) st.st_size, fp);
    if (fclose(fp) != 0 || got != (size_t) st.st_size) {
        free(buf);
        return -1;
    }
    buf[got] = '\0';
    *out = buf;
    *out_len = got;
    return 0;
}

static int pem_to_der(const char *path, unsigned char **der, size_t *der_len)
{
    static const char begin[] = "-----BEGIN CERTIFICATE-----";
    static const char end[] = "-----END CERTIFICATE-----";
    unsigned char *pem = NULL, *clean = NULL, *decoded = NULL;
    size_t pem_len = 0, clean_len = 0, needed = 0, decoded_len = 0;
    char *first, *last, *p;
    int rc = -1;

    if (read_file(path, 16384, &pem, &pem_len) != 0)
        goto done;
    first = strstr((char *) pem, begin);
    if (first == NULL)
        goto done;
    first += sizeof(begin) - 1;
    last = strstr(first, end);
    if (last == NULL)
        goto done;
    clean = malloc((size_t) (last - first) + 1U);
    if (clean == NULL)
        goto done;
    for (p = first; p < last; p++) {
        if (!isspace((unsigned char) *p))
            clean[clean_len++] = (unsigned char) *p;
    }
    if (clean_len == 0)
        goto done;
    if (mbedtls_base64_decode(NULL, 0, &needed, clean, clean_len) != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL)
        goto done;
    decoded = malloc(needed);
    if (decoded == NULL)
        goto done;
    if (mbedtls_base64_decode(decoded, needed, &decoded_len, clean, clean_len) != 0)
        goto done;
    *der = decoded;
    *der_len = decoded_len;
    decoded = NULL;
    rc = 0;
done:
    free(decoded);
    free(clean);
    free(pem);
    return rc;
}

/* Only exact sha256-pinned local anchors reach this callback. */
static int consumer_anchor_extension(void *ctx, const mbedtls_x509_crt *crt,
                                     const mbedtls_x509_buf *oid, int critical,
                                     const unsigned char *p, const unsigned char *end)
{
    (void) ctx;
    (void) crt;
    (void) p;
    (void) end;
    if (critical && MBEDTLS_OID_CMP(MBEDTLS_OID_CERTIFICATE_POLICIES, oid) == 0)
        return 0;
    return MBEDTLS_ERR_X509_INVALID_EXTENSIONS;
}

static int load_consumer_anchor(mbedtls_x509_crt *chain, const struct anchor_spec *spec)
{
    unsigned char *der = NULL;
    size_t der_len = 0;
    unsigned char digest[32];
    int rc;

    if (pem_to_der(spec->filename, &der, &der_len) != 0)
        return -1;
    rc = mbedtls_sha256(der, der_len, digest, 0);
    if (rc != 0 || memcmp(digest, spec->sha256, sizeof(digest)) != 0) {
        free(der);
        return -1;
    }
    rc = mbedtls_x509_crt_parse_der_with_ext_cb(chain, der, der_len, 1,
                                                 consumer_anchor_extension, NULL);
    free(der);
    return rc;
}

static int load_trust(mbedtls_x509_crt *chain, int *system_skipped)
{
    size_t i;
    int rc;

    rc = mbedtls_x509_crt_parse_file(chain, SYSTEM_CA_FILE);
    if (rc < 0) {
        report_mbedtls("cannot load the system CA bundle", rc);
        return -1;
    }
    *system_skipped = rc;
    for (i = 0; i < sizeof(anchors) / sizeof(anchors[0]); i++) {
        rc = load_consumer_anchor(chain, &anchors[i]);
        if (rc != 0) {
            if (rc < 0)
                report_mbedtls("cannot load a packaged Consumer CI anchor", rc);
            else
                fprintf(stderr, "apn-autoconfig-esim-http: packaged Consumer CI anchor is invalid\n");
            return -1;
        }
    }
    return 0;
}

static void print_hex(const unsigned char *p, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
        printf("%02x", p[i]);
}

static int inspect_trust(void)
{
    mbedtls_x509_crt chain;
    int skipped = 0, ok;
    size_t i;

    mbedtls_x509_crt_init(&chain);
    ok = load_trust(&chain, &skipped) == 0;
    printf("{\"version\":\"v1\",\"ready\":%s,\"system_ca_bundle\":\"%s\","
           "\"system_ca_skipped\":%d,\"revocation_checked\":false,\"consumer_ci\":[",
           ok ? "true" : "false", SYSTEM_CA_FILE, skipped);
    for (i = 0; i < sizeof(anchors) / sizeof(anchors[0]); i++) {
        if (i != 0)
            putchar(',');
        printf("{\"key_id\":\"%s\",\"name\":\"%s\",\"sha256_der\":\"",
               anchors[i].key_id, anchors[i].name);
        print_hex(anchors[i].sha256, sizeof(anchors[i].sha256));
        printf("\"}");
    }
    printf("]}\n");
    mbedtls_x509_crt_free(&chain);
    return ok ? 0 : EXIT_TRUST_STORE;
}

static int parse_port(const char *s, size_t n)
{
    unsigned long port = 0;
    size_t i;
    if (n == 0 || n > 5)
        return -1;
    for (i = 0; i < n; i++) {
        if (!isdigit((unsigned char) s[i]))
            return -1;
        port = port * 10U + (unsigned long) (s[i] - '0');
    }
    return port >= 1 && port <= 65535 ? 0 : -1;
}

static int parse_url(const char *url, struct parsed_url *out)
{
    const char *authority, *authority_end, *path, *host_start, *host_end, *port = NULL;
    size_t authority_len, host_len, port_len = 0, i;

    if (strncmp(url, "https://", 8) != 0)
        return -1;
    authority = url + 8;
    authority_end = authority + strcspn(authority, "/?#");
    authority_len = (size_t) (authority_end - authority);
    if (authority_len == 0 || authority_len >= sizeof(out->authority) ||
        memchr(authority, '@', authority_len) != NULL)
        return -1;
    memcpy(out->authority, authority, authority_len);
    out->authority[authority_len] = '\0';
    path = authority_end;
    if (*path == '#')
        return -1;
    if (*path == '\0')
        out->path = "/";
    else if (*path == '?')
        out->path = path - 1; /* fixed below by rejecting this rare shape */
    else
        out->path = path;
    if (*path == '?')
        return -1;
    if (strchr(out->path, '#') != NULL)
        return -1;
    for (i = 0; url[i] != '\0'; i++) {
        unsigned char c = (unsigned char) url[i];
        if (c <= 0x20 || c == 0x7f)
            return -1;
    }
    host_start = authority;
    if (*host_start == '[') {
        host_start++;
        host_end = memchr(host_start, ']', authority_len - 1U);
        if (host_end == NULL || host_end == host_start)
            return -1;
        if (host_end + 1 < authority_end) {
            if (host_end[1] != ':')
                return -1;
            port = host_end + 2;
            port_len = (size_t) (authority_end - port);
        }
    } else {
        const char *colon = memchr(authority, ':', authority_len);
        host_end = colon != NULL ? colon : authority_end;
        if (colon != NULL) {
            if (memchr(colon + 1, ':', (size_t) (authority_end - colon - 1)) != NULL)
                return -1;
            port = colon + 1;
            port_len = (size_t) (authority_end - port);
        }
    }
    host_len = (size_t) (host_end - host_start);
    if (host_len == 0 || host_len >= sizeof(out->host))
        return -1;
    memcpy(out->host, host_start, host_len);
    out->host[host_len] = '\0';
    if (port != NULL) {
        if (parse_port(port, port_len) != 0)
            return -1;
        memcpy(out->port, port, port_len);
        out->port[port_len] = '\0';
    } else {
        strcpy(out->port, "443");
    }
    return 0;
}

static int header_name_equal(const char *header, const char *name)
{
    const char *colon = strchr(header, ':');
    size_t i, n;
    if (colon == NULL)
        return 0;
    n = (size_t) (colon - header);
    if (n != strlen(name))
        return 0;
    for (i = 0; i < n; i++) {
        if (tolower((unsigned char) header[i]) != tolower((unsigned char) name[i]))
            return 0;
    }
    return 1;
}

static int valid_forward_header(const char *header)
{
    const char *colon = strchr(header, ':');
    const unsigned char *p;
    if (colon == NULL || colon == header)
        return 0;
    for (p = (const unsigned char *) header; *p != '\0'; p++) {
        if (*p == '\r' || *p == '\n' || *p == 0x7f || (*p < 0x20 && *p != '\t'))
            return 0;
    }
    for (p = (const unsigned char *) header; p < (const unsigned char *) colon; p++) {
        if (!(isalnum(*p) || strchr("!#$%&'*+-.^_`|~", *p) != NULL))
            return 0;
    }
    if (header_name_equal(header, "Host") || header_name_equal(header, "Content-Length") ||
        header_name_equal(header, "Connection") || header_name_equal(header, "Transfer-Encoding"))
        return 0;
    return 1;
}

static int ssl_write_all(mbedtls_ssl_context *ssl, const unsigned char *buf, size_t len)
{
    while (len != 0) {
        int rc = mbedtls_ssl_write(ssl, buf, len);
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (rc <= 0)
            return rc == 0 ? MBEDTLS_ERR_SSL_CONN_EOF : rc;
        buf += (size_t) rc;
        len -= (size_t) rc;
    }
    return 0;
}

static int stream_read(struct tls_stream *stream, unsigned char *buf, size_t len)
{
    if (stream->prefix_pos < stream->prefix_len) {
        size_t available = stream->prefix_len - stream->prefix_pos;
        if (len > available)
            len = available;
        memcpy(buf, stream->prefix + stream->prefix_pos, len);
        stream->prefix_pos += len;
        return (int) len;
    }
    for (;;) {
        int rc = mbedtls_ssl_read(stream->ssl, buf, len);
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
            return 0;
        return rc;
    }
}

static int stream_exact(struct tls_stream *stream, unsigned char *buf, size_t len)
{
    while (len != 0) {
        int rc = stream_read(stream, buf, len);
        if (rc <= 0)
            return -1;
        buf += (size_t) rc;
        len -= (size_t) rc;
    }
    return 0;
}

static int stream_line(struct tls_stream *stream, char *line, size_t cap)
{
    size_t n = 0;
    unsigned char c;
    while (n + 1U < cap) {
        if (stream_exact(stream, &c, 1) != 0)
            return -1;
        if (c == '\0')
            return -1;
        line[n++] = (char) c;
        if (n >= 2 && line[n - 2] == '\r' && line[n - 1] == '\n') {
            line[n - 2] = '\0';
            return 0;
        }
    }
    return -1;
}

static int copy_exact_body(struct tls_stream *stream, FILE *out, size_t len)
{
    unsigned char buf[IO_BUFFER];
    while (len != 0) {
        size_t want = len < sizeof(buf) ? len : sizeof(buf);
        if (stream_exact(stream, buf, want) != 0 || fwrite(buf, 1, want, out) != want)
            return -1;
        len -= want;
    }
    return 0;
}

static int copy_chunked_body(struct tls_stream *stream, FILE *out)
{
    char line[1024];
    unsigned char crlf[2];
    size_t total = 0;
    for (;;) {
        char *endptr;
        unsigned long long chunk;
        if (stream_line(stream, line, sizeof(line)) != 0)
            return -1;
        if (!isxdigit((unsigned char) line[0]))
            return -1;
        errno = 0;
        chunk = strtoull(line, &endptr, 16);
        if (errno != 0 || endptr == line || (*endptr != '\0' && *endptr != ';') ||
            chunk > MAX_RESPONSE_BODY || total > MAX_RESPONSE_BODY - (size_t) chunk)
            return -1;
        if (chunk == 0) {
            size_t trailers = 0;
            do {
                if (stream_line(stream, line, sizeof(line)) != 0)
                    return -1;
                trailers += strlen(line) + 2;
                if (trailers > MAX_HEADER_BLOCK)
                    return -1;
            } while (line[0] != '\0');
            return 0;
        }
        if (copy_exact_body(stream, out, (size_t) chunk) != 0 ||
            stream_exact(stream, crlf, sizeof(crlf)) != 0 ||
            crlf[0] != '\r' || crlf[1] != '\n')
            return -1;
        total += (size_t) chunk;
    }
}

static int copy_to_close(struct tls_stream *stream, FILE *out)
{
    unsigned char buf[IO_BUFFER];
    size_t total = 0;
    for (;;) {
        int rc = stream_read(stream, buf, sizeof(buf));
        if (rc == 0)
            return 0;
        if (rc < 0 || total > MAX_RESPONSE_BODY - (size_t) rc ||
            fwrite(buf, 1, (size_t) rc, out) != (size_t) rc)
            return -1;
        total += (size_t) rc;
    }
}

static int parse_response_headers(char *headers, int *status, int *chunked,
                                  int *has_length, size_t *content_length)
{
    char *line, *next;
    unsigned int code;
    if (strlen(headers) < 12 || strncmp(headers, "HTTP/1.", 7) != 0 ||
        (headers[7] != '0' && headers[7] != '1') || headers[8] != ' ' ||
        headers[9] < '1' || headers[9] > '5' ||
        !isdigit((unsigned char) headers[10]) || !isdigit((unsigned char) headers[11]) ||
        (headers[12] != ' ' && headers[12] != '\r'))
        return -1;
    code = (unsigned int) ((headers[9] - '0') * 100 +
                          (headers[10] - '0') * 10 + headers[11] - '0');
    *status = (int) code;
    *chunked = 0;
    *has_length = 0;
    *content_length = 0;
    line = strstr(headers, "\r\n");
    if (line == NULL)
        return -1;
    line += 2;
    while (*line != '\0') {
        char *colon;
        next = strstr(line, "\r\n");
        if (next == NULL)
            return -1;
        *next = '\0';
        if (*line == '\0')
            break;
        colon = strchr(line, ':');
        if (colon == NULL)
            return -1;
        *colon++ = '\0';
        while (*colon == ' ' || *colon == '\t')
            colon++;
        if (strcasecmp(line, "Transfer-Encoding") == 0) {
            char *end = colon + strlen(colon);
            while (end > colon && (end[-1] == ' ' || end[-1] == '\t'))
                *--end = '\0';
            /* This narrow client decodes only one chunked transfer coding. */
            if (*chunked || strcasecmp(colon, "chunked") != 0)
                return -1;
            *chunked = 1;
        } else if (strcasecmp(line, "Content-Length") == 0) {
            char *endptr;
            unsigned long long value;
            if (!isdigit((unsigned char) *colon))
                return -1;
            errno = 0;
            value = strtoull(colon, &endptr, 10);
            while (*endptr == ' ' || *endptr == '\t')
                endptr++;
            if (errno != 0 || endptr == colon || *endptr != '\0' || value > MAX_RESPONSE_BODY)
                return -1;
            if (*has_length && *content_length != (size_t) value)
                return -1;
            *has_length = 1;
            *content_length = (size_t) value;
        }
        line = next + 2;
    }
    if (*chunked && *has_length)
        return -1;
    return 0;
}

/* The peer's own chain could not be parsed, which is a different thing from a
 * chain that parsed and then failed to validate. mbedtls_ssl parses the peer
 * chain before it consults the authmode, so no verification setting -- not even
 * the consented unverified one -- changes this outcome, and offering a retry
 * after it would be offering something that cannot work. Measured on the
 * reference router: a live SM-DP+ that sends the GSMA CI root alongside its
 * leaf produces exactly this, because the ordinary parser refuses that root's
 * critical certificatePolicies extension. The relaxed parser this project uses
 * for its own anchors is deliberately unreachable here.
 *
 * X.509 module errors occupy 0x2000..0x2FFF, and a low-level ASN.1 code may be
 * added to the high-level one, so the low seven bits are masked before the one
 * value that means validation rather than parsing is excluded. */
static int is_chain_parse_error(int mrc)
{
    unsigned int code;

    if (mrc >= 0)
        return 0;
    code = (unsigned int) -mrc;
    if (code < 0x2000U || code >= 0x3000U)
        return 0;
    return (code & ~0x7FU) != (unsigned int) -MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
}

static int verification_exit(uint32_t flags)
{
    if ((flags & MBEDTLS_X509_BADCERT_CN_MISMATCH) != 0)
        return EXIT_HOSTNAME;
    if ((flags & (MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE)) != 0)
        return EXIT_TIME;
    if ((flags & MBEDTLS_X509_BADCERT_REVOKED) != 0)
        return EXIT_REVOKED;
    if ((flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) != 0 &&
        (flags & ~(uint32_t) MBEDTLS_X509_BADCERT_NOT_TRUSTED) == 0)
        return EXIT_UNTRUSTED;
    return EXIT_VERIFY_OTHER;
}

static int https_post(const struct parsed_url *url, const char *body_path,
                      const char *output_path, const char **forward_headers,
                      int forward_count, unsigned int timeout_seconds, int unverified)
{
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config config;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_entropy_context entropy;
    mbedtls_x509_crt trust;
    unsigned char *body = NULL, *response_headers = NULL;
    size_t body_len = 0, header_len = 0, body_prefix_len = 0;
    char *request_headers = NULL;
    size_t request_cap = MAX_HEADER_BLOCK, request_len = 0;
    FILE *output = NULL;
    int rc = EXIT_TRANSPORT_ERROR, mrc, i, system_skipped = 0;
    int http_status = 0, chunked = 0, has_length = 0;
    size_t content_length = 0;
    struct tls_stream stream;
    static const char personalisation[] = "apn-autoconfig-esim-http-v1";

    mbedtls_net_init(&net);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&config);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_entropy_init(&entropy);
    mbedtls_x509_crt_init(&trust);

    if (read_file(body_path, MAX_REQUEST_BODY, &body, &body_len) != 0) {
        fprintf(stderr, "apn-autoconfig-esim-http: request body is unavailable or too large\n");
        rc = EXIT_USAGE_ERROR;
        goto done;
    }
    if (!unverified && load_trust(&trust, &system_skipped) != 0) {
        rc = EXIT_TRUST_STORE;
        goto done;
    }
    mrc = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                                (const unsigned char *) personalisation,
                                sizeof(personalisation) - 1U);
    if (mrc != 0) {
        report_mbedtls("cannot seed TLS", mrc);
        goto done;
    }
    mrc = mbedtls_net_connect(&net, url->host, url->port, MBEDTLS_NET_PROTO_TCP);
    if (mrc != 0) {
        report_mbedtls("connection failed", mrc);
        goto done;
    }
    mrc = mbedtls_ssl_config_defaults(&config, MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (mrc != 0) {
        report_mbedtls("TLS configuration failed", mrc);
        goto done;
    }
    mbedtls_ssl_conf_min_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_rng(&config, mbedtls_ctr_drbg_random, &drbg);
    mbedtls_ssl_conf_read_timeout(&config, timeout_seconds * 1000U);
    if (unverified) {
        mbedtls_ssl_conf_authmode(&config, MBEDTLS_SSL_VERIFY_NONE);
    } else {
        mbedtls_ssl_conf_authmode(&config, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&config, &trust, NULL);
    }
    mrc = mbedtls_ssl_setup(&ssl, &config);
    if (mrc != 0) {
        report_mbedtls("TLS setup failed", mrc);
        goto done;
    }
    mrc = mbedtls_ssl_set_hostname(&ssl, url->host);
    if (mrc != 0) {
        report_mbedtls("invalid TLS hostname", mrc);
        rc = EXIT_USAGE_ERROR;
        goto done;
    }
    mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, NULL, mbedtls_net_recv_timeout);
    do {
        mrc = mbedtls_ssl_handshake(&ssl);
    } while (mrc == MBEDTLS_ERR_SSL_WANT_READ || mrc == MBEDTLS_ERR_SSL_WANT_WRITE);
    if (mrc != 0) {
        uint32_t flags = mbedtls_ssl_get_verify_result(&ssl);
        if (is_chain_parse_error(mrc)) {
            rc = EXIT_CHAIN_UNPARSEABLE;
            fprintf(stderr,
                    "apn-autoconfig-esim-http: the server's certificate chain could not be parsed (%d)\n",
                    rc);
        } else if (!unverified && flags != 0 && flags != VERIFY_RESULT_UNKNOWN) {
            rc = verification_exit(flags);
            fprintf(stderr, "apn-autoconfig-esim-http: certificate verification failed (%d)\n", rc);
        } else {
            report_mbedtls("TLS handshake failed", mrc);
        }
        goto done;
    }

    request_headers = malloc(request_cap);
    if (request_headers == NULL)
        goto done;
#define APPEND_HEADER(...) do { \
        int written = snprintf(request_headers + request_len, request_cap - request_len, __VA_ARGS__); \
        if (written < 0 || (size_t) written >= request_cap - request_len) goto done; \
        request_len += (size_t) written; \
    } while (0)
    APPEND_HEADER("POST %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nContent-Length: %zu\r\n",
                  url->path, url->authority, body_len);
    for (i = 0; i < forward_count; i++)
        APPEND_HEADER("%s\r\n", forward_headers[i]);
    APPEND_HEADER("\r\n");
#undef APPEND_HEADER
    mrc = ssl_write_all(&ssl, (const unsigned char *) request_headers, request_len);
    if (mrc == 0 && body_len != 0)
        mrc = ssl_write_all(&ssl, body, body_len);
    if (mrc != 0) {
        report_mbedtls("HTTPS request failed", mrc);
        goto done;
    }

    response_headers = malloc(MAX_HEADER_BLOCK + IO_BUFFER);
    if (response_headers == NULL)
        goto done;
    for (;;) {
        unsigned char *marker;
        int got;
        if (header_len >= MAX_HEADER_BLOCK) {
            fprintf(stderr, "apn-autoconfig-esim-http: response headers are too large\n");
            goto done;
        }
        got = mbedtls_ssl_read(&ssl, response_headers + header_len, IO_BUFFER);
        if (got == MBEDTLS_ERR_SSL_WANT_READ || got == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (got <= 0) {
            if (got < 0)
                report_mbedtls("HTTPS response failed", got);
            goto done;
        }
        header_len += (size_t) got;
        response_headers[header_len] = '\0';
        marker = (unsigned char *) strstr((char *) response_headers, "\r\n\r\n");
        if (marker != NULL) {
            size_t header_only = (size_t) (marker - response_headers) + 4U;
            if (header_only > MAX_HEADER_BLOCK) {
                fprintf(stderr, "apn-autoconfig-esim-http: response headers are too large\n");
                goto done;
            }
            body_prefix_len = header_len - header_only;
            memmove(response_headers + MAX_HEADER_BLOCK, response_headers + header_only,
                    body_prefix_len);
            response_headers[header_only] = '\0';
            if (parse_response_headers((char *) response_headers, &http_status, &chunked,
                                       &has_length, &content_length) != 0) {
                fprintf(stderr, "apn-autoconfig-esim-http: malformed HTTP response\n");
                goto done;
            }
            stream.ssl = &ssl;
            stream.prefix = response_headers + MAX_HEADER_BLOCK;
            stream.prefix_len = body_prefix_len;
            stream.prefix_pos = 0;
            break;
        }
    }
    output = fopen(output_path, "wb");
    if (output == NULL) {
        fprintf(stderr, "apn-autoconfig-esim-http: cannot open response output\n");
        goto done;
    }
    if (chunked)
        mrc = copy_chunked_body(&stream, output);
    else if (has_length)
        mrc = copy_exact_body(&stream, output, content_length);
    else
        mrc = copy_to_close(&stream, output);
    if (fflush(output) != 0)
        mrc = -1;
    if (fclose(output) != 0)
        mrc = -1;
    output = NULL;
    if (mrc != 0) {
        fprintf(stderr, "apn-autoconfig-esim-http: malformed or incomplete HTTP body\n");
        goto done;
    }
    output = NULL;
    printf("%d", http_status);
    rc = 0;
done:
    if (output != NULL)
        fclose(output);
    if (rc != 0)
        unlink(output_path);
    free(response_headers);
    free(request_headers);
    free(body);
    mbedtls_x509_crt_free(&trust);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&config);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    mbedtls_net_free(&net);
    return rc;
}

/* Also bound DNS, connect, writes and a peer that keeps sending just before
 * each read timeout. The parent has its own watchdog; this client honours its
 * own deadline independently. _exit is async-signal-safe and closes sockets. */
static void deadline_expired(int signum)
{
    (void) signum;
    _exit(EXIT_TRANSPORT_ERROR);
}

static void usage(FILE *out)
{
    fprintf(out, "usage: apn-autoconfig-esim-http [--unverified-transport] --timeout SECONDS "
                 "--output FILE [--header 'Name: value']... --data FILE -- https://HOST/PATH\n"
                 "       apn-autoconfig-esim-http --inspect-trust\n");
}

int main(int argc, char **argv)
{
    const char *body_path = NULL, *output_path = NULL, *url_string = NULL;
    const char *headers[MAX_FORWARD_HEADERS];
    int header_count = 0, unverified = 0, inspect = 0, i, rc;
    unsigned int timeout_seconds = 60;
    struct parsed_url url;

#if defined(MBEDTLS_USE_PSA_CRYPTO)
    if (psa_crypto_init() != PSA_SUCCESS) {
        fprintf(stderr, "apn-autoconfig-esim-http: crypto initialization failed\n");
        return EXIT_TRANSPORT_ERROR;
    }
#endif
    memset(&url, 0, sizeof(url));
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            if (++i >= argc || url_string != NULL)
                goto bad_usage;
            url_string = argv[i];
            if (i + 1 != argc)
                goto bad_usage;
            break;
        } else if (strcmp(argv[i], "--unverified-transport") == 0) {
            unverified = 1;
        } else if (strcmp(argv[i], "--inspect-trust") == 0) {
            inspect = 1;
        } else if (strcmp(argv[i], "--timeout") == 0) {
            char *endptr;
            unsigned long value;
            if (++i >= argc)
                goto bad_usage;
            errno = 0;
            value = strtoul(argv[i], &endptr, 10);
            if (errno != 0 || *argv[i] == '\0' || *endptr != '\0' || value < 1 || value > 300)
                goto bad_usage;
            timeout_seconds = (unsigned int) value;
        } else if (strcmp(argv[i], "--output") == 0) {
            if (++i >= argc || output_path != NULL)
                goto bad_usage;
            output_path = argv[i];
        } else if (strcmp(argv[i], "--data") == 0) {
            if (++i >= argc || body_path != NULL)
                goto bad_usage;
            body_path = argv[i];
        } else if (strcmp(argv[i], "--header") == 0) {
            if (++i >= argc || header_count >= MAX_FORWARD_HEADERS || !valid_forward_header(argv[i]))
                goto bad_usage;
            headers[header_count++] = argv[i];
        } else {
            goto bad_usage;
        }
    }
    if (inspect) {
        if (argc != 2)
            goto bad_usage;
        return inspect_trust();
    }
    if (body_path == NULL || output_path == NULL || url_string == NULL ||
        parse_url(url_string, &url) != 0)
        goto bad_usage;
    signal(SIGALRM, deadline_expired);
    alarm(timeout_seconds);
    rc = https_post(&url, body_path, output_path, headers, header_count,
                    timeout_seconds, unverified);
    alarm(0);
#if defined(MBEDTLS_USE_PSA_CRYPTO)
    mbedtls_psa_crypto_free();
#endif
    return rc;

bad_usage:
    usage(stderr);
#if defined(MBEDTLS_USE_PSA_CRYPTO)
    mbedtls_psa_crypto_free();
#endif
    return EXIT_USAGE_ERROR;
}
