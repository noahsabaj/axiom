/* procs.c - Axiom's L4 test: processes and pipes, as a Linux program has
 * them. Each check prints "ok <name>" or "FAIL <name>: ...", then "procs:
 * all ok".
 *
 *   procs           the checks
 *   procs fd N      whether descriptor N is open, said ("fd N open/closed")
 *
 * Built by tools/mkroot.py with WSL's gcc; run by tools/test/linux/run.py.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#pragma GCC diagnostic ignored "-Wunused-result"  /* (each result the checks need, checked) */

extern char **environ;
static int failures;

#define CHECK(name, cond, ...) do { \
    if (cond) printf("ok %s\n", name); \
    else { printf("FAIL %s: ", name); printf(__VA_ARGS__); printf("\n"); failures++; } \
    fflush(stdout); \
} while (0)

/* all of a descriptor's bytes, to its end */
static int slurp(int fd, char *buf, int size)
{
    int n = 0, r;
    while (n < size - 1 && (r = read(fd, buf + n, size - 1 - n)) > 0)
        n += r;
    buf[n] = 0;
    return n;
}

/* a program run with its output caught: fork, a pipe, exec, wait */
static int run(char *const argv[], char *out, int size, int *status)
{
    int p[2];
    if (pipe(p) < 0)
        return -1;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        execve(argv[0], argv, environ);
        _exit(127);
    }
    close(p[1]);
    int n = slurp(p[0], out, size);
    close(p[0]);
    waitpid(pid, status, 0);
    return n;
}

static volatile sig_atomic_t chld;
static void on_chld(int sig) { (void)sig; chld++; }

