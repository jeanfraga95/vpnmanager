#define _GNU_SOURCE 1

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <event2/event.h>
#include <event2/buffer.h>
#include <event2/bufferevent.h>
#include <event2/listener.h>
#include <event2/util.h>
#include <openssl/sha.h>

// --- Configurações Padrão ---
int PORT = 80;
int TO_PORT = 22;
char* RESPONSE = "OK";

// DPI bypass (ativo por padrão — use --no-dpi para desligar)
bool DPI_ENABLED = true;
bool LEGACY_101 = false;
bool WAIT_MAGIC = true;          // hibrido: so envia 200 apos npv-x/SSH-
bool SOCKS_FORCE_LOCAL = false;
int DPI_FRAG_BYTES = 48;
int DPI_CHUNK = 8;
int DPI_DELAY_MS = 12;

// Novos recursos
// 101 imediato no aceite (comportamento do proxy original). O app CloudJF
// espera o 101 sem enviar nada antes; desativar com --no-immediate-101.
bool IMMEDIATE_101 = true;
bool KEEPALIVE = true;
char TLS_TARGET_HOST[256] = "127.0.0.1";
int TLS_TARGET_PORT = 443;
char SNI_ALLOW[256] = "";       // se setado, só esse SNI é encaminhado ao TLS
char AUTH_TOKEN[256] = "";      // se setado, exige token no WS/HTTP/SOCKS

#define MAXBUF 8192

struct event_base *base;

typedef enum {
    ST_INIT = 0,
    ST_WS_MAGIC,
    ST_SOCKS5_METHODS,
    ST_SOCKS5_AUTH,
    ST_SOCKS5_REQ,
    ST_SOCKS4_REQ,
    ST_TLS,
    ST_RELAY
} conn_state_t;

typedef struct {
    struct bufferevent *client;
    struct bufferevent *remote;
    conn_state_t state;
    bool connected_to_remote;
    bool freed;
    bool sent_101;               // evita responder 101 duas vezes na mesma conexão
    bool ssh_banner_sent;        // so encaminha ao sshd apos banner SSH valido
    bool in_control;             // descartando cabecalho HTTP parcial
    bool magic_ready;            // npv-x recebido no cabecalho HTTP
    bool raw_tunnel;             // CONNECT/SOCKS/TLS: nao filtrar banner SSH
    struct event *magic_timer;   // timeout explícito (libevent não rearma sozinho)
    int frag_in;
    int frag_out;
    // buffers auxiliares
    unsigned char pending[MAXBUF];
    size_t pending_len;
    unsigned char reply[64];
    size_t reply_len;
    // SOCKS / CONNECT / TLS
    char host[256];
    uint16_t port;
    int  socks_methods;
} proxy_ctx_t;

void client_read_cb(struct bufferevent *bev, void *user_data);
void remote_read_cb(struct bufferevent *bev, void *user_data);
void event_cb(struct bufferevent *bev, short events, void *user_data);
void accept_conn_cb(struct evconnlistener *listener, evutil_socket_t fd,
                    struct sockaddr *address, int socklen, void *ctx);

static void free_proxy_ctx(proxy_ctx_t *ctx) {
    if (!ctx || ctx->freed) return;
    ctx->freed = true;
    if (ctx->magic_timer) { event_free(ctx->magic_timer); ctx->magic_timer = NULL; }
    if (ctx->client) bufferevent_free(ctx->client);
    if (ctx->remote) bufferevent_free(ctx->remote);
    free(ctx);
}

static void clear_magic_timer(proxy_ctx_t *ctx) {
    if (ctx && ctx->magic_timer) {
        event_free(ctx->magic_timer);
        ctx->magic_timer = NULL;
    }
}

// Segurança: só fecha se o estado ainda for ST_WS_MAGIC após 24h (não ocioso real)
static void magic_timeout_cb(evutil_socket_t fd, short what, void *arg) {
    proxy_ctx_t *ctx = arg;
    (void)fd; (void)what;
    if (!ctx || ctx->freed) return;
    if (ctx->state == ST_WS_MAGIC && !ctx->connected_to_remote)
        free_proxy_ctx(ctx);
}

// --- DPI: primeiros bytes em pedaços pequenos com delay ---
static void relay_with_dpi(struct bufferevent *dst, struct evbuffer *input, int *remaining) {
    size_t len = evbuffer_get_length(input);
    if (!dst || len == 0) return;
    if (!DPI_ENABLED || *remaining <= 0) {
        evbuffer_add_buffer(bufferevent_get_output(dst), input);
        return;
    }
    size_t frag = (len < (size_t)*remaining) ? len : (size_t)*remaining;
    unsigned char *p = evbuffer_pullup(input, frag);
    if (!p) return;
    size_t i = 0;
    while (i < frag) {
        size_t chunk = (size_t)DPI_CHUNK;
        if (chunk > frag - i) chunk = frag - i;
        bufferevent_write(dst, p + i, chunk);
        bufferevent_flush(dst, EV_WRITE, BEV_FLUSH);
        if (i + chunk < frag) usleep(DPI_DELAY_MS * 1000);
        i += chunk;
    }
    evbuffer_drain(input, frag);
    *remaining -= (int)frag;
    if (evbuffer_get_length(input) > 0)
        evbuffer_add_buffer(bufferevent_get_output(dst), input);
}

// --- keepalive TCP (não injeta dados na aplicação) ---
static void set_keepalive(struct bufferevent *bev) {
    if (!KEEPALIVE || !bev) return;
    int fd = bufferevent_getfd(bev);
    if (fd < 0) return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
#ifdef TCP_KEEPIDLE
    int idle = 60;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
#endif
#ifdef TCP_KEEPINTVL
    int intvl = 30;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
#endif
#ifdef TCP_KEEPCNT
    int cnt = 3;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
#endif
}

static void set_nodelay(struct bufferevent *bev) {
    if (!bev) return;
    int fd = bufferevent_getfd(bev);
    if (fd >= 0) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    }
}

static void set_magic_timeouts(proxy_ctx_t *ctx) {
    // SEM timeout ocioso: o app pode demorar depois do 101 para enviar o
    // magic (npv-x/SSH-). Um timeout curto aqui derrubava a conexão e gerava
    // "connection is closed by foreign host" / "Read timed out" no app.
    // 24h = ilimitado na pratica; o timer é limpo em connect_relay().
    if (!ctx || !ctx->client) return;
    clear_magic_timer(ctx);
    ctx->magic_timer = evtimer_new(base, magic_timeout_cb, ctx);
    struct timeval tv = {86400, 0};
    if (ctx->magic_timer) evtimer_add(ctx->magic_timer, &tv);
    bufferevent_set_timeouts(ctx->client, NULL, NULL);
}

