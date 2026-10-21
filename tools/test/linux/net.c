/* net.c - Axiom's L5 test: sockets, epoll, eventfd and timerfd, as a Linux
 * program has them. Each check prints "ok <name>" or "FAIL <name>: ...",
 * then "net: all ok".
 *
 *   net TCP UDP DNS     the checks, with the host's echo servers at 10.0.2.2
 *                       on ports TCP and UDP; DNS 1 if a DNS server says
 *                       axiom.test is 10.0.2.2
 *
 * Last, it listens on port 7777 ("net: listening on 7777") for one
 * connection, the host's through QEMU's forwarded port, and says back how
 * many bytes came and their sum once they end.
 *
 * Built by tools/mkroot.py with WSL's gcc; run by tools/test/linux/run.py.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#pragma GCC diagnostic ignored "-Wunused-result"  /* (each result the checks need, checked) */

static int failures;
static int tcp_port, udp_port;

#define CHECK(name, cond, ...) do { \
    if (cond) printf("ok %s\n", name); \
    else { printf("FAIL %s: ", name); printf(__VA_ARGS__); printf("\n"); failures++; } \
    fflush(stdout); \
} while (0)

static long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

/* whether fd has events among ev within ms */
static int ready(int fd, short ev, int ms)
{
    struct pollfd p = { fd, ev, 0 };
    return poll(&p, 1, ms) == 1 ? p.revents : 0;
}

static struct sockaddr_in host(int port)
{
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
    inet_pton(AF_INET, "10.0.2.2", &a.sin_addr);
    return a;
}

static int tcp_to_host(void)
{
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_in a = host(tcp_port);
    if (s < 0 || connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
        int e = errno;
        if (s >= 0)
            close(s);
        errno = e;
        return -1;
    }
    return s;
}

/* exactly n bytes, or fewer if they end, each within 5 s */
static int read_all(int fd, char *buf, int n)
{
    int got = 0, r;
    while (got < n) {
        if (!ready(fd, POLLIN, 5000))
            break;
        r = read(fd, buf + got, n - got);
        if (r <= 0)
            break;
        got += r;
    }
    return got;
}

static void check_tcp(void)
{
    int s = tcp_to_host();
    CHECK("tcp", s >= 0, "connect: %s", strerror(errno));
    if (s < 0)
        return;
    struct sockaddr_in me, peer;
    socklen_t ml = sizeof me, pl = sizeof peer;
    getsockname(s, (struct sockaddr *)&me, &ml);
    getpeername(s, (struct sockaddr *)&peer, &pl);
    char mine[32], theirs[32];
    inet_ntop(AF_INET, &me.sin_addr, mine, sizeof mine);
    inet_ntop(AF_INET, &peer.sin_addr, theirs, sizeof theirs);
    CHECK("names", !strcmp(mine, "10.0.2.15") && ntohs(me.sin_port) != 0 && ml == sizeof me
          && !strcmp(theirs, "10.0.2.2") && ntohs(peer.sin_port) == tcp_port,
          "ours %s:%d, theirs %s:%d", mine, ntohs(me.sin_port), theirs, ntohs(peer.sin_port));
    struct stat st;
    CHECK("fstat", fstat(s, &st) == 0 && S_ISSOCK(st.st_mode), "mode %o", st.st_mode);
    const char *hi = "hello over TCP\n";
    char buf[64] = { 0 };
    int w = write(s, hi, strlen(hi));
    int r = read_all(s, buf, strlen(hi));
    CHECK("echo", w == (int)strlen(hi) && r == w && !memcmp(buf, hi, r),
          "wrote %d, read %d: %.*s", w, r, r, buf);
    int one = 1, got = 0;
    socklen_t gl = sizeof got;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    getsockopt(s, IPPROTO_TCP, TCP_NODELAY, &got, &gl);
    int type = 0, domain = 0, listening = 1, err = 1;
    socklen_t l1 = 4, l2 = 4, l3 = 4, l4 = 4;
    getsockopt(s, SOL_SOCKET, SO_TYPE, &type, &l1);
    getsockopt(s, SOL_SOCKET, SO_DOMAIN, &domain, &l2);
    getsockopt(s, SOL_SOCKET, SO_ACCEPTCONN, &listening, &l3);
    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l4);
    CHECK("opts", got == 1 && type == SOCK_STREAM && domain == AF_INET && listening == 0 && err == 0,
          "nodelay %d, type %d, domain %d, acceptconn %d, error %d", got, type, domain, listening, err);
    close(s);
}

