// mgoplus_menu.m — v1 in-game UIKit overlay for the next-roll predictor.
//
// Two pieces:
//   * Floating orb — draggable, always on screen. Shows the predicted
//     next-roll TOTAL as a big number (the whole feature at zero taps).
//     Amber when the roll is doubles (extra roll / jail risk — the thing
//     players actually scan for). Tap reveals the panel.
//   * Panel — thick-material dark card: next roll as dice faces + sum,
//     the following rolls listed below, RNG bookkeeping in a mono footer
//     line, scripted rolls when present, master switch, "Log state" for
//     on-device validation against real rolls.
//
// Approach: pure ObjC-runtime via objc_msgSend (no SDK headers), same as
// pfplus_menu.m. All UIKit calls go through typed msgSend casts.
//
// Polish rules applied (apple-design / emil-design-eng):
//   * Restraint — one glanceable number, no gratuitous animation. The
//     orb IS the feature; the panel is detail.
//   * No redundant redraws — setText only runs when the rendered string
//     actually changed (10 Hz refresh is free but flicker isn't).
//   * Feedback — doubles gets the only color accent; everything else is
//     white-on-material monochrome.

#include "features.h"
#include <stdarg.h>
#include <string.h>
#include <stdio.h>

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

// CoreGraphics / UIKit geometry
typedef struct { double x, y; } CGPoint;
typedef struct { double w, h; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

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
static inline id msg_mono_font(double size) {
    id m = ((id (*)(Class, SEL, double, double))objc_msgSend)
        ((id)C("UIFont"), S("monospacedSystemFontOfSize:weight:"), size, 0.0);
    return m ? m : msg_font(size);
}
static inline void msg_addTarget(id ctl, id target, SEL action, unsigned events) {
    ((void (*)(id, SEL, id, SEL, unsigned))objc_msgSend)
        (ctl, S("addTarget:action:forControlEvents:"), target, action, events);
}
// UIControlEventTouchUpInside = 1 << 6 = 64
// UIControlEventValueChanged  = 1 << 12 = 4096
#define EV_TOUCH_UP   64u
#define EV_VALUE_CHG  4096u

// --- Palette ---------------------------------------------------------------
// Monochrome-on-material with two accents only: emerald = numeric readout,
// amber = doubles (the actionable state). Same accent pair as PFPlus.
#define COL_TEXT       1.00, 1.00, 1.00
#define COL_SUB        0.68, 0.72, 0.78
#define COL_EMERALD    0.37, 0.84, 0.61
#define COL_AMBER      0.91, 0.64, 0.24
#define COL_VIOLET     0.70, 0.61, 0.94

// Unicode die faces U+2680..U+2685 for pips 1..6.
static const char *die_glyph(int v) {
    static const char *g[6] = {
        "\xE2\x9A\x80", "\xE2\x9A\x81", "\xE2\x9A\x82",
        "\xE2\x9A\x83", "\xE2\x9A\x84", "\xE2\x9A\x85"
    };
    if (v < 1 || v > 6) return "\xE2\x8B\x85";  // ⋅ fallback
    return g[v - 1];
}

// --- Menu state ------------------------------------------------------------

static id   g_panel      = nil;
static id   g_orb        = nil;    // container view (circle)
static id   g_orb_num    = nil;    // the big sum label
static id   g_orb_cap    = nil;    // "NEXT" micro-caption
static id   g_controller = nil;
static int  g_installed  = 0;
static int  g_menu_visible = 0;

// Panel subviews that update from the snapshot.
static id   g_die1      = nil;
static id   g_die2      = nil;
static id   g_sum_chip  = nil;
static id   g_dbl_chip  = nil;
static id   g_next_rows[5];      // UILabel "⚄⚃ = 8" for rolls 2..peek
static int  g_next_rows_n = 0;
static id   g_info_lbl  = nil;
static id   g_scr_lbl   = nil;
static id   g_switch    = nil;

// Last-rendered cache — skip setText when unchanged.
static int  g_last_sum     = -1;
static int  g_last_d1      = -1, g_last_d2 = -1;
static int  g_last_dbl     = -1;
static int  g_last_valid   = -1;
static char g_last_info[160] = {0};
static char g_last_scr[120]  = {0};
static char g_last_rows[5][24] = {{0}};
static int  g_last_master  = -1;

// Forward decls for the handlers.
static void handler_orbTap(id self, SEL _cmd, id sender);
static void handler_close(id self, SEL _cmd, id sender);
static void handler_logState(id self, SEL _cmd, id sender);
static void handler_toggleChanged(id self, SEL _cmd, id sender);
static void handler_pan(id self, SEL _cmd, id gesture);

// --- Dynamic class registration -------------------------------------------

static Class mgo_menu_class(void) {
    static Class cls = NULL;
    if (cls) return cls;
    cls = objc_allocateClassPair(C("NSObject"), "MGOMenuCtrl", 0);
    if (!cls) {
        mgo_log("menu: objc_allocateClassPair failed");
        return NULL;
    }
    class_addMethod(cls, S("orbTap:"),        (IMP)handler_orbTap,        "v@:@");
    class_addMethod(cls, S("close:"),         (IMP)handler_close,         "v@:@");
    class_addMethod(cls, S("logState:"),      (IMP)handler_logState,      "v@:@");
    class_addMethod(cls, S("toggleChanged:"), (IMP)handler_toggleChanged, "v@:@");
    class_addMethod(cls, S("pan:"),           (IMP)handler_pan,           "v@:@");
    objc_registerClassPair(cls);
    return cls;
}

// --- Handlers --------------------------------------------------------------

static void handler_orbTap(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    if (!g_panel) return;
    g_menu_visible = !g_menu_visible;
    msg_setBool(g_panel, S("setHidden:"), g_menu_visible ? NO : YES);
}

static void handler_close(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    if (!g_panel) return;
    g_menu_visible = 0;
    msg_setBool(g_panel, S("setHidden:"), YES);
}

static void handler_toggleChanged(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd;
    BOOL on = msg_getBool(sender, S("isOn"));
    mgo_cfg_set_bool("dice", on ? 1 : 0);
    mgo_log("menu: dice -> %d", on ? 1 : 0);
}

static void handler_logState(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    mgo_dice_snapshot_t s;
    mgo_dice_get_snapshot(&s);
    mgo_log("menu: ==== state dump ====");
    if (!s.valid) {
        mgo_log("menu: no BoardState parsed yet");
    } else {
        mgo_log("menu: seed=%lld iter=%d state=%d/2000 mult=%d pos=%d",
                s.seed, s.iter, s.rng_state, s.roll_mult, s.token_pos);
        for (int i = 0; i < s.n_rolls; i++) {
            mgo_roll_t *r = &s.rolls[i];
            mgo_log("menu:   roll+%d: %d+%d=%d%s", i,
                    r->d[0], r->d[1], r->sum, r->doubles ? " DOUBLES" : "");
        }
        if (s.scripted_present) {
            char buf[96]; int w = snprintf(buf, sizeof buf, "menu:   scripted:");
            for (int i = 0; i < s.n_scripted && w < (int)sizeof buf - 6; i++)
                w += snprintf(buf + w, sizeof buf - w, " %d", s.scripted[i]);
            mgo_log("%s", buf);
        }
    }
    mgo_log("menu: ==== end dump ====");
}

static void handler_pan(id self, SEL _cmd, id gesture) {
    (void)self; (void)_cmd;
    if (!gesture) return;
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

// --- Builders --------------------------------------------------------------

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
        if (n > 0) return ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, S("objectAtIndex:"), 0UL);
    }
    return msg0(app, S("keyWindow"));
}

