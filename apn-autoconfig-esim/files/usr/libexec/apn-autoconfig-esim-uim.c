/*
 * Narrow QMI UIM APDU transport for apn-autoconfig-esim.
 *
 * This is intentionally not a QMI library. It speaks three messages of one
 * service to one card: open a logical channel, send an APDU, close the channel.
 * It knows nothing about bearers, profiles, slots beyond the one it is given,
 * or any other QMI service, and it makes no decision about whether it may run —
 * the caller has already resolved one modem, proved who owns it and taken the
 * locks, exactly as it does for the AT transport.
 *
 * Why it exists at all, measured on the reference RM520N-GL on 2026-08-30 and
 * recorded in docs/router-test-0.16.0.md: the modem's AT command handler waits
 * three seconds for the card, and the last exchange of a Bound Profile Package
 * needs four. Over AT the load cannot report itself; over QMI's UIM service the
 * same load completes and the card's own answer arrives.
 *
 * It is one process for a whole card session rather than one per APDU, and that
 * is the other half of the point. A Bound Profile Package is hundreds of
 * exchanges. Spawning a child for each one costs about 80 ms of process and
 * client-id setup apiece, and — the reason a child is refused outright rather
 * than merely disliked — it puts the APDU on a command line, where a profile's
 * own material would be world-readable in /proc/<pid>/cmdline for the length of
 * the exchange.
 *
 * The protocol on stdin and stdout is one line in, one line out, so a POSIX
 * shell can drive it through a pair of FIFOs the way it already drives the LPA:
 *
 *   open <AID-hex>          -> ok channel <n> sw <XXXX>
 *   transmit <APDU-hex>     -> ok data <hex>
 *   close <channel>         -> ok
 *   slots                   -> ok slots <n> [slot <i> <present|absent|error> <active|inactive> <euicc|uicc|unknown>]...
 *   ping                    -> ok
 *   quit                    -> (exits 0)
 *
 * `slots` is the one message here that is not about an open card session, and
 * it earns its place by answering a question no other transport can. The card
 * in a slot the modem is not using cannot be read at all -- there is no channel
 * to it -- but the modem itself knows what is in each physical slot, including
 * whether it is a eUICC, and says so without opening anything. That is the only
 * honest producer of "the active slot holds no eUICC": over an APDU channel a
 * card with no ISD-R applet and a modem that will not open a channel fail
 * identically.
 *
 * Any failure answers `err <token>` and never a partial success. Tokens are
 * stable and are the caller's to classify:
 *
 *   usage        the line was malformed
 *   device       the control device could not be used
 *   timeout      the modem did not answer within the deadline
 *   qmi          the modem refused the request, with its own error code
 *   protocol     the answer could not be parsed as the message that was asked for
 *   state        the command does not apply to the session as it stands
 *
 * Exit codes are the project's classes: 0 success, 2 usage, 3 retryable,
 * 4 blocked.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define EXIT_USAGE_ERROR 2
#define EXIT_RETRYABLE 3
#define EXIT_BLOCKED 4

/* QMI, as the framing is defined in uqmi's common/qmi-struct.h. The marker byte
 * is outside the length, the length covers everything after it, and the
 * transaction id is one byte for the control service and two for every other. */
#define QMI_MARKER 0x01
#define QMI_SERVICE_CTL 0x00
#define QMI_SERVICE_UIM 0x0B

#define QMI_CTL_ALLOCATE_CID 0x0022
#define QMI_CTL_RELEASE_CID 0x0023

#define QMI_UIM_GET_SLOT_STATUS 0x0047
#define QMI_UIM_SEND_APDU 0x003B
#define QMI_UIM_LOGICAL_CHANNEL 0x003F
#define QMI_UIM_OPEN_LOGICAL_CHANNEL 0x0042

#define TLV_RESULT 0x02

/* A message this program sends or expects never approaches this. The bound
 * exists so a modem that answers with a length it did not mean cannot make this
 * process allocate or copy on its word. */