/* 300 KB each way at once, a socket that never waits, poll saying when */
static void check_big(void)
{
    enum { N = 300000 };
    static char out[N], in[N];
    for (int i = 0; i < N; i++)
        out[i] = (char)(i * 7 + i / 251);
    int s = tcp_to_host();
    if (s < 0) {
        CHECK("big", 0, "connect: %s", strerror(errno));
        return;
    }
    fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
    int sent = 0, got = 0, again = 0;
    long long until = now_ms() + 30000;
    while (got < N && now_ms() < until) {
        struct pollfd p = { s, POLLIN | (sent < N ? POLLOUT : 0), 0 };
        if (poll(&p, 1, 5000) <= 0)
            break;
        if (p.revents & POLLOUT) {
            int w = write(s, out + sent, N - sent);
            if (w > 0)
                sent += w;
            else if (errno == EAGAIN)
                again++;
        }
        if (p.revents & POLLIN) {
            int r = read(s, in + got, N - got);
            if (r <= 0)
                break;
            got += r;
        }
    }
    CHECK("big", sent == N && got == N && !memcmp(in, out, N),
          "sent %d, back %d of %d", sent, got, N);
    close(s);
}

static void check_nonblocking_connect(void)
{
    int s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    struct sockaddr_in a = host(tcp_port);
    int r = connect(s, (struct sockaddr *)&a, sizeof a);
    int e = errno;
    int ev = ready(s, POLLOUT, 5000);
    int err = -1;
    socklen_t l = sizeof err;
    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l);
    CHECK("nbconnect", r < 0 && e == EINPROGRESS && (ev & POLLOUT) && err == 0,
          "connect %d (%s), revents %x, SO_ERROR %d", r, strerror(e), ev, err);
    r = connect(s, (struct sockaddr *)&a, sizeof a);
    CHECK("isconn", r < 0 && errno == EISCONN, "connect again: %d (%s)", r, strerror(errno));
    char buf[8] = { 0 };
    int w = write(s, "bye", 3);
    shutdown(s, SHUT_WR);
    int n = read_all(s, buf, 3);
    int end = ready(s, POLLIN, 5000) ? (int)read(s, buf + 3, 4) : -2;
    CHECK("shutdown", w == 3 && n == 3 && !memcmp(buf, "bye", 3) && end == 0,
          "wrote %d, read %d, then %d", w, n, end);
    close(s);
}

static void check_refused(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(9) };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    int r = connect(s, (struct sockaddr *)&a, sizeof a);
    CHECK("refused", r < 0 && errno == ECONNREFUSED, "connect to 127.0.0.1:9: %d (%s)", r,
          strerror(errno));
    close(s);
    s = socket(AF_INET6, SOCK_STREAM, 0);
    char c;
    r = recv(s, &c, 1, 0);
    int e = errno;
    int w = send(s, "x", 1, MSG_NOSIGNAL);
    CHECK("notconn", r < 0 && e == ENOTCONN && w < 0 && errno == EPIPE,
          "recv %d (%s), send %d (%s)", r, strerror(e), w, strerror(errno));
    close(s);
    s = socket(AF_NETLINK, SOCK_RAW, 0);
    CHECK("netlink", s < 0 && errno == EAFNOSUPPORT, "%d (%s)", s, strerror(errno));
}

