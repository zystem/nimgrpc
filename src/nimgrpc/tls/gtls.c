/*
 * I/O-free TLS on BearSSL for nimgrpc.
 *
 * A gtls_conf holds what is shared by many connections and never changes once
 * built: trust anchors, our certificate chain and private key, and whether a
 * client certificate is required. Once a connection is made from it, or it is
 * shared or handed to a server (`frozen`), its setters refuse: a connection
 * points into the arrays of the configuration, and changing them under it
 * would leave it with freed or half-written memory. A gtls_conn is one TLS session; bytes go in
 * and out through four buffers (records in, records out, plaintext in,
 * plaintext out) and the conn never touches a socket.
 *
 * Who may touch what, and what is synchronized here:
 *
 *  -- A gtls_conn is not synchronized at all: the Nim side calls every function on it with the
 *     lock of its connection held, one thread at a time.
 *  -- A gtls_conf is built by ONE thread, with the setters, before it is used. The setters
 *     (and `gtls_conf_new`) are not synchronized with each other, nor with a freeze made by another
 *     thread: a setter that runs while another thread makes a connection from the same
 *     configuration, or shares it, is a data race. The check "is it frozen" is atomic; what it
 *     guards is not locked. Once frozen, the arrays and fields of the configuration are only read,
 *     by any number of threads, except the two that follow.
 *  -- `refs` (the owners, the connections made from it) and `frozen` are atomic.
 *  -- `mu` of the configuration guards what connections write to it: the creation of the cache
 *     of sessions, and the one session a client saves (`csess`, `have_session`, `cname`, `ctime`).
 *  -- A gtls_cache has its own `mu`, which guards the LRU store and the table of the identities of
 *     the clients of its sessions.
 *  -- The text of the last error is not kept in the configuration: it is a buffer of the thread
 *     that made the call (`g_err`), because connections are made from a configuration that other
 *     threads use at the same time. Read it right after the call that failed, on the same thread.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <arpa/inet.h>
#include "bearssl.h"

/* A memset that the optimizer may not drop. A `memset` of memory that is freed next is a dead
 * store to a compiler, and with optimization it is gone: the secret stays in the freed block
 * (the audit of 2026-11-21 saw it missing in a release binary). Calling it through a volatile
 * pointer makes the call opaque. */
static void *(*volatile gtls_memset_v)(void *, int, size_t) = memset;
static void secure_zero(void *p, size_t n) {
    if (p && n) gtls_memset_v(p, 0, n);
}

/* Equality of two byte strings in a time that depends only on their length, for what a peer
 * offers and we compare with what we hold (a session id). */
static int ct_eq(const unsigned char *a, const unsigned char *b, size_t n) {
    unsigned d = 0;
    for (size_t i = 0; i < n; i++) d |= (unsigned)(a[i] ^ b[i]);
    return d == 0;
}

/* The text of the last error of this thread (see the top of this file). */
static __thread char g_err[160];

#ifdef GTLS_FAIL_INJECT
/* For tests/tmemory.nim only: the allocation with this number (0 is the next one) fails, once;
 * -1 means none. Every allocation of this file goes through these four. */
long gtls_fail_after = -1;
static int gtls_fail_now(void) {
    if (gtls_fail_after < 0) return 0;
    if (gtls_fail_after == 0) { gtls_fail_after = -1; return 1; }
    gtls_fail_after--;
    return 0;
}
static void *g_malloc(size_t n) { return gtls_fail_now() ? NULL : malloc(n); }
static void *g_calloc(size_t a, size_t b) { return gtls_fail_now() ? NULL : calloc(a, b); }
static void *g_realloc(void *p, size_t n) { return gtls_fail_now() ? NULL : realloc(p, n); }
static char *g_strdup(const char *s) { return gtls_fail_now() ? NULL : strdup(s); }
#define malloc g_malloc
#define calloc g_calloc
#define realloc g_realloc
#define strdup g_strdup
#endif