#define QMI_BUFFER 4096
/* 255 bytes of command data plus the four header bytes, doubled for hex, plus
 * the verb and the newline. A Bound Profile Package segment is 97 bytes. */
#define LINE_BUFFER 8192
#define MAX_APDU 2048

static const char *device_path;
static int device_fd = -1;
static int uim_client_id = -1;
static int open_channel = -1;
static int open_slot;
static int exchange_timeout_ms = 30000;
static volatile sig_atomic_t stop_requested;

static void on_signal(int signum)
{
    (void) signum;
    stop_requested = 1;
}

static void put_line(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

static void put_line(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    putchar('\n');
    fflush(stdout);
}

/* ---- hex ---- */

static int hex_value(int c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/* Returns the byte count, or -1 for anything that is not an even-length run of
 * hexadecimal digits that fits. A partial decode is never left behind. */
static int hex_decode(const char *text, unsigned char *out, size_t out_size)
{
    size_t length = strlen(text);
    size_t i;

    if (length == 0 || (length % 2) != 0 || (length / 2) > out_size)
        return -1;
    for (i = 0; i < length; i += 2) {
        int high = hex_value((unsigned char) text[i]);
        int low = hex_value((unsigned char) text[i + 1]);

        if (high < 0 || low < 0)
            return -1;
        out[i / 2] = (unsigned char) ((high << 4) | low);
    }
    return (int) (length / 2);
}

static void hex_encode(const unsigned char *data, size_t length, char *out)
{
    static const char digits[] = "0123456789abcdef";
    size_t i;

    for (i = 0; i < length; i++) {
        out[i * 2] = digits[data[i] >> 4];
        out[i * 2 + 1] = digits[data[i] & 0x0F];
    }
    out[length * 2] = '\0';
}

/* ---- little-endian accessors, because the buffer is not aligned ---- */

static void put_u16(unsigned char *at, uint16_t value)
{
    at[0] = (unsigned char) (value & 0xFF);
    at[1] = (unsigned char) ((value >> 8) & 0xFF);
}

static uint16_t get_u16(const unsigned char *at)
{
    return (uint16_t) (at[0] | ((uint16_t) at[1] << 8));
}

/* ---- one request, one response ---- */

struct qmi_request {
    unsigned char buffer[QMI_BUFFER];
    size_t length;
    size_t tlv_start;
};

static void request_begin(struct qmi_request *request, uint8_t service,
                          uint8_t client, uint16_t transaction, uint16_t message)
{
    unsigned char *at = request->buffer;

    memset(request, 0, sizeof(*request));
    at[0] = QMI_MARKER;
    /* qmux.len is filled in by request_finish */
    at[3] = 0x00;               /* qmux.flags: a control point request */
    at[4] = service;
    at[5] = client;
    at[6] = 0x00;               /* message flags: not a response, not an indication */
    if (service == QMI_SERVICE_CTL) {
        at[7] = (unsigned char) (transaction & 0xFF);
        put_u16(at + 8, message);
        put_u16(at + 10, 0);
        request->length = 12;
    } else {
        put_u16(at + 7, transaction);
        put_u16(at + 9, message);
        put_u16(at + 11, 0);
        request->length = 13;
    }
    request->tlv_start = request->length;
}

static int request_add_tlv(struct qmi_request *request, uint8_t type,
                           const unsigned char *value, uint16_t length)
{
    if (request->length + 3 + (size_t) length > sizeof(request->buffer))
        return -1;
    request->buffer[request->length] = type;
    put_u16(request->buffer + request->length + 1, length);
    if (length > 0)
        memcpy(request->buffer + request->length + 3, value, length);
    request->length += 3 + (size_t) length;
    return 0;
}

static void request_finish(struct qmi_request *request, uint8_t service)
{
    uint16_t tlv_length = (uint16_t) (request->length - request->tlv_start);

    if (service == QMI_SERVICE_CTL)
        put_u16(request->buffer + 10, tlv_length);
    else
        put_u16(request->buffer + 11, tlv_length);
    /* Everything after the marker, which is what qmux.len counts. */
    put_u16(request->buffer + 1, (uint16_t) (request->length - 1));
}

/* Milliseconds remaining until a deadline, clamped at zero. CLOCK_MONOTONIC
 * through clock_gettime rather than time(), so a step of the wall clock during
 * a card exchange cannot shorten or extend the bound. */
static int remaining_ms(const struct timespec *deadline)
{
    struct timespec now;
    long long ms;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
    ms = (long long) (deadline->tv_sec - now.tv_sec) * 1000
       + (deadline->tv_nsec - now.tv_nsec) / 1000000;
    if (ms < 0)
        return 0;
    if (ms > INT32_MAX)
        return INT32_MAX;
    return (int) ms;
}

static void deadline_from_now(struct timespec *deadline, int timeout_ms)
{
    if (clock_gettime(CLOCK_MONOTONIC, deadline) != 0) {
        deadline->tv_sec = 0;
        deadline->tv_nsec = 0;
        return;
    }
    deadline->tv_sec += timeout_ms / 1000;
    deadline->tv_nsec += (long) (timeout_ms % 1000) * 1000000L;
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_sec += 1;
        deadline->tv_nsec -= 1000000000L;
    }
}

/*
 * Writes one message and reads the answer to it.
 *
 * The device is message-oriented, so a read returns one whole QMI message or
 * nothing. A message that is not the answer to this transaction is discarded
 * and the read continues on the same deadline: an unsolicited indication must
 * not be mistaken for a reply, and must not consume the reply's budget by
 * ending the wait either.
 *
 * Returns the payload length on success, or a negative token index.
 */
#define EXCHANGE_DEVICE (-1)
#define EXCHANGE_TIMEOUT (-2)
#define EXCHANGE_PROTOCOL (-3)
#define EXCHANGE_INTERRUPTED (-4)

static int qmi_exchange(struct qmi_request *request, uint8_t service,
                        uint16_t transaction, unsigned char *response,
                        size_t response_size)
{
    struct timespec deadline;
    ssize_t written;

    written = write(device_fd, request->buffer, request->length);
    if (written < 0 || (size_t) written != request->length)
        return EXCHANGE_DEVICE;

    deadline_from_now(&deadline, exchange_timeout_ms);
    for (;;) {
        struct pollfd pfd;
        ssize_t got;
        int wait_ms;
        size_t header;
        uint16_t answered_transaction;

        if (stop_requested)
            return EXCHANGE_INTERRUPTED;

        wait_ms = remaining_ms(&deadline);
        if (wait_ms == 0)
            return EXCHANGE_TIMEOUT;

        pfd.fd = device_fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        if (poll(&pfd, 1, wait_ms) < 0) {
            if (errno == EINTR)
                continue;
            return EXCHANGE_DEVICE;
        }
        if ((pfd.revents & POLLIN) == 0) {
            if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL))
                return EXCHANGE_DEVICE;
            continue;
        }

        got = read(device_fd, response, response_size);
        if (got < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            return EXCHANGE_DEVICE;
        }
        if (got == 0)
            return EXCHANGE_DEVICE;
        header = service == QMI_SERVICE_CTL ? 12 : 13;
        if ((size_t) got < header || response[0] != QMI_MARKER)
            continue;
        /* Match the complete request identity. Indications and replies to a
         * different client/message must never become this APDU's answer.
         * CTL's transaction counter is eight bits on the wire. */
        if (response[4] != service || response[5] != request->buffer[5] ||
            response[3] != 0x80 ||
            response[6] != (service == QMI_SERVICE_CTL ? 0x01 : 0x02) ||
            get_u16(response + header - 4) != get_u16(request->buffer + header - 4))
            continue;
        answered_transaction = service == QMI_SERVICE_CTL ? response[7] :
                               get_u16(response + 7);
        if (answered_transaction != (service == QMI_SERVICE_CTL ?
                                     (uint8_t) transaction : transaction))
            continue;
        if ((size_t) get_u16(response + 1) + 1 != (size_t) got)
            return EXCHANGE_PROTOCOL;

        /* The declared TLV length has to fit inside what actually arrived.
         * A modem that says otherwise is not trusted about the rest. */
        {
            uint16_t tlv_length = get_u16(response + header - 2);

            if ((size_t) got != header + (size_t) tlv_length)
                return EXCHANGE_PROTOCOL;
            return (int) tlv_length;
        }
    }
}

