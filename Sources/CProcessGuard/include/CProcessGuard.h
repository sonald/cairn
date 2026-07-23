#ifndef C_PROCESS_GUARD_H
#define C_PROCESS_GUARD_H

#include <stdbool.h>
#include <sys/types.h>

bool ci_process_guard_install(void);
bool ci_process_guard_register(pid_t pid);
bool ci_process_guard_unregister(pid_t pid);
bool ci_process_guard_contains(pid_t pid);

#endif
