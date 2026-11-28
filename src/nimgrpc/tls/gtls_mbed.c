/*
 * The TLS layer on mbedTLS 4.x: the same C interface as gtls.c (BearSSL), selected with
 * -d:tlsMbed. PROTOTYPE: TLS 1.2 and TLS 1.3, ECDHE with AES-GCM or ChaCha20-Poly1305,
 * ALPN h2, certificate chains checked against the trust anchors, client certificates.
 * Not done: session resumption (gtls_resumed is 0, the lifetime is ignored), TLS 1.3 tickets.
 *
 * mbedTLS drives itself from the calls the program makes (handshake, read, write), where
 * BearSSL is a state machine fed with bytes. So this layer keeps three buffers: records
 * from the network that mbedTLS has not read yet, records for the network that it has
 * written, and plaintext it has read; every push runs the handshake or the reader as far
 * as the bytes allow.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <psa/crypto.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/error.h>

/* ------------------------------------------------------------------ buffers */

typedef struct {
    unsigned char *buf;
    size_t len, cap, pos;          /* bytes in buf[pos .. len) are waiting */
} gbuf;

static int gbuf_add(gbuf *b, const void *data, size_t len) {
    if (b->pos > 0 && b->pos == b->len) b->pos = b->len = 0;
    if (b->len + len > b->cap) {
        if (b->pos > 0) {
            memmove(b->buf, b->buf + b->pos, b->len - b->pos);
            b->len -= b->pos;
            b->pos = 0;
        }
        if (b->len + len > b->cap) {
            size_t cap = b->cap ? b->cap * 2 : 4096;
            while (cap < b->len + len) cap *= 2;
            unsigned char *nb = realloc(b->buf, cap);
            if (!nb) return -1;
            b->buf = nb;
            b->cap = cap;
        }
    }
    memcpy(b->buf + b->len, data, len);
    b->len += len;
    return 0;
}

static size_t gbuf_avail(const gbuf *b) { return b->len - b->pos; }

static size_t gbuf_take(gbuf *b, unsigned char *out, size_t cap) {
    size_t n = gbuf_avail(b);
    if (n > cap) n = cap;
    memcpy(out, b->buf + b->pos, n);
    b->pos += n;
    if (b->pos == b->len) b->pos = b->len = 0;
    return n;
}

static void gbuf_wipe(gbuf *b) {
    if (b->buf) { memset(b->buf, 0, b->cap); free(b->buf); }
    memset(b, 0, sizeof *b);
}

/* ------------------------------------------------------------------ configuration */

#define MAX_RECORDS_BUFFERED (1 << 20)   /* what a peer may have us hold before we stop taking bytes */

typedef struct gtls_conf {
    mbedtls_x509_crt ca;            /* trust anchors */
    long ca_count;
    mbedtls_x509_crt own;           /* our chain, leaf first */
    mbedtls_pk_context key;
    int have_identity;
    int require_client_cert;
    int cipher_order;               /* 0: by the CPU, 1: AES-GCM first, 2: ChaCha20 first */
    int lifetime;                   /* kept for the interface; resumption is not done here */
    int refs;                       /* owners: the TlsConfig handles and the connections (atomic) */
    pthread_mutex_t mu;             /* guards the lazy building of `cfg` */
    mbedtls_ssl_config cfg[2];      /* [0] client, [1] server; read-only once built */
    int built[2];
    int suites[16];
    char err[160];
} gtls_conf;

static pthread_once_t psa_once = PTHREAD_ONCE_INIT;
static int psa_ok;
static void psa_start(void) { psa_ok = psa_crypto_init() == PSA_SUCCESS; }