static int shared_value = 1;

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 2 && strcmp(argv[1], "fd") == 0) {
        int fd = atoi(argv[2]);
        printf("fd %d %s\n", fd, fcntl(fd, F_GETFD) < 0 ? "closed" : "open");
        return 0;
    }

    int status = -1;
    pid_t me = getpid();
    pid_t pid = fork();
    if (pid == 0)
        _exit(getppid() == me ? 7 : 8);
    pid_t got = waitpid(pid, &status, 0);
    CHECK("fork", pid > me && got == pid && WIFEXITED(status) && WEXITSTATUS(status) == 7,
          "pid %d got %d status %x", pid, got, status);

    shared_value = 2;
    int p[2];
    pipe(p);
    pid = fork();
    if (pid == 0) {
        char c = '0' + shared_value;
        shared_value = 5;
        write(p[1], &c, 1);
        _exit(0);
    }
    close(p[1]);
    char c = 0;
    read(p[0], &c, 1);
    close(p[0]);
    waitpid(pid, &status, 0);
    CHECK("memory", c == '2' && shared_value == 2, "child saw %c, parent has %d", c,
          shared_value);

    char out[4096];
    char *echo[] = {"/usr/bin/echo", "exec", "ok", NULL};
    run(echo, out, sizeof out, &status);
    CHECK("exec", strcmp(out, "exec ok\n") == 0 && status == 0, "'%s' %x", out, status);

    pid = vfork();
    if (pid == 0) {
        char *t[] = {"/usr/bin/true", NULL};
        execve(t[0], t, environ);
        _exit(9);
    }
    waitpid(pid, &status, 0);
    CHECK("vfork", pid > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "%d %x", pid,
          status);

    int q[2];
    pipe(q);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, q[1], 1);
    posix_spawn_file_actions_addclose(&fa, q[0]);
    char *sp[] = {"/usr/bin/echo", "spawn", "ok", NULL};
    int e = posix_spawn(&pid, sp[0], &fa, NULL, sp, environ);
    close(q[1]);
    slurp(q[0], out, sizeof out);
    close(q[0]);
    waitpid(pid, &status, 0);
    CHECK("spawn", e == 0 && strcmp(out, "spawn ok\n") == 0 && status == 0, "%d '%s' %x", e,
          out, status);

    pipe(p);
    int w = write(p[1], "hello", 5);
    int avail = -1;
    ioctl(p[0], FIONREAD, &avail);
    int r = read(p[0], out, sizeof out);
    out[r > 0 ? r : 0] = 0;
    CHECK("pipe", w == 5 && avail == 5 && r == 5 && strcmp(out, "hello") == 0,
          "%d %d %d '%s'", w, avail, r, out);
    struct stat st;
    fstat(p[0], &st);
    CHECK("fifo", S_ISFIFO(st.st_mode) && lseek(p[0], 0, SEEK_CUR) < 0 && errno == ESPIPE,
          "mode %o", st.st_mode);
    close(p[1]);
    r = read(p[0], out, sizeof out);
    CHECK("eof", r == 0, "%d", r);
    close(p[0]);

    pipe(p);
    struct pollfd pf = {p[0], POLLIN, 0};
    r = poll(&pf, 1, 50);
    int before = r;
    write(p[1], "x", 1);
    r = poll(&pf, 1, 50);
    CHECK("pollpipe", before == 0 && r == 1 && (pf.revents & POLLIN), "%d %d %x", before, r,
          pf.revents);
    close(p[0]);
    close(p[1]);

    pipe2(p, O_NONBLOCK);
    r = read(p[0], out, 1);
    CHECK("nonblock", r == -1 && errno == EAGAIN, "%d %d", r, errno);
    close(p[1]);
    close(p[0]);

    pipe(p);
    close(p[0]);
    signal(SIGPIPE, SIG_IGN);
    r = write(p[1], "x", 1);
    CHECK("epipe", r == -1 && errno == EPIPE, "%d %d", r, errno);
    signal(SIGPIPE, SIG_DFL);
    pid = fork();
    if (pid == 0) {
        write(p[1], "x", 1);
        _exit(0);
    }
    waitpid(pid, &status, 0);
    CHECK("sigpipe", WIFSIGNALED(status) && WTERMSIG(status) == SIGPIPE, "%x", status);
    close(p[1]);

    pipe(p);                            /* 200 KB through: waits on both sides */
    pid = fork();
    if (pid == 0) {
        close(p[0]);
        static char big[200000];
        for (int i = 0; i < (int)sizeof big; i++)
            big[i] = (char)(i * 7);
        int done = 0;
        while (done < (int)sizeof big) {
            int k = write(p[1], big + done, sizeof big - done);
            if (k <= 0)
                _exit(2);
            done += k;
        }
        _exit(0);
    }
    close(p[1]);
    static char got_big[200001];
    int n = slurp(p[0], got_big, sizeof got_big);
    int same = n == 200000;
    for (int i = 0; same && i < n; i++)
        same = got_big[i] == (char)(i * 7);
    close(p[0]);
    waitpid(pid, &status, 0);
    CHECK("big", same && status == 0, "%d bytes, %x", n, status);

    char *pipeline[] = {"/bin/sh", "-c", "echo one two three | wc -w", NULL};
    run(pipeline, out, sizeof out, &status);
    CHECK("pipeline", atoi(out) == 3 && status == 0, "'%s' %x", out, status);

    pid = fork();
    if (pid == 0) {
        sleep(30);
        _exit(0);
    }
    got = waitpid(pid, &status, WNOHANG);
    int nohang = got;
    kill(pid, SIGTERM);
    got = waitpid(pid, &status, 0);
    CHECK("wnohang", nohang == 0 && got == pid && WIFSIGNALED(status) &&
          WTERMSIG(status) == SIGTERM, "%d %d %x", nohang, got, status);

    got = waitpid(-1, &status, 0);
    CHECK("echild", got == -1 && errno == ECHILD, "%d %d", got, errno);

    struct sigaction sa = {0};
    sa.sa_handler = on_chld;
    sigaction(SIGCHLD, &sa, NULL);
    pid = fork();
    if (pid == 0)
        _exit(3);
    siginfo_t si = {0};
    e = waitid(P_PID, pid, &si, WEXITED);
    CHECK("waitid", e == 0 && si.si_pid == pid && si.si_code == CLD_EXITED && si.si_status == 3,
          "%d pid %d code %d status %d", e, si.si_pid, si.si_code, si.si_status);
    CHECK("sigchld", chld == 1, "%d", (int)chld);
    signal(SIGCHLD, SIG_DFL);

    pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        sleep(30);
        _exit(0);
    }
    setpgid(pid, pid);
    pid_t g = getpgid(pid);
    kill(-pid, SIGKILL);
    waitpid(pid, &status, 0);
    CHECK("pgid", g == pid && getpgid(0) == getpgrp() && getpgrp() != pid &&
          WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "%d %d %x", g, pid, status);

    pipe(p);
    pid = fork();
    if (pid == 0) {
        pid_t s = setsid();
        char m[64];
        int k = sprintf(m, "%d %d %d", s == getpid(), getsid(0) == getpid(),
                        getpgrp() == getpid());
        write(p[1], m, k);
        _exit(0);
    }
    close(p[1]);
    slurp(p[0], out, sizeof out);
    close(p[0]);
    waitpid(pid, &status, 0);
    CHECK("setsid", strcmp(out, "1 1 1") == 0 && getsid(0) != pid, "'%s'", out);

    char *none[] = {"/nonexistent", NULL};
    e = execve(none[0], none, environ);
    CHECK("enoent", e == -1 && errno == ENOENT, "%d %d", e, errno);

    char *script[] = {"/test/script.sh", "with", "args", NULL};
    run(script, out, sizeof out, &status);
    CHECK("script", strcmp(out, "script: /test/script.sh with args\n") == 0 && status == 0,
          "'%s' %x", out, status);

    pipe2(p, O_CLOEXEC);
    char fdarg[16];
    sprintf(fdarg, "%d", p[0]);
    char *check[] = {"/test/procs", "fd", fdarg, NULL};
    run(check, out, sizeof out, &status);
    char want[64];
    sprintf(want, "fd %d closed\n", p[0]);
    int closed = strcmp(out, want) == 0;
    fcntl(p[0], F_SETFD, 0);
    run(check, out, sizeof out, &status);
    sprintf(want, "fd %d open\n", p[0]);
    CHECK("cloexec", closed && strcmp(out, want) == 0, "'%s'", out);
    close(p[0]);
    close(p[1]);

    if (failures == 0)
        printf("procs: all ok\n");
    else
        printf("procs: %d failed\n", failures);
    return failures != 0;
}
