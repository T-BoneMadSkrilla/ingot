/*
 * hakuX on macOS — the Linux/bionic calls the native core uses that Darwin
 * lacks, force-included (-include) into the core's C sources.
 *
 * Every condition variable in the core is set to CLOCK_MONOTONIC and waited
 * on with a monotonic deadline; Darwin's only wait on CLOCK_REALTIME, so the
 * timed wait here turns the deadline into a relative one.
 */
#ifndef HAKUX_MAC_DARWIN_COMPAT_H
#define HAKUX_MAC_DARWIN_COMPAT_H
#if defined(__APPLE__) && !defined(__cplusplus)

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE CLOCK_MONOTONIC
#endif
#ifndef CLOCK_BOOTTIME
#define CLOCK_BOOTTIME CLOCK_MONOTONIC
#endif
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif

#define st_ctim st_ctimespec
#define st_mtim st_mtimespec
#define st_atim st_atimespec

typedef ssize_t slirp_ssize_t;

static inline pid_t nc_darwin_gettid(void)
{
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return (pid_t)tid;
}
#define gettid nc_darwin_gettid

static inline int nc_darwin_condattr_setclock(pthread_condattr_t *a, clockid_t c)
{
    (void)a;
    (void)c;
    return 0;
}
#define pthread_condattr_setclock nc_darwin_condattr_setclock

static inline int nc_darwin_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m,
                                           const struct timespec *deadline)
{
    struct timespec now, rel;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t ns = (int64_t)(deadline->tv_sec - now.tv_sec) * 1000000000 + (deadline->tv_nsec - now.tv_nsec);
    if (ns < 0) {
        ns = 0;
    }
    rel.tv_sec = (time_t)(ns / 1000000000);
    rel.tv_nsec = (long)(ns % 1000000000);
    return pthread_cond_timedwait_relative_np(c, m, &rel);
}
#define pthread_cond_timedwait nc_darwin_cond_timedwait

/* No per-thread CPU clocks: the callers measure only when this succeeds. */
static inline int nc_darwin_getcpuclockid(pthread_t t, clockid_t *id)
{
    (void)t;
    (void)id;
    return ENOTSUP;
}
#define pthread_getcpuclockid nc_darwin_getcpuclockid

static inline int nc_darwin_clock_nanosleep(clockid_t clk, int flags, const struct timespec *req,
                                            struct timespec *rem)
{
    struct timespec rel = *req;
    if (flags & TIMER_ABSTIME) {
        struct timespec now;
        clock_gettime(clk, &now);
        int64_t ns = (int64_t)(req->tv_sec - now.tv_sec) * 1000000000 + (req->tv_nsec - now.tv_nsec);
        if (ns <= 0) {
            return 0;
        }
        rel.tv_sec = (time_t)(ns / 1000000000);
        rel.tv_nsec = (long)(ns % 1000000000);
    }
    return nanosleep(&rel, rem) == 0 ? 0 : errno;
}
#define clock_nanosleep nc_darwin_clock_nanosleep

/* Guest memory in a host page its 4 KiB pages don't map as one is PROT_NONE
 * (native/core/vm16k.c): a system call into it fails with EFAULT where a
 * 4 KiB host's would work, and is made again through a bounce buffer. */
ssize_t nc_vm16k_read_slow(int fd, void *buf, size_t n, off_t off, bool positioned);
ssize_t nc_vm16k_write_slow(int fd, const void *buf, size_t n, off_t off, bool positioned);

static inline ssize_t nc_darwin_pread(int fd, void *buf, size_t n, off_t off)
{
    const ssize_t r = pread(fd, buf, n, off);
    return r < 0 && errno == EFAULT ? nc_vm16k_read_slow(fd, buf, n, off, true) : r;
}

static inline ssize_t nc_darwin_read(int fd, void *buf, size_t n)
{
    const ssize_t r = read(fd, buf, n);
    return r < 0 && errno == EFAULT ? nc_vm16k_read_slow(fd, buf, n, 0, false) : r;
}

static inline ssize_t nc_darwin_pwrite(int fd, const void *buf, size_t n, off_t off)
{
    const ssize_t r = pwrite(fd, buf, n, off);
    return r < 0 && errno == EFAULT ? nc_vm16k_write_slow(fd, buf, n, off, true) : r;
}

static inline ssize_t nc_darwin_write(int fd, const void *buf, size_t n)
{
    const ssize_t r = write(fd, buf, n);
    return r < 0 && errno == EFAULT ? nc_vm16k_write_slow(fd, buf, n, 0, false) : r;
}

#define pread  nc_darwin_pread
#define read   nc_darwin_read
#define pwrite nc_darwin_pwrite
#define write  nc_darwin_write

/* Darwin names only the calling thread. */
static inline int nc_darwin_setname(pthread_t t, const char *name)
{
    return pthread_equal(t, pthread_self()) ? pthread_setname_np(name) : 0;
}
#define pthread_setname_np(t, name) nc_darwin_setname(t, name)


#endif
#endif
