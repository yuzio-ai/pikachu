#include "CProcessInspection.h"
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

static volatile sig_atomic_t stopping = 0;
static void stop_handler(int signal) { stopping = signal; }
void pk_install_signal_handlers(void) {
    signal(SIGTERM, stop_handler); signal(SIGINT, stop_handler); signal(SIGHUP, stop_handler);
    signal(SIGPIPE, SIG_IGN);
}
int pk_stop_requested(void) { return stopping; }

int pk_process_identity_for(int pid, pk_process_identity *result) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    *result = (pk_process_identity){info.pbi_pid, info.pbi_ppid, info.pbi_uid, info.pbi_status,
                                    info.pbi_start_tvsec, info.pbi_start_tvusec};
    return 0;
}
int pk_list_pids(int *buffer, int capacity) {
    int size = proc_listallpids(buffer, capacity * sizeof(int));
    return size;
}
// Inspect only to match a per-instance marker. Never expose arguments or environment.
int pk_process_has_marker(int pid, const char *token) {
    int max = 0, mib[] = {CTL_KERN, KERN_ARGMAX}; size_t n = sizeof(max);
    if (sysctl(mib, 2, &max, &n, NULL, 0) || max <= 0) return -1;
    char *bytes = calloc(1, (size_t)max);
    if (!bytes) return -1;
    int args[] = {CTL_KERN, KERN_PROCARGS2, pid}; n = max;
    if (sysctl(args, 3, bytes, &n, NULL, 0)) { free(bytes); return -1; }
    if (n < sizeof(int)) { free(bytes); return -1; }
    int argc; memcpy(&argc, bytes, sizeof(int));
    char *p = bytes + sizeof(int), *end = bytes + n;
    p += strnlen(p, end-p); if (p < end) p++;
    while (p < end && !*p) p++;
    for (int i = 0; i < argc && p < end; i++) { p += strnlen(p, end-p); if (p < end) p++; }
    char expected[160]; snprintf(expected, sizeof(expected), "PIKACHU_EXECUTION_TOKEN=%s", token);
    int found = 0;
    while (p < end && *p) {
        size_t length = strnlen(p, end-p);
        if (length == strlen(expected) && !memcmp(p, expected, length)) { found = 1; break; }
        p += length; if (p < end) p++;
    }
    volatile unsigned char *clear = (volatile unsigned char *)bytes;
    for (size_t i = 0; i < n; i++) clear[i] = 0;
    free(bytes);
    return found;
}
