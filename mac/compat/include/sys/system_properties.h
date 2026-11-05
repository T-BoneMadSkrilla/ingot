/*
 * hakuX on macOS — Android's system properties (debug.hakux.*) read from
 * the environment instead: `env debug.hakux.foo=1 xboxrun ...`.
 */
#ifndef HAKUX_MAC_SYS_SYSTEM_PROPERTIES_H
#define HAKUX_MAC_SYS_SYSTEM_PROPERTIES_H

#include <stdlib.h>
#include <string.h>

#define PROP_VALUE_MAX 92

static inline int __system_property_get(const char *name, char *value)
{
    const char *e = getenv(name);
    if (!e) {
        value[0] = 0;
        return 0;
    }
    size_t n = strlen(e);
    if (n > PROP_VALUE_MAX - 1) {
        n = PROP_VALUE_MAX - 1;
    }
    memcpy(value, e, n);
    value[n] = 0;
    return (int)n;
}

#endif