gtls_conf *gtls_conf_new(void) {
    pthread_once(&psa_once, psa_start);
    if (!psa_ok) return NULL;
    gtls_conf *c = calloc(1, sizeof(gtls_conf));
    if (!c) return NULL;
    mbedtls_x509_crt_init(&c->ca);
    mbedtls_x509_crt_init(&c->own);
    mbedtls_pk_init(&c->key);
    c->lifetime = 600;
    c->refs = 1;
    pthread_mutex_init(&c->mu, NULL);
    return c;
}

const char *gtls_conf_error(gtls_conf *c) { return c->err; }
void gtls_conf_set_cipher_order(gtls_conf *c, int order) { c->cipher_order = order; }
void gtls_conf_set_lifetime(gtls_conf *c, int seconds) { c->lifetime = seconds < 0 ? 0 : seconds; }
void gtls_conf_require_client_cert(gtls_conf *c, int on) { c->require_client_cert = on; }

static unsigned char *with_nul(const unsigned char *p, size_t len) {
    unsigned char *q = malloc(len + 1);
    if (q) { if (len) memcpy(q, p, len); q[len] = 0; }
    return q;
}

/* mbedTLS's errors for a buffer in which no certificate could be found. */
static int no_cert(int rc) {
    return rc == MBEDTLS_ERR_X509_CERT_UNKNOWN_FORMAT || rc == MBEDTLS_ERR_X509_INVALID_FORMAT;
}

static long chain_count(const mbedtls_x509_crt *c) {
    long n = 0;
    for (; c; c = c->next) if (c->raw.p) n++;
    return n;
}

/* Adds every certificate in `pem` as a trust anchor. Returns the count, or -1. */
long gtls_conf_add_ca(gtls_conf *c, const unsigned char *pem, size_t len) {
    unsigned char *b = with_nul(pem, len);
    if (!b) { strcpy(c->err, "out of memory"); return -1; }
    long before = chain_count(&c->ca);
    int rc = mbedtls_x509_crt_parse(&c->ca, b, len + 1);
    free(b);
    if (no_cert(rc)) { strcpy(c->err, "no certificate in CA bundle"); return -1; }
    if (rc != 0) { snprintf(c->err, sizeof c->err, "CA certificate: decode error %d", rc); return -1; }
    long added = chain_count(&c->ca) - before;
    if (added == 0) { strcpy(c->err, "no certificate in CA bundle"); return -1; }
    c->ca_count += added;
    return added;
}

/* Our certificate chain (leaf first) and its private key. Returns 0 or -1. */
int gtls_conf_set_identity(gtls_conf *c, const unsigned char *chain_pem, size_t chain_len,
                           const unsigned char *key_pem, size_t key_len) {
    unsigned char *b = with_nul(chain_pem, chain_len);
    unsigned char *k = with_nul(key_pem, key_len);
    int ret = -1;
    if (!b || !k) { strcpy(c->err, "out of memory"); goto done; }
    mbedtls_x509_crt_free(&c->own);
    mbedtls_x509_crt_init(&c->own);
    mbedtls_pk_free(&c->key);
    mbedtls_pk_init(&c->key);
    int rc = mbedtls_x509_crt_parse(&c->own, b, chain_len + 1);
    if (no_cert(rc)) { strcpy(c->err, "no certificate in chain"); goto done; }
    if (rc != 0) { strcpy(c->err, "invalid PEM in certificate chain"); goto done; }
    if (chain_count(&c->own) == 0) { strcpy(c->err, "no certificate in chain"); goto done; }
    rc = mbedtls_pk_parse_key(&c->key, k, key_len + 1, NULL, 0);
    if (rc != 0) { snprintf(c->err, sizeof c->err, "private key decode error %d", rc); goto done; }
    c->have_identity = 1;
    ret = 0;
done:
    if (k) { memset(k, 0, key_len + 1); free(k); }
    free(b);
    return ret;
}

static void conf_destroy(gtls_conf *c) {
    for (int i = 0; i < 2; i++) if (c->built[i]) mbedtls_ssl_config_free(&c->cfg[i]);
    mbedtls_x509_crt_free(&c->ca);
    mbedtls_x509_crt_free(&c->own);
    mbedtls_pk_free(&c->key);
    pthread_mutex_destroy(&c->mu);
    free(c);
}

