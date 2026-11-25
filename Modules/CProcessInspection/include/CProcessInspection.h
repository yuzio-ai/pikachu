#include <stdint.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid, status;
    uint64_t seconds, microseconds;
} pk_process_identity;
int pk_process_identity_for(int pid, pk_process_identity *result);
int pk_list_pids(int *buffer, int capacity);
typedef struct pk_marker_scan pk_marker_scan;
pk_marker_scan *pk_marker_scan_create(const char *token);
int pk_marker_scan_matches(pk_marker_scan *scan, int pid);
void pk_marker_scan_destroy(pk_marker_scan *scan);
void pk_install_signal_handlers(void);
int pk_stop_requested(void);
int pk_spawn_terminal_child(int32_t *pid, const char *executable, char *const argv[], char *const envp[]);
int pk_poll_terminal_child(int32_t pid, int32_t *exit_code, int32_t *by_signal);