/* ------------------------------------------------------------------ buffers */

typedef struct {
    unsigned char *buf;
    size_t len, cap;
    int err;               /* an allocation failed: what is in `buf` is not all there was */
    int secret;            /* it may hold a private key: growing it must not leave a copy behind */
} gbuf;

/* Room for `need` bytes. A buffer that may hold a private key is not grown with `realloc`: that
 * may move the bytes and give the old block back to the allocator as it is. The new block is made,
 * the bytes copied, the old block wiped and then freed; if the new block cannot be made, the old
 * one is left as it was (and the owner wipes it when it lets go). No size is allowed to wrap. */
static int gbuf_room(gbuf *b, size_t need) {
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < need) {
        if (cap > ((size_t)-1) / 2) return -1;
        cap *= 2;
    }
    if (b->secret) {
        unsigned char *nb = malloc(cap);
        if (!nb) return -1;
        if (b->len) memcpy(nb, b->buf, b->len);
        secure_zero(b->buf, b->cap);
        free(b->buf);
        b->buf = nb;
    } else {
        unsigned char *nb = realloc(b->buf, cap);
        if (!nb) return -1;
        b->buf = nb;
    }
    b->cap = cap;
    return 0;
}

static int gbuf_add(gbuf *b, const void *data, size_t len) {
    if (b->err) return -1;
    if (len > ((size_t)-1) - b->len) { b->err = 1; return -1; }
    if (b->len + len > b->cap && gbuf_room(b, b->len + len) != 0) { b->err = 1; return -1; }
    memcpy(b->buf + b->len, data, len);
    b->len += len;
    return 0;
}

/* The decoders call this with no way to say "no": the failure is kept in the buffer, and whoever
 * owns the buffer looks at `err` (a half-copied certificate or key must not be used). */
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

/* Decodes every PEM object in `pem`. Returns the number of objects, or -1 (a bad PEM, or an
 * allocation that failed: nothing is returned then). The bytes of an object may be a private key;
 * the working buffer is wiped before it is freed. */
static long decode_pem(const unsigned char *pem, size_t len, pem_obj **out) {
    br_pem_decoder_context pc;
    pem_obj *objs = NULL;
    size_t n = 0;
    gbuf cur = {0};
    int inobj = 0;
    char *name = NULL;
    int extra_nl = 1;

    cur.secret = 1;           /* an object of a PEM may be a private key */

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
            free(name);
            name = strdup(br_pem_decoder_name(&pc));
            if (!name) goto fail;
            cur.len = 0;
            br_pem_decoder_setdest(&pc, gbuf_sink, &cur);
            inobj = 1;
            break;
        case BR_PEM_END_OBJ:
            if (inobj) {
                if (cur.err) goto fail;
                pem_obj *no = realloc(objs, (n + 1) * sizeof *objs);
                if (!no) goto fail;
                objs = no;
                unsigned char *d = dupmem(cur.buf, cur.len);
                if (!d) goto fail;
                objs[n].name = name;
                objs[n].data = d;
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
    secure_zero(cur.buf, cur.cap);
    free(cur.buf);
    if (inobj) { free(name); goto fail2; }
    free(name);
    *out = objs;
    return (long)n;
fail:
    secure_zero(cur.buf, cur.cap);
    free(cur.buf);
    free(name);
fail2:
    for (size_t i = 0; i < n; i++) { free(objs[i].name); secure_zero(objs[i].data, objs[i].len); free(objs[i].data); }
    free(objs);
    return -1;
}

static void free_pem(pem_obj *objs, long n) {
    for (long i = 0; i < n; i++) {
        free(objs[i].name);
        secure_zero(objs[i].data, objs[i].len);    /* it may be a private key */
        free(objs[i].data);
    }
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
    int refs;                      /* owners: the TlsConfig handles and the connections made from it (atomic) */
    int frozen;                    /* set once the configuration is in use (atomic); the setters then refuse */
    pthread_mutex_t mu;            /* guards `cache` (creation) and the saved client session */
    struct gtls_cache *cache;      /* server: sessions that may be resumed */
    int have_session;              /* client: the last verified session ... */
    br_ssl_session_parameters csess;
    char cname[256];               /* ... and the server name it was made for */
    long long ctime;               /* ... and when (monotonic seconds) */
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
        c->refs = 1;
        pthread_mutex_init(&c->mu, NULL);
    }
    return c;
}