static void check_udp(void)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a = host(udp_port), from;
    socklen_t fl = sizeof from;
    const char *one = "datagram one";
    char buf[64] = { 0 };
    int w = sendto(s, one, strlen(one), 0, (struct sockaddr *)&a, sizeof a);
    int r = ready(s, POLLIN, 5000) ? (int)recvfrom(s, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl) : -2;
    char who[32];
    inet_ntop(AF_INET, &from.sin_addr, who, sizeof who);
    CHECK("udp", w == (int)strlen(one) && r == w && !memcmp(buf, one, r) && !strcmp(who, "10.0.2.2")
          && ntohs(from.sin_port) == udp_port, "sent %d, back %d from %s:%d", w, r, who,
          ntohs(from.sin_port));
    struct sockaddr_in me;
    socklen_t ml = sizeof me;
    getsockname(s, (struct sockaddr *)&me, &ml);
    CHECK("udpport", ntohs(me.sin_port) >= 32768 && ntohs(me.sin_port) < 49152, "port %d",
          ntohs(me.sin_port));
    close(s);

    s = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    connect(s, (struct sockaddr *)&a, sizeof a);
    const char *two = "datagram two, connected";
    w = send(s, two, strlen(two), 0);
    int n = 0;
    char peek[8] = { 0 };
    int p = -2;
    if (ready(s, POLLIN, 5000)) {
        ioctl(s, FIONREAD, &n);
        p = recv(s, peek, 8, MSG_PEEK);
    }
    memset(buf, 0, sizeof buf);
    r = recv(s, buf, 8, MSG_TRUNC);             /* the rest of it is lost, its length said */
    int again = recv(s, buf + 8, 8, 0);
    int e = errno;
    CHECK("udpconn", w == (int)strlen(two) && n == w && p == 8 && !memcmp(peek, two, 8) && r == w
          && !memcmp(buf, two, 8) && again < 0 && e == EAGAIN,
          "sent %d, FIONREAD %d, peeked %d, read %d, then %d (%s)", w, n, p, r, again, strerror(e));
    close(s);

    s = socket(AF_INET, SOCK_DGRAM, 0);         /* nothing comes: SO_RCVTIMEO ends the wait */
    struct sockaddr_in any = { .sin_family = AF_INET };
    bind(s, (struct sockaddr *)&any, sizeof any);
    struct timeval tv = { 0, 300000 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct timeval back = { 0 };
    socklen_t bl = sizeof back;
    getsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &back, &bl);
    long long t = now_ms();
    r = recv(s, buf, sizeof buf, 0);
    e = errno;
    t = now_ms() - t;
    CHECK("rcvtimeo", r < 0 && e == EAGAIN && t >= 250 && t < 3000 && back.tv_usec == 300000,
          "%d (%s) after %lld ms, said %ld us", r, strerror(e), t, (long)back.tv_usec);
    close(s);

    s = socket(AF_INET, SOCK_DGRAM, 0);         /* two at once each way */
    connect(s, (struct sockaddr *)&a, sizeof a);
    struct iovec iv[2] = { { "first", 5 }, { "second!", 7 } };
    struct mmsghdr m[2] = { { .msg_hdr = { .msg_iov = &iv[0], .msg_iovlen = 1 } },
                            { .msg_hdr = { .msg_iov = &iv[1], .msg_iovlen = 1 } } };
    int sent = sendmmsg(s, m, 2, 0);
    char b1[16] = { 0 }, b2[16] = { 0 };
    struct iovec ri[2] = { { b1, sizeof b1 }, { b2, sizeof b2 } };
    struct mmsghdr rm[2] = { { .msg_hdr = { .msg_iov = &ri[0], .msg_iovlen = 1 } },
                             { .msg_hdr = { .msg_iov = &ri[1], .msg_iovlen = 1 } } };
    int got = 0;
    long long until = now_ms() + 5000;
    while (got < 2 && now_ms() < until && ready(s, POLLIN, 5000)) {
        int k = recvmmsg(s, rm + got, 2 - got, MSG_DONTWAIT, NULL);
        if (k > 0)
            got += k;
    }
    CHECK("mmsg", sent == 2 && got == 2 && rm[0].msg_len == 5 && rm[1].msg_len == 7
          && !strcmp(b1, "first") && !strcmp(b2, "second!"),
          "sent %d, received %d: %s (%u), %s (%u)", sent, got, b1, rm[0].msg_len, b2, rm[1].msg_len);
    close(s);
}

static void check_dns(int dns)
{
    char buf[512] = { 0 };
    int fd = open("/etc/resolv.conf", O_RDONLY);
    int n = fd >= 0 ? (int)read(fd, buf, sizeof buf - 1) : -1;
    close(fd);
    CHECK("resolv", n > 0 && strstr(buf, "nameserver 10.0.2."), "%d: %s", n, buf);
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM }, *res = NULL;
    int r = getaddrinfo("localhost", "80", &hints, &res);
    char text[64] = "";
    if (r == 0)
        inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, text, sizeof text);
    CHECK("localhost", r == 0 && !strcmp(text, "127.0.0.1"), "%s %s", gai_strerror(r), text);
    if (res)
        freeaddrinfo(res);
    if (!dns)
        return;
    res = NULL;
    r = getaddrinfo("axiom.test", "80", &hints, &res);
    text[0] = 0;
    if (r == 0)
        inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, text, sizeof text);
    CHECK("dns", r == 0 && !strcmp(text, "10.0.2.2"), "axiom.test: %s %s", gai_strerror(r), text);
    if (res)
        freeaddrinfo(res);
    res = NULL;
    r = getaddrinfo("nothing.here", "80", &hints, &res);
    CHECK("nxdomain", r == EAI_NONAME, "nothing.here: %s", gai_strerror(r));
    if (res)
        freeaddrinfo(res);
}

