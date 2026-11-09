/*
 * I/O-free TLS on BearSSL for nimgrpc.
 *
 * A gtls_conf holds what is shared by many connections and never changes once
 * built: trust anchors, our certificate chain and private key, and whether a
 * client certificate is required. A gtls_conn is one TLS session; bytes go in
 * and out through four buffers (records in, records out, plaintext in,
 * plaintext out) and the conn never touches a socket.
 *
 * Every function here is called with the connection's lock held by the Nim
 * side; nothing in this file is thread-aware.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <arpa/inet.h>
#include "bearssl.h"

/* ------------------------------------------------------------------ buffers */

typedef struct {
    unsigned char *buf;
    size_t len, cap;
} gbuf;

static int gbuf_add(gbuf *b, const void *data, size_t len) {
    if (b->len + len > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 1024;
        while (cap < b->len + len) cap *= 2;
        unsigned char *nb = realloc(b->buf, cap);
        if (!nb) return -1;
        b->buf = nb;
        b->cap = cap;
    }
    memcpy(b->buf + b->len, data, len);
    b->len += len;
    return 0;
}

static void gbuf_sink(void *ctx, const void *data, size_t len) {
    gbuf_add((gbuf *)ctx, data, len);
}

static void *dupmem(const void *p, size_t len) {
    void *q = malloc(len ? len : 1);
    if (q && len) memcpy(q, p, len);
    return q;
}

/* ------------------------------------------------------------------ PEM */

typedef struct {
    char *name;
    unsigned char *data;
    size_t len;
} pem_obj;

/* Decodes every PEM object in `pem`. Returns the number of objects, or -1. */
static long decode_pem(const unsigned char *pem, size_t len, pem_obj **out) {
    br_pem_decoder_context pc;
    pem_obj *objs = NULL;
    size_t n = 0;
    gbuf cur = {0};
    int inobj = 0;
    char *name = NULL;
    int extra_nl = 1;

    br_pem_decoder_init(&pc);
    while (len > 0 || extra_nl) {
        size_t tlen;
        if (len == 0) {   /* a final newline ends an object at end of input */
            tlen = br_pem_decoder_push(&pc, "\n", 1);
            extra_nl = 0;
        } else {
            tlen = br_pem_decoder_push(&pc, pem, len);
            pem += tlen;
            len -= tlen;
        }
        switch (br_pem_decoder_event(&pc)) {
        case BR_PEM_BEGIN_OBJ:
            name = strdup(br_pem_decoder_name(&pc));
            cur.len = 0;
            br_pem_decoder_setdest(&pc, gbuf_sink, &cur);
            inobj = 1;
            break;
        case BR_PEM_END_OBJ:
            if (inobj) {
                pem_obj *no = realloc(objs, (n + 1) * sizeof *objs);
                if (!no) goto fail;
                objs = no;
                objs[n].name = name;
                objs[n].data = dupmem(cur.buf, cur.len);
                objs[n].len = cur.len;
                name = NULL;
                n++;
                inobj = 0;
            }
            break;
        case BR_PEM_ERROR:
            goto fail;
        }
    }
    free(cur.buf);
    if (inobj) { free(name); goto fail2; }
    *out = objs;
    return (long)n;
fail:
    free(cur.buf);
    free(name);
fail2:
    for (size_t i = 0; i < n; i++) { free(objs[i].name); free(objs[i].data); }
    free(objs);
    return -1;
}

static void free_pem(pem_obj *objs, long n) {
    for (long i = 0; i < n; i++) { free(objs[i].name); free(objs[i].data); }
    free(objs);
}

static int is_cert_name(const char *name) {
    return strcmp(name, "CERTIFICATE") == 0 || strcmp(name, "X509 CERTIFICATE") == 0;
}

/* ------------------------------------------------------------------ conf */

typedef struct {
    br_x509_trust_anchor *tas;
    size_t ta_num;
    br_x509_certificate *chain;
    size_t chain_len;
    int key_type;                  /* 0: none, BR_KEYTYPE_RSA or BR_KEYTYPE_EC */
    br_rsa_private_key rsa;
    br_ec_private_key ec;
    unsigned char *key_mem;        /* owns the key's byte arrays */
    int require_client_cert;
    int cipher_order;              /* 0: by the CPU, 1: AES-GCM first, 2: ChaCha20 first */
    int lifetime;                  /* seconds a session may be resumed; 0: never */
    pthread_mutex_t mu;            /* guards `cache` (creation) and the saved client session */
    struct gtls_cache *cache;      /* server: sessions that may be resumed */
    int have_session;              /* client: the last verified session ... */
    br_ssl_session_parameters csess;
    char cname[256];               /* ... and the server name it was made for */
    long long ctime;               /* ... and when (monotonic seconds) */
    char err[160];
} gtls_conf;

