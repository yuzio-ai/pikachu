#include <stdint.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid, status;
    uint64_t seconds, microseconds;
} zv_process_identity;
int zv_process_identity_for(int pid, zv_process_identity *result);
int zv_list_pids(int *buffer, int capacity);
typedef struct zv_marker_scan zv_marker_scan;
zv_marker_scan *zv_marker_scan_create(const char *token);
int zv_marker_scan_matches(zv_marker_scan *scan, int pid);
void zv_marker_scan_destroy(zv_marker_scan *scan);
void zv_install_signal_handlers(void);
int zv_stop_requested(void);
int zv_spawn_terminal_child(int32_t *pid, const char *executable, char *const argv[], char *const envp[]);
int zv_poll_terminal_child(int32_t pid, int32_t *exit_code, int32_t *by_signal);
int zv_spawn_group_child(int32_t *pid, const char *executable, char *const argv[], char *const envp[]);
int zv_observe_group_child_exit(int32_t pid, int32_t *exit_code, int32_t *by_signal);
