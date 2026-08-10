#include <git2.h>

static inline int codeinsight_repository_oid_type(git_repository *repository) {
    return (int)git_repository_oid_type(repository);
}

static inline int codeinsight_use_repository_config_only(void) {
    const git_config_level_t levels[] = {
        GIT_CONFIG_LEVEL_SYSTEM,
        GIT_CONFIG_LEVEL_XDG,
        GIT_CONFIG_LEVEL_GLOBAL,
    };
    for (size_t index = 0; index < sizeof(levels) / sizeof(levels[0]); index++) {
        int code = git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, levels[index], "");
        if (code < 0) {
            return code;
        }
    }
    return 0;
}

static inline int codeinsight_oid_sha1(void) {
    return (int)GIT_OID_SHA1;
}

static inline int codeinsight_oid_sha256(void) {
#ifdef GIT_EXPERIMENTAL_SHA256
    return (int)GIT_OID_SHA256;
#else
    return 2;
#endif
}
