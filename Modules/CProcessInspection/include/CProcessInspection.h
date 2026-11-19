#include <stdint.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid, status;
    uint64_t seconds, microseconds;
} pk_process_identity;
int pk_process_identity_for(int pid, pk_process_identity *result);
int pk_list_pids(int *buffer, int capacity);
int pk_process_has_marker(int pid, const char *token);
void pk_install_signal_handlers(void);
int pk_stop_requested(void);
