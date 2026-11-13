// pfplus_menu.m — v2.4.1 in-game UIKit overlay menu (premium polish).
//
// Replaces hand-editing Documents/pfplus.json with a floating panel of
// UISwitches. Reveal via tap on a floating "PF+" orb pinned to the
// top-right of the screen. Toggles write directly to the in-memory
// config (pfp_cfg_set_bool) so the next tick picks them up — no file
// reload, no app relaunch.
//
// v2.4.1: orb is now draggable too. Pan handler moved to gesture.view
// so it reuses between orb + panel. Added a visible drag handle (grab
// bar) at the top of the panel so users can see where to drag.
//
// Approach: pure ObjC-runtime via objc_msgSend. No SDK headers needed —
// we forward-declare the ObjC runtime API, then build a dynamic
// NSObject subclass for the target/action handlers. All UIKit calls go
// through typed objc_msgSend casts. SPPlus uses the same pattern
// (SEND macros in SpooferProPlus.m); this file is a stripped-down
// variant with just what the menu needs.
//
// v2.4 visual upgrade — matches the premium design artifact:
//   * UIVisualEffectView with systemThickMaterialDark blur backing
//   * Per-row tier chip (T1 emerald / T2 amber / T2.5 violet / SAFE red)
//   * Bold label + mono meta subline per row
//   * Bold "PFPlus" header + version pill + "×" close button
//   * Footer action bar: Kill All (red) and Dump Log (amber)
//   * Draggable panel via UIPanGestureRecognizer on header
//   * Floating orb redesigned with gradient-amber fill and shadow

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
    const char *meta;     // small mono subline (method or scope)
    const char *tier;     // "T1" / "T2" / "T2.5" / "SAFE"
    double tr, tg, tb;    // tier color
    id          sw;       // UISwitch id (set during buildMenu)
};

// Palette matching the "PFPlus Menu" design artifact:
//   T1 emerald  (0.37, 0.84, 0.61)
//   T2 amber    (0.91, 0.64, 0.24)
//   T2.5 violet (0.70, 0.61, 0.94)
//   SAFE red    (0.94, 0.48, 0.48)
static struct toggle_def g_toggles[] = {
    // Safety — flip ON before joining multiplayer. Blocks installation
    // of all physics/offense hooks (tackle/fumbles/injuries/catch/throw/
    // accuracy). Already-installed hooks from a prior session persist
    // until next cold boot, so set this before you first enable them.
    { "mp_safe",        "MP safe mode",     "gates offense hooks for MP",     "SAFE", 0.94,0.48,0.48, nil },
    // Tier 1 — economy (invoke-pattern, already proven)
    { "pro",            "Pro",              "UnlockPro · static",            "T1",  0.37,0.84,0.61, nil },
    { "agent",          "Agent",            "UnlockAgent · static",          "T1",  0.37,0.84,0.61, nil },
    { "triple_tickets", "Triple ticket boost", "UnlockTripleTicket · static", "T1",  0.37,0.84,0.61, nil },
    { "cap_increase",   "Save-cap increase","UnlockCapIncrease · static",    "T1",  0.37,0.84,0.61, nil },
    // Tier 2 — physics (methodPointer swap, v2.2.1)
    { "fumbles_force",  "No fumbles",       "FootballFumbleRules · 5 hooks",  "T2",  0.91,0.64,0.24, nil },
    { "injuries_force", "No injuries",      "InjuryCatalog · 4 hooks",        "T2",  0.91,0.64,0.24, nil },
    { "tackle_force",   "Never tackled",    "CarrierMoveRules · 6 hooks",     "T2",  0.91,0.64,0.24, nil },
    { "catch_force",    "Magnet hands",     "FootballCatchReach · 2 hooks",   "T2",  0.91,0.64,0.24, nil },
    // Tier 2 — economy/offense (methodPointer swap, v2.5)
    { "skills_force",   "Free skill points","CareerSkillCosts · Cost+Spent=0","T2",  0.91,0.64,0.24, nil },
    { "cap_force",      "Infinite save-cap","CareerTeamBudget.Cap · huge int","T2",  0.91,0.64,0.24, nil },
    { "throw_force",    "Cannon arm",       "ThrowController · PassIsBullet", "T2",  0.91,0.64,0.24, nil },
    { "accuracy_force", "Perfect accuracy", "ThrowController · spread=0",     "T2",  0.91,0.64,0.24, nil },
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
static void handler_killAll(id self, SEL _cmd, id sender);
static void handler_dumpLog(id self, SEL _cmd, id sender);
static void handler_pan(id self, SEL _cmd, id gesture);

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
    class_addMethod(cls, S("killAll:"),       (IMP)handler_killAll,       "v@:@");
    class_addMethod(cls, S("dumpLog:"),       (IMP)handler_dumpLog,       "v@:@");
    class_addMethod(cls, S("pan:"),           (IMP)handler_pan,           "v@:@");
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

static void handler_killAll(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    // Flip every toggle to OFF in both config and UI. Note: methodPointer
    // swaps that were already installed stay installed (no un-swap path
    // in v2.4) — but the force flags going false means the game's
    // behavior reverts because the hooks are only installed once on the
    // true→next-tick transition. Flipping back off prevents re-install.
    for (int i = 0; i < NUM_TOGGLES; i++) {
        pfp_cfg_set_bool(g_toggles[i].key, 0);
        if (g_toggles[i].sw) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)
                (g_toggles[i].sw, S("setOn:animated:"), NO, YES);
        }
    }
    pfp_log("menu: Kill All — all toggles reset to 0");
}