const char *gtls_conf_error(gtls_conf *c) { (void)c; return g_err; }

/* The building phase is over: connections, `share` and servers call this. Nothing writes
 * to the configuration's own fields after it. */
void gtls_conf_freeze(gtls_conf *c) {
    if (c) __atomic_store_n(&c->frozen, 1, __ATOMIC_RELEASE);
}

int gtls_conf_frozen(gtls_conf *c) { return __atomic_load_n(&c->frozen, __ATOMIC_ACQUIRE); }

/* The setters return -1 on a frozen configuration, and then write nothing, not even the error text (another thread may be reading it). */
int gtls_conf_set_cipher_order(gtls_conf *c, int order) {
    if (gtls_conf_frozen(c)) return -1;
    c->cipher_order = order;
    return 0;
}

int gtls_conf_set_lifetime(gtls_conf *c, int seconds) {
    if (gtls_conf_frozen(c)) return -1;
    c->lifetime = seconds < 0 ? 0 : seconds;
    return 0;
}

static void dn_append(void *ctx, const void *buf, size_t len) {
    gbuf_add((gbuf *)ctx, buf, len);
}

static void free_ta(br_x509_trust_anchor *ta) {
    free(ta->dn.data);
    if (ta->pkey.key_type == BR_KEYTYPE_RSA) {
        free(ta->pkey.key.rsa.n);
        free(ta->pkey.key.rsa.e);
    } else {
        free(ta->pkey.key.ec.q);
    }
}

/* Adds every certificate in `pem` as a trust anchor. Returns the count, or -1; on -1 nothing
 * was added (the certificates are collected first and published together). */
long gtls_conf_add_ca(gtls_conf *c, const unsigned char *pem, size_t len) {
    if (gtls_conf_frozen(c)) return -1;
    pem_obj *objs;
    long n = decode_pem(pem, len, &objs), added = 0;
    if (n < 0) { strcpy(g_err, "invalid PEM in CA bundle"); return -1; }
    br_x509_trust_anchor *nta = NULL;
    for (long i = 0; i < n; i++) {
        if (!is_cert_name(objs[i].name)) continue;
        br_x509_decoder_context dc;
        gbuf dn = {0};
        br_x509_decoder_init(&dc, dn_append, &dn);
        br_x509_decoder_push(&dc, objs[i].data, objs[i].len);
        if (dn.err) { free(dn.buf); strcpy(g_err, "out of memory"); goto fail; }
        br_x509_pkey *pk = br_x509_decoder_get_pkey(&dc);
        if (pk == NULL) {
            free(dn.buf);
            snprintf(g_err, sizeof g_err, "CA certificate %ld: decode error %d",
                     i, br_x509_decoder_last_error(&dc));
            goto fail;
        }
        br_x509_trust_anchor *t = realloc(nta, (added + 1) * sizeof *t);
        if (!t) { free(dn.buf); strcpy(g_err, "out of memory"); goto fail; }
        nta = t;
        br_x509_trust_anchor *ta = &nta[added];
        memset(ta, 0, sizeof *ta);
        ta->dn.data = dn.buf;
        ta->dn.len = dn.len;
        ta->flags = br_x509_decoder_isCA(&dc) ? BR_X509_TA_CA : 0;
        ta->pkey.key_type = pk->key_type;
        added++;      /* counted now, so that `fail` frees what is half made */
        int ok;
        if (pk->key_type == BR_KEYTYPE_RSA) {
            ta->pkey.key.rsa.n = dupmem(pk->key.rsa.n, pk->key.rsa.nlen);
            ta->pkey.key.rsa.nlen = pk->key.rsa.nlen;
            ta->pkey.key.rsa.e = dupmem(pk->key.rsa.e, pk->key.rsa.elen);
            ta->pkey.key.rsa.elen = pk->key.rsa.elen;
            ok = ta->pkey.key.rsa.n && ta->pkey.key.rsa.e;
        } else {
            ta->pkey.key.ec.curve = pk->key.ec.curve;
            ta->pkey.key.ec.q = dupmem(pk->key.ec.q, pk->key.ec.qlen);
            ta->pkey.key.ec.qlen = pk->key.ec.qlen;
            ok = ta->pkey.key.ec.q != NULL;
        }
        if (!ok || !ta->dn.data) { strcpy(g_err, "out of memory"); goto fail; }
    }
    free_pem(objs, n);
    if (added == 0) { strcpy(g_err, "no certificate in CA bundle"); return -1; }
    br_x509_trust_anchor *all = realloc(c->tas, (c->ta_num + added) * sizeof *all);
    if (!all) {
        for (long k = 0; k < added; k++) free_ta(&nta[k]);
        free(nta);
        strcpy(g_err, "out of memory");
        return -1;
    }
    memcpy(all + c->ta_num, nta, added * sizeof *nta);
    c->tas = all;
    c->ta_num += added;
    free(nta);
    return added;
fail:
    for (long k = 0; k < added; k++) free_ta(&nta[k]);
    free(nta);
    free_pem(objs, n);
    return -1;
}

