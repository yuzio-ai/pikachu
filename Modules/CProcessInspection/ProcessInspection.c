#define __STDC_WANT_LIB_EXT1__ 1 // memset_s: clearing must survive optimization.
#include "CProcessInspection.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>

static volatile sig_atomic_t stopping = 0;
static void stop_handler(int signal) { stopping = signal; }
void zv_install_signal_handlers(void) {
    signal(SIGTERM, stop_handler); signal(SIGINT, stop_handler); signal(SIGHUP, stop_handler);
    signal(SIGPIPE, SIG_IGN);
}
int zv_stop_requested(void) { return stopping; }

int zv_process_identity_for(int pid, zv_process_identity *result) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    *result = (zv_process_identity){info.pbi_pid, info.pbi_ppid, info.pbi_uid, info.pbi_status,
                                    info.pbi_start_tvsec, info.pbi_start_tvusec};
    return 0;
}
int zv_list_pids(int *buffer, int capacity) {
    int size = proc_listallpids(buffer, capacity * sizeof(int));
    return size;
}
// Inspect only to match a per-instance marker. Never expose arguments or environment.
struct zv_marker_scan {
    size_t capacity, expected_length;
    char expected[160];
    char bytes[];
};

zv_marker_scan *zv_marker_scan_create(const char *token) {
    int max = 0, mib[] = {CTL_KERN, KERN_ARGMAX}; size_t n = sizeof(max);
    if (sysctl(mib, 2, &max, &n, NULL, 0) || max <= 0) return NULL;
    zv_marker_scan *scan = calloc(1, sizeof(*scan) + (size_t)max);
    if (!scan) return NULL;
    int length = snprintf(scan->expected, sizeof(scan->expected), "ZIVVI_EXECUTION_TOKEN=%s", token);
    if (length < 0 || (size_t)length >= sizeof(scan->expected)) { zv_marker_scan_destroy(scan); return NULL; }
    scan->capacity = (size_t)max;
    scan->expected_length = (size_t)length;
    return scan;
}

void zv_marker_scan_destroy(zv_marker_scan *scan) {
    memset_s(scan->expected, sizeof(scan->expected), 0, sizeof(scan->expected));
    free(scan);
}

int zv_marker_scan_matches(zv_marker_scan *scan, int pid) {
    char *bytes = scan->bytes;
    int args[] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t n = scan->capacity;
    if (sysctl(args, 3, bytes, &n, NULL, 0) || n > scan->capacity) {
        // A failed call may have written data without reporting a reliable size.
        memset_s(bytes, scan->capacity, 0, scan->capacity);
        return -1;
    }
    if (n < sizeof(int)) { memset_s(bytes, scan->capacity, 0, n); return -1; }
    int argc; memcpy(&argc, bytes, sizeof(int));
    char *p = bytes + sizeof(int), *end = bytes + n;
    p += strnlen(p, end-p); if (p < end) p++;
    while (p < end && !*p) p++;
    for (int i = 0; i < argc && p < end; i++) { p += strnlen(p, end-p); if (p < end) p++; }
    int found = 0;
    while (p < end && *p) {
        size_t length = strnlen(p, end-p);
        if (length == (size_t)(end - p)) break; // No terminator in the returned data.
        if (length == scan->expected_length && !memcmp(p, scan->expected, length)) { found = 1; break; }
        p += length + 1;
    }
    memset_s(bytes, scan->capacity, 0, n);
    return found;
}

static int spawn_child(int32_t *pid, const char *executable, char *const argv[],
                       char *const envp[], int separate_group) {
    posix_spawnattr_t attributes;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0) return error;
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGINT);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGHUP);
    sigaddset(&signals, SIGPIPE);
    short flags = POSIX_SPAWN_SETSIGDEF | (separate_group ? POSIX_SPAWN_SETPGROUP : 0);
    error = posix_spawnattr_setflags(&attributes, flags);
    if (error == 0) error = posix_spawnattr_setsigdefault(&attributes, &signals);
    if (error == 0 && separate_group) error = posix_spawnattr_setpgroup(&attributes, 0);
    if (error == 0) error = posix_spawn(pid, executable, NULL, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    return error;
}

int zv_spawn_terminal_child(int32_t *pid, const char *executable, char *const argv[], char *const envp[]) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || !isatty(STDERR_FILENO) ||
        tcgetpgrp(STDIN_FILENO) != getpgrp()) return ENOTTY;
    // Inherit the supervisor's foreground group and controlling terminal.
    return spawn_child(pid, executable, argv, envp, 0);
}

int zv_spawn_group_child(int32_t *pid, const char *executable, char *const argv[], char *const envp[]) {
    return spawn_child(pid, executable, argv, envp, 1);
}

int zv_observe_group_child_exit(int32_t pid, int32_t *exit_code, int32_t *by_signal) {
    // Leave the leader waitable until the supervisor finishes its group sweep.
    // Its PID cannot be recycled into an unrelated group's ID in that interval.
    siginfo_t status = {0};
    int result;
    do { result = waitid(P_PID, pid, &status, WEXITED | WNOHANG | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return result;
    if (status.si_pid == 0) return 0;
    *exit_code = status.si_status;
    *by_signal = status.si_code != CLD_EXITED;
    return 1;
}

int zv_poll_terminal_child(int32_t pid, int32_t *exit_code, int32_t *by_signal) {
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result <= 0) return (int)result;

    *by_signal = WIFSIGNALED(status);
    *exit_code = *by_signal ? WTERMSIG(status) : WEXITSTATUS(status);
    return 1;
}
