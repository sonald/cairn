#ifndef C_PROCESS_GUARD_TEST_SUPPORT_H
#define C_PROCESS_GUARD_TEST_SUPPORT_H

#include <stdbool.h>
#include <sys/types.h>

bool ci_test_spawn_abort_helper(
    bool guard_enabled,
    pid_t *helper_pid,
    pid_t *fake_child_pid
);

#endif