static void free_chain(br_x509_certificate *chain, size_t n) {
    for (size_t i = 0; i < n; i++) free(chain[i].data);
    free(chain);
}

static size_t key_bytes(int key_type, const br_rsa_private_key *rsa, const br_ec_private_key *ec) {
    return key_type == BR_KEYTYPE_RSA
        ? rsa->plen + rsa->qlen + rsa->dplen + rsa->dqlen + rsa->iqlen
        : ec->xlen;
}

/* Our certificate chain (leaf first) and its private key. Returns 0 or -1. The chain and the
 * key are decoded and checked first and replace the ones in use together: on -1 the
 * configuration is as it was, and a second call replaces the identity, it does not add to it. */
int gtls_conf_set_identity(gtls_conf *c, const unsigned char *chain_pem, size_t chain_len,
                           const unsigned char *key_pem, size_t key_len) {
    if (gtls_conf_frozen(c)) return -1;
    pem_obj *objs;
    br_x509_certificate *nchain = NULL;
    size_t nlen = 0;
    br_rsa_private_key nrsa;
    br_ec_private_key nec;
    unsigned char *nkey = NULL;
    int ntype = 0;
    memset(&nrsa, 0, sizeof nrsa);
    memset(&nec, 0, sizeof nec);

    long n = decode_pem(chain_pem, chain_len, &objs);
    if (n < 0) { strcpy(g_err, "invalid PEM in certificate chain"); return -1; }
    for (long i = 0; i < n; i++) {
        if (!is_cert_name(objs[i].name)) continue;
        unsigned char *d = dupmem(objs[i].data, objs[i].len);
        br_x509_certificate *t = realloc(nchain, (nlen + 1) * sizeof *t);
        if (t) nchain = t;
        if (!d || !t) {
            free(d);
            free_chain(nchain, nlen);
            free_pem(objs, n);
            strcpy(g_err, "out of memory");
            return -1;
        }
        nchain[nlen].data = d;
        nchain[nlen].data_len = objs[i].len;
        nlen++;
    }
    free_pem(objs, n);
    if (nlen == 0) { strcpy(g_err, "no certificate in chain"); return -1; }

    n = decode_pem(key_pem, key_len, &objs);
    if (n < 0) {
        free_chain(nchain, nlen);
        strcpy(g_err, "invalid PEM in private key");
        return -1;
    }
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
            snprintf(g_err, sizeof g_err, "private key decode error %d", err);
            secure_zero(&sk, sizeof sk);
            goto fail;
        }
        ntype = br_skey_decoder_key_type(&sk);
        if (ntype == BR_KEYTYPE_RSA) {
            const br_rsa_private_key *k = br_skey_decoder_get_rsa(&sk);
            size_t tot = k->plen + k->qlen + k->dplen + k->dqlen + k->iqlen;
            unsigned char *m = malloc(tot ? tot : 1), *p = m;
            if (!m) { strcpy(g_err, "out of memory"); secure_zero(&sk, sizeof sk); goto fail; }
            nrsa = *k;
#define CP(f, l) memcpy(p, k->f, k->l); nrsa.f = p; p += k->l;
            CP(p, plen) CP(q, qlen) CP(dp, dplen) CP(dq, dqlen) CP(iq, iqlen)
#undef CP
            nkey = m;
        } else if (ntype == BR_KEYTYPE_EC) {
            const br_ec_private_key *k = br_skey_decoder_get_ec(&sk);
            nec = *k;
            nkey = dupmem(k->x, k->xlen);
            if (!nkey) { strcpy(g_err, "out of memory"); secure_zero(&sk, sizeof sk); goto fail; }
            nec.x = nkey;
        } else {
            strcpy(g_err, "unsupported private key");
            secure_zero(&sk, sizeof sk);
            goto fail;
        }
        secure_zero(&sk, sizeof sk);     /* the decoder holds a copy of the key */
        found = 1;
    }
    free_pem(objs, n);                   /* wipes the DER of the key */
    if (!found) {
        free_chain(nchain, nlen);
        strcpy(g_err, "no private key in PEM");
        return -1;
    }
    /* publish: the old identity goes, the new one is whole */
    free_chain(c->chain, c->chain_len);
    if (c->key_mem) {
        secure_zero(c->key_mem, key_bytes(c->key_type, &c->rsa, &c->ec));
        free(c->key_mem);
    }
    c->chain = nchain;
    c->chain_len = nlen;
    c->key_type = ntype;
    c->rsa = nrsa;
    c->ec = nec;
    c->key_mem = nkey;
    return 0;