/* Finds one TLV in a payload. Returns its length and sets *value, or -1. */
static int find_tlv(const unsigned char *tlvs, size_t length, uint8_t type,
                    const unsigned char **value)
{
    size_t offset = 0;
    int result = -1;
    const unsigned char *match = NULL;

    while (offset + 3 <= length) {
        uint8_t found = tlvs[offset];
        uint16_t size = get_u16(tlvs + offset + 1);

        if (offset + 3 + (size_t) size > length)
            return -1;
        if (found == type) {
            if (match != NULL)
                return -1; /* Ambiguous singleton, not a first-match choice. */
            match = tlvs + offset + 3;
            result = (int) size;
        }
        offset += 3 + (size_t) size;
    }
    if (offset != length || match == NULL)
        return -1;
    *value = match;
    return result;
}

/* The standard result TLV: zero status is success, otherwise the QMI error
 * code. A response without one is a protocol error rather than a success --
 * "no news is good news" is exactly the reading that turns a refusal into a
 * pretend answer. */
static int qmi_result(const unsigned char *tlvs, size_t length, uint16_t *code)
{
    const unsigned char *value;
    int size = find_tlv(tlvs, length, TLV_RESULT, &value);

    if (size != 4)
        return -1;
    *code = get_u16(value + 2);
    return get_u16(value) == 0 ? 0 : 1;
}

