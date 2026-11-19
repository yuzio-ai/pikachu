#include <stdint.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid, status;
    uint64_t seconds, microseconds;
} m0_identity;
int m0_identity_for(int pid, m0_identity *result);
int m0_pids(int *buffer, int capacity);
int m0_has_marker(int pid, const char *token);
void m0_install_signals(void);
int m0_stop_requested(void);