static void check_pair(void)
{
    int sv[2];
    int r = socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv);
    char buf[64] = { 0 };
    int w = write(sv[0], "across", 6);
    int n = read(sv[1], buf, sizeof buf);
    struct stat st;
    fstat(sv[0], &st);
    struct sockaddr_un { unsigned short f; char p[108]; } un;
    socklen_t ul = sizeof un;
    int g = getpeername(sv[0], (struct sockaddr *)&un, &ul);
    CHECK("pair", r == 0 && w == 6 && n == 6 && !memcmp(buf, "across", 6) && S_ISSOCK(st.st_mode)
          && g == 0 && un.f == AF_UNIX && ul == 2, "socketpair %d, wrote %d, read %d, peer %d (%u)",
          r, w, n, g, ul);
    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        write(sv[1], "from the child", 14);
        _exit(0);
    }
    close(sv[1]);
    memset(buf, 0, sizeof buf);
    n = read_all(sv[0], buf, 14);
    int end = ready(sv[0], POLLIN, 5000) ? (int)read(sv[0], buf + 14, 8) : -2;
    waitpid(pid, NULL, 0);
    w = send(sv[0], "x", 1, MSG_NOSIGNAL);
    CHECK("pairfork", n == 14 && !memcmp(buf, "from the child", 14) && end == 0 && w < 0
          && errno == EPIPE, "read %d, then %d; a send after: %d (%s)", n, end, w, strerror(errno));
    close(sv[0]);

    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    shutdown(sv[0], SHUT_WR);
    int eof = ready(sv[1], POLLIN, 1000) ? (int)read(sv[1], buf, 8) : -2;
    w = write(sv[1], "back", 4);
    n = read(sv[0], buf, 8);
    CHECK("pairshut", eof == 0 && w == 4 && n == 4, "read %d after the shutdown; back %d, %d",
          eof, w, n);
    close(sv[0]);
    close(sv[1]);
}

static void check_eventfd(void)
{
    int e = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    uint64_t v = 0;
    int r0 = read(e, &v, 8);
    int e0 = errno;
    uint64_t three = 3, four = 4;
    write(e, &three, 8);
    write(e, &four, 8);
    int r1 = read(e, &v, 8);
    CHECK("eventfd", r0 < 0 && e0 == EAGAIN && r1 == 8 && v == 7, "empty %d (%s), then %d: %llu",
          r0, strerror(e0), r1, (unsigned long long)v);
    close(e);
    e = eventfd(2, EFD_SEMAPHORE | EFD_NONBLOCK);
    uint64_t a = 0, b = 0;
    int ra = read(e, &a, 8), rb = read(e, &b, 8), rc = read(e, &v, 8);
    CHECK("semaphore", ra == 8 && a == 1 && rb == 8 && b == 1 && rc < 0 && errno == EAGAIN,
          "%d %llu, %d %llu, %d", ra, (unsigned long long)a, rb, (unsigned long long)b, rc);
    close(e);
}

static void check_timerfd(void)
{
    int t = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    struct itimerspec it = { .it_value = { 0, 50000000 } };
    long long t0 = now_ms();
    timerfd_settime(t, 0, &it, NULL);
    uint64_t n = 0;
    int r = read(t, &n, 8);
    long long took = now_ms() - t0;
    CHECK("timerfd", r == 8 && n == 1 && took >= 40 && took < 2000, "%d: %llu after %lld ms", r,
          (unsigned long long)n, took);
    struct itimerspec every = { { 0, 20000000 }, { 0, 20000000 } }, now;
    timerfd_settime(t, 0, &every, NULL);
    usleep(110000);
    r = read(t, &n, 8);
    timerfd_gettime(t, &now);
    CHECK("interval", r == 8 && n >= 3 && n <= 8 && now.it_interval.tv_nsec == 20000000,
          "%d: %llu expirations, interval %ld ns", r, (unsigned long long)n, now.it_interval.tv_nsec);
    struct itimerspec off = { 0 };
    timerfd_settime(t, 0, &off, NULL);
    fcntl(t, F_SETFL, O_NONBLOCK);
    r = read(t, &n, 8);
    CHECK("disarmed", r < 0 && errno == EAGAIN, "%d (%s)", r, strerror(errno));
    struct timespec mono;
    clock_gettime(CLOCK_MONOTONIC, &mono);
    struct itimerspec abs = { .it_value = { mono.tv_sec, mono.tv_nsec } };
    abs.it_value.tv_nsec += 30000000;
    if (abs.it_value.tv_nsec >= 1000000000) {
        abs.it_value.tv_sec++;
        abs.it_value.tv_nsec -= 1000000000;
    }
    timerfd_settime(t, TFD_TIMER_ABSTIME, &abs, NULL);
    int ev = ready(t, POLLIN, 2000);
    r = read(t, &n, 8);
    CHECK("abstime", (ev & POLLIN) && r == 8 && n == 1, "revents %x, %d: %llu", ev, r,
          (unsigned long long)n);
    close(t);
}