static void handler_dumpLog(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    pfp_log("menu: ==== Dump Log ====");
    for (int i = 0; i < NUM_TOGGLES; i++) {
        int on = pfp_cfg_bool(g_toggles[i].key, 0);
        pfp_log("menu:   %s=%d  (%s)", g_toggles[i].key, on, g_toggles[i].meta);
    }
    pfp_log("menu: ==== End Dump ====");
}

static void handler_pan(id self, SEL _cmd, id gesture) {
    (void)self; (void)_cmd;
    if (!gesture) return;
    // Use the gesture's own view so one handler drags whatever it's on:
    // the panel OR the floating orb. This lets us reuse the same handler
    // for both — no duplicated geometry code.
    id view = msg0(gesture, S("view"));
    if (!view) return;
    id parent = msg0(view, S("superview"));
    if (!parent) return;

    CGPoint t = ((CGPoint (*)(id, SEL, id))objc_msgSend)
        (gesture, S("translationInView:"), parent);
    CGPoint c = ((CGPoint (*)(id, SEL))objc_msgSend)(view, S("center"));
    c.x += t.x; c.y += t.y;
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(view, S("setCenter:"), c);
    CGPoint zero = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)
        (gesture, S("setTranslation:inView:"), zero, parent);
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
    // Emerald on-tint to match the artifact palette.
    msg1(sw, S("setOnTintColor:"), (void *)msg_color_rgba(0.37, 0.84, 0.61, 1.0));
    (void)key;
    return sw;
}

