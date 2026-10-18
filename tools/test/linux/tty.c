/* tty.c - Axiom's L3 test: the terminal, as a Linux program has it.
 *
 *   tty        the checks, a line each, then "tty: all ok"; some wait for
 *              keys, each asked for by a line "tty: press ..." (run.py types
 *              them): a line edited, an arrow raw and in DECCKM, ctrl+C as
 *              a byte, as SIGINT, and ctrl+D
 *   tty draw   the screen cleared and drawn on with escape sequences, the
 *              cursor left below; the shell's 'screen' shows what it holds
 *
 * Built by tools/mkroot.py with WSL's gcc; run by tools/test/linux/run.py.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(name, cond, ...) do { \
    if (cond) printf("ok %s\n", name); \
    else { printf("FAIL %s: ", name); printf(__VA_ARGS__); printf("\n"); failures++; } \
    fflush(stdout); \
} while (0)

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static struct termios sane;

static void raw(int vmin, int vtime, int isig)
{
    struct termios t = sane;
    t.c_lflag &= ~(ICANON | ECHO | (isig ? 0 : ISIG));
    t.c_iflag &= ~ICRNL;
    t.c_cc[VMIN] = vmin;
    t.c_cc[VTIME] = vtime;
    tcsetattr(0, TCSANOW, &t);
}

static void cooked(void)
{
    tcsetattr(0, TCSANOW, &sane);
}

/* what the terminal answers a question with, as read in raw mode: a CSI
 * sequence to its final byte, an OSC or DCS string to BEL or ST */
static int ask(const char *q, char *a, int size)
{
    raw(0, 10, 1);
    int n = 0;
    if (write(1, q, strlen(q)) < 0)
        size = 1;
    while (n < size - 1) {
        int r = read(0, a + n, 1);
        if (r <= 0)
            break;
        n++;
        char c = a[n - 1];
        if (n < 3)
            continue;
        if (a[1] == '[' ? c >= 0x40 && c <= 0x7e : c == 7 || (c == '\\' && a[n - 2] == 27))
            break;
    }
    a[n] = 0;
    cooked();
    return n;
}

static void show(const char *s, char *out)
{
    for (; *s; s++)
        out += sprintf(out, *s == 27 ? "ESC" : "%c", *s);
    *out = 0;
}

static volatile sig_atomic_t winched, interrupted;
static void on_winch(int sig) { (void)sig; winched++; }
static void on_int(int sig) { (void)sig; interrupted++; }

static void prompt(const char *what)
{
    printf("tty: press %s\n", what);
    fflush(stdout);
}

/* bytes typed, raw, until VTIME passes with no more */
static int keys(char *buf, int size, int isig)
{
    raw(1, 0, isig);
    int n = read(0, buf, size);
    if (n > 0) {
        raw(0, 3, isig);
        int r;
        while (n < size && (r = read(0, buf + n, size - n)) > 0)
            n += r;
    }
    cooked();
    return n;
}

