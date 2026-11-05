/*
 * hakuX on macOS — the window the HLE GPU presents to (vk/swapchain.c): a
 * CAMetalLayer and its drawable size in pixels, set by the app's view.
 */
#ifndef HAKUX_MAC_ANDROID_NATIVE_WINDOW_H
#define HAKUX_MAC_ANDROID_NATIVE_WINDOW_H

#include <stdint.h>

struct ANativeWindow {
    const void *layer;          /* CAMetalLayer */
    volatile int32_t width, height;
};
typedef struct ANativeWindow ANativeWindow;

static inline int32_t ANativeWindow_getWidth(ANativeWindow *w)
{
    return w->width;
}

static inline int32_t ANativeWindow_getHeight(ANativeWindow *w)
{
    return w->height;
}

#endif