#define DEFAULT_LIFETIME 600
#define CACHE_BYTES (128 * 1024)

static long long now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec;
}

gtls_conf *gtls_conf_new(void) {
    gtls_conf *c = calloc(1, sizeof(gtls_conf));
    if (c) {
        c->lifetime = DEFAULT_LIFETIME;
        pthread_mutex_init(&c->mu, NULL);
    }
    return c;
}

const char *gtls_conf_error(gtls_conf *c) { return c->err; }

void gtls_conf_set_cipher_order(gtls_conf *c, int order) { c->cipher_order = order; }

void gtls_conf_set_lifetime(gtls_conf *c, int seconds) { c->lifetime = seconds < 0 ? 0 : seconds; }

static void dn_append(void *ctx, const void *buf, size_t len) {
    gbuf_add((gbuf *)ctx, buf, len);
}

/* Adds every certificate in `pem` as a trust anchor. Returns the count, or -1. */
long gtls_conf_add_ca(gtls_conf *c, const unsigned char *pem, size_t len) {
    pem_obj *objs;
    long n = decode_pem(pem, len, &objs), added = 0;
    if (n < 0) { strcpy(c->err, "invalid PEM in CA bundle"); return -1; }
    for (long i = 0; i < n; i++) {
        if (!is_cert_name(objs[i].name)) continue;
        br_x509_decoder_context dc;
        gbuf dn = {0};
        br_x509_decoder_init(&dc, dn_append, &dn);
        br_x509_decoder_push(&dc, objs[i].data, objs[i].len);
        br_x509_pkey *pk = br_x509_decoder_get_pkey(&dc);
        if (pk == NULL) {
            free(dn.buf);
            snprintf(c->err, sizeof c->err, "CA certificate %ld: decode error %d",
                     i, br_x509_decoder_last_error(&dc));
            free_pem(objs, n);
            return -1;
        }
        br_x509_trust_anchor *nt = realloc(c->tas, (c->ta_num + 1) * sizeof *nt);
        if (!nt) { free(dn.buf); free_pem(objs, n); return -1; }
        c->tas = nt;
        br_x509_trust_anchor *ta = &c->tas[c->ta_num];
        memset(ta, 0, sizeof *ta);
        ta->dn.data = dn.buf;
        ta->dn.len = dn.len;
        ta->flags = br_x509_decoder_isCA(&dc) ? BR_X509_TA_CA : 0;
        ta->pkey.key_type = pk->key_type;
        if (pk->key_type == BR_KEYTYPE_RSA) {
            ta->pkey.key.rsa.n = dupmem(pk->key.rsa.n, pk->key.rsa.nlen);
            ta->pkey.key.rsa.nlen = pk->key.rsa.nlen;
            ta->pkey.key.rsa.e = dupmem(pk->key.rsa.e, pk->key.rsa.elen);
            ta->pkey.key.rsa.elen = pk->key.rsa.elen;
        } else {
            ta->pkey.key.ec.curve = pk->key.ec.curve;
            ta->pkey.key.ec.q = dupmem(pk->key.ec.q, pk->key.ec.qlen);
            ta->pkey.key.ec.qlen = pk->key.ec.qlen;
        }
        c->ta_num++;
        added++;
    }
    free_pem(objs, n);
    if (added == 0) { strcpy(c->err, "no certificate in CA bundle"); return -1; }
    return added;
}

