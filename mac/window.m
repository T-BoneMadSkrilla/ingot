/*
 * hakuX on macOS — the window: a Cocoa window whose view is a CAMetalLayer,
 * handed to the HLE GPU's presenter as the ANativeWindow it draws into
 * (mac/compat/include/android/native_window.h; hw/xbox/hle/vk/swapchain.c
 * makes its Vulkan surface of the layer through MoltenVK). The main thread
 * runs the window and presents, as the Android app's does
 * (native/app/app_main.c); the core runs on a thread of its own.
 *
 * Each game controller (GameController framework) takes the lowest free
 * player of 1-4 as it connects and keeps it until it disconnects, or until
 * the Controllers menu gives it another; the console sees those players'
 * controllers plugged in, and player 1's always, for the keyboard:
 *   WASD left stick     arrows right stick    J A   K B   U X   I Y
 *   H white   L black   Q left trigger        E right trigger
 *   1 2 3 4 D-pad up, down, left, right       Return start   Backspace back
 *   Z, C left and right stick click           Cmd-Q quits    Ctrl-Cmd-F full screen
 *
 * Ingot's launcher names the window (INGOT_TITLE, else the disc's file
 * name), gives the app its icon (INGOT_ICON, a file), may start it full
 * screen (INGOT_FULLSCREEN=1) and shapes it 16:9 (INGOT_WIDESCREEN=1).
 *
 * A title that reboots into another XBE (XLaunchNewImage: KotOR II between
 * areas) ends the core's run; the process execs itself again with relaunch,
 * and the new window opens where the old one was (INGOT_FRAME), full screen
 * if it was, showing the old one's last frame (INGOT_COVER) until the game
 * presents.
 */
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>

#include "native/app/app.h"
#include "native/dev/usb.h"
#include "native/state/save.h"
#include "mac/window.h"

#include <android/native_window.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <spawn.h>
#include <stdlib.h>
#include <unistd.h>

void nc_kernel_relaunch_file(char *out, size_t n);
uint8_t *hle_disp_read_front(uint32_t *w, uint32_t *h);
void g_free(void *p);

static struct ANativeWindow g_nw;
static bool g_keys[128];
/* the window as the main loop last saw it, for a relaunch */
static NSRect g_win_frame;
static bool g_win_full;
/* a relaunch asks the main loop to hand this app's activation to the image it
 * execs (macOS activates an app only when the active one yields to it) */
static _Atomic bool g_yield;
static dispatch_semaphore_t g_yielded;

@interface NcView : NSView
@end

@implementation NcView
- (BOOL)acceptsFirstResponder
{
    return YES;
}
- (void)keyDown:(NSEvent *)e
{
    if (e.modifierFlags & NSEventModifierFlagCommand) {
        return; /* the menus' */
    }
    if (e.keyCode == 0x35) { /* Esc: out of full screen */
        if (self.window.styleMask & NSWindowStyleMaskFullScreen) {
            [self.window toggleFullScreen:nil];
        }
        return;
    }
    if (e.keyCode < 128) {
        g_keys[e.keyCode] = true;
    }
}
- (void)keyUp:(NSEvent *)e
{
    if (e.keyCode < 128) {
        g_keys[e.keyCode] = false;
    }
}
@end

static GCController *g_player[4];
static NSString *g_note;                /* shown in the title until g_note_until */
static CFTimeInterval g_note_until;

static void put_player(GCController *c, unsigned p)
{
    g_player[p] = c;
    if (c) {
        c.playerIndex = (GCControllerPlayerIndex)(GCControllerPlayerIndex1 + p);
    }
}

@interface NcDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@end

@implementation NcDelegate
/* Save State: the running game to ~/Library/Application Support/Ingot/States/
 * (the folder also holds the states' shared blobs), off the main thread;
 * the window's title says how it went. */
