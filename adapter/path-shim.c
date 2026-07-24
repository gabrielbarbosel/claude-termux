/* path-shim.c — LD_PRELOAD shim for the Termux glibc runtime.
 *
 * Node's bundled binaries ignore NODE_OPTIONS, so a JS-level dns shim can
 * never load. Meanwhile node's c-ares resolver (dns.resolve*, dns.Resolver —
 * the path Claude Code's OAuth flow uses) reads the literal /etc/resolv.conf,
 * which does not exist on Android and cannot be created without root; c-ares
 * then falls back to 127.0.0.1:53 where nothing listens, and every resolve
 * dies with ETIMEOUT ("getaddrinfo ETIMEOUT platform.claude.com" on login).
 *
 * Redirect the two DNS config paths to Termux's real ones at the libc layer,
 * where every runtime (c-ares, glibc nss, anything else) ends up.
 *
 * Build (any aarch64 glibc system):
 *   gcc -shared -fPIC -O2 -o path-shim.so path-shim.c -ldl
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define TERMUX_ETC "/data/data/com.termux/files/usr/etc"

static const char *redir(const char *path) {
    if (!path) return path;
    if (strcmp(path, "/etc/resolv.conf") == 0) return TERMUX_ETC "/resolv.conf";
    if (strcmp(path, "/etc/hosts") == 0)       return TERMUX_ETC "/hosts";
    return path;
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(redir(path), flags, mode);
}

int open64(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "open64");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(redir(path), flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(dirfd, redir(path), flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...);
    if (!real) real = dlsym(RTLD_NEXT, "openat64");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return real(dirfd, redir(path), flags, mode);
}

FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    return real(redir(path), mode);
}

FILE *fopen64(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen64");
    return real(redir(path), mode);
}

/* Access checks routed straight to the faccessat syscall (SYS_faccessat = 48),
 * bypassing glibc's access()/faccessat(), which issue faccessat2 (439) — a
 * syscall some Android seccomp policies kill with SIGSYS, crashing node the
 * instant its runtime probes any path. The plain faccessat syscall is allowed.
 * AT_EACCESS (effective-uid) semantics are dropped, which is correct here: a
 * Termux process runs with real == effective uid. The /etc redirect is kept. */
int access(const char *path, int mode) {
    return syscall(SYS_faccessat, AT_FDCWD, redir(path), mode);
}

int eaccess(const char *path, int mode) {
    return syscall(SYS_faccessat, AT_FDCWD, redir(path), mode);
}

int euidaccess(const char *path, int mode) {
    return syscall(SYS_faccessat, AT_FDCWD, redir(path), mode);
}

int faccessat(int dirfd, const char *path, int mode, int flags) {
    (void)flags;
    return syscall(SYS_faccessat, dirfd, redir(path), mode);
}

int stat(const char *path, struct stat *buf) {
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "stat");
    return real(redir(path), buf);
}

int lstat(const char *path, struct stat *buf) {
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "lstat");
    return real(redir(path), buf);
}
