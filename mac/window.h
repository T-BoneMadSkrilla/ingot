/*
 * hakuX on macOS — the window (mac/window.m).
 */
#ifndef HAKUX_MAC_WINDOW_H
#define HAKUX_MAC_WINDOW_H

/* Opens the window and presents into it on the calling (main) thread, with
 * core(arg) on a thread of its own: the process exits with what it returns,
 * or when the window closes. Doesn't return. */
void nc_mac_window_run(const char *title, int (*core)(void *), void *arg);

#endif