/* An owner more: a handle made by `share`, or a connection. The count is atomic. */
void gtls_conf_retain(gtls_conf *c) {
    if (c) __atomic_fetch_add(&c->refs, 1, __ATOMIC_RELAXED);
}

/* An owner less; the last one frees the configuration. */
void gtls_conf_free(gtls_conf *c) {
    if (!c) return;
    if (__atomic_fetch_sub(&c->refs, 1, __ATOMIC_ACQ_REL) == 1) conf_destroy(c);
}

/* AES-GCM is fast only with hardware help; ChaCha20 stays fast without it. */
static int aes_gcm_is_fast(void) {
#if defined(__x86_64__) || defined(__i386__)
    return __builtin_cpu_supports("aes") && __builtin_cpu_supports("pclmul");
#elif defined(__aarch64__)
    return 1;
#else
    return 0;
#endif
}

static int aes_first(const gtls_conf *c) {
    if (c->cipher_order == 1) return 1;
    if (c->cipher_order == 2) return 0;
    return aes_gcm_is_fast();
}

/* Only forward-secret key agreement with an AEAD cipher: the same six suites of TLS 1.2 as
 * gtls.c, and the three of TLS 1.3. */
static void fill_suites(gtls_conf *c) {
    static const int aes13[] = { MBEDTLS_TLS1_3_AES_128_GCM_SHA256, MBEDTLS_TLS1_3_AES_256_GCM_SHA384 };
    static const int aes12[] = {
        MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384, MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    };
    static const int cha12[] = {
        MBEDTLS_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, MBEDTLS_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    };
    int n = 0;
    if (aes_first(c)) {
        for (size_t i = 0; i < 2; i++) c->suites[n++] = aes13[i];
        c->suites[n++] = MBEDTLS_TLS1_3_CHACHA20_POLY1305_SHA256;
        for (size_t i = 0; i < 4; i++) c->suites[n++] = aes12[i];
        for (size_t i = 0; i < 2; i++) c->suites[n++] = cha12[i];
    } else {
        c->suites[n++] = MBEDTLS_TLS1_3_CHACHA20_POLY1305_SHA256;
        for (size_t i = 0; i < 2; i++) c->suites[n++] = aes13[i];
        for (size_t i = 0; i < 2; i++) c->suites[n++] = cha12[i];
        for (size_t i = 0; i < 4; i++) c->suites[n++] = aes12[i];
    }
    c->suites[n] = 0;
}

static const char *h2_protos[] = { "h2", NULL };