static void check_epoll(void)
{
    int ep = epoll_create1(EPOLL_CLOEXEC);
    int p[2];
    pipe(p);
    int e = eventfd(0, EFD_NONBLOCK);
    int t = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
    struct epoll_event ev = { .events = EPOLLIN, .data.u64 = 0xE1 }, out[8];
    int a1 = epoll_ctl(ep, EPOLL_CTL_ADD, e, &ev);
    int a2 = epoll_ctl(ep, EPOLL_CTL_ADD, e, &ev);
    int e2 = errno;
    ev.data.u64 = 0x71;
    int a3 = epoll_ctl(ep, EPOLL_CTL_ADD, t, &ev);
    int n0 = epoll_wait(ep, out, 8, 0);
    uint64_t one = 1;
    write(e, &one, 8);
    int n1 = epoll_wait(ep, out, 8, 1000);
    CHECK("epoll", ep >= 0 && a1 == 0 && a2 < 0 && e2 == EEXIST && a3 == 0 && n0 == 0 && n1 == 1
          && out[0].data.u64 == 0xE1 && out[0].events == EPOLLIN,
          "create %d, add %d, again %d (%s), %d; waits %d, %d (%llx %x)", ep, a1, a2, strerror(e2),
          a3, n0, n1, (unsigned long long)out[0].data.u64, out[0].events);
    uint64_t v;
    read(e, &v, 8);
    struct itimerspec it = { .it_value = { 0, 30000000 } };
    timerfd_settime(t, 0, &it, NULL);
    long long t0 = now_ms();
    int n2 = epoll_wait(ep, out, 8, 2000);
    long long took = now_ms() - t0;
    CHECK("epolltimer", n2 == 1 && out[0].data.u64 == 0x71 && took >= 20 && took < 1500,
          "%d (%llx) after %lld ms", n2, (unsigned long long)out[0].data.u64, took);
    read(t, &v, 8);
    int d1 = epoll_ctl(ep, EPOLL_CTL_DEL, t, NULL);
    int d2 = epoll_ctl(ep, EPOLL_CTL_DEL, t, NULL);
    CHECK("epolldel", d1 == 0 && d2 < 0 && errno == ENOENT, "%d, then %d (%s)", d1, d2,
          strerror(errno));

    ev.events = EPOLLIN | EPOLLET;              /* edge: once per change */
    ev.data.u64 = 0x99;
    epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev);
    write(p[1], "a", 1);
    int m1 = epoll_wait(ep, out, 8, 1000);
    int m2 = epoll_wait(ep, out, 8, 50);
    write(p[1], "b", 1);
    int m3 = epoll_wait(ep, out, 8, 1000);
    CHECK("edge", m1 == 1 && m2 == 0 && m3 == 1 && out[0].data.u64 == 0x99, "%d, %d, %d", m1, m2, m3);
    char buf[8];
    read(p[0], buf, sizeof buf);

    int e3 = eventfd(0, EFD_NONBLOCK);           /* one shot, until it is armed again */
    ev.events = EPOLLIN | EPOLLONESHOT;
    ev.data.u64 = 0x05;
    epoll_ctl(ep, EPOLL_CTL_ADD, e3, &ev);
    write(e3, &one, 8);
    int o1 = epoll_wait(ep, out, 8, 1000);
    int o2 = epoll_wait(ep, out, 8, 50);
    epoll_ctl(ep, EPOLL_CTL_MOD, e3, &ev);
    int o3 = epoll_wait(ep, out, 8, 1000);
    CHECK("oneshot", o1 == 1 && o2 == 0 && o3 == 1 && out[0].data.u64 == 0x05, "%d, %d, %d", o1,
          o2, o3);
    epoll_ctl(ep, EPOLL_CTL_DEL, e3, NULL);
    close(e3);

    close(p[1]);                                /* the writer gone: the reader hears */
    int h = epoll_wait(ep, out, 8, 1000);
    CHECK("hup", h == 1 && (out[0].events & EPOLLHUP), "%d: %x", h, out[0].events);
    close(p[0]);                                /* closed: its watch goes with it */
    int g = epoll_wait(ep, out, 8, 50);
    CHECK("gone", g == 0, "%d", g);

    int s = tcp_to_host();                      /* a socket among them */
    ev.events = EPOLLIN | EPOLLOUT;
    ev.data.u64 = 0x50;
    epoll_ctl(ep, EPOLL_CTL_ADD, s, &ev);
    int w1 = epoll_wait(ep, out, 8, 2000);
    int wout = w1 == 1 ? (int)out[0].events : 0;
    write(s, "ping", 4);
    ev.events = EPOLLIN;
    epoll_ctl(ep, EPOLL_CTL_MOD, s, &ev);
    int w2 = epoll_wait(ep, out, 8, 5000);
    int rn = read(s, buf, 4);
    CHECK("epollsock", s >= 0 && w1 == 1 && (wout & EPOLLOUT) && !(wout & EPOLLIN) && w2 == 1
          && (out[0].events & EPOLLIN) && rn == 4, "%d (%x), %d (%x), read %d", w1, wout, w2,
          out[0].events, rn);
    close(s);
    close(e);
    close(t);
    close(ep);
}