fail:
    if (nkey) { secure_zero(nkey, key_bytes(ntype, &nrsa, &nec)); free(nkey); }
    free_pem(objs, n);
    free_chain(nchain, nlen);
    return -1;
}

int gtls_conf_require_client_cert(gtls_conf *c, int on) {
    if (gtls_conf_frozen(c)) return -1;
    c->require_client_cert = on;
    return 0;
}

static void cache_free(struct gtls_cache *k);

static void conf_destroy(gtls_conf *c) {
    for (size_t i = 0; i < c->ta_num; i++) free_ta(&c->tas[i]);
    free(c->tas);
    cache_free(c->cache);
    pthread_mutex_destroy(&c->mu);
    for (size_t i = 0; i < c->chain_len; i++) free(c->chain[i].data);
    free(c->chain);
    if (c->key_mem) {
        /* wipe the private key before giving the memory back */
        secure_zero(c->key_mem, key_bytes(c->key_type, &c->rsa, &c->ec));
        free(c->key_mem);
    }
    secure_zero(c, sizeof *c);                   /* the saved client session's master secret, and the key's pointers */
    free(c);
}

/* An owner more: a handle made by `share`, or a connection. The count is atomic, so owners in different threads need no lock of ours. */
void gtls_conf_retain(gtls_conf *c) {
    if (!c) return;
    gtls_conf_freeze(c);          /* a second owner: the setters are over */
    __atomic_fetch_add(&c->refs, 1, __ATOMIC_RELAXED);
}

