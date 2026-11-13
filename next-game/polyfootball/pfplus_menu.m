// pfplus_menu.m — v2.3 in-game UIKit overlay menu.
//
// Replaces hand-editing Documents/pfplus.json with a floating panel of
// UISwitches. Reveal via tap on a floating "PF+" orb pinned to the
// top-right of the screen. Toggles write directly to the in-memory
// config (pfp_cfg_set_bool) so the next tick picks them up — no file
// reload, no app relaunch.
//
// Approach: pure ObjC-runtime via objc_msgSend. No SDK headers needed —
// we forward-declare the ObjC runtime API, then build a dynamic
// NSObject subclass for the target/action handlers. All UIKit calls go
// through typed objc_msgSend casts. SPPlus uses the same pattern
// (SEND macros in SpooferProPlus.m); this file is a stripped-down
// variant with just what the menu needs.
//
// Visual: not the premium glass/tier-badge mockup yet — that's v2.4
// polish. v2.3 ships a functional panel: dark semi-transparent
// background, title row, one UISwitch per force flag, close button.

#include "features.h"
#include <stdarg.h>
#include <string.h>

// --- ObjC runtime surface --------------------------------------------------

typedef void *id;
typedef void *SEL;
typedef void (*IMP)(id, SEL, ...);
typedef struct objc_class *Class;
typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO  ((BOOL)0)
#define nil ((id)0)

extern id       objc_msgSend();
extern Class    objc_getClass(const char *);
extern SEL      sel_registerName(const char *);
extern Class    objc_allocateClassPair(Class, const char *, unsigned long);
extern void     objc_registerClassPair(Class);
extern BOOL     class_addMethod(Class, SEL, IMP, const char *);
extern id       objc_autoreleasePoolPush(void);
extern void     objc_autoreleasePoolPop(void *);