/* Builds the mbedTLS configuration for one side the first time it is needed. */
static int build_cfg(gtls_conf *c, int server) {
    int ret = -1;
    pthread_mutex_lock(&c->mu);
    if (c->built[server]) { ret = 0; goto done; }
    mbedtls_ssl_config *cfg = &c->cfg[server];
    mbedtls_ssl_config_init(cfg);
    if (mbedtls_ssl_config_defaults(cfg, server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        mbedtls_ssl_config_free(cfg);
        strcpy(c->err, "TLS configuration");
        goto done;
    }
    mbedtls_ssl_conf_min_tls_version(cfg, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(cfg, MBEDTLS_SSL_VERSION_TLS1_3);
    fill_suites(c);
    mbedtls_ssl_conf_ciphersuites(cfg, c->suites);
    if (mbedtls_ssl_conf_alpn_protocols(cfg, h2_protos) != 0) { strcpy(c->err, "ALPN"); mbedtls_ssl_config_free(cfg); goto done; }
    if (server) {
        if (mbedtls_ssl_conf_own_cert(cfg, &c->own, &c->key) != 0) { strcpy(c->err, "identity"); mbedtls_ssl_config_free(cfg); goto done; }
        if (c->require_client_cert) {
            mbedtls_ssl_conf_authmode(cfg, MBEDTLS_SSL_VERIFY_REQUIRED);
            mbedtls_ssl_conf_ca_chain(cfg, &c->ca, NULL);
        } else {
            mbedtls_ssl_conf_authmode(cfg, MBEDTLS_SSL_VERIFY_NONE);
        }
    } else {
        mbedtls_ssl_conf_authmode(cfg, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(cfg, &c->ca, NULL);
        if (c->have_identity && mbedtls_ssl_conf_own_cert(cfg, &c->own, &c->key) != 0) {
            strcpy(c->err, "identity");
            mbedtls_ssl_config_free(cfg);
            goto done;
        }
    }
    c->built[server] = 1;
    ret = 0;
done:
    pthread_mutex_unlock(&c->mu);
    return ret;
}

/* ------------------------------------------------------------------ conn */

typedef struct gtls_conn {
    mbedtls_ssl_context ssl;
    gtls_conf *conf;
    int is_server;
    int verify_peer;               /* the peer's certificate is required and was checked */
    int hs_done;
    int closed;                    /* failed, or closed by either side */
    int err;                       /* a BearSSL-style error number, 0 if none (see gtls_last_error) */
    int alpn_refused;
    gbuf in;                       /* records from the network, not yet read by mbedTLS */
    gbuf out;                      /* records for the network */
    gbuf app;                      /* plaintext received */
    char alpn[8];
    char sni[256];
    char errtext[160];             /* mbedTLS's own words for the error */
} gtls_conn;

static int bio_send(void *ctx, const unsigned char *b, size_t n) {
    gtls_conn *t = ctx;
    if (gbuf_add(&t->out, b, n) != 0) return MBEDTLS_ERR_SSL_ALLOC_FAILED;
    return (int)n;
}

static int bio_recv(void *ctx, unsigned char *b, size_t n) {
    gtls_conn *t = ctx;
    if (gbuf_avail(&t->in) == 0) return MBEDTLS_ERR_SSL_WANT_READ;
    return (int)gbuf_take(&t->in, b, n);
}

/* mbedTLS's error and the verification flags, as the BearSSL error numbers that
 * tls.nim's errorMessage knows: 3 and 4 protocol version, 29 and 35 no certificate, 54 dates,
 * 56 name, 62 not trusted, 512 + a alert sent, 256 + an alert received. */
static int map_error(gtls_conn *t, int rc) {
    uint32_t flags = mbedtls_ssl_get_verify_result(&t->ssl) & ~(uint32_t)MBEDTLS_X509_BADCERT_SKIP_VERIFY;
    if (rc == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
        if (flags & (MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE)) return 54;
        if (flags & MBEDTLS_X509_BADCERT_CN_MISMATCH) return 56;
        if (flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) return 62;
        if (flags & MBEDTLS_X509_BADCERT_MISSING) return t->is_server ? 29 : 35;
        return 512 + 42;           /* bad_certificate */
    }
    switch (rc) {
    case MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE: return 29;
    case MBEDTLS_ERR_SSL_BAD_PROTOCOL_VERSION: return 3;
    case MBEDTLS_ERR_SSL_NO_APPLICATION_PROTOCOL: return 512 + 120;
    case MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE: return 256 + t->ssl.MBEDTLS_PRIVATE(in_msg)[1];   /* the alert's number */
    case MBEDTLS_ERR_SSL_INVALID_RECORD: return 3;            /* not TLS at all */
    default: return 1;                                        /* see gtls_error_text */
    }
}

static void fail(gtls_conn *t, int rc) {
    t->closed = 1;
    if (t->err == 0) {
        t->err = map_error(t, rc);
        mbedtls_strerror(rc, t->errtext, sizeof t->errtext);
    }
}

/* Runs mbedTLS as far as the bytes it has allow: the handshake, then the reader. */
static void advance(gtls_conn *t) {
    if (t->closed) return;
    while (!t->hs_done) {
        int before = t->ssl.MBEDTLS_PRIVATE(state);
        int rc = mbedtls_ssl_handshake_step(&t->ssl);
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return;
        if (rc == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
        if (rc != 0) { fail(t, rc); return; }
        int now = t->ssl.MBEDTLS_PRIVATE(state);
        /* A client that offers no ALPN protocol is refused as soon as its ClientHello is read,
         * before anything is sent back, as with BearSSL (mbedTLS fails only when the client
         * offers some and none matches). */
        if (t->is_server && before == MBEDTLS_SSL_CLIENT_HELLO && now != before &&
            mbedtls_ssl_get_alpn_protocol(&t->ssl) == NULL) {
            t->alpn_refused = 1;
            mbedtls_ssl_send_alert_message(&t->ssl, MBEDTLS_SSL_ALERT_LEVEL_FATAL,
                                           MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE);
            t->err = 512 + 40;
            t->closed = 1;
            return;
        }
        if (now == MBEDTLS_SSL_HANDSHAKE_OVER) {
            t->hs_done = 1;
            const char *a = mbedtls_ssl_get_alpn_protocol(&t->ssl);
            if (a) snprintf(t->alpn, sizeof t->alpn, "%s", a);
        }
    }
    unsigned char tmp[16384];
    for (;;) {
        int rc = mbedtls_ssl_read(&t->ssl, tmp, sizeof tmp);
        if (rc > 0) {
            if (gbuf_add(&t->app, tmp, (size_t)rc) != 0) { fail(t, MBEDTLS_ERR_SSL_ALLOC_FAILED); return; }
            continue;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return;
        if (rc == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
        if (rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || rc == 0) { t->closed = 1; return; }
        fail(t, rc);
        return;
    }
}

/* A name that is an IP address is compared with the iPAddress entries of the certificate. */
static int is_ip_literal(const char *name) {
    unsigned char ip[16];
    return inet_pton(AF_INET, name, ip) == 1 || inet_pton(AF_INET6, name, ip) == 1;
}

/* A client session. `server_name` is checked against the server's certificate and sent as SNI.
 * Returns NULL on error. */
gtls_conn *gtls_client_new(gtls_conf *c, const char *server_name) {
    if (c->ca_count == 0) { strcpy(c->err, "client needs trust anchors"); return NULL; }
    if (build_cfg(c, 0) != 0) return NULL;
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    mbedtls_ssl_init(&t->ssl);
    if (mbedtls_ssl_setup(&t->ssl, &c->cfg[0]) != 0) { free(t); return NULL; }
    char name[256] = "";
    if (server_name) {
        size_t n = strlen(server_name);
        if (n > 2 && server_name[0] == '[' && server_name[n - 1] == ']') snprintf(name, sizeof name, "%.*s", (int)(n - 2), server_name + 1);
        else snprintf(name, sizeof name, "%s", server_name);
    }
    snprintf(t->sni, sizeof t->sni, "%s", name);
    if (mbedtls_ssl_set_hostname(&t->ssl, name[0] ? name : NULL) != 0) { mbedtls_ssl_free(&t->ssl); free(t); return NULL; }
    (void)is_ip_literal;
    mbedtls_ssl_set_bio(&t->ssl, t, bio_send, bio_recv, NULL);
    t->verify_peer = 1;
    t->conf = c;
    gtls_conf_retain(c);
    advance(t);                    /* the ClientHello */
    return t;
}

/* A server session. Returns NULL on error. */
gtls_conn *gtls_server_new(gtls_conf *c) {
    if (!c->have_identity) { strcpy(c->err, "server needs a certificate and key"); return NULL; }
    if (build_cfg(c, 1) != 0) return NULL;
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    t->is_server = 1;
    t->verify_peer = c->require_client_cert;
    mbedtls_ssl_init(&t->ssl);
    if (mbedtls_ssl_setup(&t->ssl, &c->cfg[1]) != 0) { free(t); return NULL; }
    mbedtls_ssl_set_bio(&t->ssl, t, bio_send, bio_recv, NULL);
    t->conf = c;
    gtls_conf_retain(c);
    return t;
}

void gtls_free(gtls_conn *t) {
    if (!t) return;
    gtls_conf *c = t->conf;
    mbedtls_ssl_free(&t->ssl);
    gbuf_wipe(&t->in);
    gbuf_wipe(&t->out);
    gbuf_wipe(&t->app);
    memset(t, 0, sizeof *t);
    free(t);
    gtls_conf_free(c);
}

/* ------------------------------------------------------------------ pump */

/* The bits tls.nim looks at: the BearSSL state flags 1 (closed) and 8 (can send application
 * data). */
#define GT_CLOSED 0x01
#define GT_SENDAPP 0x08

unsigned gtls_state(gtls_conn *t) {
    unsigned s = 0;
    if (t->closed) s |= GT_CLOSED;
    else if (t->hs_done) s |= GT_SENDAPP;
    return s;
}

int gtls_alpn_refused(gtls_conn *t) { return t->alpn_refused; }
int gtls_last_error(gtls_conn *t) { return t->err; }
/* mbedTLS's text for an error that has no BearSSL number (gtls_last_error is 1). */
const char *gtls_error_text(gtls_conn *t) { return t->errtext; }

/* Records from the network. Returns bytes taken. */
size_t gtls_push_records(gtls_conn *t, const unsigned char *data, size_t len) {
    if (t->closed || len == 0) return 0;
    if (gbuf_avail(&t->in) >= MAX_RECORDS_BUFFERED) return 0;
    if (gbuf_add(&t->in, data, len) != 0) return 0;
    advance(t);
    return len;
}

/* Records for the network. Returns bytes written to `out`. */
size_t gtls_pull_records(gtls_conn *t, unsigned char *out, size_t cap) {
    return gbuf_take(&t->out, out, cap);
}

/* Plaintext to send. Returns bytes taken (0 until the handshake is done). */
size_t gtls_push_app(gtls_conn *t, const unsigned char *data, size_t len) {
    if (t->closed || !t->hs_done || len == 0) return 0;
    int rc;
    do {
        /* TLS 1.3: a NewSessionTicket the server sent after its Finished is reported once, by
         * whichever call meets it first; the call is then made again. */
        rc = mbedtls_ssl_write(&t->ssl, data, len);
    } while (rc == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);
    if (rc > 0) return (size_t)rc;
    if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
    fail(t, rc);
    return 0;
}

/* mbedTLS writes a record per call; nothing is held back. */
void gtls_flush(gtls_conn *t) { (void)t; }

/* Plaintext received. Returns bytes written to `out`. */
size_t gtls_pull_app(gtls_conn *t, unsigned char *out, size_t cap) {
    return gbuf_take(&t->app, out, cap);
}

/* Starts close_notify. */
void gtls_close(gtls_conn *t) {
    if (t->closed) return;
    if (t->hs_done) mbedtls_ssl_close_notify(&t->ssl);
    t->closed = 1;
}

/* After the handshake: the negotiated ALPN protocol, or NULL. */
const char *gtls_alpn(gtls_conn *t) { return t->alpn[0] ? t->alpn : NULL; }

/* After the handshake: 1 if the session was resumed rather than made afresh. */
int gtls_resumed(gtls_conn *t) { (void)t; return 0; }

/* After the handshake: 1 if the peer is authenticated as required (a failed verification
 * ends the handshake with an error, so a finished handshake is a verified one). */
int gtls_peer_ok(gtls_conn *t) {
    return t->hs_done && (!t->verify_peer || mbedtls_ssl_get_verify_result(&t->ssl) == 0);
}