/* An owner less; the last one frees the configuration (and so the trust anchors, the identity and the sessions that connections made from it still use are never freed under them). */
void gtls_conf_free(gtls_conf *c) {
    if (!c) return;
    if (__atomic_fetch_sub(&c->refs, 1, __ATOMIC_ACQ_REL) == 1) conf_destroy(c);
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
    int capture;                   /* keep the leaf for the application too (a server that asks for client certificates) */
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
    if ((w->want_ip || w->capture) && w->cert_idx == 0 && !w->leaf_bad) {
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
    /* A client certificate that chains to a trusted CA but whose bytes we could not keep has no
     * identity to give the application: refused, not accepted without one. */
    if (r == 0 && w->capture && (w->leaf_bad || w->leaf_len == 0))
        r = BR_ERR_X509_LIMIT_EXCEEDED;
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
    const br_ssl_server_policy_class *policy_vt;  /* server: wraps the inner policy (ALPN check) */
    const br_ssl_server_policy_class **inner;     /* server: the policy BearSSL installed */
    int alpn_refused;              /* server: the client offered no ALPN protocol */
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

/* A server policy that refuses a client which did not offer ALPN: BearSSL's
 * BR_OPT_FAIL_ON_ALPN_MISMATCH only fails when the client offers protocols and none
 * matches; a ClientHello with no ALPN extension would complete the handshake. BearSSL asks
 * the policy on a full handshake only; a resumed one is checked by gtls_alpn once it is done. */
static int policy_choose(const br_ssl_server_policy_class **pctx, const br_ssl_server_context *cc,
                         br_ssl_server_choices *choices) {
    gtls_conn *t = (gtls_conn *)((char *)pctx - offsetof(gtls_conn, policy_vt));
    if (br_ssl_engine_get_selected_protocol((br_ssl_engine_context *)&cc->eng) == NULL) {
        t->alpn_refused = 1;
        return 0;                  /* handshake_failure alert */
    }
    return (*t->inner)->choose(t->inner, cc, choices);
}
static uint32_t policy_keyx(const br_ssl_server_policy_class **pctx, unsigned char *data,
                            size_t *len) {
    gtls_conn *t = (gtls_conn *)((char *)pctx - offsetof(gtls_conn, policy_vt));
    return (*t->inner)->do_keyx(t->inner, data, len);
}
static size_t policy_sign(const br_ssl_server_policy_class **pctx, unsigned algo_id,
                          unsigned char *data, size_t hv_len, size_t len) {
    gtls_conn *t = (gtls_conn *)((char *)pctx - offsetof(gtls_conn, policy_vt));
    return (*t->inner)->do_sign(t->inner, algo_id, data, hv_len, len);
}
static const br_ssl_server_policy_class policy_class = {
    sizeof(br_ssl_server_policy_class *), policy_choose, policy_keyx, policy_sign
};

/* ---------------------------------------------------------- session cache
 *
 * Session resumption (TLS 1.2 session ids) skips the public-key work of a
 * handshake. BearSSL's LRU cache is not thread-safe and has no lifetime, so it
 * is wrapped: a mutex around every call, and the whole cache is dropped once
 * `lifetime` seconds have passed since it was started, so no session lives
 * longer than that. Only sessions of peers that were authenticated as required
 * are kept (checked in `cache_save`).
 */

/* A resumed session presents no certificate, so a server that asks for client certificates keeps
 * the leaf of each session it saves, next to the session, under the session id: the identity of
 * a resumed connection is that of the connection the session was made on. A session whose
 * identity is not here (the table is smaller than the cache, and goes with it) is not resumed. */
#define IDENT_SLOTS 512
typedef struct {
    unsigned char id[32];
    size_t id_len;
    unsigned char *der;
    size_t der_len;
} ident_slot;

typedef struct gtls_cache {
    const br_ssl_session_cache_class *vt;
    br_ssl_session_cache_lru lru;
    pthread_mutex_t mu;
    unsigned char *buf;
    long long epoch;
    int lifetime;
    ident_slot ident[IDENT_SLOTS];
    unsigned ident_next;
} gtls_cache;

static void ident_clear(gtls_cache *k) {
    for (int i = 0; i < IDENT_SLOTS; i++) { free(k->ident[i].der); }
    memset(k->ident, 0, sizeof k->ident);
    k->ident_next = 0;
}

static void ident_put(gtls_cache *k, const unsigned char *id, size_t id_len,
                      const unsigned char *der, size_t der_len) {
    if (id_len == 0 || id_len > sizeof k->ident[0].id) return;
    ident_slot *sl = &k->ident[k->ident_next++ % IDENT_SLOTS];
    free(sl->der);
    sl->der = dupmem(der, der_len);
    sl->der_len = sl->der ? der_len : 0;
    sl->id_len = sl->der ? id_len : 0;
    if (sl->der) memcpy(sl->id, id, id_len);
}

static const ident_slot *ident_get(const gtls_cache *k, const unsigned char *id, size_t id_len) {
    /* the id is what the client offers: every slot is looked at, each in constant time */
    const ident_slot *found = NULL;
    for (int i = 0; i < IDENT_SLOTS; i++) {
        const ident_slot *sl = &k->ident[i];
        if (sl->der && sl->id_len == id_len && ct_eq(sl->id, id, id_len)) found = sl;
    }
    return found;
}

static void cache_expire(gtls_cache *k) {
    long long now = now_s();
    if (now - k->epoch >= k->lifetime) {
        secure_zero(k->buf, CACHE_BYTES);      /* the old sessions' master secrets, not only forgotten */
        br_ssl_session_cache_lru_init(&k->lru, k->buf, CACHE_BYTES);
        ident_clear(k);
        k->epoch = now;
    }
}

static void cache_save(const br_ssl_session_cache_class **ctx, br_ssl_server_context *sc,
                       const br_ssl_session_parameters *params) {
    gtls_cache *k = (gtls_cache *)ctx;
    gtls_conn *t = (gtls_conn *)sc;            /* the server context is the first member */
    if (t->verify_peer && (!t->watch.validated || t->watch.leaf_bad || t->watch.leaf_len == 0)) return;
    pthread_mutex_lock(&k->mu);
    cache_expire(k);
    k->lru.vtable->save(&k->lru.vtable, sc, params);
    if (t->verify_peer)
        ident_put(k, params->session_id, params->session_id_len, t->watch.leaf, t->watch.leaf_len);
    pthread_mutex_unlock(&k->mu);
}

static int cache_load(const br_ssl_session_cache_class **ctx, br_ssl_server_context *sc,
                      br_ssl_session_parameters *params) {
    gtls_cache *k = (gtls_cache *)ctx;
    gtls_conn *t = (gtls_conn *)sc;
    pthread_mutex_lock(&k->mu);
    cache_expire(k);
    int r = k->lru.vtable->load(&k->lru.vtable, sc, params);
    if (r && t->verify_peer) {
        /* the client of this session was authenticated by a certificate: it is still this one */
        const ident_slot *sl = ident_get(k, params->session_id, params->session_id_len);
        unsigned char *copy = sl ? dupmem(sl->der, sl->der_len) : NULL;
        if (!copy) {
            r = 0;                              /* no identity to give: a full handshake */
        } else {
            free(t->watch.leaf);
            t->watch.leaf = copy;
            t->watch.leaf_len = t->watch.leaf_cap = sl->der_len;
            t->watch.leaf_bad = 0;
        }
    }
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
    ident_clear(k);
    secure_zero(k->buf, CACHE_BYTES);          /* sessions with their master secrets */
    free(k->buf);
    secure_zero(k, sizeof *k);
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
    gtls_conf_freeze(c);          /* before anything is read from it */
    if (c->ta_num == 0) { strcpy(g_err, "client needs trust anchors"); return NULL; }
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) { strcpy(g_err, "out of memory"); return NULL; }
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
        secure_zero(t, sizeof *t);
        free(t);
        strcpy(g_err, "cannot start the handshake");
        return NULL;
    }
    gtls_conf_retain(c);          /* the connection keeps the configuration alive; gtls_free lets go */
    return t;
}