static id build_label(const char *text, CGRect frame, int bold, double size,
                      double r, double g, double b) {
    id lbl = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(lbl, frame);
    msg1(lbl, S("setText:"), (void *)msg_string(text));
    msg1(lbl, S("setFont:"), (void *)(bold ? msg_bold_font(size) : msg_font(size)));
    msg1(lbl, S("setTextColor:"), (void *)msg_color_rgba(r, g, b, 1.0));
    return lbl;
}

static id build_chip(const char *text, double r, double g, double b, CGRect frame) {
    id chip = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(chip, frame);
    msg1(chip, S("setText:"), (void *)msg_string(text));
    msg1(chip, S("setFont:"), (void *)msg_bold_font(11.0));
    msg1(chip, S("setTextColor:"), (void *)msg_color_rgba(1, 1, 1, 1));
    msg1(chip, S("setBackgroundColor:"), (void *)msg_color_rgba(r, g, b, 0.9));
    ((void (*)(id, SEL, long))objc_msgSend)(chip, S("setTextAlignment:"), 1L);
    id layer = msg0(chip, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 6.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    return chip;
}

// Pan + tap coexist on the orb: tap requires pan to FAIL first, else a
// drag-release pops the panel open unintentionally. The panel itself
// only needs pan (no tap action on it).
static void attach_pan(id view) {
    id pan = msg2(msg0((id)C("UIPanGestureRecognizer"), S("alloc")),
                  S("initWithTarget:action:"), g_controller, (void *)S("pan:"));
    msg1(view, S("addGestureRecognizer:"), (void *)pan);
}

static void attach_orb_gestures(id view) {
    id pan = msg2(msg0((id)C("UIPanGestureRecognizer"), S("alloc")),
                  S("initWithTarget:action:"), g_controller, (void *)S("pan:"));
    id tap = msg2(msg0((id)C("UITapGestureRecognizer"), S("alloc")),
                  S("initWithTarget:action:"), g_controller, (void *)S("orbTap:"));
    msg1(tap, S("requireGestureRecognizerToFail:"), (void *)pan);
    msg1(view, S("addGestureRecognizer:"), (void *)pan);
    msg1(view, S("addGestureRecognizer:"), (void *)tap);
}

// --- Orb -------------------------------------------------------------------
// 56pt circle: thick dark backing, white 1px-ish border, micro "NEXT"
// caption and the predicted sum. Amber text when doubles.

static void build_orb(id host) {
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds"));
    g_orb = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(g_orb, (CGRect){{bounds.size.w - 72, 96}, {56, 56}});
    msg1(g_orb, S("setBackgroundColor:"),
         (void *)msg_color_rgba(0.10, 0.10, 0.14, 0.88));
    id layer = msg0(g_orb, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 28.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setBorderWidth:"), 0.5);
    id bc = msg0(msg_color_rgba(1, 1, 1, 0.14), S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setBorderColor:"), (void *)bc);
    // Soft lift so it reads as floating above the board.
    id shc = msg0(msg_color_rgba(0, 0, 0, 0.35), S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setShadowColor:"), (void *)shc);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setShadowOpacity:"), 1.0);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setShadowRadius:"), 8.0);
    CGSize zoff = {0, 2};
    ((void (*)(id, SEL, CGSize))objc_msgSend)(layer, S("setShadowOffset:"), zoff);

    g_orb_cap = build_label("NEXT", (CGRect){{0, 7}, {56, 12}}, 1, 8.0, COL_SUB);
    ((void (*)(id, SEL, long))objc_msgSend)(g_orb_cap, S("setTextAlignment:"), 1L);
    // Slight tracking for the micro-caption.
    msg1(g_orb, S("addSubview:"), (void *)g_orb_cap);

    g_orb_num = build_label("–", (CGRect){{0, 14}, {56, 36}}, 1, 26.0, COL_EMERALD);
    ((void (*)(id, SEL, long))objc_msgSend)(g_orb_num, S("setTextAlignment:"), 1L);
    msg1(g_orb, S("addSubview:"), (void *)g_orb_num);

    attach_orb_gestures(g_orb);
    msg1(host, S("addSubview:"), (void *)g_orb);
}

// --- Panel -----------------------------------------------------------------

static void build_panel(id host) {
    const double panel_w  = 300.0;
    const double header_h = 54.0;
    const double hero_h   = 104.0;
    const double row_h    = 30.0;
    const int    max_rows = 5;
    const double info_h   = 30.0;
    const double scr_h    = 28.0;
    const double ctl_h    = 52.0;
    const double side_pad = 14.0;

    g_next_rows_n = max_rows;
    double desired_h = header_h + hero_h + max_rows * row_h + info_h + scr_h + ctl_h + 8.0;
    CGSize host_size = ((CGRect (*)(id, SEL))objc_msgSend)(host, S("bounds")).size;
    double max_h = host_size.h - 100.0;
    const double panel_h = desired_h < max_h ? desired_h : max_h;

    // Backing: systemThickMaterialDark blur, 18pt radius, hairline border.
    id effect = ((id (*)(Class, SEL, long))objc_msgSend)
        ((id)C("UIBlurEffect"), S("effectWithStyle:"), 15L);
    g_panel = ((id (*)(id, SEL, id))objc_msgSend)
        (msg0((id)C("UIVisualEffectView"), S("alloc")),
         S("initWithEffect:"), effect);
    msg_setFrame(g_panel, (CGRect){{(host_size.w - panel_w) / 2.0, 90},
                                   {panel_w, panel_h}});
    id layer = msg0(g_panel, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setCornerRadius:"), 18.0);
    msg_setBool(layer, S("setMasksToBounds:"), YES);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, S("setBorderWidth:"), 0.5);
    id bc = msg0(msg_color_rgba(1, 1, 1, 0.12), S("CGColor"));
    ((void (*)(id, SEL, void *))objc_msgSend)(layer, S("setBorderColor:"), (void *)bc);
    msg_setBool(g_panel, S("setHidden:"), YES);

    id content = msg0(g_panel, S("contentView"));
    double y = 0;

    // Grab bar — the only affordance hint for drag.
    id grab = msg0(msg0((id)C("UIView"), S("alloc")), S("init"));
    msg_setFrame(grab, (CGRect){{(panel_w - 40) / 2.0, 6}, {40, 4}});
    msg1(grab, S("setBackgroundColor:"), (void *)msg_color_rgba(1, 1, 1, 0.35));
    id gl = msg0(grab, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(gl, S("setCornerRadius:"), 2.0);
    msg_setBool(gl, S("setMasksToBounds:"), YES);
    msg1(content, S("addSubview:"), (void *)grab);

    // Header: wordmark + version pill + close.
    id title = build_label("MGOPlus", (CGRect){{side_pad, 16}, {120, 22}}, 1, 17.0, COL_TEXT);
    msg1(content, S("addSubview:"), (void *)title);
    id ver = build_chip("v1", 0.45, 0.48, 0.55, (CGRect){{side_pad + 70, 18}, {30, 18}});
    msg1(content, S("addSubview:"), (void *)ver);
    id close = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 0L);
    msg_setFrame(close, (CGRect){{panel_w - 44, 14}, {30, 30}});
    ((void (*)(id, SEL, void *, long))objc_msgSend)(close, S("setTitle:forState:"),
        (void *)msg_string("\xC3\x97"), 0L);
    id cl = msg0(close, S("titleLabel"));
    msg1(cl, S("setFont:"), (void *)msg_bold_font(22.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(close, S("setTitleColor:forState:"),
        (void *)msg_color_rgba(COL_SUB, 1.0), 0L);
    msg_addTarget(close, g_controller, S("close:"), EV_TOUCH_UP);
    msg1(content, S("addSubview:"), (void *)close);
    y = header_h;

    // Hero: "NEXT ROLL" caption + two die faces + sum + doubles chip.
    id cap = build_label("N E X T   R O L L", (CGRect){{0, y}, {panel_w, 16}}, 1, 10.0, COL_SUB);
    ((void (*)(id, SEL, long))objc_msgSend)(cap, S("setTextAlignment:"), 1L);
    msg1(content, S("addSubview:"), (void *)cap);
    y += 18;

    g_die1 = build_label(die_glyph(0), (CGRect){{panel_w / 2 - 74, y}, {64, 64}}, 0, 56.0, COL_TEXT);
    ((void (*)(id, SEL, long))objc_msgSend)(g_die1, S("setTextAlignment:"), 1L);
    msg1(content, S("addSubview:"), (void *)g_die1);
    g_die2 = build_label(die_glyph(0), (CGRect){{panel_w / 2 + 10, y}, {64, 64}}, 0, 56.0, COL_TEXT);
    ((void (*)(id, SEL, long))objc_msgSend)(g_die2, S("setTextAlignment:"), 1L);
    msg1(content, S("addSubview:"), (void *)g_die2);
    y += 68;

    g_sum_chip = build_chip("= –", COL_EMERALD, (CGRect){{panel_w / 2 - 70, y}, {64, 20}});
    msg1(content, S("addSubview:"), (void *)g_sum_chip);
    g_dbl_chip = build_chip("DOUBLES", COL_AMBER, (CGRect){{panel_w / 2 + 6, y}, {80, 20}});
    msg_setBool(g_dbl_chip, S("setHidden:"), YES);
    msg1(content, S("addSubview:"), (void *)g_dbl_chip);
    y += 26;

    // Upcoming rolls: "⚃ ⚄ · 9" rows, right-aligned sum.
    for (int i = 0; i < g_next_rows_n; i++) {
        g_next_rows[i] = build_label("", (CGRect){{0, y + i * row_h}, {panel_w, 20}}, 0, 17.0, COL_SUB);
        ((void (*)(id, SEL, long))objc_msgSend)(g_next_rows[i], S("setTextAlignment:"), 1L);
        msg1(content, S("addSubview:"), (void *)g_next_rows[i]);
    }
    y += g_next_rows_n * row_h;

    // Info line — the RNG bookkeeping, monospace, quiet.
    g_info_lbl = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(g_info_lbl, (CGRect){{0, y}, {panel_w, 18}});
    msg1(g_info_lbl, S("setFont:"), (void *)msg_mono_font(10.0));
    msg1(g_info_lbl, S("setTextColor:"), (void *)msg_color_rgba(COL_SUB, 1.0));
    ((void (*)(id, SEL, long))objc_msgSend)(g_info_lbl, S("setTextAlignment:"), 1L);
    msg1(content, S("addSubview:"), (void *)g_info_lbl);
    y += 22;

    // Scripted rolls (hidden unless the server queued some).
    g_scr_lbl = msg0(msg0((id)C("UILabel"), S("alloc")), S("init"));
    msg_setFrame(g_scr_lbl, (CGRect){{0, y}, {panel_w, 18}});
    msg1(g_scr_lbl, S("setFont:"), (void *)msg_mono_font(11.0));
    msg1(g_scr_lbl, S("setTextColor:"), (void *)msg_color_rgba(COL_VIOLET, 1.0));
    ((void (*)(id, SEL, long))objc_msgSend)(g_scr_lbl, S("setTextAlignment:"), 1L);
    msg_setBool(g_scr_lbl, S("setHidden:"), YES);
    msg1(content, S("addSubview:"), (void *)g_scr_lbl);
    y += 26;

    // Control row: master switch + "Log state" button.
    id swlbl = build_label("Prediction", (CGRect){{side_pad, y + 8}, {120, 22}}, 0, 14.0, COL_TEXT);
    msg1(content, S("addSubview:"), (void *)swlbl);
    g_switch = msg0(msg0((id)C("UISwitch"), S("alloc")), S("init"));
    msg_setFrame(g_switch, (CGRect){{side_pad + 110, y + 4}, {51, 31}});
    msg_setBool(g_switch, S("setOn:"), YES);
    msg1(g_switch, S("setOnTintColor:"), (void *)msg_color_rgba(COL_EMERALD, 1.0));
    msg_addTarget(g_switch, g_controller, S("toggleChanged:"), EV_VALUE_CHG);
    msg1(content, S("addSubview:"), (void *)g_switch);

    id logbtn = ((id (*)(Class, SEL, long))objc_msgSend)((id)C("UIButton"), S("buttonWithType:"), 0L);
    msg_setFrame(logbtn, (CGRect){{panel_w - side_pad - 92, y + 4}, {92, 32}});
    msg1(logbtn, S("setBackgroundColor:"), (void *)msg_color_rgba(COL_AMBER, 1.0));
    ((void (*)(id, SEL, void *, long))objc_msgSend)(logbtn, S("setTitle:forState:"),
        (void *)msg_string("Log state"), 0L);
    ((void (*)(id, SEL, void *, long))objc_msgSend)(logbtn, S("setTitleColor:forState:"),
        (void *)msg_color_rgba(1, 1, 1, 1), 0L);
    id tl = msg0(logbtn, S("titleLabel"));
    msg1(tl, S("setFont:"), (void *)msg_bold_font(13.0));
    id bl = msg0(logbtn, S("layer"));
    ((void (*)(id, SEL, double))objc_msgSend)(bl, S("setCornerRadius:"), 9.0);
    msg_setBool(bl, S("setMasksToBounds:"), YES);
    msg_addTarget(logbtn, g_controller, S("logState:"), EV_TOUCH_UP);
    msg1(content, S("addSubview:"), (void *)logbtn);

    attach_pan(g_panel);
    msg1(host, S("addSubview:"), (void *)g_panel);
}

// --- Install / refresh ------------------------------------------------------

void mgo_menu_install(void) {
    if (g_installed) return;
    id host = find_host_window();
    if (!host) return;
    Class cls = mgo_menu_class();
    if (!cls) return;
    g_controller = msg0(msg0((id)cls, S("alloc")), S("init"));
    if (!g_controller) return;
    build_orb(host);
    build_panel(host);
    g_installed = 1;
    mgo_log("menu: installed (orb + panel)");
}

static void set_text_if_changed(id lbl, const char *utf8, char *cache, size_t cap) {
    if (strncmp(cache, utf8, cap) == 0) return;
    strncpy(cache, utf8, cap - 1);
    cache[cap - 1] = 0;
    msg1(lbl, S("setText:"), (void *)msg_string(utf8));
}

void mgo_menu_refresh(void) {
    if (!g_installed) return;

    int master = mgo_cfg_bool("dice", 1);
    if (master != g_last_master) {
        g_last_master = master;
        msg_setBool(g_orb, S("setHidden:"), master ? NO : YES);
        if (!master) {
            g_menu_visible = 0;
            msg_setBool(g_panel, S("setHidden:"), YES);
        }
        if (g_switch) msg_setBool(g_switch, S("setOn:"), master ? YES : NO);
    }
    if (!master) return;

    mgo_dice_snapshot_t s;
    mgo_dice_get_snapshot(&s);

    if (s.valid != g_last_valid) {
        g_last_valid = s.valid;
        if (!s.valid) {
            // No BoardState yet — neutral state everywhere.
            msg1(g_orb_num, S("setText:"), (void *)msg_string("\xE2\x80\x93"));  // –
            msg1(g_orb_num, S("setTextColor:"), (void *)msg_color_rgba(COL_SUB, 1.0));
            msg_setBool(g_dbl_chip, S("setHidden:"), YES);
            for (int i = 0; i < g_next_rows_n; i++)
                msg1(g_next_rows[i], S("setText:"), (void *)msg_string(""));
            msg1(g_info_lbl, S("setText:"), (void *)msg_string("waiting for board state…"));
            g_last_sum = g_last_d1 = g_last_d2 = g_last_dbl = -1;
            g_last_info[0] = 0;
            for (int i = 0; i < 5; i++) g_last_rows[i][0] = 0;
        }
    }
    if (!s.valid || s.n_rolls < 1) return;

    mgo_roll_t *r0 = &s.rolls[0];

    // Orb + sum chip: the glanceable number. Sum and doubles tracked
    // separately — a sum change with unchanged doubles still re-renders.
    if (r0->sum != g_last_sum || r0->doubles != g_last_dbl) {
        char buf[8];
        snprintf(buf, sizeof buf, "%d", r0->sum);
        msg1(g_orb_num, S("setText:"), (void *)msg_string(buf));
        id col = msg_color_rgba(r0->doubles ? COL_AMBER : COL_EMERALD, 1.0);
        msg1(g_orb_num, S("setTextColor:"), (void *)col);
        char buf2[16];
        snprintf(buf2, sizeof buf2, "= %d", r0->sum);
        msg1(g_sum_chip, S("setText:"), (void *)msg_string(buf2));
        g_last_sum = r0->sum;
    }

    // Panel hero dice.
    if (r0->d[0] != g_last_d1) {
        msg1(g_die1, S("setText:"), (void *)msg_string(die_glyph(r0->d[0])));
        g_last_d1 = r0->d[0];
    }
    if (r0->d[1] != g_last_d2) {
        msg1(g_die2, S("setText:"), (void *)msg_string(die_glyph(r0->d[1])));
        g_last_d2 = r0->d[1];
    }
    if (r0->doubles != g_last_dbl) {
        msg_setBool(g_dbl_chip, S("setHidden:"), r0->doubles ? NO : YES);
        g_last_dbl = r0->doubles;
    }

    // Upcoming rolls 2..peek.
    for (int i = 1; i < 6; i++) {
        char buf[24] = {0};
        if (i < s.n_rolls && i - 1 < g_next_rows_n) {
            mgo_roll_t *r = &s.rolls[i];
            int w = 0;
            for (int d = 0; d < r->n && d < 4; d++)
                w += snprintf(buf + w, sizeof buf - w, "%s ", die_glyph(r->d[d]));
            snprintf(buf + w, sizeof buf - w, "= %d%s", r->sum,
                     r->doubles ? " ·dbl" : "");
        }
        if (i - 1 < g_next_rows_n)
            set_text_if_changed(g_next_rows[i - 1], buf, g_last_rows[i - 1],
                                sizeof g_last_rows[i - 1]);
    }

    // Info line.
    char info[160];
    snprintf(info, sizeof info, "mult \xC3\x97%d · pos %d · draw %d/2000 · it %d",
             s.roll_mult, s.token_pos, s.rng_state, s.iter);
    set_text_if_changed(g_info_lbl, info, g_last_info, sizeof g_last_info);

    // Scripted row.
    char scr[120] = {0};
    if (s.scripted_present) {
        int w = snprintf(scr, sizeof scr, "scripted:");
        for (int i = 0; i < s.n_scripted && w < (int)sizeof scr - 6; i++)
            w += snprintf(scr + w, sizeof scr - w, " %d", s.scripted[i]);
    }
    if (strncmp(scr, g_last_scr, sizeof scr) != 0) {
        strncpy(g_last_scr, scr, sizeof g_last_scr - 1);
        msg_setBool(g_scr_lbl, S("setHidden:"), scr[0] ? NO : YES);
        msg1(g_scr_lbl, S("setText:"), (void *)msg_string(scr));
    }
}
