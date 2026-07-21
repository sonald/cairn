#include <git2.h>

static inline int codeinsight_repository_oid_type(git_repository *repository) {
    return (int)git_repository_oid_type(repository);
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