static uint16_t next_transaction(void)
{
    static uint16_t counter;

    /* Zero is avoided because some firmware treats it as "no transaction". */
    if (++counter == 0)
        counter = 1;
    return counter;
}

/* ---- the three things this program does ---- */

static int allocate_client_id(void)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    unsigned char service = QMI_SERVICE_UIM;
    uint16_t transaction = next_transaction();
    const unsigned char *value;
    uint16_t code = 0;
    int payload;
    int size;

    request_begin(&request, QMI_SERVICE_CTL, 0, transaction, QMI_CTL_ALLOCATE_CID);
    if (request_add_tlv(&request, 0x01, &service, 1) != 0)
        return -1;
    request_finish(&request, QMI_SERVICE_CTL);

    payload = qmi_exchange(&request, QMI_SERVICE_CTL, transaction,
                           response, sizeof(response));
    if (payload < 0)
        return payload;
    if (qmi_result(response + 12, (size_t) payload, &code) != 0)
        return -1;
    size = find_tlv(response + 12, (size_t) payload, 0x01, &value);
    if (size != 2 || value[0] != QMI_SERVICE_UIM)
        return -1;
    uim_client_id = value[1];
    return 0;
}

static void release_client_id(void)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    unsigned char info[2];
    uint16_t transaction;

    if (uim_client_id < 0)
        return;
    transaction = next_transaction();
    info[0] = QMI_SERVICE_UIM;
    info[1] = (unsigned char) uim_client_id;
    request_begin(&request, QMI_SERVICE_CTL, 0, transaction, QMI_CTL_RELEASE_CID);
    if (request_add_tlv(&request, 0x01, info, sizeof(info)) == 0) {
        request_finish(&request, QMI_SERVICE_CTL);
        (void) qmi_exchange(&request, QMI_SERVICE_CTL, transaction,
                            response, sizeof(response));
    }
    uim_client_id = -1;
}

/* Open a logical channel to an AID. On success the channel number and the
 * card's status word are reported; the select response is deliberately not,
 * because nothing above this needs it and it is card material. */