/* Our certificate chain (leaf first) and its private key. Returns 0 or -1. */
int gtls_conf_set_identity(gtls_conf *c, const unsigned char *chain_pem, size_t chain_len,
                           const unsigned char *key_pem, size_t key_len) {
    pem_obj *objs;
    long n = decode_pem(chain_pem, chain_len, &objs);
    if (n < 0) { strcpy(c->err, "invalid PEM in certificate chain"); return -1; }
    for (long i = 0; i < n; i++) {
        if (!is_cert_name(objs[i].name)) continue;
        br_x509_certificate *nc = realloc(c->chain, (c->chain_len + 1) * sizeof *nc);
        if (!nc) { free_pem(objs, n); return -1; }
        c->chain = nc;
        c->chain[c->chain_len].data = dupmem(objs[i].data, objs[i].len);
        c->chain[c->chain_len].data_len = objs[i].len;
        c->chain_len++;
    }
    free_pem(objs, n);
    if (c->chain_len == 0) { strcpy(c->err, "no certificate in chain"); return -1; }

    n = decode_pem(key_pem, key_len, &objs);
    if (n < 0) { strcpy(c->err, "invalid PEM in private key"); return -1; }
    int found = 0;
    for (long i = 0; i < n && !found; i++) {
        const char *nm = objs[i].name;
        if (strcmp(nm, "RSA PRIVATE KEY") && strcmp(nm, "EC PRIVATE KEY") &&
            strcmp(nm, "PRIVATE KEY")) continue;
        br_skey_decoder_context sk;
        br_skey_decoder_init(&sk);
        br_skey_decoder_push(&sk, objs[i].data, objs[i].len);
        int err = br_skey_decoder_last_error(&sk);
        if (err != 0) {
            snprintf(c->err, sizeof c->err, "private key decode error %d", err);
            free_pem(objs, n);
            return -1;
        }
        c->key_type = br_skey_decoder_key_type(&sk);
        if (c->key_type == BR_KEYTYPE_RSA) {
            const br_rsa_private_key *k = br_skey_decoder_get_rsa(&sk);
            size_t tot = k->plen + k->qlen + k->dplen + k->dqlen + k->iqlen;
            unsigned char *m = malloc(tot), *p = m;
            if (!m) { free_pem(objs, n); return -1; }
            c->rsa = *k;
#define CP(f, l) memcpy(p, k->f, k->l); c->rsa.f = p; p += k->l;
            CP(p, plen) CP(q, qlen) CP(dp, dplen) CP(dq, dqlen) CP(iq, iqlen)
#undef CP
            c->key_mem = m;
        } else {
            const br_ec_private_key *k = br_skey_decoder_get_ec(&sk);
            c->ec = *k;
            c->key_mem = dupmem(k->x, k->xlen);
            c->ec.x = c->key_mem;
        }
        found = 1;
    }
    free_pem(objs, n);
    if (!found) { strcpy(c->err, "no private key in PEM"); return -1; }
    return 0;
}

void gtls_conf_require_client_cert(gtls_conf *c, int on) { c->require_client_cert = on; }

static void cache_free(struct gtls_cache *k);

void gtls_conf_free(gtls_conf *c) {
    if (!c) return;
    for (size_t i = 0; i < c->ta_num; i++) {
        br_x509_trust_anchor *ta = &c->tas[i];
        free(ta->dn.data);
        if (ta->pkey.key_type == BR_KEYTYPE_RSA) {
            free(ta->pkey.key.rsa.n);
            free(ta->pkey.key.rsa.e);
        } else {
            free(ta->pkey.key.ec.q);
        }
    }
    free(c->tas);
    cache_free(c->cache);
    pthread_mutex_destroy(&c->mu);
    memset(&c->csess, 0, sizeof c->csess);       /* the master secret */
    for (size_t i = 0; i < c->chain_len; i++) free(c->chain[i].data);
    free(c->chain);
    if (c->key_mem) {
        /* wipe the private key before giving the memory back */
        size_t len = c->key_type == BR_KEYTYPE_RSA
            ? c->rsa.plen + c->rsa.qlen + c->rsa.dplen + c->rsa.dqlen + c->rsa.iqlen
            : c->ec.xlen;
        memset(c->key_mem, 0, len);
        free(c->key_mem);
    }
    free(c);
}

/* ------------------------------------------------------------------ conn */

/*
 * The X.509 engine is wrapped so we learn whether the peer presented a chain
 * that validated: a BearSSL server otherwise accepts a client that sends no
 * certificate at all.
 */
typedef struct {
    const br_x509_class *vtable;
    const br_x509_class **inner;
    int validated;
    int chain_seen;                /* a certificate chain was presented in this handshake */
    /* A server named by an IP address: BearSSL checks DNS names only, so the leaf certificate
     * is kept and its iPAddress entries (subjectAltName) are compared with `ip` here. */
    int want_ip;                   /* 4 or 16: the length of `ip`; 0 for a DNS name */
    unsigned char ip[16];
    int cert_idx;                  /* the certificate of the chain being read */
    unsigned char *leaf;
    size_t leaf_len, leaf_cap;
    int leaf_bad;                  /* the leaf was too large to keep */
} x509_watch;

/* ---- the iPAddress entries of a certificate (DER, just enough of it) */

/* One element at buf[*pos]: its tag, and where its content is. 0 if malformed. */
static int der_next(const unsigned char *buf, size_t len, size_t *pos,
                    unsigned *tag, size_t *cstart, size_t *clen) {
    size_t p = *pos;
    if (p + 2 > len) return 0;
    *tag = buf[p++];
    size_t l = buf[p++];
    if (l & 0x80) {
        size_t n = l & 0x7f;
        if (n == 0 || n > 3 || p + n > len) return 0;
        l = 0;
        while (n--) l = (l << 8) | buf[p++];
    }
    if (l > len - p) return 0;
    *cstart = p;
    *clen = l;
    *pos = p + l;
    return 1;
}