// --- utilitários HTTP / cripto ---
static void make_ws_accept(const char *key, char *out, size_t outlen) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char buf[1024];
    snprintf(buf, sizeof(buf), "%s%s", key, guid);
    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)buf, strlen(buf), digest);
    static const char b64[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t j = 0;
    for (size_t i = 0; i < SHA_DIGEST_LENGTH; i += 3) {
        unsigned int v = ((unsigned int)digest[i] << 16);
        if (i + 1 < SHA_DIGEST_LENGTH) v |= ((unsigned int)digest[i+1] << 8);
        if (i + 2 < SHA_DIGEST_LENGTH) v |= (unsigned int)digest[i+2];
        if (j + 4 >= outlen) break;
        out[j++] = b64[(v >> 18) & 63];
        out[j++] = b64[(v >> 12) & 63];
        out[j++] = (i + 1 < SHA_DIGEST_LENGTH) ? b64[(v >> 6) & 63] : '=';
        out[j++] = (i + 2 < SHA_DIGEST_LENGTH) ? b64[v & 63] : '=';
    }
    out[j] = '\0';
}

// O app CloudJF envia cabeçalhos com \n (LF), não \r\n (CRLF).
// Retorna a posição do fim e o tamanho do terminador encontrado.
static size_t find_header_end(struct evbuffer *input, struct evbuffer_ptr *out) {
    size_t len = evbuffer_get_length(input);
    out->pos = -1;
    if (len == 0 || len > MAXBUF) return 0;
    unsigned char *d = evbuffer_pullup(input, len);
    if (!d) return 0;
    static const unsigned char crlf2[4] = {'\r','\n','\r','\n'};
    static const unsigned char lfcrlf[3] = {'\n','\r','\n'};
    static const unsigned char lf2[2] = {'\n','\n'};
    for (size_t i = 0; i + 4 <= len; i++)
        if (memcmp(d + i, crlf2, 4) == 0) { out->pos = (ev_ssize_t)i; return 4; }
    for (size_t i = 0; i + 3 <= len; i++)
        if (memcmp(d + i, lfcrlf, 3) == 0) { out->pos = (ev_ssize_t)i; return 3; }
    for (size_t i = 0; i + 2 <= len; i++)
        if (memcmp(d + i, lf2, 2) == 0) { out->pos = (ev_ssize_t)i; return 2; }
    return 0;
}

static char *hdr_blob(struct evbuffer *input, size_t *outlen) {
    if (!input) return NULL;
    struct evbuffer_ptr end;
    size_t term = find_header_end(input, &end);
    size_t hlen = (end.pos == -1) ? evbuffer_get_length(input) : (size_t)end.pos + term;
    if (hlen == 0 || hlen > MAXBUF) return NULL;
    char *h = malloc(hlen + 1);
    if (!h) return NULL;
    evbuffer_copyout(input, h, hlen);
    h[hlen] = '\0';
    if (outlen) *outlen = hlen;
    return h;
}

static bool header_value(const char *hdr, const char *name, char *out, size_t outlen) {
    if (!hdr || !name || !out || outlen == 0) return false;
    char needle[128];
    snprintf(needle, sizeof(needle), "%s:", name);
    char *p = strcasestr(hdr, needle);
    if (!p) return false;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t') p++;
    char *e = p;
    while (*e && *e != '\r' && *e != '\n') e++;
    size_t n = (size_t)(e - p);
    while (n > 0 && (p[n-1] == ' ' || p[n-1] == '\t')) n--;
    if (n == 0 || n >= outlen) return false;
    memcpy(out, p, n);
    out[n] = '\0';
    return true;
}

static bool token_ok(const char *hdr, const char *request_line) {
    if (AUTH_TOKEN[0] == '\0') return true;
    char v[512] = {0};
    if (header_value(hdr, "X-Auth-Token", v, sizeof(v)) && strcmp(v, AUTH_TOKEN) == 0)
        return true;
    if (header_value(hdr, "Authorization", v, sizeof(v))) {
        char *p = strcasestr(v, "Bearer ");
        if (p) {
            p += 7;
            while (*p == ' ') p++;
            if (strcmp(p, AUTH_TOKEN) == 0) return true;
        }
    }
    if (request_line) {
        char needle[300];
        snprintf(needle, sizeof(needle), "token=%s", AUTH_TOKEN);
        if (strstr(request_line, needle)) return true;
    }
    return false;
}

static void send_ws_101(proxy_ctx_t *ctx, struct evbuffer *input) {
    char resp[2048];
    if (LEGACY_101) {
        snprintf(resp, sizeof(resp), "HTTP/1.1 101 %s\r\n\r\n", RESPONSE);
    } else {
        size_t hlen = 0;
        char *hdr = hdr_blob(input, &hlen);
        char key[256] = {0}, accept[64] = {0};
        bool have_key = false;
        if (hdr) {
            have_key = header_value(hdr, "Sec-WebSocket-Key", key, sizeof(key));
            if (have_key) make_ws_accept(key, accept, sizeof(accept));
        }
        if (have_key) {
            snprintf(resp, sizeof(resp),
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n"
                "Server: nginx\r\n"
                "X-Request-Id: %08x\r\n"
                "\r\n", accept, (unsigned int)rand());
        } else {
            snprintf(resp, sizeof(resp),
                "HTTP/1.1 101 %s\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Server: nginx\r\n"
                "X-Request-Id: %08x\r\n"
                "\r\n", RESPONSE, (unsigned int)rand());
        }
        free(hdr);
    }
    bufferevent_write(ctx->client, resp, strlen(resp));
    bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
}

// 101 exato do proxy original (sem headers extras). Usado quando o cliente
// não envia nada no aceite — o app CloudJF espera essa resposta para continuar.
static void send_immediate_101(proxy_ctx_t *ctx) {
    char r[128];
    snprintf(r, sizeof(r), "HTTP/1.1 101 %s\r\n\r\n", RESPONSE);
    bufferevent_write(ctx->client, r, strlen(r));
    bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
}