static int draw(void)
{
    printf("\033[2J\033[H");
    printf("\033[3;5Hplaced at 3,5 \033[1;31mred\033[0m");
    printf("\033[5;1H\033(0lqqk\033(B");
    printf("\033[6;1H\033(0x\033(B  \033(0x\033(B");
    printf("\033[7;1H\033(0mqqj\033(B");
    printf("\033[8;1Habcdef\033[8;3H\033[2P");
    printf("\033[9;1Hxyz\033[9;2H\033[1@");
    printf("\033[10;1H12345\033[10;3H\033[K");
    printf("\033[11;1H\033[?1049h\033[2J\033[Hthe alternate screen\033[?1049l");
    printf("\033[11;1Hutf8: \xc3\xa9 \xe2\x9d\xaf \xe2\x9c\xbb \xe2\x8f\xba \xe2\x8e\xbf");
    printf("\033[12;1Hwrap: ");
    struct winsize ws;
    ioctl(1, TIOCGWINSZ, &ws);
    for (int i = 6; i < ws.ws_col; i++)
        putchar('.');
    printf("next");
    printf("\033[14;1H");
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "draw") == 0)
        return draw();

    CHECK("isatty", isatty(0) && isatty(1) && isatty(2), "%d %d %d", isatty(0), isatty(1), isatty(2));
    struct winsize ws = {0};
    int r = ioctl(1, TIOCGWINSZ, &ws);
    CHECK("winsize", r == 0 && ws.ws_row > 4 && ws.ws_col > 20, "%d: %dx%d", r, ws.ws_row, ws.ws_col);
    r = tcgetattr(0, &sane);
    CHECK("termios", r == 0 && (sane.c_lflag & (ICANON | ECHO | ISIG)) == (ICANON | ECHO | ISIG)
          && (sane.c_iflag & ICRNL) && (sane.c_oflag & (OPOST | ONLCR)) == (OPOST | ONLCR)
          && sane.c_cc[VMIN] == 1 && sane.c_cc[VINTR] == 3 && sane.c_cc[VERASE] == 0x7f,
          "%d: lflag %x iflag %x oflag %x", r, sane.c_lflag, sane.c_iflag, sane.c_oflag);
    CHECK("pgrp", tcgetpgrp(0) == getpgrp() && tcgetsid(0) == getsid(0),
          "%d %d %d %d", tcgetpgrp(0), getpgrp(), tcgetsid(0), getsid(0));

    char a[64], s[256];
    ask("\033[5n", a, sizeof a);
    show(a, s);
    CHECK("dsr", strcmp(a, "\033[0n") == 0, "%s", s);
    ask("\033[3;5H\033[6n", a, sizeof a);
    show(a, s);
    CHECK("cursor", strcmp(a, "\033[3;5R") == 0, "%s", s);
    ask("\033[4;1H\xe4\xb8\xad\xe6\x96\x87|\033[6n", a, sizeof a);
    printf("\n");
    show(a, s);
    CHECK("wide", strcmp(a, "\033[4;6R") == 0, "%s", s);
    ask("\033[c", a, sizeof a);
    show(a, s);
    CHECK("da", strncmp(a, "\033[?", 3) == 0 && a[strlen(a) - 1] == 'c', "%s", s);
    ask("\033[?2026$p", a, sizeof a);
    show(a, s);
    CHECK("decrqm", strcmp(a, "\033[?2026;2$y") == 0, "%s", s);
    ask("\033[18t", a, sizeof a);
    show(a, s);
    char want[32];
    sprintf(want, "\033[8;%d;%dt", ws.ws_row, ws.ws_col);
    CHECK("size", strcmp(a, want) == 0, "%s", s);
    ask("\033[6;1H\033[?1049h\033[2;2H\033[?1049l\033[6n", a, sizeof a);
    show(a, s);
    CHECK("altscreen", strcmp(a, "\033[6;1R") == 0, "%s", s);
    ask("\033]11;?\033\\", a, sizeof a);
    show(a, s);
    CHECK("osc", strncmp(a, "\033]11;rgb:", 9) == 0, "%s", s);
    printf("\033[8;1H");

    raw(0, 0, 1);
    double t = now();
    r = read(0, a, sizeof a);
    CHECK("vmin0", r == 0 && now() - t < 0.1, "%d after %.3f s", r, now() - t);
    raw(0, 2, 1);
    t = now();
    r = read(0, a, sizeof a);
    double took = now() - t;
    CHECK("vtime", r == 0 && took > 0.15 && took < 1, "%d after %.3f s", r, took);
    cooked();

    struct pollfd p[2] = {{0, POLLIN, 0}, {1, POLLOUT, 0}};
    t = now();
    r = poll(p, 1, 100);
    took = now() - t;
    CHECK("poll", r == 0 && took > 0.08, "%d after %.3f s", r, took);
    r = poll(p + 1, 1, 0);
    CHECK("pollout", r == 1 && (p[1].revents & POLLOUT), "%d %x", r, p[1].revents);
    fd_set rd;
    FD_ZERO(&rd);
    FD_SET(0, &rd);
    struct timeval tv = {0, 50000};
    t = now();
    r = select(1, &rd, NULL, NULL, &tv);
    took = now() - t;
    CHECK("select", r == 0 && took > 0.03, "%d after %.3f s", r, took);

    int fl = fcntl(0, F_GETFL);
    fcntl(0, F_SETFL, fl | O_NONBLOCK);
    r = read(0, a, sizeof a);
    CHECK("nonblock", r == -1 && errno == EAGAIN, "%d errno %d", r, errno);
    fcntl(0, F_SETFL, fl);

    signal(SIGWINCH, on_winch);
    struct winsize w2 = ws;
    w2.ws_row = ws.ws_row - 1;
    ioctl(0, TIOCSWINSZ, &w2);
    ioctl(0, TIOCSWINSZ, &ws);
    CHECK("sigwinch", winched == 2, "%d", (int)winched);

    prompt("a line");
    r = read(0, s, sizeof s - 1);
    s[r > 0 ? r : 0] = 0;
    CHECK("line", strcmp(s, "abc\n") == 0, "%d '%s'", r, s);

    prompt("up");
    r = keys(a, sizeof a - 1, 1);
    a[r > 0 ? r : 0] = 0;
    show(a, s);
    CHECK("arrow", strcmp(a, "\033[A") == 0, "%s", s);
    printf("\033[?1h");
    prompt("up again");
    r = keys(a, sizeof a - 1, 1);
    a[r > 0 ? r : 0] = 0;
    show(a, s);
    CHECK("decckm", strcmp(a, "\033OA") == 0, "%s", s);
    printf("\033[?1l");

    prompt("ctrl+C as a byte");
    r = keys(a, sizeof a - 1, 0);
    CHECK("rawctrlc", r == 1 && a[0] == 3, "%d %d", r, a[0]);

    struct sigaction sa = {0};
    sa.sa_handler = on_int;
    sigaction(SIGINT, &sa, NULL);
    prompt("ctrl+C for SIGINT");
    errno = 0;
    r = read(0, a, sizeof a);
    CHECK("sigint", r == -1 && errno == EINTR && interrupted == 1, "%d errno %d, %d", r, errno,
          (int)interrupted);

    prompt("ctrl+D");
    r = read(0, a, sizeof a);
    CHECK("eof", r == 0, "%d", r);

    if (failures == 0)
        printf("tty: all ok\n");
    else
        printf("tty: %d failed\n", failures);
    return failures != 0;
}