/* A server session. Returns NULL on error. */
gtls_conn *gtls_server_new(gtls_conf *c) {
    gtls_conf_freeze(c);
    if (c->chain_len == 0) { strcpy(g_err, "server needs a certificate and key"); return NULL; }
    gtls_conn *t = calloc(1, sizeof *t);
    if (!t) { strcpy(g_err, "out of memory"); return NULL; }
    t->is_server = 1;
    t->eng = &t->u.server.eng;
    if (c->key_type == BR_KEYTYPE_RSA)
        br_ssl_server_init_full_rsa(&t->u.server, c->chain, c->chain_len, &c->rsa);
    else
        br_ssl_server_init_full_ec(&t->u.server, c->chain, c->chain_len,
                                   BR_KEYTYPE_EC, &c->ec);
    setup_common(t, c);
    t->inner = t->u.server.policy_vtable;
    t->policy_vt = &policy_class;
    br_ssl_server_set_policy(&t->u.server, &t->policy_vt);
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
        t->watch.capture = 1;        /* the client's certificate is the identity the handlers see */
    }
    if (!br_ssl_server_reset(&t->u.server)) {
        secure_zero(t, sizeof *t);
        free(t);
        strcpy(g_err, "cannot start the handshake");
        return NULL;
    }
    gtls_conf_retain(c);
    return t;
}

