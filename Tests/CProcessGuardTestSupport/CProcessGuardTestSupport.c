#include "CProcessGuardTestSupport.h"

#include "CProcessGuard.h"

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const int crash_signals[] = {
    SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL,
};

static const int termination_signals[] = {
    SIGTERM, SIGINT, SIGHUP,
};

static void restore_default_handlers(void) {
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (unsigned long i = 0;
         i < sizeof(crash_signals) / sizeof(crash_signals[0]);
         i++) {
        sigaction(crash_signals[i], &action, NULL);
    }
    for (unsigned long i = 0;
         i < sizeof(termination_signals) / sizeof(termination_signals[0]);
         i++) {
        sigaction(termination_signals[i], &action, NULL);
    }
}

static void unblock_signal(int signal_number) {
    sigset_t signal_set;
    sigemptyset(&signal_set);
    sigaddset(&signal_set, signal_number);
    sigprocmask(SIG_UNBLOCK, &signal_set, NULL);
}

static void restore_default_handler(int signal_number) {
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(signal_number, &action, NULL);
    unblock_signal(signal_number);
}

static bool write_pid(int fd, pid_t pid) {
    const char *bytes = (const char *)&pid;
    size_t remaining = sizeof(pid);
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }
        bytes += written;
        remaining -= (size_t)written;
    }
    return true;
}

static bool read_pid(int fd, pid_t *pid) {
    char *bytes = (char *)pid;
    size_t remaining = sizeof(*pid);
    while (remaining > 0) {
        ssize_t count = read(fd, bytes, remaining);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return false;
        }
        bytes += count;
        remaining -= (size_t)count;
    }
    return true;
}

static bool process_exists(pid_t pid) {
    return pid > 1 && (kill(pid, 0) == 0 || errno != ESRCH);
}

static bool wait_for_no_process(pid_t pid, int seconds) {
    time_t deadline = time(NULL) + seconds;
    while (time(NULL) < deadline) {
        if (!process_exists(pid)) {
            return true;
        }
        usleep(10000);
    }
    return !process_exists(pid);
}

static void kill_group_and_wait(pid_t leader, pid_t child) {
    if (leader > 1) {
        kill(-leader, SIGKILL);
        int status = 0;
        (void)waitpid(leader, &status, 0);
    }
    if (child > 1) {
        kill(child, SIGKILL);
    }
}

static bool spawn_signal_helper(
    bool guard_enabled,
    int signal_number,
    bool use_abort,
    pid_t *helper_pid,
    pid_t *fake_child_pid
) {
    if (guard_enabled && !ci_process_guard_install()) {
        return false;
    }

    int output[2];
    if (pipe(output) != 0) {
        return false;
    }

    pid_t helper = fork();
    if (helper < 0) {
        close(output[0]);
        close(output[1]);
        return false;
    }
    if (helper == 0) {
        close(output[0]);
        if (guard_enabled) {
            if (!ci_process_guard_install()) {
                _exit(123);
            }
        } else {
            restore_default_handlers();
            if (!use_abort) {
                restore_default_handler(signal_number);
            }
        }
        if (!use_abort) {
            unblock_signal(signal_number);
        }

        pid_t fake_child = fork();
        if (fake_child < 0) {
            _exit(124);
        }
        if (fake_child == 0) {
            close(output[1]);
            execl("/bin/sleep", "sleep", "300", NULL);
            _exit(127);
        }
        if (!ci_process_guard_register(fake_child, false)) {
            kill(fake_child, SIGKILL);
            _exit(125);
        }
        if (!write_pid(output[1], fake_child)) {
            kill(fake_child, SIGKILL);
            _exit(126);
        }
        close(output[1]);
        if (use_abort) {
            abort();
        }
        kill(getpid(), signal_number);
        _exit(127);
    }

    close(output[1]);
    bool read_succeeded = read_pid(output[0], fake_child_pid);
    close(output[0]);
    if (!read_succeeded) {
        kill(helper, SIGKILL);
        waitpid(helper, NULL, 0);
        return false;
    }
    *helper_pid = helper;
    return true;
}

bool ci_test_spawn_guard_leader(
    bool guard_enabled,
    pid_t *guard_leader_pid,
    pid_t *grandchild_pid,
    bool *grandchild_alive_after_unregister
) {
    if (guard_enabled && !ci_process_guard_install()) {
        return false;
    }

    int output[2];
    if (pipe(output) != 0) {
        return false;
    }
    pid_t leader = fork();
    if (leader < 0) {
        close(output[0]);
        close(output[1]);
        return false;
    }
    if (leader > 0) {
        close(output[1]);
        bool read_ok = read_pid(output[0], grandchild_pid);
        close(output[0]);
        if (!read_ok) {
            kill(-leader, SIGKILL);
            waitpid(leader, NULL, 0);
            return false;
        }
        if (guard_enabled
            && (!ci_process_guard_register(leader, true)
                || !ci_process_guard_register(leader, false)
                || !ci_process_guard_unregister(leader))) {
            kill_group_and_wait(leader, *grandchild_pid);
            return false;
        }
        bool cleaned = wait_for_no_process(*grandchild_pid, 1);
        kill_group_and_wait(leader, *grandchild_pid);
        *guard_leader_pid = leader;
        *grandchild_alive_after_unregister = !cleaned;
        return true;
    }

    close(output[0]);
    if (setpgid(0, 0) != 0) {
        _exit(125);
    }
    pid_t grandchild = fork();
    if (grandchild < 0) {
        _exit(126);
    }
    if (grandchild == 0) {
        close(output[1]);
        execl("/bin/sleep", "sleep", "300", NULL);
        _exit(127);
    }
    if (!write_pid(output[1], grandchild)) {
        kill(grandchild, SIGKILL);
        _exit(128);
    }
    close(output[1]);
    for (;;) {
        pause();
    }
}

bool ci_test_spawn_abort_helper(
    bool guard_enabled,
    pid_t *helper_pid,
    pid_t *fake_child_pid
) {
    return spawn_signal_helper(
        guard_enabled,
        SIGABRT,
        true,
        helper_pid,
        fake_child_pid
    );
}

bool ci_test_spawn_signal_helper(
    bool guard_enabled,
    int signal_number,
    pid_t *helper_pid,
    pid_t *fake_child_pid
) {
    return spawn_signal_helper(
        guard_enabled,
        signal_number,
        false,
        helper_pid,
        fake_child_pid
    );
}