static int command_open(const char *aid_hex)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    unsigned char aid[64];
    unsigned char slot = (unsigned char) open_slot;
    unsigned char aid_tlv[1 + sizeof(aid)];
    uint16_t transaction = next_transaction();
    const unsigned char *value;
    uint16_t code = 0;
    int aid_length;
    int payload;
    int size;

    if (open_channel >= 0) {
        put_line("err state a channel is already open");
        return 0;
    }
    aid_length = hex_decode(aid_hex, aid, sizeof(aid));
    if (aid_length <= 0) {
        put_line("err usage the AID is not hexadecimal");
        return 0;
    }

    request_begin(&request, QMI_SERVICE_UIM, (uint8_t) uim_client_id,
                  transaction, QMI_UIM_OPEN_LOGICAL_CHANNEL);
    if (request_add_tlv(&request, 0x01, &slot, 1) != 0) {
        put_line("err protocol the request did not fit");
        return 0;
    }
    aid_tlv[0] = (unsigned char) aid_length;
    memcpy(aid_tlv + 1, aid, (size_t) aid_length);
    if (request_add_tlv(&request, 0x10, aid_tlv, (uint16_t) (aid_length + 1)) != 0) {
        put_line("err protocol the request did not fit");
        return 0;
    }
    request_finish(&request, QMI_SERVICE_UIM);

    payload = qmi_exchange(&request, QMI_SERVICE_UIM, transaction,
                           response, sizeof(response));
    if (payload == EXCHANGE_TIMEOUT) {
        put_line("err timeout");
        return 0;
    }
    if (payload == EXCHANGE_INTERRUPTED) {
        put_line("err state interrupted");
        return 0;
    }
    if (payload < 0) {
        put_line("err device");
        return 0;
    }
    if (qmi_result(response + 13, (size_t) payload, &code) != 0) {
        put_line("err qmi %u", (unsigned) code);
        return 0;
    }
    size = find_tlv(response + 13, (size_t) payload, 0x10, &value);
    if (size != 1) {
        put_line("err protocol no channel was named");
        return 0;
    }
    open_channel = value[0];
    {
        unsigned sw1 = 0x90;
        unsigned sw2 = 0x00;
        const unsigned char *card;
        int card_size = find_tlv(response + 13, (size_t) payload, 0x11, &card);

        if (card_size == 2) {
            sw1 = card[0];
            sw2 = card[1];
        }
        put_line("ok channel %d sw %02X%02X", open_channel, sw1, sw2);
    }
    return 0;
}

static int command_transmit(const char *apdu_hex)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    static unsigned char apdu[MAX_APDU];
    static unsigned char apdu_tlv[2 + MAX_APDU];
    static char out[MAX_APDU * 2 + 1];
    unsigned char slot = (unsigned char) open_slot;
    unsigned char channel;
    uint16_t transaction = next_transaction();
    const unsigned char *value;
    uint16_t code = 0;
    int apdu_length;
    int payload;
    int size;

    if (open_channel < 0) {
        put_line("err state no channel is open");
        return 0;
    }
    apdu_length = hex_decode(apdu_hex, apdu, sizeof(apdu));
    if (apdu_length <= 0) {
        put_line("err usage the APDU is not hexadecimal");
        return 0;
    }
    channel = (unsigned char) open_channel;

    request_begin(&request, QMI_SERVICE_UIM, (uint8_t) uim_client_id,
                  transaction, QMI_UIM_SEND_APDU);
    put_u16(apdu_tlv, (uint16_t) apdu_length);
    memcpy(apdu_tlv + 2, apdu, (size_t) apdu_length);
    if (request_add_tlv(&request, 0x01, &slot, 1) != 0 ||
        request_add_tlv(&request, 0x02, apdu_tlv, (uint16_t) (apdu_length + 2)) != 0 ||
        request_add_tlv(&request, 0x10, &channel, 1) != 0) {
        put_line("err protocol the request did not fit");
        return 0;
    }
    request_finish(&request, QMI_SERVICE_UIM);

    payload = qmi_exchange(&request, QMI_SERVICE_UIM, transaction,
                           response, sizeof(response));
    if (payload == EXCHANGE_TIMEOUT) {
        put_line("err timeout");
        return 0;
    }
    if (payload == EXCHANGE_INTERRUPTED) {
        put_line("err state interrupted");
        return 0;
    }
    if (payload < 0) {
        put_line("err device");
        return 0;
    }
    if (qmi_result(response + 13, (size_t) payload, &code) != 0) {
        put_line("err qmi %u", (unsigned) code);
        return 0;
    }
    size = find_tlv(response + 13, (size_t) payload, 0x10, &value);
    /* The array carries its own 16-bit count, and it has to agree with the TLV
     * that contains it. Trusting the inner count alone is how a truncated read
     * becomes a short answer nobody notices. */
    if (size < 2) {
        put_line("err protocol no response data");
        return 0;
    }
    {
        uint16_t declared = get_u16(value);

        if ((size_t) size != (size_t) declared + 2 || declared > MAX_APDU) {
            put_line("err protocol the response length disagrees with itself");
            return 0;
        }
        hex_encode(value + 2, declared, out);
        put_line("ok data %s", out);
    }
    return 0;
}