static void send_http_200(proxy_ctx_t *ctx) {
    char r[256];
    snprintf(r, sizeof(r), "HTTP/1.1 200 %s\r\n\r\n", RESPONSE);
    bufferevent_write(ctx->client, r, strlen(r));
}

// Decoy: página nginx plausível para sondagens de DPI
// Fecha a conexão só depois do flush (evita perder a resposta escrita)
static void close_after_write(proxy_ctx_t *ctx) {
    if (!ctx || ctx->freed) return;
    ctx->state = ST_RELAY;
    struct timeval tv = {3, 0};
    if (ctx->client) bufferevent_set_timeouts(ctx->client, &tv, &tv);
}

static void send_decoy(proxy_ctx_t *ctx) {
    static const char body[] =
        "<!DOCTYPE html><html><head><title>Welcome to nginx!</title></head>"
        "<body><h1>Welcome to nginx!</h1>"
        "<p>If you see this page, the nginx web server is successfully installed "
        "and working. Further configuration is required.</p>"
        "<p>For online documentation and support please refer to "
        "<a href=\"http://nginx.org/\">nginx.org</a>.</p></body></html>";
    char r[1024];
    snprintf(r, sizeof(r),
        "HTTP/1.1 200 OK\r\n"
        "Server: nginx\r\n"
        "Content-Type: text/html; charset=UTF-8\r\n"
        "Content-Length: %zu\r\n"
        "Cache-Control: no-cache\r\n"
        "Connection: close\r\n"
        "\r\n%s", strlen(body), body);
    bufferevent_write(ctx->client, r, strlen(r));
    bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
    close_after_write(ctx);
}

static void send_403(proxy_ctx_t *ctx) {
    const char *r = "HTTP/1.1 403 Forbidden\r\nServer: nginx\r\n"
                    "Content-Length: 0\r\nConnection: close\r\n\r\n";
    bufferevent_write(ctx->client, r, strlen(r));
    bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
    close_after_write(ctx);
}

// --- SNI do ClientHello TLS ---
static bool extract_sni(const unsigned char *d, size_t len, char *out, size_t outlen) {
    if (len < 5 || d[0] != 0x16 || d[1] != 0x03) return false;
    size_t rec = ((size_t)d[3] << 8) | d[4];
    if (rec < 4 || len < 5 + rec) return false;
    const unsigned char *hs = d + 5;
    if (hs[0] != 0x01) return false;
    size_t bodylen = ((size_t)hs[1] << 16) | ((size_t)hs[2] << 8) | hs[3];
    if (bodylen + 4 > rec) return false;
    const unsigned char *p = hs + 4;
    const unsigned char *end = hs + 4 + bodylen;
    if (p + 2 + 32 > end) return false;
    p += 2 + 32;                       // client_version + random
    if (p >= end) return false;
    size_t sid = *p++;
    if (p + sid > end) return false;
    p += sid;
    if (p + 2 > end) return false;
    size_t cs = ((size_t)p[0] << 8) | p[1];
    p += 2 + cs;
    if (p + 1 > end) return false;
    size_t comp = *p++;
    p += comp;
    if (p + 2 > end) return false;
    size_t ext = ((size_t)p[0] << 8) | p[1];
    p += 2;
    const unsigned char *eend = p + ext;
    if (eend > end) eend = end;
    while (p + 4 <= eend) {
        uint16_t type = (uint16_t)((p[0] << 8) | p[1]);
        size_t elen = ((size_t)p[2] << 8) | p[3];
        p += 4;
        if (p + elen > eend) break;
        if (type == 0x0000 && elen >= 5) {
            size_t llen = ((size_t)p[0] << 8) | p[1];
            const unsigned char *s = p + 2;
            if (llen >= 3 && s + 3 <= p + elen && s[0] == 0x00) {
                size_t nl = ((size_t)s[1] << 8) | s[2];
                s += 3;
                if (nl > 0 && nl < outlen && s + nl <= p + elen) {
                    memcpy(out, s, nl);
                    out[nl] = '\0';
                    return true;
                }
            }
        }
        p += elen;
    }
    return false;
}