// CoreGraphics / UIKit geometry
typedef struct { double x, y; } CGPoint;
typedef struct { double w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

// Typed msgSend wrappers. The 0/1/2/3 suffix is argument count after
// (id, SEL). msg_frame/msg_bool/msg_double are special-case signatures
// for arg types that need HFA / scalar calling conventions.
#define C(s) objc_getClass(s)
#define S(s) sel_registerName(s)

static inline id msg0(id o, SEL s) {
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static inline id msg1(id o, SEL s, void *a) {
    return ((id (*)(id, SEL, void *))objc_msgSend)(o, s, a);
}
static inline id msg2(id o, SEL s, void *a, void *b) {
    return ((id (*)(id, SEL, void *, void *))objc_msgSend)(o, s, a, b);
}
static inline id msg3(id o, SEL s, void *a, void *b, void *c) {
    return ((id (*)(id, SEL, void *, void *, void *))objc_msgSend)(o, s, a, b, c);
}
static inline void msg_setFrame(id o, CGRect r) {
    ((void (*)(id, SEL, CGRect))objc_msgSend)(o, S("setFrame:"), r);
}
static inline void msg_setBool(id o, SEL s, BOOL b) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(o, s, b);
}
static inline BOOL msg_getBool(id o, SEL s) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static inline id msg_color_rgba(double r, double g, double b, double a) {
    return ((id (*)(Class, SEL, double, double, double, double))objc_msgSend)
        (C("UIColor"), S("colorWithRed:green:blue:alpha:"), r, g, b, a);
}
static inline id msg_string(const char *utf8) {
    return ((id (*)(Class, SEL, const char *))objc_msgSend)
        (C("NSString"), S("stringWithUTF8String:"), utf8);
}
static inline id msg_font(double size) {
    return ((id (*)(Class, SEL, double))objc_msgSend)
        (C("UIFont"), S("systemFontOfSize:"), size);
}
static inline id msg_bold_font(double size) {
    return ((id (*)(Class, SEL, double))objc_msgSend)
        (C("UIFont"), S("boldSystemFontOfSize:"), size);
}
static inline void msg_addTarget(id ctl, id target, SEL action, unsigned events) {
    ((void (*)(id, SEL, id, SEL, unsigned))objc_msgSend)
        (ctl, S("addTarget:action:forControlEvents:"), target, action, events);
}
// UIControlEventTouchUpInside = 1 << 6 = 64
// UIControlEventValueChanged = 1 << 12 = 4096
#define EV_TOUCH_UP   64u
#define EV_VALUE_CHG  4096u

// --- Toggle registry -------------------------------------------------------

struct toggle_def {
    const char *key;      // config key
    const char *label;    // display text
    id          sw;       // UISwitch id (set during buildMenu)
};

static struct toggle_def g_toggles[] = {
    { "fumbles_force",  "No Fumbles",        nil },
    { "injuries_force", "No Injuries",       nil },
    { "tackle_force",   "Never Tackled",     nil },
    { "catch_force",    "Magnet Hands",      nil },
    { "pro",            "Pro Unlock",        nil },
    { "agent",          "Agent Unlock",      nil },
    { "triple_tickets", "Triple Tickets",    nil },
    { "cap_increase",   "Cap Increase",      nil },
};
#define NUM_TOGGLES ((int)(sizeof(g_toggles) / sizeof(g_toggles[0])))

// --- Menu state ------------------------------------------------------------

static id   g_panel        = nil;   // the floating panel UIView
static id   g_orb          = nil;   // the floating button
static id   g_controller   = nil;   // instance of our dynamic class
static int  g_installed    = 0;
static int  g_menu_visible = 0;

// Forward decls for the handlers (defined below).
static void handler_toggleChanged(id self, SEL _cmd, id sender);
static void handler_orbTap(id self, SEL _cmd, id sender);
static void handler_close(id self, SEL _cmd, id sender);

// --- Dynamic class registration -------------------------------------------

static Class pfp_menu_class(void) {
    static Class cls = NULL;
    if (cls) return cls;
    cls = objc_allocateClassPair(C("NSObject"), "PFPMenuCtrl", 0);
    if (!cls) {
        pfp_log("menu: objc_allocateClassPair failed");
        return NULL;
    }
    class_addMethod(cls, S("toggleChanged:"), (IMP)handler_toggleChanged, "v@:@");
    class_addMethod(cls, S("orbTap:"),        (IMP)handler_orbTap,        "v@:@");
    class_addMethod(cls, S("close:"),         (IMP)handler_close,         "v@:@");
    objc_registerClassPair(cls);
    return cls;
}

// --- Handlers --------------------------------------------------------------

static void handler_toggleChanged(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd;
    for (int i = 0; i < NUM_TOGGLES; i++) {
        if (g_toggles[i].sw == sender) {
            BOOL on = msg_getBool(sender, S("isOn"));
            pfp_cfg_set_bool(g_toggles[i].key, on ? 1 : 0);
            pfp_log("menu: %s -> %d", g_toggles[i].key, on ? 1 : 0);
            return;
        }
    }
}

static void handler_orbTap(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    if (!g_panel) return;
    g_menu_visible = !g_menu_visible;
    msg_setBool(g_panel, S("setHidden:"), g_menu_visible ? NO : YES);
    pfp_log("menu: orb tap -> visible=%d", g_menu_visible);
}

static void handler_close(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    if (!g_panel) return;
    g_menu_visible = 0;
    msg_setBool(g_panel, S("setHidden:"), YES);
}

// --- Panel builder ---------------------------------------------------------

// Returns the host UIWindow to add our subviews into. Uses the first
// UIWindow of UIApplication.windows (iOS 13+ safe); keyWindow as a
// fallback on older paths.
static id find_host_window(void) {
    id app = msg0((id)C("UIApplication"), S("sharedApplication"));
    if (!app) return nil;
    id windows = msg0(app, S("windows"));
    if (windows) {
        unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(windows, S("count"));
        for (unsigned long i = 0; i < n; i++) {
            id w = ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, S("objectAtIndex:"), i);
            if (w && msg_getBool(w, S("isKeyWindow"))) return w;
        }
        // fallback: first window
        if (n > 0) return ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, S("objectAtIndex:"), 0UL);
    }
    return msg0(app, S("keyWindow"));  // deprecated but widely-used fallback
}

static id build_label(const char *text, CGRect frame, int bold, double size, double r, double g, double b) {
    id lbl = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(lbl, frame);
    msg1(lbl, S("setText:"), (void *)msg_string(text));
    msg1(lbl, S("setFont:"), (void *)(bold ? msg_bold_font(size) : msg_font(size)));
    msg1(lbl, S("setTextColor:"), (void *)msg_color_rgba(r, g, b, 1.0));
    return lbl;
}

static id build_switch(const char *key, BOOL initial, CGRect frame) {
    id sw = msg0(msg0((id)C("UISwitch"), S("alloc")), S("init"));
    CGRect sf = frame;
    // UISwitch has intrinsic size; set origin only.
    sf.size.w = 51; sf.size.h = 31;
    msg_setFrame(sw, sf);
    msg_setBool(sw, S("setOn:"), initial);
    msg_addTarget(sw, g_controller, S("toggleChanged:"), EV_VALUE_CHG);
    (void)key;
    return sw;
}