void gtls_free(gtls_conn *t) {
    if (t) {
        gtls_conf *c = t->conf;
        free(t->watch.leaf);
        secure_zero(t, sizeof *t);     /* the record keys and the plaintext in its buffers */
        free(t);
        gtls_conf_free(c);
    }
}

/* ------------------------------------------------------------------ pump */

enum {
    GT_CLOSED = BR_SSL_CLOSED, GT_SENDREC = BR_SSL_SENDREC, GT_RECVREC = BR_SSL_RECVREC,
    GT_SENDAPP = BR_SSL_SENDAPP, GT_RECVAPP = BR_SSL_RECVAPP
};

unsigned gtls_state(gtls_conn *t) { return br_ssl_engine_current_state(t->eng); }
/* 1 if a server refused the client because it offered no ALPN protocol. */
int gtls_alpn_refused(gtls_conn *t) { return t->alpn_refused; }
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

/* Bytes of records ready for the network, and of plaintext ready to be read. The caller asks
   before it makes room: an empty poll then allocates nothing, and a small record does not sit in a
   buffer of 16 KiB or more, which a limit on the bytes of a queue would not see. */
size_t gtls_ready_records(gtls_conn *t) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_SENDREC)) return 0;
    size_t len;
    br_ssl_engine_sendrec_buf(t->eng, &len);
    return len;
}

size_t gtls_ready_app(gtls_conn *t) {
    if (!(br_ssl_engine_current_state(t->eng) & BR_SSL_RECVAPP)) return 0;
    size_t len;
    br_ssl_engine_recvapp_buf(t->eng, &len);
    return len;
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
    int same = t->offered && p.session_id_len == t->offered_len &&
               ct_eq(p.session_id, t->offered_id, t->offered_len);
    secure_zero(&p, sizeof p);           /* a copy of the master secret, on the stack */
    return same;
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
        secure_zero(&p, sizeof p);
    }
    return ok;
}

/* The leaf certificate (DER) of the client of a server that asks for client certificates, once the
 * handshake is done and the peer is authenticated; NULL if there is none. The bytes belong to
 * the connection and stay as long as it does. */
const unsigned char *gtls_peer_cert(gtls_conn *t, size_t *len) {
    if (!t->is_server || !t->verify_peer || t->watch.leaf_bad || t->watch.leaf_len == 0) return NULL;
    if (!gtls_peer_ok(t)) return NULL;
    *len = t->watch.leaf_len;
    return t->watch.leaf;
}
