#include "CProcessGuard.h"

#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>

#define CI_PROCESS_GUARD_CAPACITY 64

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "pid slots must be lock-free");

static _Atomic int child_pids[CI_PROCESS_GUARD_CAPACITY];
static _Atomic int install_result;
static pthread_once_t install_once = PTHREAD_ONCE_INIT;

static const int crash_signals[] = {
    SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL,
};

static void kill_registered_children(void) {
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        pid_t pid = atomic_load_explicit(&child_pids[i], memory_order_relaxed);
        if (pid > 1) {
            kill(pid, SIGKILL);
        }
    }
}

static void clear_registered_children_after_fork(void) {
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        atomic_store_explicit(&child_pids[i], 0, memory_order_relaxed);
    }
}

static void crash_handler(int signal_number) {
    kill_registered_children();
    if (kill(getpid(), signal_number) == -1) {
        _exit(128 + signal_number);
    }
}

static void install(void) {
    if (atexit(kill_registered_children) != 0
        || pthread_atfork(NULL, NULL, clear_registered_children_after_fork) != 0) {
        atomic_store_explicit(&install_result, -1, memory_order_relaxed);
        return;
    }

    struct sigaction action = {0};
    action.sa_handler = crash_handler;
    action.sa_flags = SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (unsigned long i = 0;
         i < sizeof(crash_signals) / sizeof(crash_signals[0]);
         i++) {
        if (sigaction(crash_signals[i], &action, NULL) != 0) {
            atomic_store_explicit(&install_result, -1, memory_order_relaxed);
            return;
        }
    }
    atomic_store_explicit(&install_result, 1, memory_order_relaxed);
}

bool ci_process_guard_install(void) {
    pthread_once(&install_once, install);
    return atomic_load_explicit(&install_result, memory_order_relaxed) == 1;
}

bool ci_process_guard_register(pid_t pid) {
    if (pid <= 1) {
        return false;
    }
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        int expected = 0;
        if (atomic_compare_exchange_strong_explicit(
                &child_pids[i],
                &expected,
                pid,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return true;
        }
        if (expected == pid) {
            return true;
        }
    }
    return false;
}

bool ci_process_guard_unregister(pid_t pid) {
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        int expected = pid;
        if (atomic_compare_exchange_strong_explicit(
                &child_pids[i],
                &expected,
                0,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return true;
        }
    }
    return false;
}

bool ci_process_guard_contains(pid_t pid) {
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        if (atomic_load_explicit(&child_pids[i], memory_order_relaxed) == pid) {
            return true;
        }
    }
    return false;
}
