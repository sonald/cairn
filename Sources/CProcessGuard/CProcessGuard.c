#include "CProcessGuard.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define CI_PROCESS_GUARD_CAPACITY 64

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "pid slots must be lock-free");

static _Atomic int fallback_child_pids[CI_PROCESS_GUARD_CAPACITY];
static _Atomic int *child_pids = fallback_child_pids;
static _Atomic int install_result;
static pthread_once_t install_once = PTHREAD_ONCE_INIT;
static int reaper_write_fd = -1;
static pid_t reaper_owner_pid;

static const int crash_signals[] = {
    SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL,
};

static void kill_children(_Atomic int *pids) {
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        pid_t pid = atomic_load_explicit(&pids[i], memory_order_relaxed);
        if (pid > 1) {
            kill(pid, SIGKILL);
        }
    }
}

static void kill_registered_children(void) {
    kill_children(child_pids);
}

static void clear_registered_children_after_fork(void) {
    if (reaper_write_fd >= 0) {
        close(reaper_write_fd);
    }
    reaper_write_fd = -1;
    reaper_owner_pid = 0;
    child_pids = fallback_child_pids;
    for (int i = 0; i < CI_PROCESS_GUARD_CAPACITY; i++) {
        atomic_store_explicit(
            &fallback_child_pids[i],
            0,
            memory_order_relaxed
        );
    }
}

static void crash_handler(int signal_number) {
    kill_registered_children();
    if (kill(getpid(), signal_number) == -1) {
        _exit(128 + signal_number);
    }
}

static void watch_parent(
    int fd,
    int descriptor_limit,
    _Atomic int *pids
) {
    setpgid(0, 0);
    for (int inherited_fd = 0;
         inherited_fd < descriptor_limit;
         inherited_fd++) {
        if (inherited_fd != fd) {
            close(inherited_fd);
        }
    }

    char byte;
    while (true) {
        ssize_t count = read(fd, &byte, sizeof(byte));
        if (count == 0) {
            kill_children(pids);
            _exit(0);
        }
        if (count < 0 && errno != EINTR) {
            kill_children(pids);
            _exit(1);
        }
    }
}

static bool start_reaper(void) {
    size_t registry_size = sizeof(*child_pids) * CI_PROCESS_GUARD_CAPACITY;
    _Atomic int *shared_pids = mmap(
        NULL,
        registry_size,
        PROT_READ | PROT_WRITE,
        MAP_ANON | MAP_SHARED,
        -1,
        0
    );
    if (shared_pids == MAP_FAILED) {
        return false;
    }

    int descriptor_limit = getdtablesize();
    int liveness[2] = {-1, -1};
    if (pipe(liveness) != 0
        || fcntl(liveness[1], F_SETFD, FD_CLOEXEC) != 0) {
        if (liveness[0] >= 0) {
            close(liveness[0]);
            close(liveness[1]);
        }
        munmap(shared_pids, registry_size);
        return false;
    }

    pid_t reaper = fork();
    if (reaper == 0) {
        watch_parent(liveness[0], descriptor_limit, shared_pids);
    }
    if (reaper < 0) {
        close(liveness[0]);
        close(liveness[1]);
        munmap(shared_pids, registry_size);
        return false;
    }

    close(liveness[0]);
    child_pids = shared_pids;
    reaper_write_fd = liveness[1];
    reaper_owner_pid = getpid();
    return true;
}

static bool install_signal_handlers(void) {
    struct sigaction action = {0};
    action.sa_handler = crash_handler;
    action.sa_flags = SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (unsigned long i = 0;
         i < sizeof(crash_signals) / sizeof(crash_signals[0]);
         i++) {
        if (sigaction(crash_signals[i], &action, NULL) != 0) {
            return false;
        }
    }
    return true;
}

static void install(void) {
    if (atexit(kill_registered_children) != 0
        || pthread_atfork(
            NULL,
            NULL,
            clear_registered_children_after_fork
        ) != 0
        || !install_signal_handlers()
        || !start_reaper()) {
        atomic_store_explicit(&install_result, -1, memory_order_relaxed);
        return;
    }
    atomic_store_explicit(&install_result, 1, memory_order_relaxed);
}

bool ci_process_guard_install(void) {
    pthread_once(&install_once, install);
    if (atomic_load_explicit(&install_result, memory_order_relaxed) != 1) {
        return false;
    }
    if (reaper_owner_pid == getpid()) {
        return true;
    }
    return install_signal_handlers() && start_reaper();
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