- (void)saveState:(id)sender
{
    NSString *title = NSApp.windows.firstObject.title ?: @"game";
    NSString *name = [[title componentsSeparatedByString:@" — "].firstObject
        stringByReplacingOccurrencesOfString:@"/"
                                  withString:@"-"];
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"Ingot/States"
                        isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"hxs"]].path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *err = nc_state_save(path.fileSystemRepresentation);
        NSLog(@"Save State: %@: %s", path, err ? err : "saved");
        NSString *note = err ? [NSString stringWithFormat:@"couldn't save state: %s", err] : @"state saved";
        dispatch_async(dispatch_get_main_queue(), ^{
            g_note = note;
            g_note_until = CACurrentMediaTime() + 4.0;
        });
    });
}
/* The Controllers menu: each controller's player, chosen there; taking a
 * player another controller has swaps the two. */
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];
    unsigned n = 0;
    for (unsigned p = 0; p < 4; p++) {
        GCController *c = g_player[p];
        if (!c) {
            continue;
        }
        NSString *name = c.vendorName ?: @"Controller";
        NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ (Player %u)", name, p + 1]
                                           action:nil
                                    keyEquivalent:@""];
        NSMenu *sub = [NSMenu new];
        for (unsigned q = 0; q < 4; q++) {
            NSMenuItem *pick = [sub addItemWithTitle:[NSString stringWithFormat:@"Player %u", q + 1]
                                              action:@selector(pickPlayer:)
                                       keyEquivalent:@""];
            pick.target = self;
            pick.tag = q;
            pick.representedObject = c;
            pick.state = q == p ? NSControlStateValueOn : NSControlStateValueOff;
        }
        item.submenu = sub;
        n++;
    }
    if (!n) {
        [menu addItemWithTitle:@"No Controllers Connected" action:nil keyEquivalent:@""].enabled = NO;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"The keyboard is always Player 1" action:nil keyEquivalent:@""].enabled = NO;
}
- (void)pickPlayer:(NSMenuItem *)item
{
    GCController *c = item.representedObject;
    const unsigned to = (unsigned)item.tag;
    for (unsigned p = 0; p < 4; p++) {
        if (g_player[p] == c && p != to) {
            GCController *other = g_player[to];
            put_player(c, to);
            put_player(other, p);
            return;
        }
    }
}
- (void)windowWillClose:(NSNotification *)n
{
    _exit(0);
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    _exit(0);
}
@end

/* macOS virtual key codes (Carbon's kVK_*) */
enum {
    K_A = 0x00, K_S = 0x01, K_D = 0x02, K_H = 0x04, K_Z = 0x06, K_C = 0x08, K_Q = 0x0C, K_W = 0x0D,
    K_E = 0x0E, K_1 = 0x12, K_2 = 0x13, K_3 = 0x14, K_4 = 0x15, K_U = 0x20, K_I = 0x22, K_RETURN = 0x24,
    K_L = 0x25, K_J = 0x26, K_K = 0x28, K_DELETE = 0x33, K_LEFT = 0x7B, K_RIGHT = 0x7C, K_DOWN = 0x7D,
    K_UP = 0x7E,
};

static int16_t axis(bool neg, bool pos)
{
    return (int16_t)((pos ? 32767 : 0) - (neg ? 32767 : 0));
}

static void read_keys(NcPadState *s)
{
    static const struct {
        uint8_t key, analog;
    } k_analog[] = {
        {K_J, 0}, {K_K, 1}, {K_U, 2}, {K_I, 3}, {K_L, 4}, {K_H, 5}, {K_Q, 6}, {K_E, 7},
    };
    static const struct {
        uint8_t key;
        uint16_t bit;
    } k_digital[] = {
        {K_1, NC_PAD_DPAD_UP}, {K_2, NC_PAD_DPAD_DOWN}, {K_3, NC_PAD_DPAD_LEFT}, {K_4, NC_PAD_DPAD_RIGHT},
        {K_RETURN, NC_PAD_START}, {K_DELETE, NC_PAD_BACK}, {K_Z, NC_PAD_LTHUMB}, {K_C, NC_PAD_RTHUMB},
    };
    for (unsigned i = 0; i < sizeof(k_analog) / sizeof(k_analog[0]); i++) {
        if (g_keys[k_analog[i].key]) {
            s->analog[k_analog[i].analog] = 0xFF;
        }
    }
    for (unsigned i = 0; i < sizeof(k_digital) / sizeof(k_digital[0]); i++) {
        if (g_keys[k_digital[i].key]) {
            s->buttons |= k_digital[i].bit;
        }
    }
    s->lx = axis(g_keys[K_A], g_keys[K_D]);
    s->ly = axis(g_keys[K_S], g_keys[K_W]);
    s->rx = axis(g_keys[K_LEFT], g_keys[K_RIGHT]);
    s->ry = axis(g_keys[K_DOWN], g_keys[K_UP]);
}