static void build_panel(id host) {
    // Dimensions: ~300x(60+rows*46+40) centered horizontally, offset from top.
    double panel_w = 300.0;
    double row_h   = 46.0;
    double panel_h = 60.0 + NUM_TOGGLES * row_h + 40.0;
    CGSize screen = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds")).size;
    (void)screen;  // used for centering if needed

    g_panel = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(g_panel, (CGRect){{20, 80}, {panel_w, panel_h}});
    // Dark translucent background.
    msg1(g_panel, S("setBackgroundColor:"), (void *)msg_color_rgba(0.08, 0.08, 0.10, 0.92));
    // Rounded corners via layer.cornerRadius = 16.
    id layer = msg0(g_panel, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 16.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    msg_setBool(g_panel, S("setHidden:"), YES);  // hidden by default; orb tap reveals

    // Title
    id title = build_label("PFPlus v2.3", (CGRect){{20, 14}, {200, 24}}, 1, 18.0, 1.0, 1.0, 1.0);
    msg1(g_panel, S("addSubview:"), (void *)title);

    // Close button
    id close_btn = msg0(((id (*)(Class, SEL, long))objc_msgSend)(
        (id)C("UIButton"), S("buttonWithType:"), 1L), S("self"));
    // UIButtonTypeSystem = 1; init via class method
    close_btn = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 1L);
    msg_setFrame(close_btn, (CGRect){{panel_w - 60, 10}, {50, 30}});
    ((void (*)(id, SEL, void *, long))objc_msgSend)(close_btn, S("setTitle:forState:"),
                                                     (void *)msg_string("Close"), 0L);
    msg_addTarget(close_btn, g_controller, S("close:"), EV_TOUCH_UP);
    msg1(g_panel, S("addSubview:"), (void *)close_btn);

    // Divider
    id div = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(div, (CGRect){{16, 50}, {panel_w - 32, 0.5}});
    msg1(div, S("setBackgroundColor:"), (void *)msg_color_rgba(1.0, 1.0, 1.0, 0.18));
    msg1(g_panel, S("addSubview:"), (void *)div);

    // Rows
    double y = 60.0;
    for (int i = 0; i < NUM_TOGGLES; i++) {
        id lbl = build_label(g_toggles[i].label, (CGRect){{16, y + 8}, {200, 28}},
                             0, 15.0, 0.95, 0.95, 0.95);
        msg1(g_panel, S("addSubview:"), (void *)lbl);

        BOOL initial = pfp_cfg_bool(g_toggles[i].key, 0) ? YES : NO;
        g_toggles[i].sw = build_switch(g_toggles[i].key, initial,
                                        (CGRect){{panel_w - 67, y + 7}, {51, 31}});
        msg1(g_panel, S("addSubview:"), (void *)g_toggles[i].sw);

        y += row_h;
    }

    msg1(host, S("addSubview:"), (void *)g_panel);
}

static void build_orb(id host) {
    g_orb = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 0L);  // Custom
    CGSize host_size = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds")).size;
    double x = host_size.w - 60;
    msg_setFrame(g_orb, (CGRect){{x, 60}, {44, 44}});
    msg1(g_orb, S("setBackgroundColor:"), (void *)msg_color_rgba(0.95, 0.65, 0.20, 1.0));  // amber
    ((void (*)(id, SEL, void *, long))objc_msgSend)(g_orb, S("setTitle:forState:"),
                                                     (void *)msg_string("PF+"), 0L);
    id title_lbl = msg0(g_orb, S("titleLabel"));
    msg1(title_lbl, S("setFont:"), (void *)msg_bold_font(13.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(g_orb, S("setTitleColor:forState:"),
                                                     (void *)msg_color_rgba(1,1,1,1), 0L);
    id layer = msg0(g_orb, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 22.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    msg_addTarget(g_orb, g_controller, S("orbTap:"), EV_TOUCH_UP);
    msg1(host, S("addSubview:"), (void *)g_orb);
}

// --- Public entry ----------------------------------------------------------

void pfp_menu_install(void) {
    if (g_installed) return;
    id host = find_host_window();
    if (!host) {
        // Try again next tick — UIKit may not be fully initialised.
        return;
    }
    Class cls = pfp_menu_class();
    if (!cls) return;

    void *pool = objc_autoreleasePoolPush();
    g_controller = msg0(msg0((id)cls, S("alloc")), S("init"));
    build_panel(host);
    build_orb(host);
    objc_autoreleasePoolPop(pool);

    g_installed = 1;
    pfp_log("menu: installed · host=%p panel=%p orb=%p controller=%p",
            (void *)host, (void *)g_panel, (void *)g_orb, (void *)g_controller);
}