static void check_listen(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(7777) };
    int b = bind(s, (struct sockaddr *)&a, sizeof a);
    int l = listen(s, 4);
    struct sockaddr_in me;
    socklen_t ml = sizeof me;
    getsockname(s, (struct sockaddr *)&me, &ml);
    int acc = 0;
    socklen_t al = 4;
    getsockopt(s, SOL_SOCKET, SO_ACCEPTCONN, &acc, &al);
    CHECK("listen", b == 0 && l == 0 && ntohs(me.sin_port) == 7777 && acc == 1,
          "bind %d, listen %d, port %d, acceptconn %d", b, l, ntohs(me.sin_port), acc);
    fcntl(s, F_SETFL, O_NONBLOCK);          /* (SOCK_NONBLOCK is the new socket's) */
    int nb = accept4(s, NULL, NULL, SOCK_NONBLOCK);
    CHECK("noone", nb < 0 && errno == EAGAIN, "accept4 with none waiting: %d (%s)", nb,
          strerror(errno));
    printf("net: listening on 7777\n");
    fflush(stdout);
    int ev = ready(s, POLLIN, 60000);
    struct sockaddr_in peer;
    socklen_t pl = sizeof peer;
    int c = accept4(s, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC);
    char who[32] = "";
    inet_ntop(AF_INET, &peer.sin_addr, who, sizeof who);
    CHECK("accept", (ev & POLLIN) && c >= 0 && pl == sizeof peer && !strcmp(who, "10.0.2.2")
          && (fcntl(c, F_GETFD) & FD_CLOEXEC) && !(fcntl(c, F_GETFL) & O_NONBLOCK),
          "revents %x, accept4 %d (%s) from %s", ev, c, strerror(errno), who);
    if (c < 0)
        return;
    static char buf[65536];
    long total = 0;
    unsigned sum = 0;
    int r;
    while (ready(c, POLLIN, 10000) && (r = read(c, buf, sizeof buf)) > 0) {
        for (int i = 0; i < r; i++)
            sum = sum * 31 + (unsigned char)buf[i];
        total += r;
    }
    char say[64];
    int n = snprintf(say, sizeof say, "got %ld bytes, sum %u\n", total, sum);
    int w = write(c, say, n);
    printf("net: %s", say);
    CHECK("served", total == 100000 && w == n, "%ld bytes, wrote %d", total, w);
    close(c);
    close(s);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "net TCP UDP DNS\n");
        return 2;
    }
    tcp_port = atoi(argv[1]);
    udp_port = atoi(argv[2]);
    signal(SIGPIPE, SIG_IGN);
    check_tcp();
    check_big();
    check_nonblocking_connect();
    check_refused();
    check_udp();
    check_dns(atoi(argv[3]));
    check_pair();
    check_eventfd();
    check_timerfd();
    check_epoll();
    check_listen();
    if (failures == 0)
        printf("net: all ok\n");
    return failures ? 1 : 0;
}