/*
 * What the modem says is in each physical slot, without opening anything.
 *
 * Two arrays answer this, and both are needed because neither is complete on
 * its own: the *status* array carries card and slot state, and the
 * *information* array carries the flag that says a card is a eUICC. They are
 * parallel -- entry i of one describes the same physical slot as entry i of the
 * other -- and a modem that returns different counts for them is answering
 * something this cannot interpret, so it is refused rather than half-read.
 *
 * Every length is checked against the TLV that contains it before it is used.
 * A firmware that returns a shorter array than it declares is not hypothetical
 * on this class of device, and a short read here would be a slot's state taken
 * from whatever followed it in the buffer.
 */
static int command_slots(void)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    uint16_t transaction = next_transaction();
    const unsigned char *status = NULL;
    const unsigned char *info = NULL;
    uint16_t code = 0;
    int payload;
    int status_size;
    int info_size;
    unsigned status_count;
    unsigned info_count;
    size_t status_at;
    size_t info_at;
    unsigned index;
    char out[512];
    size_t written = 0;
    int printed;

    request_begin(&request, QMI_SERVICE_UIM, (uint8_t) uim_client_id,
                  transaction, QMI_UIM_GET_SLOT_STATUS);
    request_finish(&request, QMI_SERVICE_UIM);

    payload = qmi_exchange(&request, QMI_SERVICE_UIM, transaction,
                           response, sizeof(response));
    if (payload == EXCHANGE_TIMEOUT) {
        put_line("err timeout");
        return 0;
    }
    if (payload == EXCHANGE_INTERRUPTED) {
        put_line("err state interrupted");
        return 0;
    }
    if (payload < 0) {
        put_line("err device");
        return 0;
    }
    if (qmi_result(response + 13, (size_t) payload, &code) != 0) {
        /* A modem whose firmware has no slot status at all answers with its
         * own error, and that is a fact about the modem rather than about the
         * card. The caller turns it into "not asked", never into "no eUICC". */
        put_line("err qmi %u", (unsigned) code);
        return 0;
    }

    status_size = find_tlv(response + 13, (size_t) payload, 0x10, &status);
    info_size = find_tlv(response + 13, (size_t) payload, 0x11, &info);
    if (status_size < 1 || info_size < 1) {
        put_line("err protocol no slot arrays");
        return 0;
    }
    status_count = status[0];
    info_count = info[0];
    if (status_count == 0 || status_count != info_count || status_count > 8) {
        put_line("err protocol the slot arrays disagree");
        return 0;
    }

    printed = snprintf(out, sizeof(out), "ok slots %u", status_count);
    if (printed < 0 || (size_t) printed >= sizeof(out)) {
        put_line("err protocol the answer did not fit");
        return 0;
    }
    written = (size_t) printed;

    status_at = 1;
    info_at = 1;
    for (index = 0; index < status_count; index++) {
        uint32_t card_state;
        uint32_t slot_state;
        unsigned iccid_length;
        unsigned atr_length;
        unsigned char is_euicc;
        const char *card_text;
        const char *slot_text;
        const char *kind_text;

        /* card_state(4) slot_state(4) logical_slot(1) iccid_len(1) + iccid */
        if (status_at + 10 > (size_t) status_size) {
            put_line("err protocol a slot status entry is short");
            return 0;
        }
        card_state = (uint32_t) status[status_at] |
                     ((uint32_t) status[status_at + 1] << 8) |
                     ((uint32_t) status[status_at + 2] << 16) |
                     ((uint32_t) status[status_at + 3] << 24);
        slot_state = (uint32_t) status[status_at + 4] |
                     ((uint32_t) status[status_at + 5] << 8) |
                     ((uint32_t) status[status_at + 6] << 16) |
                     ((uint32_t) status[status_at + 7] << 24);
        iccid_length = status[status_at + 9];
        status_at += 10;
        if (status_at + iccid_length > (size_t) status_size) {
            put_line("err protocol a slot iccid is short");
            return 0;
        }
        /* The ICCID is deliberately not reported. This process has no reason to
         * carry a card identifier and its caller has no field for one. */
        status_at += iccid_length;

        /* card_protocol(4) valid_applications(1) atr_len(1) + atr + is_euicc(1) */
        if (info_at + 6 > (size_t) info_size) {
            put_line("err protocol a slot information entry is short");
            return 0;
        }
        atr_length = info[info_at + 5];
        info_at += 6;
        if (info_at + atr_length + 1 > (size_t) info_size) {
            put_line("err protocol a slot atr is short");
            return 0;
        }
        info_at += atr_length;
        is_euicc = info[info_at];
        info_at += 1;

        switch (card_state) {
        case 0: card_text = "absent"; break;
        case 1: card_text = "present"; break;
        default: card_text = "error"; break;
        }
        slot_text = (slot_state == 1) ? "active" : "inactive";
        /* `unknown` is not a third state the modem reports; it is what an
         * absent card gets, because a slot with nothing in it holds neither a
         * eUICC nor a plain UICC and saying either would be wrong. */
        if (card_state != 1)
            kind_text = "unknown";
        else
            kind_text = is_euicc ? "euicc" : "uicc";

        printed = snprintf(out + written, sizeof(out) - written,
                           " slot %u %s %s %s", index + 1, card_text,
                           slot_text, kind_text);
        if (printed < 0 || (size_t) printed >= sizeof(out) - written) {
            put_line("err protocol the answer did not fit");
            return 0;
        }
        written += (size_t) printed;
    }
    put_line("%s", out);
    return 0;
}

