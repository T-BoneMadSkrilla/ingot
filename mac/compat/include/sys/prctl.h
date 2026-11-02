/* Darwin has no prctl: every option reports EINVAL, as an old Linux kernel would for one it lacks. */
#pragma once
#include <errno.h>

static inline int prctl(int option, ...)
{
    (void)option;
    errno = EINVAL;
    return -1;
}
