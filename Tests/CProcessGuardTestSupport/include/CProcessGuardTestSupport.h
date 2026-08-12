#ifndef C_PROCESS_GUARD_TEST_SUPPORT_H
#define C_PROCESS_GUARD_TEST_SUPPORT_H

#include <stdbool.h>
#include <sys/types.h>

bool ci_test_spawn_abort_helper(
    bool guard_enabled,
    pid_t *helper_pid,
    pid_t *fake_child_pid
);

bool ci_test_spawn_signal_helper(
    bool guard_enabled,
    int signal_number,
    pid_t *helper_pid,
    pid_t *fake_child_pid
);

bool ci_test_spawn_guard_leader(
    bool guard_enabled,
    pid_t *guard_leader_pid,
    pid_t *grandchild_pid,
    bool *grandchild_alive_after_unregister
);

#endif