static int close_channel(int channel)
{
    struct qmi_request request;
    unsigned char response[QMI_BUFFER];
    unsigned char slot = (unsigned char) open_slot;
    unsigned char channel_byte = (unsigned char) channel;
    unsigned char terminate = 1;
    uint16_t transaction = next_transaction();
    uint16_t code = 0;
    int payload;

    request_begin(&request, QMI_SERVICE_UIM, (uint8_t) uim_client_id,
                  transaction, QMI_UIM_LOGICAL_CHANNEL);
    if (request_add_tlv(&request, 0x01, &slot, 1) != 0 ||
        request_add_tlv(&request, 0x11, &channel_byte, 1) != 0 ||
        request_add_tlv(&request, 0x13, &terminate, 1) != 0)
        return -1;
    request_finish(&request, QMI_SERVICE_UIM);

    payload = qmi_exchange(&request, QMI_SERVICE_UIM, transaction,
                           response, sizeof(response));
    if (payload < 0)
        return -1;
    if (qmi_result(response + 13, (size_t) payload, &code) != 0)
        return -1;
    return 0;
}

static int command_close(const char *channel_text)
{
    char *end = NULL;
    long requested;

    if (open_channel < 0) {
        put_line("err state no channel is open");
        return 0;
    }
    requested = strtol(channel_text, &end, 10);
    if (end == channel_text || (end != NULL && *end != '\0') ||
        requested < 0 || requested > 19) {
        put_line("err usage the channel is not a number");
        return 0;
    }
    /* Closing a channel this session did not open is refused rather than
     * attempted: the number would be somebody else's, and on this transport
     * there is no second owner to complain. */
    if ((int) requested != open_channel) {
        put_line("err state that is not this session's channel");
        return 0;
    }
    if (close_channel(open_channel) != 0) {
        put_line("err qmi the channel could not be closed");
        return 0;
    }
    open_channel = -1;
    put_line("ok");
    return 0;
}

