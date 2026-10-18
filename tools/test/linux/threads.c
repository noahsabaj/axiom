/* threads.c - Axiom's L2 test: threads, futexes and signals, through glibc.
 *
 *   threads            every check below, a line each, then "threads: all ok"
 *   threads abort      abort(): the process ends by SIGABRT
 *   threads segv       a fault with no handler: SIGSEGV
 *   threads lastexit   main leaves by pthread_exit, the last thread exits 0
 *   threads exitgroup  a thread calls exit(3) while main waits in a join
 *   threads nointr     SIGINT ignored, then a long sleep: ctrl+C twice stops it
 *
 * Built by tools/mkroot.py with WSL's gcc; run by tools/test/linux/run.py.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(name, cond, ...) do { \
    if (cond) printf("ok %s\n", name); \
    else { printf("FAIL %s: ", name); printf(__VA_ARGS__); printf("\n"); failures++; } \
} while (0)

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void ms(int n)
{
    struct timespec ts = { n / 1000, (n % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) && errno == EINTR)
        ;
}

/* ---- threads and a mutex */

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static __thread long mine;
static _Atomic int tids_differ;

static void *adder(void *arg)
{
    mine = (long)arg;
    for (int i = 0; i < 20000; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
    }
    if (syscall(SYS_gettid) != getpid())
        tids_differ++;
    return (void *)(mine * 2);
}

static void test_mutex(void)
{
    pthread_t t[8];
    long sum = 0;
    for (long i = 0; i < 8; i++)
        pthread_create(&t[i], NULL, adder, (void *)(i + 1));
    for (int i = 0; i < 8; i++) {
        void *r;
        pthread_join(t[i], &r);
        sum += (long)r;
    }
    CHECK("mutex", counter == 8 * 20000, "counter %ld", counter);
    CHECK("tls", sum == 2 * 36 && mine == 0, "sum %ld, main's %ld", sum, mine);
    CHECK("gettid", tids_differ == 8, "%d of 8 had their own id", tids_differ);
}

/* ---- a condition variable */

static pthread_cond_t ready = PTHREAD_COND_INITIALIZER, room = PTHREAD_COND_INITIALIZER;
static int queue[16], qhead, qtail;
static long consumed;