static int16_t stick(float v)
{
    return (int16_t)(v < -1.0f ? -32767 : v > 1.0f ? 32767 : v * 32767.0f);
}

/* The Duke from a modern controller, as app_main.c's read_gamepad: the face
 * buttons and black/white (the shoulder buttons) fully pressed or not; the
 * stick pushed furthest wins over the keyboard's. */
static void read_controller(GCExtendedGamepad *g, NcPadState *s)
{
    if (!g) {
        return;
    }
    GCControllerButtonInput *analog[6] = {g.buttonA, g.buttonB, g.buttonX, g.buttonY, g.rightShoulder,
                                          g.leftShoulder};
    for (unsigned i = 0; i < 6; i++) {
        if (analog[i].pressed) {
            s->analog[i] = 0xFF;
        }
    }
    const uint8_t lt = (uint8_t)(g.leftTrigger.value * 255.0f), rt = (uint8_t)(g.rightTrigger.value * 255.0f);
    s->analog[6] = lt > s->analog[6] ? lt : s->analog[6];
    s->analog[7] = rt > s->analog[7] ? rt : s->analog[7];
    s->buttons |= (g.dpad.up.pressed ? NC_PAD_DPAD_UP : 0) | (g.dpad.down.pressed ? NC_PAD_DPAD_DOWN : 0) |
                  (g.dpad.left.pressed ? NC_PAD_DPAD_LEFT : 0) | (g.dpad.right.pressed ? NC_PAD_DPAD_RIGHT : 0) |
                  (g.buttonMenu.pressed ? NC_PAD_START : 0) | (g.buttonOptions.pressed ? NC_PAD_BACK : 0) |
                  (g.leftThumbstickButton.pressed ? NC_PAD_LTHUMB : 0) |
                  (g.rightThumbstickButton.pressed ? NC_PAD_RTHUMB : 0);
    const int16_t lx = stick(g.leftThumbstick.xAxis.value), ly = stick(g.leftThumbstick.yAxis.value);
    const int16_t rx = stick(g.rightThumbstick.xAxis.value), ry = stick(g.rightThumbstick.yAxis.value);
    if (abs(lx) + abs(ly) > abs(s->lx) + abs(s->ly)) {
        s->lx = lx;
        s->ly = ly;
    }
    if (abs(rx) + abs(ry) > abs(s->rx) + abs(s->ry)) {
        s->rx = rx;
        s->ry = ry;
    }
}

/* Gives the controllers that came their players and frees the players of
 * those that went; the console's controllers follow. */
static void assign_players(void)
{
    static int s_mask = -1;
    NSArray<GCController *> *now = GCController.controllers;
    for (unsigned p = 0; p < 4; p++) {
        if (g_player[p] && ![now containsObject:g_player[p]]) {
            g_player[p] = nil;
        }
    }
    for (GCController *c in now) {
        if (!c.extendedGamepad) {
            continue;
        }
        unsigned p = 0;
        while (p < 4 && g_player[p] != c) {
            p++;
        }
        if (p < 4) {
            continue;
        }
        for (p = 0; p < 4 && g_player[p]; p++) {
        }
        if (p == 4) {
            break;
        }
        put_player(c, p);
    }
    int mask = 1;
    for (unsigned p = 0; p < 4; p++) {
        mask |= g_player[p] ? 1 << p : 0;
    }
    if (mask != s_mask) {
        nc_dev_ohci_set_pads((unsigned)mask);
        s_mask = mask;
    }
}

static int (*g_core)(void *);
static void *g_core_arg;

/* The front image as the cover file: width, height, then RGBA rows. */
static bool write_cover(const char *path)
{
    uint32_t w = 0, h = 0;
    uint8_t *px = hle_disp_read_front(&w, &h);
    if (!px) {
        return false;
    }
    FILE *f = fopen(path, "wb");
    const uint32_t dim[2] = {w, h};
    const bool ok = f && fwrite(dim, sizeof(dim), 1, f) == 1 && fwrite(px, (size_t)w * h * 4, 1, f) == 1;
    if (f) {
        fclose(f);
    }
    g_free(px);
    return ok;
}