/* Whether the certificate has an iPAddress subjectAltName equal to ip[0..iplen). */
static int cert_has_ip(const unsigned char *der, size_t len, const unsigned char *ip, int iplen) {
    static const unsigned char oid_san[] = { 0x55, 0x1d, 0x11 };
    size_t pos = 0, cs, cl;
    unsigned tag;
    if (!der_next(der, len, &pos, &tag, &cs, &cl) || tag != 0x30) return 0;      /* Certificate */
    size_t p = cs, end = cs + cl;
    if (!der_next(der, end, &p, &tag, &cs, &cl) || tag != 0x30) return 0;        /* tbsCertificate */
    size_t tp = cs, tend = cs + cl;
    while (tp < tend) {
        size_t es, el;
        if (!der_next(der, tend, &tp, &tag, &es, &el)) return 0;
        if (tag != 0xa3) continue;                                               /* [3] extensions */
        size_t xp = es;
        size_t ss, sl;
        if (!der_next(der, es + el, &xp, &tag, &ss, &sl) || tag != 0x30) return 0;
        size_t ep = ss, eend = ss + sl;
        while (ep < eend) {
            size_t xs, xl;
            if (!der_next(der, eend, &ep, &tag, &xs, &xl) || tag != 0x30) return 0;
            size_t ip2 = xs, iend = xs + xl;
            size_t os, ol;
            if (!der_next(der, iend, &ip2, &tag, &os, &ol) || tag != 0x06) return 0;
            if (ol != sizeof oid_san || memcmp(der + os, oid_san, ol) != 0) continue;
            if (ip2 < iend && der[ip2] == 0x01) {                                /* critical */
                if (!der_next(der, iend, &ip2, &tag, &os, &ol)) return 0;
            }
            if (!der_next(der, iend, &ip2, &tag, &os, &ol) || tag != 0x04) return 0;
            size_t np = os, nend = os + ol;
            size_t gs, gl;
            if (!der_next(der, nend, &np, &tag, &gs, &gl) || tag != 0x30) return 0;
            size_t g = gs, gend = gs + gl;
            while (g < gend) {
                size_t vs, vl;
                if (!der_next(der, gend, &g, &tag, &vs, &vl)) return 0;
                if (tag == 0x87 && (int)vl == iplen && memcmp(der + vs, ip, vl) == 0) return 1;
            }
            return 0;
        }
    }
    return 0;
}

#define LEAF_MAX (128 * 1024)

static void xw_start_chain(const br_x509_class **ctx, const char *name) {
    x509_watch *w = (x509_watch *)ctx;
    w->validated = 0;
    w->chain_seen = 1;
    w->cert_idx = -1;
    w->leaf_len = 0;
    w->leaf_bad = 0;
    (*w->inner)->start_chain(w->inner, name);
}
static void xw_start_cert(const br_x509_class **ctx, uint32_t len) {
    x509_watch *w = (x509_watch *)ctx;
    w->cert_idx++;
    (*w->inner)->start_cert(w->inner, len);
}
static void xw_append(const br_x509_class **ctx, const unsigned char *buf, size_t len) {
    x509_watch *w = (x509_watch *)ctx;
    if (w->want_ip && w->cert_idx == 0 && !w->leaf_bad) {
        if (w->leaf_len + len > LEAF_MAX) {
            w->leaf_bad = 1;
        } else {
            if (w->leaf_len + len > w->leaf_cap) {
                size_t nc = w->leaf_cap ? w->leaf_cap * 2 : 4096;
                while (nc < w->leaf_len + len) nc *= 2;
                unsigned char *nb = realloc(w->leaf, nc);
                if (!nb) { w->leaf_bad = 1; nc = w->leaf_cap; }
                else { w->leaf = nb; w->leaf_cap = nc; }
            }
            if (!w->leaf_bad) { memcpy(w->leaf + w->leaf_len, buf, len); w->leaf_len += len; }
        }
    }
    (*w->inner)->append(w->inner, buf, len);
}
static void xw_end_cert(const br_x509_class **ctx) {
    x509_watch *w = (x509_watch *)ctx;
    (*w->inner)->end_cert(w->inner);
}
static unsigned xw_end_chain(const br_x509_class **ctx) {
    x509_watch *w = (x509_watch *)ctx;
    unsigned r = (*w->inner)->end_chain(w->inner);
    if (r == 0 && w->want_ip &&
        (w->leaf_bad || !cert_has_ip(w->leaf, w->leaf_len, w->ip, w->want_ip)))
        r = BR_ERR_X509_BAD_SERVER_NAME;
    w->validated = (r == 0);
    return r;
}
static const br_x509_pkey *xw_get_pkey(const br_x509_class *const *ctx, unsigned *usages) {
    x509_watch *w = (x509_watch *)ctx;
    return (*w->inner)->get_pkey(w->inner, usages);
}
static const br_x509_class x509_watch_vtable = {
    sizeof(x509_watch), xw_start_chain, xw_start_cert, xw_append,
    xw_end_cert, xw_end_chain, xw_get_pkey
};