static void *producer(void *arg)
{
    (void)arg;
    for (int i = 1; i <= 5000; i++) {
        pthread_mutex_lock(&lock);
        while (qtail - qhead == 16)
            pthread_cond_wait(&room, &lock);
        queue[qtail++ % 16] = i;
        pthread_cond_signal(&ready);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

static void *consumer(void *arg)
{
    (void)arg;
    for (int i = 0; i < 2500; i++) {
        pthread_mutex_lock(&lock);
        while (qtail == qhead)
            pthread_cond_wait(&ready, &lock);
        consumed += queue[qhead++ % 16];
        pthread_cond_signal(&room);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

static void test_cond(void)
{
    pthread_t p, c1, c2;
    pthread_create(&c1, NULL, consumer, NULL);
    pthread_create(&c2, NULL, consumer, NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(c1, NULL);
    pthread_join(c2, NULL);
    CHECK("cond", consumed == 5000L * 5001 / 2, "consumed %ld", consumed);
}

/* ---- a timed wait */

static void test_timeout(void)
{
    pthread_cond_t never = PTHREAD_COND_INITIALIZER;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_nsec += 150 * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000L;
    }
    double t0 = now();
    pthread_mutex_lock(&lock);
    int r = pthread_cond_timedwait(&never, &lock, &until);
    pthread_mutex_unlock(&lock);
    double took = now() - t0;
    CHECK("timedwait", r == ETIMEDOUT && took > 0.1 && took < 1.0, "%d after %.3f s", r, took);
}

/* ---- many threads, detached ones */

static _Atomic int detached_done;

static void *quick(void *arg)
{
    if (arg)
        detached_done++;
    return arg;
}

static void test_many(void)
{
    int ok = 1;
    for (int round = 0; round < 8 && ok; round++) {
        pthread_t t[32];
        for (int i = 0; i < 32; i++)
            if (pthread_create(&t[i], NULL, quick, NULL))
                ok = 0;
        for (int i = 0; i < 32; i++)
            pthread_join(t[i], NULL);
    }
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    for (int i = 0; i < 16; i++) {
        pthread_t t;
        pthread_create(&t, &a, quick, (void *)1);
    }
    for (int i = 0; i < 200 && detached_done < 16; i++)
        ms(5);
    CHECK("many", ok && detached_done == 16, "created ok %d, detached %d", ok, (int)detached_done);
}

/* ---- signals */

static volatile sig_atomic_t got, got_signo, got_round, got_onalt;
static char *alt;
static size_t altsize = 64 * 1024;

static void on_usr1(int sig, siginfo_t *si, void *uc)
{
    (void)uc;
    got++;
    got_signo = si->si_signo == sig ? sig : -1;
    got_round = fegetround();
    char here;
    got_onalt = alt && &here >= alt && &here < alt + altsize;
    fesetround(FE_UPWARD);      /* undone by the return */
}

static void handle(int sig, int flags)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_usr1;
    sa.sa_flags = SA_SIGINFO | flags;
    sigaction(sig, &sa, NULL);
}

static void test_handler(void)
{
    handle(SIGUSR1, 0);
    got = 0;
    fesetround(FE_DOWNWARD);
    raise(SIGUSR1);
    int round = fegetround();
    fesetround(FE_TONEAREST);
    CHECK("handler", got == 1 && got_signo == SIGUSR1, "ran %d times, signo %d", (int)got, (int)got_signo);
    CHECK("fpstate", got_round == FE_TONEAREST && round == FE_DOWNWARD,
          "handler's rounding %d, after %d", (int)got_round, round);
}

static void test_altstack(void)
{
    alt = malloc(altsize);
    stack_t ss = { .ss_sp = alt, .ss_size = altsize, .ss_flags = 0 };
    int r = sigaltstack(&ss, NULL);
    handle(SIGUSR1, SA_ONSTACK);
    got = got_onalt = 0;
    raise(SIGUSR1);
    stack_t old;
    sigaltstack(NULL, &old);
    CHECK("sigaltstack", r == 0 && got == 1 && got_onalt && old.ss_sp == alt && old.ss_flags == 0,
          "r %d, ran %d, on it %d, flags %d", r, (int)got, (int)got_onalt, old.ss_flags);
    ss.ss_flags = SS_DISABLE;
    sigaltstack(&ss, NULL);
    handle(SIGUSR1, 0);
}

static void test_blocked(void)
{
    sigset_t s, pend;
    sigemptyset(&s);
    sigaddset(&s, SIGUSR2);
    handle(SIGUSR2, 0);
    got = 0;
    sigprocmask(SIG_BLOCK, &s, NULL);
    raise(SIGUSR2);
    int before = got;
    sigpending(&pend);
    int pending = sigismember(&pend, SIGUSR2);
    sigprocmask(SIG_UNBLOCK, &s, NULL);
    CHECK("blocked", before == 0 && pending == 1 && got == 1, "before %d, pending %d, after %d",
          before, pending, (int)got);
}

static void test_kill(void)
{
    got = 0;
    kill(getpid(), SIGUSR1);
    CHECK("kill", got == 1, "ran %d times", (int)got);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_IGN;
    sigaction(SIGUSR2, &sa, NULL);
    kill(getpid(), SIGUSR2);
    CHECK("ignored", got == 1, "ran %d times", (int)got);
}

static sigjmp_buf back;
static void *volatile fault_addr;

static void on_segv(int sig, siginfo_t *si, void *uc)
{
    (void)sig;
    (void)uc;
    fault_addr = si->si_addr;
    siglongjmp(back, 1);
}

static void test_segv(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_segv;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    volatile int *bad = (int *)0x1238;
    int caught = 0;
    if (sigsetjmp(back, 1) == 0)
        *bad = 1;
    else
        caught = 1;
    /* the mask siglongjmp put back: SIGSEGV may come again */
    if (sigsetjmp(back, 1) == 0)
        *bad = 2;
    else
        caught++;
    CHECK("sigsegv", caught == 2 && fault_addr == (void *)0x1238, "caught %d, at %p", caught, fault_addr);
    signal(SIGSEGV, SIG_DFL);
}

static pthread_t main_thread;

static void *poke_main(void *arg)
{
    ms((int)(long)arg);
    pthread_kill(main_thread, SIGUSR1);
    ms(100);
    return NULL;
}

static void test_eintr(void)
{
    handle(SIGUSR1, 0);
    got = 0;
    pthread_t t;
    pthread_create(&t, NULL, poke_main, (void *)50L);
    struct timespec ts = { 5, 0 };
    double t0 = now();
    int r = nanosleep(&ts, NULL);
    int e = errno;
    double took = now() - t0;
    pthread_join(t, NULL);
    CHECK("eintr", r == -1 && e == EINTR && got == 1 && took < 2.0, "r %d errno %d ran %d after %.3f s",
          r, e, (int)got, took);
}

static void test_restart(void)
{
    handle(SIGUSR1, SA_RESTART);
    got = 0;
    pthread_t t;
    pthread_create(&t, NULL, poke_main, (void *)50L);
    int r = pthread_join(t, NULL);  /* a futex wait the signal cuts short, made again */
    CHECK("restart", r == 0 && got == 1, "join %d, ran %d", r, (int)got);
    handle(SIGUSR1, 0);
}

static void *poke_proc(void *arg)
{
    (void)arg;
    ms(50);
    kill(getpid(), SIGUSR1);
    return NULL;
}

static void test_sigsuspend(void)
{
    sigset_t block, none, after;
    sigemptyset(&block);
    sigaddset(&block, SIGUSR1);
    sigprocmask(SIG_BLOCK, &block, NULL);
    got = 0;
    pthread_t t;
    pthread_create(&t, NULL, poke_proc, NULL);
    sigemptyset(&none);
    int r = sigsuspend(&none);
    int e = errno;
    sigprocmask(SIG_BLOCK, NULL, &after);
    pthread_join(t, NULL);
    CHECK("sigsuspend", r == -1 && e == EINTR && got == 1 && sigismember(&after, SIGUSR1),
          "r %d errno %d ran %d, blocked after %d", r, e, (int)got, sigismember(&after, SIGUSR1));
    sigprocmask(SIG_UNBLOCK, &block, NULL);
}

/* ---- the other ways out */

static void *last(void *arg)
{
    (void)arg;
    ms(100);
    printf("last thread\n");
    return NULL;
}

static void *exiter(void *arg)
{
    (void)arg;
    ms(50);
    exit(3);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    main_thread = pthread_self();
    if (argc > 1) {
        pthread_t t;
        if (!strcmp(argv[1], "abort"))
            abort();
        if (!strcmp(argv[1], "segv")) {
            int *volatile bad = (int *)8;
            *bad = 0;
        }
        if (!strcmp(argv[1], "lastexit")) {
            pthread_create(&t, NULL, last, NULL);
            pthread_exit(NULL);
        }
        if (!strcmp(argv[1], "exitgroup")) {
            pthread_create(&t, NULL, exiter, NULL);
            pthread_join(t, NULL);
            printf("joined: not expected\n");
            return 1;
        }
        if (!strcmp(argv[1], "nointr")) {
            signal(SIGINT, SIG_IGN);
            printf("ignoring SIGINT\n");
            sleep(60);
            printf("slept: not expected\n");
            return 1;
        }
        printf("threads: what is %s?\n", argv[1]);
        return 2;
    }
    test_mutex();
    test_cond();
    test_timeout();
    test_many();
    test_handler();
    test_altstack();
    test_blocked();
    test_kill();
    test_segv();
    test_eintr();
    test_restart();
    test_sigsuspend();
    if (failures) {
        printf("threads: %d failed\n", failures);
        return 1;
    }
    printf("threads: all ok\n");
    return 0;
}