/* The core again in this process's place, booting what the relaunch file
 * names; returns only if it couldn't (the launcher starts it then). */
static void relaunch(void)
{
    char cover[512];
    snprintf(cover, sizeof(cover), "%s/ingot-cover-%d.rgba", getenv("TMPDIR") ?: "/tmp", getpid());
    if (write_cover(cover)) {
        setenv("INGOT_COVER", cover, 1);
    }    char frame[128];
    snprintf(frame, sizeof(frame), "%g %g %g %g", g_win_frame.origin.x, g_win_frame.origin.y,
             g_win_frame.size.width, g_win_frame.size.height);
    setenv("INGOT_FRAME", frame, 1);
    setenv("INGOT_FULLSCREEN", g_win_full ? "1" : "0", 1);
    g_yield = true;
    dispatch_semaphore_wait(g_yielded, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));

    const int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    char *args[argc + 2];
    int n = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "relaunch")) {
            args[n++] = argv[i];
        }
    }
    args[n++] = "relaunch";
    args[n] = NULL;

    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size)) {
        return;
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    for (int fd = 0; fd < 3; fd++) {
        posix_spawn_file_actions_addinherit_np(&fa, fd);
    }
    fflush(NULL);
    posix_spawn(NULL, exe, &fa, &attr, args, *_NSGetEnviron());
    fprintf(stderr, "hakuX-mac: relaunch: exec %s failed\n", exe);
    unlink(cover);
}

static void *core_thread(void *arg)
{
    const int status = g_core(g_core_arg);
    char file[512];
    nc_kernel_relaunch_file(file, sizeof(file));
    if (status == 10 && access(file, F_OK) == 0) {
        relaunch();
    }
    _exit(status);
}

static void add_menus(NSString *app_name, NcDelegate *delegate)
{
    NSMenu *bar = [NSMenu new];
    NSMenuItem *app_item = [NSMenuItem new];
    [bar addItem:app_item];
    NSMenu *app_menu = [NSMenu new];
    [app_menu addItemWithTitle:[@"Hide " stringByAppendingString:app_name] action:@selector(hide:) keyEquivalent:@"h"];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:@"Save State" action:@selector(saveState:) keyEquivalent:@"s"].target = delegate;
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:@"Quit Game" action:@selector(terminate:) keyEquivalent:@"q"];
    app_item.submenu = app_menu;

    NSMenuItem *window_item = [NSMenuItem new];
    [bar addItem:window_item];
    NSMenu *window_menu = [[NSMenu alloc] initWithTitle:@"Window"];
    NSMenuItem *full = [window_menu addItemWithTitle:@"Toggle Full Screen"
                                              action:@selector(toggleFullScreen:)
                                       keyEquivalent:@"f"];
    full.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [window_menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    window_item.submenu = window_menu;

    NSMenuItem *pads_item = [NSMenuItem new];
    [bar addItem:pads_item];
    NSMenu *pads_menu = [[NSMenu alloc] initWithTitle:@"Controllers"];
    pads_menu.delegate = delegate;
    pads_item.submenu = pads_menu;
    NSApp.mainMenu = bar;
}

/* The last frame before a relaunch (INGOT_COVER), over the layer until the
 * game presents, or nil. */
static CALayer *cover_layer(CALayer *layer)
{
    const char *path = getenv("INGOT_COVER");
    if (!path) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    unlink(path);
    unsetenv("INGOT_COVER");
    uint32_t dim[2];
    if (data.length < sizeof(dim)) {
        return nil;
    }
    memcpy(dim, data.bytes, sizeof(dim));
    const size_t bytes = (size_t)dim[0] * dim[1] * 4;
    if (!dim[0] || !dim[1] || data.length < sizeof(dim) + bytes) {
        return nil;
    }
    CGDataProviderRef src = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)[data subdataWithRange:NSMakeRange(sizeof(dim), bytes)]);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(dim[0], dim[1], 8, 32, (size_t)dim[0] * 4, cs,
                                     kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast, src, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(src);
    if (!image) {
        return nil;
    }
    CALayer *cover = [CALayer layer];
    cover.contents = (__bridge_transfer id)image;
    cover.contentsGravity = kCAGravityResizeAspect;
    cover.frame = layer.bounds;
    cover.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [layer addSublayer:cover];
    return cover;
}