// --- Conexão remota comum ---
static bool connect_relay(proxy_ctx_t *ctx, const char *host, uint16_t port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr(host);
    if (addr.sin_addr.s_addr == INADDR_NONE)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    ctx->connected_to_remote = true;
    clear_magic_timer(ctx);
    bufferevent_set_timeouts(ctx->client, NULL, NULL);
    ctx->remote = bufferevent_socket_new(base, -1, BEV_OPT_CLOSE_ON_FREE);
    if (!ctx->remote) { free_proxy_ctx(ctx); return false; }
    bufferevent_setcb(ctx->remote, remote_read_cb, NULL, event_cb, ctx);
    bufferevent_enable(ctx->remote, EV_READ | EV_WRITE);
    set_keepalive(ctx->remote);

    if (bufferevent_socket_connect(ctx->remote,
            (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        free_proxy_ctx(ctx);
        return false;
    }
    ctx->state = ST_RELAY;
    ctx->frag_in = (DPI_ENABLED && !ctx->raw_tunnel) ? DPI_FRAG_BYTES : 0;
    ctx->frag_out = (DPI_ENABLED && !ctx->raw_tunnel) ? DPI_FRAG_BYTES : 0;
    return true;
}

static bool start_remote(proxy_ctx_t *ctx) {
    return connect_relay(ctx, "127.0.0.1", (uint16_t)TO_PORT);
}

// --- SOCKS5 ---
// full=false => resposta de negociação (2 bytes); full=true => resposta de request (10 bytes)
static void socks_reply_error(proxy_ctx_t *ctx, unsigned char rep, bool full) {
    if (full) {
        unsigned char r[10] = {0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
        bufferevent_write(ctx->client, r, sizeof(r));
    } else {
        unsigned char r[2] = {0x05, rep};
        bufferevent_write(ctx->client, r, sizeof(r));
    }
    bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
    close_after_write(ctx);
}

static void socks5_handle_methods(proxy_ctx_t *ctx, struct evbuffer *input) {
    size_t len = evbuffer_get_length(input);
    if (len < 2) return;
    unsigned char b[2];
    evbuffer_copyout(input, b, 2);
    int nm = b[1];
    if (nm < 1 || nm > 255 || len < (size_t)(2 + nm)) return;
    unsigned char tmp[258] = {0};
    evbuffer_copyout(input, tmp, (size_t)(2 + nm));
    evbuffer_drain(input, (size_t)(2 + nm));

    bool noauth = false, userpass = false;
    for (int i = 0; i < nm; i++) {
        if (tmp[2+i] == 0x00) noauth = true;
        if (tmp[2+i] == 0x02) userpass = true;
    }
    // com token, exige user/pass
    if (AUTH_TOKEN[0] != '\0') noauth = false;

    if (noauth) {
        unsigned char ok[2] = {0x05, 0x00};
        bufferevent_write(ctx->client, ok, 2);
        ctx->state = ST_SOCKS5_REQ;
    } else if (userpass) {
        unsigned char ok[2] = {0x05, 0x02};
        bufferevent_write(ctx->client, ok, 2);
        ctx->state = ST_SOCKS5_AUTH;
    } else {
        socks_reply_error(ctx, 0xFF, false);
    }
}

static void socks5_handle_auth(proxy_ctx_t *ctx, struct evbuffer *input) {
    size_t len = evbuffer_get_length(input);
    if (len < 2) return;
    unsigned char b[2];
    evbuffer_copyout(input, b, 2);
    if (b[0] != 0x01) { socks_reply_error(ctx, 0xFF, false); return; }
    size_t need = 2 + (size_t)b[1];
    if (len < need + 1) return;
    unsigned char tmp[512] = {0};
    if (need + 1 > sizeof(tmp)) { socks_reply_error(ctx, 0xFF, false); return; }
    evbuffer_copyout(input, tmp, need + 1); // inclui o byte de tamanho da senha
    size_t need2 = need + 1 + (size_t)tmp[need];
    if (len < need2) return;
    evbuffer_drain(input, need2);

    if (AUTH_TOKEN[0] != '\0') {
        if (b[1] != strlen(AUTH_TOKEN) || memcmp(tmp + 2, AUTH_TOKEN, b[1]) != 0) {
            unsigned char bad[2] = {0x01, 0x01};
            bufferevent_write(ctx->client, bad, 2);
            bufferevent_flush(ctx->client, EV_WRITE, BEV_FLUSH);
            close_after_write(ctx);
            return;
        }
    }
    unsigned char ok[2] = {0x01, 0x00};
    bufferevent_write(ctx->client, ok, 2);
    ctx->state = ST_SOCKS5_REQ;
}

static void socks5_handle_request(proxy_ctx_t *ctx, struct evbuffer *input) {
    size_t len = evbuffer_get_length(input);
    if (len < 4) return;
    unsigned char h[4];
    evbuffer_copyout(input, h, 4);
    if (h[0] != 0x05) { free_proxy_ctx(ctx); return; }
    if (h[1] != 0x01) { socks_reply_error(ctx, 0x07, true); return; }

    size_t need = 0;
    switch (h[3]) {
        case 0x01: need = 10; break;
        case 0x03: {
            if (len < 5) return;
            unsigned char t[5] = {0};
            evbuffer_copyout(input, t, 5);
            need = 7 + (size_t)t[4];
            break;
        }
        case 0x04: need = 22; break;
        default: socks_reply_error(ctx, 0x08, true); return;
    }
    if (len < need) return;
    unsigned char req[512] = {0};
    if (need > sizeof(req)) { socks_reply_error(ctx, 0x08, true); return; }
    evbuffer_copyout(input, req, need);
    evbuffer_drain(input, need);

    uint16_t port = (uint16_t)((req[need-2] << 8) | req[need-1]);
    char host[256] = {0};
    if (h[3] == 0x01)
        snprintf(host, sizeof(host), "%d.%d.%d.%d", req[4], req[5], req[6], req[7]);
    else if (h[3] == 0x03) {
        size_t l = req[4];
        if (l > sizeof(host)-1) l = sizeof(host)-1;
        memcpy(host, req + 5, l);
    } else
        strncpy(host, "ipv6", sizeof(host)-1);

    unsigned char rep[10] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    memcpy(ctx->reply, rep, sizeof(rep));
    ctx->reply_len = sizeof(rep);

    ctx->raw_tunnel = true;
    if (SOCKS_FORCE_LOCAL) connect_relay(ctx, "127.0.0.1", (uint16_t)TO_PORT);
    else connect_relay(ctx, host, port);
}

static void socks4_handle_request(proxy_ctx_t *ctx, struct evbuffer *input) {
    size_t len = evbuffer_get_length(input);
    if (len < 9) return;
    unsigned char h[9] = {0};
    evbuffer_copyout(input, h, 9);
    if (h[0] != 0x04 || h[1] != 0x01) { free_proxy_ctx(ctx); return; }
    // IMPORTANTE: o IP 127.0.0.1 contém zeros; começar a busca no offset 8
    struct evbuffer_ptr start;
    evbuffer_ptr_set(input, &start, 8, EVBUFFER_PTR_SET);
    struct evbuffer_ptr z = evbuffer_search(input, "\x00", 1, &start);
    if (z.pos < 8) return;
    size_t need = (size_t)z.pos + 1;
    unsigned char req[512] = {0};
    if (need > sizeof(req)) { free_proxy_ctx(ctx); return; }
    evbuffer_copyout(input, req, need);
    evbuffer_drain(input, need);

    if (AUTH_TOKEN[0] != '\0') {
        if (need < 9 + strlen(AUTH_TOKEN) ||
            memcmp(req + 8, AUTH_TOKEN, strlen(AUTH_TOKEN)) != 0) {
            free_proxy_ctx(ctx);
            return;
        }
    }

    uint16_t port = (uint16_t)((req[2] << 8) | req[3]);
    unsigned char a = req[4], b = req[5], c = req[6], d = req[7];
    char host[256] = {0};
    if (a == 0 && b == 0 && c == 0 && d != 0) {
        struct evbuffer_ptr z2 = evbuffer_search(input, "\x00", 1, NULL);
        if (z2.pos > 0) {
            unsigned char dom[256] = {0};
            size_t dl = (size_t)z2.pos;
            if (dl > sizeof(dom)-1) dl = sizeof(dom)-1;
            evbuffer_copyout(input, dom, dl);
            evbuffer_drain(input, z2.pos + 1);
            memcpy(host, dom, dl);
        }
    } else
        snprintf(host, sizeof(host), "%d.%d.%d.%d", a, b, c, d);

    unsigned char rep[8] = {0x00, 0x5A, (unsigned char)(port >> 8),
                            (unsigned char)(port & 0xFF), a, b, c, d};
    memcpy(ctx->reply, rep, sizeof(rep));
    ctx->reply_len = sizeof(rep);

    ctx->raw_tunnel = true;
    if (SOCKS_FORCE_LOCAL) connect_relay(ctx, "127.0.0.1", (uint16_t)TO_PORT);
    else connect_relay(ctx, host, port);
}

// --- HTTP CONNECT ---
static void handle_http_connect(proxy_ctx_t *ctx, struct evbuffer *input,
                                const char *hdr, const char *line) {
    if (!token_ok(hdr, line)) { send_403(ctx); return; }
    char target[512] = {0};
    const char *p = line + strlen("CONNECT ");
    size_t n = 0;
    while (*p && *p != ' ' && *p != '\t' && n < sizeof(target)-1) {
        target[n++] = *p++;
    }
    target[n] = '\0';
    char *colon = strrchr(target, ':');
    if (!colon) { send_decoy(ctx); return; }
    *colon = '\0';
    int prt = atoi(colon + 1);
    if (prt < 1 || prt > 65535) { send_decoy(ctx); return; }

    const char *r = "HTTP/1.1 200 Connection Established\r\n"
                    "Proxy-Agent: nginx\r\n\r\n";
    memcpy(ctx->reply, r, strlen(r));
    ctx->reply_len = strlen(r);

    // drina o cabeçalho HTTP para não vazar para o túnel
    struct evbuffer_ptr end;
    size_t term = find_header_end(input, &end);
    if (end.pos != -1) evbuffer_drain(input, (size_t)end.pos + term);

    ctx->raw_tunnel = true;
    if (SOCKS_FORCE_LOCAL) connect_relay(ctx, "127.0.0.1", (uint16_t)TO_PORT);
    else connect_relay(ctx, target, (uint16_t)prt);
}

// --- TLS / SNI ---
static void handle_tls(proxy_ctx_t *ctx, struct evbuffer *input) {
    size_t len = evbuffer_get_length(input);
    if (len < 5) return;
    unsigned char h[5];
    evbuffer_copyout(input, h, 5);
    size_t rec = ((size_t)h[3] << 8) | h[4];
    size_t need = 5 + rec;
    if (need > MAXBUF) { free_proxy_ctx(ctx); return; }
    // espera o ClientHello completo (ou timeout)
    if (len < need && len < MAXBUF) return;

    unsigned char *data = evbuffer_pullup(input, len < need ? len : need);
    char sni[256] = {0};
    bool have_sni = extract_sni(data, len < need ? len : need, sni, sizeof(sni));

    if (SNI_ALLOW[0] != '\0' && (!have_sni || strcmp(sni, SNI_ALLOW) != 0)) {
        send_decoy(ctx);
        return;
    }
    if (TLS_TARGET_HOST[0] == '\0') { send_decoy(ctx); return; }

    // guarda o ClientHello para reenviar após conectar
    size_t keep = len < need ? len : need;
    if (keep > sizeof(ctx->pending)) keep = sizeof(ctx->pending);
    memcpy(ctx->pending, data, keep);
    ctx->pending_len = keep;
    evbuffer_drain(input, keep);

    ctx->raw_tunnel = true;
    connect_relay(ctx, TLS_TARGET_HOST, (uint16_t)TLS_TARGET_PORT);
}

// --- Callbacks ---
void remote_read_cb(struct bufferevent *bev, void *user_data) {
    proxy_ctx_t *ctx = user_data;
    struct evbuffer *input = bufferevent_get_input(bev);
    if (ctx && ctx->client && !ctx->freed)
        relay_with_dpi(ctx->client, input, &ctx->frag_out);
}

static bool starts_http(const char *b, size_t n) {
    const char *ms[] = {"GET ", "POST ", "HEAD ", "PUT ", "CONNECT ",
                        "OPTIONS ", "DELETE ", "PATCH "};
    for (size_t i = 0; i < sizeof(ms)/sizeof(ms[0]); i++) {
        size_t l = strlen(ms[i]);
        if (n >= l && memcmp(b, ms[i], l) == 0) return true;
    }
    return false;
}

// Antes do banner SSH, o app dispara decoys/DPI (POLL, ACL, MERGE,
// BASELINE-CONTROL, lixo binario). Nada disso pode chegar ao sshd: ele fecha
// com "invalid protocol identifier" e o app mostra "connection closed by
// foreign host". Descarta tudo ate o cliente enviar um banner SSH real.
static bool strip_ws_control(proxy_ctx_t *ctx, struct evbuffer *input);

static bool filter_client_to_ssh(proxy_ctx_t *ctx, struct evbuffer *input) {
    if (!ctx || !input) return true;
    if (!ctx->ssh_banner_sent) {
        struct evbuffer_ptr p = evbuffer_search(input, "SSH-", 4, NULL);
        if (p.pos == -1) {
            evbuffer_drain(input, evbuffer_get_length(input));
            return false;
        }
        if (p.pos > 0) evbuffer_drain(input, (size_t)p.pos);
        ctx->ssh_banner_sent = true;
    }
    return strip_ws_control(ctx, input);
}

// Tuneis raw (CONNECT/SOCKS/TLS) nao passam pelo filtro de banner SSH:
// o ClientHello TLS e o payload SOCKS nao contem "SSH-" e seriam descartados.
static bool filter_client(proxy_ctx_t *ctx, struct evbuffer *input) {
    if (!ctx || !input) return true;
    if (ctx->raw_tunnel) return true;
    return filter_client_to_ssh(ctx, input);
}

// O app CloudJF envia mensagens de controle HTTP pelo mesmo tunel SSH:
// preambulo GET/ACL e keepalive "POLL / HTTP/1.1". Se isso chegar ao sshd,
// ele fecha com "invalid protocol identifier" / "banner line invalid".
// Remove tambem o magic legado npv-x. Retorna false se o cabecalho ainda
// esta incompleto (para nao repassar bytes parciais ao sshd).
static bool strip_ws_control(proxy_ctx_t *ctx, struct evbuffer *input) {
    if (!input) return true;
    static const char *methods[] = {
        "GET", "POST", "PUT", "PATCH", "PATH", "DELETE", "HEAD", "OPTIONS",
        "CONNECT", "TRACE", "ACL", "UNLOCK", "LOCK", "MKCOL", "COPY", "MOVE",
        "PROPFIND", "PROPPATCH", "PROPATH", "POLL", "SEARCH", "MERGE",
        "BASELINE-CONTROL", "REPORT", "MKACTIVITY", "CHECKOUT", "UPDATE",
        "VERSION-CONTROL", "BIND", "UNBIND", "REBIND", "LINK", "UNLINK",
        "PURGE", "MKCALENDAR", "SUBSCRIBE", "UNSUBSCRIBE", "NOTIFY", "PUBLISH",
        "M-SEARCH", "NOTIFY", "SOURCE", "QUERY", "INDEX", "SCAN", "PING",
        "BASELINE", "LABEL", "ORDERPATCH", "ACL-ANSWER", NULL
    };
    for (;;) {
        size_t len = evbuffer_get_length(input);
        if (len == 0) return true;

        // Cabecalho de controle parcial: descarta ate a linha em branco
        if (ctx->in_control) {
            struct evbuffer_ptr e;
            size_t t = find_header_end(input, &e);
            if (e.pos != -1 && (size_t)e.pos + t <= len) {
                evbuffer_drain(input, (size_t)e.pos + t);
                ctx->in_control = false;
                continue;
            }
            evbuffer_drain(input, len);
            return false;
        }

        // magic legado do app (pode vir a qualquer momento)
        if (len >= 5) {
            unsigned char b5[5];
            evbuffer_copyout(input, b5, 5);
            if (memcmp(b5, "npv-x", 5) == 0) {
                evbuffer_drain(input, 5);
                continue;
            }
        }

        // so texto que comeca com Token maiusculo pode ser controle HTTP.
        // banner SSH ("SSH-2.0-...") e binario naiveo nao batem aqui.
        unsigned char c0 = 0;
        evbuffer_copyout(input, &c0, 1);
        if (!((c0 >= 'A' && c0 <= 'Z'))) return true;

        size_t peeklen = len < 255 ? len : 255;
        char first[256] = {0};
        evbuffer_copyout(input, first, peeklen);
        size_t fl = 0;
        while (fl < peeklen && first[fl] != '\r' && first[fl] != '\n') fl++;
        first[fl] = '\0';

        char method[40] = {0};
        size_t m = 0;
        while (m < fl && m < sizeof(method)-1 && first[m] != ' ') {
            method[m] = first[m]; m++;
        }
        method[m] = '\0';

        bool ctl = (strstr(first, "HTTP/") != NULL);
        if (!ctl) {
            for (int j = 0; methods[j] != NULL; j++) {
                if (strcmp(method, methods[j]) == 0) { ctl = true; break; }
            }
        }
        if (!ctl) return true;

        // com cabecalho completo: descarta bloco inteiro ate linha em branco
        struct evbuffer_ptr end;
        size_t term = find_header_end(input, &end);
        if (end.pos != -1 && (size_t)end.pos + term <= len) {
            evbuffer_drain(input, (size_t)end.pos + term);
            continue;
        }

        // sem cabecalho completo: entra em modo descarte ate 


        ctx->in_control = true;
        evbuffer_drain(input, len);
        return false;

        ctx->in_control = true;
        evbuffer_drain(input, len);
        return false;
    }
}

// Hibrido (timing do hsproxy): so completa o handshake quando o app envia
// npv-x (header HTTP ou payload legado) ou o banner SSH-. Decoys HTTP sao
// descartados sem responder 200. Mantem o filtro, o DPI e o keepalive.
static bool start_ws_on_magic(proxy_ctx_t *ctx, struct evbuffer *input) {
    if (!ctx || ctx->connected_to_remote || !input) return false;

    struct evbuffer_ptr ssh = evbuffer_search(input, "SSH-", 4, NULL);
    if (ssh.pos != -1) {
        if (ssh.pos > 0) evbuffer_drain(input, (size_t)ssh.pos);
        send_http_200(ctx);
        start_remote(ctx);
        return true;
    }

    struct evbuffer_ptr p = evbuffer_search(input, "npv-x", 5, NULL);
    if (p.pos != -1) {
        evbuffer_drain(input, (size_t)p.pos + 5);
        send_http_200(ctx);
        start_remote(ctx);
        return true;
    }

    strip_ws_control(ctx, input);
    return false;
}

// Compatibilidade: o app nao precisa mais enviar o magic "npv-x".
// Responde 200 e conecta ao SSH local. Se o app ainda enviar o magic legado
// no inicio do payload, ele e descartado em vez de chegar ao sshd como banner.
static void start_ws_relay(proxy_ctx_t *ctx, struct evbuffer *input) {
    if (!ctx || ctx->connected_to_remote) return;
    if (input) {
        struct evbuffer_ptr p = evbuffer_search(input, "npv-x", 5, NULL);
        if (p.pos == 0) {
            evbuffer_drain(input, 5);
        } else if (p.pos > 0 && p.pos < 64) {
            evbuffer_drain(input, (size_t)p.pos + 5);
        }
    }
    send_http_200(ctx);
    start_remote(ctx);
}

void client_read_cb(struct bufferevent *bev, void *user_data) {
    proxy_ctx_t *ctx = user_data;
    if (!ctx || ctx->freed) return;
    struct evbuffer *input = bufferevent_get_input(bev);

    if (ctx->state == ST_INIT) {
        size_t len = evbuffer_get_length(input);
        if (len == 0) return;
        // O cliente falou primeiro: cancela a janela de 50ms para não derrubar
        // SOCKS/probe/WS enquanto o handshake está em andamento.
        bufferevent_set_timeouts(bev, NULL, NULL);
        unsigned char first = 0;
        evbuffer_copyout(input, &first, 1);

        if (first == 0x05) {
            ctx->state = ST_SOCKS5_METHODS;
            socks5_handle_methods(ctx, input);
            return;
        }
        if (first == 0x04) {
            ctx->state = ST_SOCKS4_REQ;
            socks4_handle_request(ctx, input);
            return;
        }
        if (first == 0x16 && len >= 2) {
            unsigned char v[2];
            evbuffer_copyout(input, v, 2);
            if (v[1] == 0x03) {
                ctx->state = ST_TLS;
                handle_tls(ctx, input);
                return;
            }
        }

        char peek[16] = {0};
        size_t pn = len < sizeof(peek) ? len : sizeof(peek);
        evbuffer_copyout(input, peek, pn);

        if (starts_http(peek, pn)) {
            struct evbuffer_ptr end;
            size_t term = find_header_end(input, &end);
            if (end.pos == -1) return; // espera headers completos
            size_t hlen = 0;
            char *hdr = hdr_blob(input, &hlen);
            char line[512] = {0};
            if (hdr) {
                size_t le = 0;
                while (le < hlen && hdr[le] != '\r' && hdr[le] != '\n' && le < sizeof(line)-1) {
                    line[le] = hdr[le]; le++;
                }
            }
            if (strncmp(line, "CONNECT", 7) == 0) {
                handle_http_connect(ctx, input, hdr ? hdr : "", line);
                free(hdr);
                return;
            }
            // WebSocket legítimo: exige Upgrade: websocket
            bool has_ws = hdr ? (strcasestr(hdr, "Upgrade:") &&
                                 strcasestr(hdr, "websocket") != NULL) : false;
            if (!token_ok(hdr ? hdr : "", line)) {
                free(hdr);
                send_403(ctx);
                return;
            }
            // iOS envia npv-x como header da requisicao: conta como magic.
            if (hdr && strcasestr(hdr, "npv-x") != NULL) ctx->magic_ready = true;
            free(hdr);

            if (IMMEDIATE_101 && ctx->sent_101) {
                // O app CloudJF manda um preâmbulo HTTP "quebrado" depois do
                // 101 imediato (GET sem path com \r\n\r\n antes do Host, e um
                // decoy "ACL /"). Não é sondagem: só descarta o cabeçalho e
                // continua esperando o magic real (npv-x / SSH-).
                // O decoy continua ativo no modo estrito (--no-immediate-101).
                evbuffer_drain(input, (size_t)end.pos + term);
                ctx->state = ST_WS_MAGIC;
                set_magic_timeouts(ctx);
                // não retorna: processa magic que já esteja no buffer
            } else {
                if (!has_ws) { send_decoy(ctx); return; }
                if (!ctx->sent_101) send_ws_101(ctx, input);
                ctx->sent_101 = true;
                evbuffer_drain(input, (size_t)end.pos + term);
                ctx->state = ST_WS_MAGIC;
                set_magic_timeouts(ctx);
            }
            // processa magic que já esteja no buffer
        } else {
            // Fluxo legado: aguarda npv-x / SSH-
            if (!ctx->sent_101) send_ws_101(ctx, input);
            ctx->sent_101 = true;
            ctx->state = ST_WS_MAGIC;
            set_magic_timeouts(ctx);
        }
    }

    if (ctx->state == ST_SOCKS5_METHODS) { socks5_handle_methods(ctx, input); return; }
    if (ctx->state == ST_SOCKS5_AUTH) { socks5_handle_auth(ctx, input); return; }
    if (ctx->state == ST_SOCKS5_REQ) { socks5_handle_request(ctx, input); return; }
    if (ctx->state == ST_SOCKS4_REQ) { socks4_handle_request(ctx, input); return; }
    if (ctx->state == ST_TLS) { handle_tls(ctx, input); return; }

    if (ctx->connected_to_remote && ctx->remote && !ctx->freed) {
        if (filter_client(ctx, input))
            relay_with_dpi(ctx->remote, input, &ctx->frag_in);
        return;
    }

    if (ctx->state == ST_WS_MAGIC) {
        // Hibrido: o 200 so sai depois que o app enviou npv-x (header/payload)
        // ou o banner SSH-. Isso mantem o timing do hsproxy sem perder o filtro
        // de decoys, o DPI, o keepalive e o timeout de 24h do proxy novo.
        bool started = false;
        if (!WAIT_MAGIC) {
            start_ws_relay(ctx, input);
            started = ctx->connected_to_remote;
        } else if (ctx->magic_ready) {
            ctx->magic_ready = false;
            send_http_200(ctx);
            start_remote(ctx);
            started = true;
        } else {
            started = start_ws_on_magic(ctx, input);
        }
        if (started && ctx->connected_to_remote && evbuffer_get_length(input) > 0 &&
            filter_client_to_ssh(ctx, input))
            relay_with_dpi(ctx->remote, input, &ctx->frag_in);
        return;
    }
}

void event_cb(struct bufferevent *bev, short events, void *user_data) {
    proxy_ctx_t *ctx = user_data;
    if (!ctx || ctx->freed) return;

    if (events & BEV_EVENT_CONNECTED) {
        if (bev == ctx->remote) {
            set_nodelay(ctx->remote);
            if (ctx->reply_len > 0 && ctx->client) {
                bufferevent_write(ctx->client, ctx->reply, ctx->reply_len);
                ctx->reply_len = 0;
            }
            if (ctx->pending_len > 0 && ctx->remote) {
                bufferevent_write(ctx->remote, ctx->pending, ctx->pending_len);
                ctx->pending_len = 0;
            }
            struct evbuffer *ci = bufferevent_get_input(ctx->client);
            if (filter_client(ctx, ci) && evbuffer_get_length(ci) > 0)
                relay_with_dpi(ctx->remote, ci, &ctx->frag_in);
        }
        return;
    }

    if (events & BEV_EVENT_TIMEOUT) {
        if (bev == ctx->client && ctx->state == ST_INIT) {
            if (IMMEDIATE_101 && AUTH_TOKEN[0] == '\0' && !ctx->sent_101) {
                // Cliente silenciou: envia o 101 exato do original e passa a
                // esperar o magic (npv-x / SSH-) por mais 10s.
                send_immediate_101(ctx);
                ctx->sent_101 = true;
                ctx->state = ST_WS_MAGIC;
                // O libevent desabilita EV_READ após um timeout: reabilita
                // para continuar lendo o preâmbulo e o magic do app.
                bufferevent_enable(bev, EV_READ);
                set_magic_timeouts(ctx);
            } else {
                // Modo estrito/com token: sem handshake válido, apenas fecha.
                free_proxy_ctx(ctx);
            }
            return;
        }
        free_proxy_ctx(ctx);
        return;
    }

    if (events & (BEV_EVENT_EOF | BEV_EVENT_ERROR)) free_proxy_ctx(ctx);
}

void accept_conn_cb(struct evconnlistener *listener, evutil_socket_t fd,
                    struct sockaddr *address, int socklen, void *ctx_arg) {
    struct event_base *base_local = evconnlistener_get_base(listener);
    struct bufferevent *bev = bufferevent_socket_new(base_local, fd,
                                                     BEV_OPT_CLOSE_ON_FREE);
    if (!bev) { evutil_closesocket(fd); return; }
    proxy_ctx_t *pc = calloc(1, sizeof(proxy_ctx_t));
    if (!pc) { bufferevent_free(bev); return; }
    pc->client = bev;
    pc->state = ST_INIT;
    set_nodelay(bev);
    set_keepalive(bev);
    bufferevent_setcb(bev, client_read_cb, NULL, event_cb, pc);
    bufferevent_enable(bev, EV_READ | EV_WRITE);
    // Janela curta para detectar SOCKS/probe/WS real. Se o cliente silenciar,
    // o timeout envia o 101 exato do original (necessário para o app CloudJF).
    // Com token ou --no-immediate-101, espera o handshake e valida antes.
    struct timeval tv = (IMMEDIATE_101 && AUTH_TOKEN[0] == '\0') ?
                        (struct timeval){0, 50000} : (struct timeval){10, 0};
    bufferevent_set_timeouts(bev, &tv, &tv);
}

void print_usage_and_exit(const char *prog) {
    fprintf(stderr,
        "Uso: %s [--port N] [--to|-to N] [--response TEXTO]\n"
        "  --no-dpi             desliga fragmentação/headers anti-DPI\n"
        "  --legacy-101         resposta 101 original exata\n"
        "  --no-immediate-101   nao responde 101 no aceite (espera o GET WebSocket)\n"
        "  --auto-200           responde 200 imediatamente (modo anterior)\n"
        "  --socks-force-local  ignora destino SOCKS/CONNECT e usa 127.0.0.1:<to>\n"
        "  --no-keepalive       desliga TCP keepalive\n"
        "  --tls-target HOST:PORT  destino do ClientHello TLS (default 127.0.0.1:443)\n"
        "  --sni-allow HOST     só encaminha TLS com esse SNI (senão decoy)\n"
        "  --token TEXTO        exige token (WS: X-Auth-Token/Bearer/?token=, SOCKS: USERID)\n"
        "  --dpi-bytes N --dpi-chunk N --dpi-delay MS\n", prog);
    exit(1);
}

bool is_number(const char *str) {
    char *endptr;
    errno = 0;
    long val = strtol(str, &endptr, 10);
    if (errno != 0 || *endptr != '\0' || str == endptr) return false;
    return val >= 1 && val <= 65535;
}

int main(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--to-port") == 0 || strcmp(argv[i], "--to") == 0 ||
            strcmp(argv[i], "-to") == 0) {
            if (i+1 < argc && is_number(argv[i+1])) TO_PORT = atoi(argv[++i]);
            else print_usage_and_exit(argv[0]);
        } else if (strcmp(argv[i], "--port") == 0) {
            if (i+1 < argc && is_number(argv[i+1])) PORT = atoi(argv[++i]);
            else print_usage_and_exit(argv[0]);
        } else if (strcmp(argv[i], "--response") == 0) {
            if (i+1 < argc) RESPONSE = argv[++i]; else print_usage_and_exit(argv[0]);
        } else if (strcmp(argv[i], "--no-dpi") == 0) DPI_ENABLED = false;
        else if (strcmp(argv[i], "--no-immediate-101") == 0) IMMEDIATE_101 = false;
        else if (strcmp(argv[i], "--auto-200") == 0) WAIT_MAGIC = false;
        else if (strcmp(argv[i], "--legacy-101") == 0) LEGACY_101 = true;
        else if (strcmp(argv[i], "--socks-force-local") == 0) SOCKS_FORCE_LOCAL = true;
        else if (strcmp(argv[i], "--no-keepalive") == 0) KEEPALIVE = false;
        else if (strcmp(argv[i], "--tls-target") == 0 && i+1 < argc) {
            char *v = argv[++i];
            char *colon = strrchr(v, ':');
            if (colon) {
                *colon = '\0';
                strncpy(TLS_TARGET_HOST, v, sizeof(TLS_TARGET_HOST)-1);
                TLS_TARGET_PORT = atoi(colon+1);
            }
        }
        else if (strcmp(argv[i], "--sni-allow") == 0 && i+1 < argc)
            strncpy(SNI_ALLOW, argv[++i], sizeof(SNI_ALLOW)-1);
        else if (strcmp(argv[i], "--token") == 0 && i+1 < argc)
            strncpy(AUTH_TOKEN, argv[++i], sizeof(AUTH_TOKEN)-1);
        else if (strcmp(argv[i], "--dpi-bytes") == 0 && i+1 < argc) DPI_FRAG_BYTES = atoi(argv[++i]);
        else if (strcmp(argv[i], "--dpi-chunk") == 0 && i+1 < argc) DPI_CHUNK = atoi(argv[++i]);
        else if (strcmp(argv[i], "--dpi-delay") == 0 && i+1 < argc) DPI_DELAY_MS = atoi(argv[++i]);
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) print_usage_and_exit(argv[0]);
    }

    srand((unsigned int)time(NULL) ^ (unsigned int)getpid());
    signal(SIGPIPE, SIG_IGN);
    base = event_base_new();
    if (!base) { fprintf(stderr, "Erro libevent\n"); return 1; }

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(0);
    sin.sin_port = htons(PORT);

    struct evconnlistener *listener = evconnlistener_new_bind(
        base, accept_conn_cb, NULL,
        LEV_OPT_CLOSE_ON_FREE | LEV_OPT_REUSEABLE,
        -1, (struct sockaddr*)&sin, sizeof(sin));

    if (!listener) {
        fprintf(stderr, "Erro ao escutar %d: %s\n", PORT, strerror(errno));
        event_base_free(base);
        return 1;
    }

    printf("Proxy CloudJF :%d -> 127.0.0.1:%d | WS+SOCKS4/5+CONNECT+TLS | DPI=%s KEEPALIVE=%s TOKEN=%s\n",
           PORT, TO_PORT,
           DPI_ENABLED ? "on" : "off",
           KEEPALIVE ? "on" : "off",
           AUTH_TOKEN[0] ? "on" : "off");
    event_base_dispatch(base);
    evconnlistener_free(listener);
    event_base_free(base);
    return 0;
}