// Small colored pill label — tier chip ("T1", "T2", "SAFE", …) or the
// version pill in the header. Centered bold white text on a rounded
// colored background.
static id build_tier_chip(const char *text, double r, double g, double b, CGRect frame) {
    id chip = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(chip, frame);
    msg1(chip, S("setText:"), (void *)msg_string(text));
    msg1(chip, S("setFont:"), (void *)msg_bold_font(10.0));
    msg1(chip, S("setTextColor:"), (void *)msg_color_rgba(1, 1, 1, 1));
    msg1(chip, S("setBackgroundColor:"), (void *)msg_color_rgba(r, g, b, 0.85));
    // NSTextAlignmentCenter = 1
    ((void (*)(id, SEL, long))objc_msgSend)(chip, S("setTextAlignment:"), 1L);
    id layer = msg0(chip, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 5.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    return chip;
}

// Monospace label for the meta subline ("UnlockPro · static").
static id build_mono_label(const char *text, CGRect frame, double size) {
    id lbl = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(lbl, frame);
    msg1(lbl, S("setText:"), (void *)msg_string(text));
    // UIFont.monospacedSystemFontOfSize:weight: — regular = 0.0
    id mono = ((id (*)(Class, SEL, double, double))objc_msgSend)
        ((id)C("UIFont"), S("monospacedSystemFontOfSize:weight:"), size, 0.0);
    if (mono) {
        msg1(lbl, S("setFont:"), (void *)mono);
    } else {
        msg1(lbl, S("setFont:"), (void *)msg_font(size));
    }
    msg1(lbl, S("setTextColor:"), (void *)msg_color_rgba(0.68, 0.72, 0.78, 1.0));
    return lbl;
}

// Footer action button — "Kill All" / "Dump Log". Rounded, filled, bold.
static id build_action_button(const char *title, double r, double g, double b,
                              CGRect frame, const char *action_sel) {
    // UIButtonTypeCustom = 0
    id btn = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 0L);
    msg_setFrame(btn, frame);
    msg1(btn, S("setBackgroundColor:"), (void *)msg_color_rgba(r, g, b, 1.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(btn, S("setTitle:forState:"),
                                                     (void *)msg_string(title), 0L);
    ((void (*)(id, SEL, void *, long))objc_msgSend)(btn, S("setTitleColor:forState:"),
                                                     (void *)msg_color_rgba(1, 1, 1, 1), 0L);
    id title_lbl = msg0(btn, S("titleLabel"));
    msg1(title_lbl, S("setFont:"), (void *)msg_bold_font(14.0));
    id layer = msg0(btn, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 10.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    msg_addTarget(btn, g_controller, S(action_sel), EV_TOUCH_UP);
    return btn;
}

static void build_panel(id host) {
    // Layout constants — mirror the design artifact.
    // v2.5.1: rows live in a UIScrollView so the panel fits on smaller
    // phones (iPhone SE ≈ 667pt). Panel height is capped at the host
    // window's bounds minus 100pt safe margin; the scroll view takes
    // whatever's between header and footer.
    const double panel_w     = 320.0;
    const double header_h    = 56.0;
    const double row_h       = 50.0;
    const double footer_h    = 60.0;
    const double side_pad    = 14.0;
    const double desired_h   = header_h + NUM_TOGGLES * row_h + footer_h + 8.0;
    CGSize host_size_tmp = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds")).size;
    const double max_h       = host_size_tmp.h - 100.0;
    const double panel_h     = desired_h < max_h ? desired_h : max_h;
    const double scroll_h    = panel_h - header_h - footer_h - 8.0;
    const double scroll_content_h = NUM_TOGGLES * row_h;

    // --- Backing: UIVisualEffectView with systemThickMaterialDark blur.
    // UIBlurEffectStyleSystemThickMaterialDark = 15 (iOS 13+). If this
    // enum changes on a later OS the view still renders — just as a
    // fainter blur — so we don't guard with a fallback.
    id effect = ((id (*)(Class, SEL, long))objc_msgSend)
        ((id)C("UIBlurEffect"), S("effectWithStyle:"), 15L);
    g_panel = ((id (*)(id, SEL, id))objc_msgSend)
        (msg0((id)C("UIVisualEffectView"), S("alloc")),
         S("initWithEffect:"), effect);
    msg_setFrame(g_panel, (CGRect){{20, 60}, {panel_w, panel_h}});

    // Rounded corners + a subtle border on the panel's own layer.
    id layer = msg0(g_panel, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 18.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setBorderWidth:"), 0.5);
    id border_col = msg_color_rgba(1, 1, 1, 0.12);
    id cg_border = msg0(border_col, S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setBorderColor:"), (void *)cg_border);

    msg_setBool(g_panel, S("setHidden:"), YES);  // orb tap reveals

    // All children hang off the visual-effect view's contentView — the
    // effect view's own addSubview: works too but Apple's docs insist
    // on contentView, so follow that.
    id content = msg0(g_panel, S("contentView"));

    // --- Header ---
    // Drag handle "grab bar" — a short pale pill centered at the very
    // top of the header. Purely visual: hints to the user that the panel
    // is draggable. The pan gesture is attached to the whole panel below,
    // so dragging anywhere empty on the header actually moves it.
    id grab = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(grab, (CGRect){{(panel_w - 40) / 2.0, 6}, {40, 4}});
    msg1(grab, S("setBackgroundColor:"), (void *)msg_color_rgba(1, 1, 1, 0.35));
    id grab_layer = msg0(grab, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(grab_layer, S("setCornerRadius:"), 2.0);
    msg_setBool(grab_layer, S("setMasksToBounds:"), YES);
    msg1(content, S("addSubview:"), (void *)grab);

    // Bold "PFPlus" wordmark.
    id wordmark = build_label("PFPlus", (CGRect){{side_pad, 16}, {120, 26}},
                              1, 22.0, 1, 1, 1);
    msg1(content, S("addSubview:"), (void *)wordmark);

    // "v2.5.1" version pill — small amber chip to the right of the wordmark.
    id ver_pill = build_tier_chip("v2.5.1", 0.91, 0.64, 0.24,
                                  (CGRect){{side_pad + 92, 24}, {50, 18}});
    msg1(content, S("addSubview:"), (void *)ver_pill);

    // "×" close button — top-right of the header.
    id close_btn = ((id (*)(Class, SEL, long))objc_msgSend)
        ((id)C("UIButton"), S("buttonWithType:"), 0L);  // Custom
    msg_setFrame(close_btn, (CGRect){{panel_w - 44, 14}, {32, 32}});
    ((void (*)(id, SEL, void *, long))objc_msgSend)(close_btn, S("setTitle:forState:"),
                                                     (void *)msg_string("×"), 0L);
    ((void (*)(id, SEL, void *, long))objc_msgSend)(close_btn, S("setTitleColor:forState:"),
                                                     (void *)msg_color_rgba(1, 1, 1, 0.75), 0L);
    id close_lbl = msg0(close_btn, S("titleLabel"));
    msg1(close_lbl, S("setFont:"), (void *)msg_bold_font(22.0));
    msg1(close_btn, S("setBackgroundColor:"), (void *)msg_color_rgba(1, 1, 1, 0.08));
    id close_layer = msg0(close_btn, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(close_layer, S("setCornerRadius:"), 8.0);
    msg_setBool(close_layer, S("setMasksToBounds:"), YES);
    msg_addTarget(close_btn, g_controller, S("close:"), EV_TOUCH_UP);
    msg1(content, S("addSubview:"), (void *)close_btn);

    // Header-level pan gesture for drag. Attached to the panel itself —
    // handler_pan reads translation in panel.superview and shifts
    // panel.center accordingly, so grabbing anywhere drags for v2.4.
    // (A future polish can confine the hit area to a narrow header strip.)
    id pan = ((id (*)(id, SEL, id, SEL))objc_msgSend)
        (msg0((id)C("UIPanGestureRecognizer"), S("alloc")),
         S("initWithTarget:action:"), g_controller, S("pan:"));
    msg1(g_panel, S("addGestureRecognizer:"), (void *)pan);

    // Header divider.
    id div = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(div, (CGRect){{side_pad, header_h - 1}, {panel_w - 2 * side_pad, 0.5}});
    msg1(div, S("setBackgroundColor:"), (void *)msg_color_rgba(1, 1, 1, 0.15));
    msg1(content, S("addSubview:"), (void *)div);

    // --- Scrollable rows container ---
    // v2.5.1 — a UIScrollView between header and footer holds every
    // toggle row, so the panel fits SE-sized screens.
    id scroll = msg0(msg0((id)C("UIScrollView"), S("alloc")), S("init"));
    msg_setFrame(scroll, (CGRect){{0, header_h}, {panel_w, scroll_h}});
    ((void (*)(id, SEL, CGSize))objc_msgSend)
        (scroll, S("setContentSize:"), (CGSize){panel_w, scroll_content_h});
    msg_setBool(scroll, S("setShowsVerticalScrollIndicator:"), YES);
    msg_setBool(scroll, S("setBounces:"), YES);
    // Let the panel's own pan gesture work even when the touch starts
    // on the scroll view — the recognizer will fail if the user is
    // flicking the scroll content, so both gestures coexist naturally.
    msg1(content, S("addSubview:"), (void *)scroll);

    // --- Rows (into the scroll view, origin starts at 4) ---
    double y = 4.0;
    for (int i = 0; i < NUM_TOGGLES; i++) {
        struct toggle_def *t = &g_toggles[i];

        // Tier chip on the left.
        id chip = build_tier_chip(t->tier, t->tr, t->tg, t->tb,
                                  (CGRect){{side_pad, y + 8}, {36, 16}});
        msg1(scroll, S("addSubview:"), (void *)chip);

        // Bold row label.
        id lbl = build_label(t->label,
                             (CGRect){{side_pad + 44, y + 4}, {panel_w - 44 - 80, 20}},
                             1, 14.0, 0.98, 0.98, 1.0);
        msg1(scroll, S("addSubview:"), (void *)lbl);

        // Mono meta subline.
        id meta = build_mono_label(t->meta,
                                   (CGRect){{side_pad + 44, y + 24}, {panel_w - 44 - 80, 14}},
                                   10.0);
        msg1(scroll, S("addSubview:"), (void *)meta);

        // UISwitch on the right.
        BOOL initial = pfp_cfg_bool(t->key, 0) ? YES : NO;
        t->sw = build_switch(t->key, initial,
                             (CGRect){{panel_w - 51 - side_pad, y + 9}, {51, 31}});
        msg1(scroll, S("addSubview:"), (void *)t->sw);

        // Row separator.
        if (i < NUM_TOGGLES - 1) {
            id sep = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
            msg_setFrame(sep, (CGRect){{side_pad, y + row_h - 1}, {panel_w - 2 * side_pad, 0.5}});
            msg1(sep, S("setBackgroundColor:"), (void *)msg_color_rgba(1, 1, 1, 0.07));
            msg1(scroll, S("addSubview:"), (void *)sep);
        }

        y += row_h;
    }

    // --- Footer action bar ---
    // v2.5.1 — pinned to the panel's bottom, outside the scroll view.
    double footer_y = panel_h - footer_h + 8.0;
    double btn_w = (panel_w - 3 * side_pad) / 2.0;
    // Kill All — red (SAFE palette).
    id kill_btn = build_action_button("Kill All", 0.94, 0.48, 0.48,
                                      (CGRect){{side_pad, footer_y}, {btn_w, 40}},
                                      "killAll:");
    msg1(content, S("addSubview:"), (void *)kill_btn);
    // Dump Log — amber.
    id dump_btn = build_action_button("Dump Log", 0.91, 0.64, 0.24,
                                      (CGRect){{side_pad * 2 + btn_w, footer_y}, {btn_w, 40}},
                                      "dumpLog:");
    msg1(content, S("addSubview:"), (void *)dump_btn);

    // Drop shadow on the panel (configured on the view's own layer, not
    // the backing effect view — shadow needs masksToBounds off, which
    // would break our rounded corners. So the shadow sits on an
    // outer wrapper view when added; for v2.4 we skip it rather than
    // introduce a wrapper. The blur + border already give it depth.)

    msg1(host, S("addSubview:"), (void *)g_panel);
}

static void build_orb(id host) {
    g_orb = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 0L);  // Custom
    CGSize host_size = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds")).size;
    double orb_size = 54.0;
    double x = host_size.w - orb_size - 14.0;
    msg_setFrame(g_orb, (CGRect){{x, 80}, {orb_size, orb_size}});

    // Amber fill matching the artifact palette.
    msg1(g_orb, S("setBackgroundColor:"), (void *)msg_color_rgba(0.95, 0.63, 0.22, 1.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(g_orb, S("setTitle:forState:"),
                                                     (void *)msg_string("PF+"), 0L);
    id title_lbl = msg0(g_orb, S("titleLabel"));
    msg1(title_lbl, S("setFont:"), (void *)msg_bold_font(16.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(g_orb, S("setTitleColor:forState:"),
                                                     (void *)msg_color_rgba(1, 1, 1, 1), 0L);

    id layer = msg0(g_orb, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), orb_size / 2.0);
    // Keep masksToBounds OFF so the drop-shadow renders — the rounded
    // corner still clips the fill because background and content fit
    // the circular bounds.
    msg_setBool(layer, S("setMasksToBounds:"), NO);

    // Drop shadow. shadowColor expects a CGColorRef — fetch via UIColor.CGColor.
    id shadow_col = msg_color_rgba(0, 0, 0, 0.45);
    id cg_shadow = msg0(shadow_col, S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setShadowColor:"), (void *)cg_shadow);
    ((void (*)(id, SEL, float))objc_msgSend)(layer, S("setShadowOpacity:"), 1.0f);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setShadowRadius:"), 8.0);
    ((void (*)(id, SEL, CGSize))objc_msgSend)(layer, S("setShadowOffset:"), (CGSize){0, 4});

    // Thin white ring for the glass-button finish.
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setBorderWidth:"), 1.0);
    id border_col = msg_color_rgba(1, 1, 1, 0.35);
    id cg_border = msg0(border_col, S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setBorderColor:"), (void *)cg_border);

    msg_addTarget(g_orb, g_controller, S("orbTap:"), EV_TOUCH_UP);

    // v2.4.1 — orb is now draggable too. Attach the same pan handler;
    // the handler uses gesture.view so it drags the orb directly.
    // Short taps still fire orbTap: because the pan gesture only triggers
    // once the finger moves far enough — iOS cancels the button's touch
    // at that moment.
    id orb_pan = ((id (*)(id, SEL, id, SEL))objc_msgSend)
        (msg0((id)C("UIPanGestureRecognizer"), S("alloc")),
         S("initWithTarget:action:"), g_controller, S("pan:"));
    msg1(g_orb, S("addGestureRecognizer:"), (void *)orb_pan);

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