void nc_mac_window_run(const char *title, int (*core)(void *), void *arg)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NcDelegate *delegate = [NcDelegate new];
        NSApp.delegate = delegate;
        const char *icon = getenv("INGOT_ICON");
        if (icon) {
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:icon]];
            if (image) {
                NSApp.applicationIconImage = image;
            }
        }
        if (getenv("INGOT_TITLE")) {
            title = getenv("INGOT_TITLE");
        }
        add_menus(NSProcessInfo.processInfo.processName, delegate);
        [NSApp finishLaunching];

        NSWindow *w = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1280, 960)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        w.delegate = delegate;
        w.title = [NSString stringWithUTF8String:title];
        const bool wide = getenv("INGOT_WIDESCREEN") && atoi(getenv("INGOT_WIDESCREEN"));
        w.contentAspectRatio = wide ? NSMakeSize(16, 9) : NSMakeSize(4, 3);
        if (wide) {
            [w setContentSize:NSMakeSize(1280, 720)];
        }
        w.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        w.backgroundColor = NSColor.blackColor;
        NcView *view = [[NcView alloc] initWithFrame:w.contentLayoutRect];
        CAMetalLayer *layer = [CAMetalLayer layer];
        view.layer = layer;
        view.wantsLayer = YES;
        w.contentView = view;
        [w makeFirstResponder:view];
        double fx, fy, fw, fh;
        const char *frame = getenv("INGOT_FRAME");
        if (frame && sscanf(frame, "%lf %lf %lf %lf", &fx, &fy, &fw, &fh) == 4 && fw > 0 && fh > 0) {
            [w setFrame:NSMakeRect(fx, fy, fw, fh) display:NO];
        } else {
            [w center];
        }
        CALayer *cover = cover_layer(layer);
        [w makeKeyAndOrderFront:nil];
        [NSApp activate];
        if (getenv("INGOT_FULLSCREEN") && atoi(getenv("INGOT_FULLSCREEN"))) {
            [w toggleFullScreen:nil];
        }
        g_nw.layer = (__bridge const void *)layer;

        g_core = core;
        g_core_arg = arg;
        g_yielded = dispatch_semaphore_create(0);
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 16u << 20);
        pthread_t t;
        pthread_create(&t, &attr, core_thread, NULL);
        pthread_attr_destroy(&attr);
        uint64_t n = 0;
        for (;;) {
            @autoreleasepool {
                NSEvent *e;
                while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                               untilDate:nil
                                                  inMode:NSDefaultRunLoopMode
                                                 dequeue:YES])) {
                    [NSApp sendEvent:e];
                }
                const CGFloat scale = w.backingScaleFactor;
                const CGSize size = view.bounds.size;
                layer.contentsScale = scale;
                const CGSize px = CGSizeMake(size.width * scale, size.height * scale);
                if (!CGSizeEqualToSize(layer.drawableSize, px)) {
                    layer.drawableSize = px;
                }
                g_nw.width = (int32_t)px.width;
                g_nw.height = (int32_t)px.height;

                assign_players();
                for (unsigned p = 0; p < 4; p++) {
                    NcPadState s = {0};
                    if (p == 0 && w.isKeyWindow) {
                        read_keys(&s);
                    }
                    read_controller(g_player[p].extendedGamepad, &s);
                    nc_pad_set(p, &s);
                }

                g_win_full = w.styleMask & NSWindowStyleMaskFullScreen;
                if (!g_win_full) {
                    g_win_frame = w.frame;
                }
                if (g_yield) {
                    g_yield = false;
                    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
                    if (bid) {
                        [NSApp yieldActivationToApplicationWithBundleIdentifier:bid];
                    }
                    dispatch_semaphore_signal(g_yielded);
                }

                if (!nc_present_frame(&g_nw)) {
                    usleep(8000);
                } else if (cover) {
                    [cover removeFromSuperlayer];
                    cover = nil;
                }
                if (++n % 30 == 0) {
                    float fps, avg, last;
                    nc_present_stats(&fps, &avg, &last);
                    w.title = CACurrentMediaTime() < g_note_until
                                  ? [NSString stringWithFormat:@"%s — %@", title, g_note]
                                  : [NSString stringWithFormat:@"%s — %.0f fps", title, fps];
                }
            }
        }
    }
}