typedef struct {
    union {
        br_ssl_client_context client;
        br_ssl_server_context server;
    } u;
    br_ssl_engine_context *eng;
    br_x509_minimal_context x509;
    x509_watch watch;
    int is_server;
    int verify_peer;               /* the peer must present a valid chain */
    gtls_conf *conf;
    char sni[256];                 /* client: the name the session is for */
    int resumed;                   /* server: the session came out of the cache */
    int offered;                   /* client: a saved session was offered ... */
    unsigned char offered_id[32];  /* ... under this id */
    size_t offered_len;
    int saved;                     /* client: the session has been kept for next time */
    const char *alpn[1];
    unsigned char iobuf[BR_SSL_BUFSIZE_BIDI];
} gtls_conn;

static const char *h2_name = "h2";

/* ---------------------------------------------------------- session cache
 *
 * Session resumption (TLS 1.2 session ids) skips the public-key work of a
 * handshake. BearSSL's LRU cache is not thread-safe and has no lifetime, so it
 * is wrapped: a mutex around every call, and the whole cache is dropped once
 * `lifetime` seconds have passed since it was started, so no session lives
 * longer than that. Only sessions of peers that were authenticated as required
 * are kept (checked in `cache_save`).
 */

typedef struct gtls_cache {
    const br_ssl_session_cache_class *vt;
    br_ssl_session_cache_lru lru;
    pthread_mutex_t mu;
    unsigned char *buf;
    long long epoch;
    int lifetime;
} gtls_cache;

static void cache_expire(gtls_cache *k) {
    long long now = now_s();
    if (now - k->epoch >= k->lifetime) {
        br_ssl_session_cache_lru_init(&k->lru, k->buf, CACHE_BYTES);
        k->epoch = now;
    }
}

static void cache_save(const br_ssl_session_cache_class **ctx, br_ssl_server_context *sc,
                       const br_ssl_session_parameters *params) {
    gtls_cache *k = (gtls_cache *)ctx;
    gtls_conn *t = (gtls_conn *)sc;            /* the server context is the first member */
    if (t->verify_peer && !t->watch.validated) return;
    pthread_mutex_lock(&k->mu);
    cache_expire(k);
    k->lru.vtable->save(&k->lru.vtable, sc, params);
    pthread_mutex_unlock(&k->mu);
}

static int cache_load(const br_ssl_session_cache_class **ctx, br_ssl_server_context *sc,
                      br_ssl_session_parameters *params) {
    gtls_cache *k = (gtls_cache *)ctx;
    gtls_conn *t = (gtls_conn *)sc;
    pthread_mutex_lock(&k->mu);
    cache_expire(k);
    int r = k->lru.vtable->load(&k->lru.vtable, sc, params);
    pthread_mutex_unlock(&k->mu);
    if (r) t->resumed = 1;
    return r;
}

static const br_ssl_session_cache_class cache_class = {
    sizeof(gtls_cache), cache_save, cache_load
};

static void cache_free(gtls_cache *k) {
    if (!k) return;
    pthread_mutex_destroy(&k->mu);
    free(k->buf);
    free(k);
}

/* The cache of a server configuration, made on first use; NULL if resumption is off. */
static gtls_cache *conf_cache(gtls_conf *c) {
    if (c->lifetime <= 0) return NULL;
    pthread_mutex_lock(&c->mu);
    if (!c->cache) {
        gtls_cache *k = calloc(1, sizeof *k);
        unsigned char *buf = malloc(CACHE_BYTES);
        if (k && buf) {
            k->vt = &cache_class;
            k->buf = buf;
            k->lifetime = c->lifetime;
            k->epoch = now_s();
            pthread_mutex_init(&k->mu, NULL);
            br_ssl_session_cache_lru_init(&k->lru, buf, CACHE_BYTES);
            c->cache = k;
        } else {
            free(k);
            free(buf);
        }
    }
    gtls_cache *k = c->cache;
    pthread_mutex_unlock(&c->mu);
    return k;
}