/*
 * Everything this process owns, given back in the reverse order it was taken.
 * The channel first, because it is the card's state and the one thing nothing
 * above can repair; then the client id; then the device.
 */
static void cleanup(void)
{
    /* Bound release even when allocation succeeded but no channel opened. */
    exchange_timeout_ms = 5000;
    if (open_channel >= 0 && device_fd >= 0 && uim_client_id >= 0) {
        /* A cleanup that waits out the full exchange budget is a cleanup that
         * looks like a hang. The card only has to be told, and the modem
         * forgets the channel when the client id goes anyway. */
        (void) close_channel(open_channel);
        open_channel = -1;
    }
    release_client_id();
    if (device_fd >= 0) {
        close(device_fd);
        device_fd = -1;
    }
}

static void usage(void)
{
    fprintf(stderr,
            "usage: apn-autoconfig-esim-uim --device <path> [--slot <1-2>]"
            " [--timeout <seconds>]\n");
}

int main(int argc, char **argv)
{
    struct sigaction action;
    static char line[LINE_BUFFER];
    int i;

    open_slot = 1;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            device_path = argv[++i];
        } else if (strcmp(argv[i], "--slot") == 0 && i + 1 < argc) {
            char *end = NULL;
            long value = strtol(argv[++i], &end, 10);

            if (end == argv[i] || *end != '\0' || value < 1 || value > 2) {
                usage();
                return EXIT_USAGE_ERROR;
            }
            open_slot = (int) value;
        } else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
            char *end = NULL;
            long value = strtol(argv[++i], &end, 10);

            if (end == argv[i] || *end != '\0' || value < 1 || value > 600) {
                usage();
                return EXIT_USAGE_ERROR;
            }
            exchange_timeout_ms = (int) value * 1000;
        } else {
            usage();
            return EXIT_USAGE_ERROR;
        }
    }
    if (device_path == NULL) {
        usage();
        return EXIT_USAGE_ERROR;
    }

    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* Keep uqmi's open flags, but mutual exclusion is provided by the
     * caller's shared control-channel locks, not assumed from O_EXCL. */
    device_fd = open(device_path, O_RDWR | O_EXCL | O_NONBLOCK | O_NOCTTY);
    if (device_fd < 0) {
        fprintf(stderr, "apn-autoconfig-esim-uim: cannot open %s: %s\n",
                device_path, strerror(errno));
        return EXIT_BLOCKED;
    }

    if (allocate_client_id() != 0) {
        fprintf(stderr, "apn-autoconfig-esim-uim: the modem did not allocate a"
                        " UIM client id\n");
        cleanup();
        return EXIT_RETRYABLE;
    }

    put_line("ready");

    while (!stop_requested && fgets(line, sizeof(line), stdin) != NULL) {
        char *argument;
        size_t length = strlen(line);

        /* Never interpret the tail of an overlong command as a new command. */
        if (length == sizeof(line) - 1 && line[length - 1] != '\n') {
            put_line("err protocol input-too-long");
            break;
        }
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r'))
            line[--length] = '\0';

        argument = strchr(line, ' ');
        if (argument != NULL)
            *argument++ = '\0';

        if (strcmp(line, "quit") == 0)
            break;
        if (strcmp(line, "slots") == 0) {
            if (command_slots() != 0)
                break;
            continue;
        }
        if (strcmp(line, "ping") == 0) {
            put_line("ok");
            continue;
        }
        if (strcmp(line, "open") == 0 && argument != NULL) {
            command_open(argument);
            continue;
        }
        if (strcmp(line, "transmit") == 0 && argument != NULL) {
            command_transmit(argument);
            continue;
        }
        if (strcmp(line, "close") == 0 && argument != NULL) {
            command_close(argument);
            continue;
        }
        put_line("err usage unknown command");
    }

    cleanup();
    return 0;
}