/* Only forward-secret key agreement with an AEAD cipher. BearSSL's "full"
 * profiles also offer static RSA, CBC and 3DES suites; those are dropped.
 * The same six suites in two orders: whichever cipher is first is the one
 * chosen when both sides support it. */
static const uint16_t suites_aes_first[] = {
    BR_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    BR_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    BR_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
};
static const uint16_t suites_chacha_first[] = {
    BR_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
    BR_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    BR_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
};
#define N_SUITES (sizeof suites_aes_first / sizeof suites_aes_first[0])

/* AES-GCM is fast only with hardware help (AES-NI and PCLMULQDQ); BearSSL's
 * portable AES is constant-time and slow, where ChaCha20 stays fast. */
static int aes_gcm_is_fast(void) {
    return br_aes_x86ni_ctr_get_vtable() != NULL && br_ghash_pclmul_get() != NULL;
}

static int aes_first(const gtls_conf *c) {
    if (c->cipher_order == 1) return 1;
    if (c->cipher_order == 2) return 0;
    return aes_gcm_is_fast();
}


/* Elliptic curves. BearSSL's "full" profiles verify certificate signatures
 * with the generic prime_i31 code, which spends most of a handshake (about 60%
 * of the CPU of a new mutual-TLS connection) on ECDSA verification. P-256
 * has a much faster implementation on 64-bit machines (m64) and a fast one
 * everywhere else (m31, inside br_ec_all_m31). Route P-256 to the best one and
 * leave the other curves to br_ec_all_m31. */
static const br_ec_impl *ec_p256_fast;

static const br_ec_impl *ec_for(int curve) {
    return (curve == BR_EC_secp256r1 && ec_p256_fast) ? ec_p256_fast : &br_ec_all_m31;
}
static const unsigned char *ecx_generator(int curve, size_t *len) {
    return ec_for(curve)->generator(curve, len);
}
static const unsigned char *ecx_order(int curve, size_t *len) {
    return ec_for(curve)->order(curve, len);
}
static size_t ecx_xoff(int curve, size_t *len) {
    return ec_for(curve)->xoff(curve, len);
}
static uint32_t ecx_mul(unsigned char *G, size_t Glen, const unsigned char *x, size_t xlen, int curve) {
    return ec_for(curve)->mul(G, Glen, x, xlen, curve);
}
static size_t ecx_mulgen(unsigned char *R, const unsigned char *x, size_t xlen, int curve) {
    return ec_for(curve)->mulgen(R, x, xlen, curve);
}
static uint32_t ecx_muladd(unsigned char *A, const unsigned char *B, size_t len,
                           const unsigned char *x, size_t xlen,
                           const unsigned char *y, size_t ylen, int curve) {
    return ec_for(curve)->muladd(A, B, len, x, xlen, y, ylen, curve);
}
static br_ec_impl ec_fast;

static pthread_once_t ec_once = PTHREAD_ONCE_INIT;

static void ec_init(void) {
    ec_p256_fast = br_ec_p256_m64_get();
    ec_fast.supported_curves = br_ec_all_m31.supported_curves;
    ec_fast.generator = ecx_generator;
    ec_fast.order = ecx_order;
    ec_fast.xoff = ecx_xoff;
    ec_fast.mul = ecx_mul;
    ec_fast.mulgen = ecx_mulgen;
    ec_fast.muladd = ecx_muladd;
}

static const br_ec_impl *ec_best(void) {
    pthread_once(&ec_once, ec_init);
    return &ec_fast;
}

static void setup_common(gtls_conn *t, gtls_conf *c) {
    br_x509_minimal_init_full(&t->x509, c->tas, c->ta_num);
    /* Certificates: RSA keys of 2048 bits or more (the default admits 1017),
     * and no MD5 or SHA-1 signatures. */
    br_x509_minimal_set_ecdsa(&t->x509, ec_best(), br_ecdsa_vrfy_asn1_get_default());
    br_ssl_engine_set_ec(t->eng, ec_best());
    br_x509_minimal_set_minrsa(&t->x509, 256);
    br_x509_minimal_set_hash(&t->x509, br_md5_ID, NULL);
    br_x509_minimal_set_hash(&t->x509, br_sha1_ID, NULL);
    br_ssl_engine_set_suites(t->eng, aes_first(c) ? suites_aes_first : suites_chacha_first, N_SUITES);
    /* A server knows its own CPU: its order decides, not the client's. */
    if (t->is_server) br_ssl_engine_add_flags(t->eng, BR_OPT_ENFORCE_SERVER_PREFERENCES);
    t->watch.vtable = &x509_watch_vtable;
    t->watch.inner = &t->x509.vtable;
    br_ssl_engine_set_x509(t->eng, &t->watch.vtable);
    br_ssl_engine_set_buffer(t->eng, t->iobuf, sizeof t->iobuf, 1);
    br_ssl_engine_set_versions(t->eng, BR_TLS12, BR_TLS12);
    t->alpn[0] = h2_name;
    br_ssl_engine_set_protocol_names(t->eng, t->alpn, 1);
    br_ssl_engine_add_flags(t->eng, BR_OPT_FAIL_ON_ALPN_MISMATCH);
}

/* A client session. `server_name` is checked against the server's certificate (a DNS name
 * against its dNSName entries and CN, an IP address against its iPAddress entries) and sent
 * as SNI unless it is an IP address. Returns NULL on error. */
gtls_conn *gtls_client_new(gtls_conf *c, const char *server_name) {
    if (c->ta_num == 0) { strcpy(c->err, "client needs trust anchors"); return NULL; }
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    t->eng = &t->u.client.eng;
    br_ssl_client_init_full(&t->u.client, &t->x509, c->tas, c->ta_num);
    setup_common(t, c);
    t->verify_peer = 1;
    if (c->chain_len > 0) {
        if (c->key_type == BR_KEYTYPE_RSA)
            br_ssl_client_set_single_rsa(&t->u.client, c->chain, c->chain_len,
                                         &c->rsa, br_rsa_pkcs1_sign_get_default());
        else
            br_ssl_client_set_single_ec(&t->u.client, c->chain, c->chain_len,
                                        &c->ec, BR_KEYTYPE_SIGN, 0,
                                        ec_best(), br_ecdsa_sign_asn1_get_default());
    }
    t->conf = c;
    snprintf(t->sni, sizeof t->sni, "%s", server_name ? server_name : "");
    if (c->lifetime > 0 && server_name) {
        pthread_mutex_lock(&c->mu);
        if (c->have_session && now_s() - c->ctime < c->lifetime &&
            strcmp(c->cname, server_name) == 0) {
            br_ssl_engine_set_session_parameters(t->eng, &c->csess);
            t->offered = 1;
            t->offered_len = c->csess.session_id_len;
            memcpy(t->offered_id, c->csess.session_id, t->offered_len);
        }
        pthread_mutex_unlock(&c->mu);
    }
    /* A name that is an IP address: no SNI (RFC 6066), BearSSL does not check a name, and the
     * certificate's iPAddress entries are compared in xw_end_chain. */
    const char *reset_name = server_name;
    if (server_name && server_name[0]) {
        char lit[256];
        size_t n = strlen(server_name);
        if (n > 2 && server_name[0] == '[' && server_name[n - 1] == ']') {
            snprintf(lit, sizeof lit, "%.*s", (int)(n - 2), server_name + 1);
        } else {
            snprintf(lit, sizeof lit, "%s", server_name);
        }
        if (inet_pton(AF_INET, lit, t->watch.ip) == 1) t->watch.want_ip = 4;
        else if (inet_pton(AF_INET6, lit, t->watch.ip) == 1) t->watch.want_ip = 16;
        if (t->watch.want_ip) reset_name = NULL;
    }
    if (!br_ssl_client_reset(&t->u.client, reset_name, t->offered)) {
        free(t);
        return NULL;
    }
    return t;
}

/* A server session. Returns NULL on error. */
gtls_conn *gtls_server_new(gtls_conf *c) {
    if (c->chain_len == 0) { strcpy(c->err, "server needs a certificate and key"); return NULL; }
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    t->is_server = 1;
    t->eng = &t->u.server.eng;
    if (c->key_type == BR_KEYTYPE_RSA)
        br_ssl_server_init_full_rsa(&t->u.server, c->chain, c->chain_len, &c->rsa);
    else
        br_ssl_server_init_full_ec(&t->u.server, c->chain, c->chain_len,
                                   BR_KEYTYPE_EC, &c->ec);
    setup_common(t, c);
    t->conf = c;
    gtls_cache *k = conf_cache(c);
    if (k) br_ssl_server_set_cache(&t->u.server, &k->vt);
    if (c->require_client_cert) {
        br_ssl_server_set_trust_anchor_names_alt(&t->u.server, c->tas, c->ta_num);
        /* The server only asks for certificate types it can verify; the
         * "full" server profiles install no signature verifiers. */
        br_ssl_engine_set_default_rsavrfy(t->eng);
        br_ssl_engine_set_ecdsa(t->eng, br_ecdsa_vrfy_asn1_get_default());
        t->verify_peer = 1;
    }
    if (!br_ssl_server_reset(&t->u.server)) {
        free(t);
        return NULL;
    }
    return t;
}

void gtls_free(gtls_conn *t) {
    if (t) {
        free(t->watch.leaf);
        memset(t, 0, sizeof *t);
        free(t);
    }
}

/* ------------------------------------------------------------------ pump */

enum {
    GT_CLOSED = BR_SSL_CLOSED, GT_SENDREC = BR_SSL_SENDREC, GT_RECVREC = BR_SSL_RECVREC,
    GT_SENDAPP = BR_SSL_SENDAPP, GT_RECVAPP = BR_SSL_RECVAPP
};

unsigned gtls_state(gtls_conn *t) { return br_ssl_engine_current_state(t->eng); }
int gtls_last_error(gtls_conn *t) { return br_ssl_engine_last_error(t->eng); }

/* Records from the network. Returns bytes taken (0 if the engine wants none now). */
size_t gtls_push_records(gtls_conn *t, const unsigned char *data, size_t len) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_RECVREC)) return 0;
    size_t cap;
    unsigned char *buf = br_ssl_engine_recvrec_buf(t->eng, &cap);
    size_t n = len < cap ? len : cap;
    memcpy(buf, data, n);
    br_ssl_engine_recvrec_ack(t->eng, n);
    return n;
}

/* Records for the network. Returns bytes written to `out`. */
size_t gtls_pull_records(gtls_conn *t, unsigned char *out, size_t cap) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_SENDREC)) return 0;
    size_t len;
    unsigned char *buf = br_ssl_engine_sendrec_buf(t->eng, &len);
    size_t n = len < cap ? len : cap;
    memcpy(out, buf, n);
    br_ssl_engine_sendrec_ack(t->eng, n);
    return n;
}

/* Plaintext to send. Returns bytes taken (0 until the handshake is done). */
size_t gtls_push_app(gtls_conn *t, const unsigned char *data, size_t len) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_SENDAPP)) return 0;
    size_t cap;
    unsigned char *buf = br_ssl_engine_sendapp_buf(t->eng, &cap);
    size_t n = len < cap ? len : cap;
    memcpy(buf, data, n);
    br_ssl_engine_sendapp_ack(t->eng, n);
    return n;
}

void gtls_flush(gtls_conn *t) { br_ssl_engine_flush(t->eng, 0); }

/* Plaintext received. Returns bytes written to `out`. */
size_t gtls_pull_app(gtls_conn *t, unsigned char *out, size_t cap) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_RECVAPP)) return 0;
    size_t len;
    unsigned char *buf = br_ssl_engine_recvapp_buf(t->eng, &len);
    size_t n = len < cap ? len : cap;
    memcpy(out, buf, n);
    br_ssl_engine_recvapp_ack(t->eng, n);
    return n;
}

/* Starts close_notify. */
void gtls_close(gtls_conn *t) { br_ssl_engine_close(t->eng); }

/* After the handshake: the negotiated ALPN protocol, or NULL. */
const char *gtls_alpn(gtls_conn *t) { return br_ssl_engine_get_selected_protocol(t->eng); }

/* After the handshake: 1 if the peer is authenticated as required. */
/* After the handshake: 1 if the session was resumed rather than made afresh. */
int gtls_resumed(gtls_conn *t) {
    if (t->watch.chain_seen) return 0;
    if (t->is_server) return t->resumed;
    br_ssl_session_parameters p;
    br_ssl_engine_get_session_parameters(t->eng, &p);
    return t->offered && p.session_id_len == t->offered_len &&
           memcmp(p.session_id, t->offered_id, t->offered_len) == 0;
}

int gtls_peer_ok(gtls_conn *t) {
    /* A resumed session presents no chain; the peer was authenticated when the
     * session was made (only such sessions are offered or cached) and proves
     * it still holds the master secret by the Finished messages. */
    int ok = !t->verify_peer || t->watch.validated || gtls_resumed(t);
    /* Keep a session that was just made for the next connection. */
    if (ok && !t->is_server && !t->saved && t->watch.chain_seen && t->watch.validated &&
        t->conf && t->conf->lifetime > 0) {
        br_ssl_session_parameters p;
        br_ssl_engine_get_session_parameters(t->eng, &p);
        if (p.session_id_len > 0 && p.session_id_len <= sizeof p.session_id) {
            gtls_conf *c = t->conf;
            pthread_mutex_lock(&c->mu);
            c->csess = p;
            c->have_session = 1;
            c->ctime = now_s();
            snprintf(c->cname, sizeof c->cname, "%s", t->sni);
            pthread_mutex_unlock(&c->mu);
        }
        t->saved = 1;
        memset(&p, 0, sizeof p);
    }
    return ok;
}
