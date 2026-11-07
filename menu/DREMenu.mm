// DREMenu.dylib — custom cheat menu for DREDGE iOS (build 246)
// Injected via LC_LOAD_DYLIB into the DREDGE executable.
// Floating mini button -> cheat panel -> calls Terminal.Shell.RunCommand("...").
// Cheats are static patches baked at build time (see inject_menu.py).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>

#pragma mark - UnityFramework helpers

static uintptr_t g_ufBase = 0;

static uintptr_t uf_base(void) {
    if (g_ufBase) return g_ufBase;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework.framework/UnityFramework"))
            g_ufBase = (uintptr_t)_dyld_get_image_header(i);
    }
    return g_ufBase;
}

typedef void *(*il2cpp_str_new_t)(const char *);
static il2cpp_str_new_t d_str_new = NULL;

// CommandShell helpers (build 246 RVAs)
#define RVA_GET_SHELL   0x1216E70
#define RVA_RUN_COMMAND 0x1214D50
#define RVA_GET_COMMANDS 0x1215CD0

typedef void *(*shell_fn_t)(void *mi);
typedef void *(*getter_fn_t)(void *self, void *mi);
typedef void   (*run_fn_t)(void *self, void *line, void *mi);

static void *g_shell(void) {
    uintptr_t b = uf_base();
    if (!b) return NULL;
    void *r = NULL;
    try { r = ((shell_fn_t)(b + RVA_GET_SHELL))(NULL); } catch (...) { r = NULL; }
    return r;
}

static void run_cmd(const char *cmd) {
    if (!d_str_new) d_str_new = (il2cpp_str_new_t)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
    uintptr_t b = uf_base();
    void *shell = g_shell();
    if (!b || !shell || !d_str_new) return;
    void *s = NULL;
    try { s = d_str_new(cmd); } catch (...) { s = NULL; }
    if (!s) return;
    try { ((run_fn_t)(b + RVA_RUN_COMMAND))(shell, s, NULL); } catch (...) {}
}

#pragma mark - Toggle flags (data writes into UnityFramework __DATA zerofill)

// Runtime code patching is impossible under dev signing (Signulous): writing
// to a signed executable page needs dynamic-codesigning. So inject_menu.py
// patches GameManager.AddFunds / CalculateCatchRoll entries to `b <stub>` —
// stubs live in a __TEXT-tail code cave and read flag bytes from the dead
// bss page at uf_base+FLAG_RVA. Toggling = writing a byte — always legal.
#define FLAG_RVA 0x46DF528
static uint8_t *flag_base(void) {
    uintptr_t b = uf_base();
    return b ? (uint8_t *)(b + FLAG_RVA) : NULL;
}

// Two toggle mechanisms (v15):
//   TOG_FLAG — write a flag byte at flag_base()+off; the AddFunds/CatchRoll
//     trampolines read it (verified real callers).
//   TOG_CMD  — run the game's own terminal command (SetGodMode writes the real
//     Player field; the property getter we used to patch had zero callers).
typedef enum { TOG_FLAG, TOG_CMD } togkind;
typedef struct {
    const char *name;
    const char *icon;      // SF Symbol name
    togkind kind;
    uint32_t off;          // TOG_FLAG: flag byte offset
    const char *cmd;       // TOG_CMD: command name (1/0 arg if it takes one)
} tog_t;
static const tog_t g_togs[] = {
    {"God Mode",       "shield.fill",                     TOG_CMD,  0, "SetGodMode"},
    {"Immune (Equip)", "checkmark.shield.fill",           TOG_CMD,  0, "SetImmuneMode"},
    {"Sell Value",     "dollarsign.circle.fill",          TOG_FLAG, 0, NULL},
    {"Pot Auto-Catch", "fish.fill",                       TOG_FLAG, 1, NULL},
    {"No Overheat",    "flame.fill",                      TOG_FLAG, 2, NULL},
    {"Fish Quality",   "sparkles",                        TOG_FLAG, 3, NULL},
    {"Free Upgrades",  "wrench.and.screwdriver.fill",     TOG_FLAG, 8, NULL},
    {"Free Research",  "book.fill",                       TOG_FLAG, 9, NULL},
};
#define NTOGS 8
static BOOL g_state[NTOGS] = {NO, NO, YES, YES, YES, YES, YES, YES};  // flags on; god/immune session-only
static BOOL g_flags_init = NO;
static float g_sell_mult = 4.0f;

static void flag_apply(int i) {
    uint8_t *f = flag_base();
    if (!f || g_togs[i].kind != TOG_FLAG) return;
    f[g_togs[i].off] = g_state[i] ? 1 : 0;
    if (i == 2) *(float *)(f + 4) = g_sell_mult;   // sell multiplier float
}
static void flags_write(void) { for (int i = 0; i < NTOGS; i++) flag_apply(i); }

// Only the flag toggles persist — god/immune game state resets each session.
static void state_persist(void) {
    [[NSUserDefaults standardUserDefaults] setObject:@[@(g_state[2]), @(g_state[3]), @(g_state[4]), @(g_state[5]), @(g_state[6]), @(g_state[7])]
        forKey:@"dre_toggles"];
    [[NSUserDefaults standardUserDefaults] setFloat:g_sell_mult forKey:@"dre_sellmult"];
}
static void state_restore(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *a = [d objectForKey:@"dre_toggles"];
    // apply as many as were saved — older builds persisted fewer toggles
    for (NSUInteger i = 0; i < a.count && i < NTOGS - 2; i++)
        g_state[i + 2] = [a[i] boolValue];
    if ([d objectForKey:@"dre_sellmult"]) g_sell_mult = [d floatForKey:@"dre_sellmult"];
    if (g_sell_mult <= 0) g_sell_mult = 4.0f;
}

#pragma mark - Command dictionary enumeration

// Terminal.Shell.Commands -> Dictionary<string,CommandInfo>
// il2cpp object: [0]=klass [8]=monitor, fields at +0x10
// Dictionary .NET Core layout: _buckets@+0x10, _entries@+0x18
// Entry<string,obj>: {i32 hash, i32 next, key@8, value@16} = 24B
// szarray: hdr16 + bounds8 + len@0x18(8) -> data @0x20
// Il2CppString: hdr16 + len@0x10(i32) + chars utf16 @0x14
// plausible managed-heap pointer: non-null, 8-aligned, in userland range
static inline BOOL ok_ptr(uintptr_t p) {
    return p > 0x10000 && (p & 7) == 0 && (p >> 40) == 0;
}

// Entries -> [{name, min, max, help}] — CommandInfo is a 24B VALUE struct stored
// inline, so Dictionary<string,CommandInfo>.Entry stride = 40 bytes:
//   hashCode@0(i32) next@4(i32) key@8(str*) | value: proc@16 max@24(i32) min@28(i32) help@32(str*)
static NSString *read_il2cpp_string(uintptr_t sp) {
    if (!ok_ptr(sp) || !ok_ptr(*(uintptr_t *)sp)) return nil;
    int32_t slen = *(int32_t *)(sp + 0x10);
    if (slen <= 0 || slen > 256) return nil;
    return [[NSString alloc] initWithCharacters:(const unichar *)(sp + 0x14) length:slen];
}
static NSArray<NSDictionary *> *enum_commands(void) {
    uintptr_t b = uf_base();
    void *shell = g_shell();
    if (!b || !shell) return nil;
    void *dict = NULL;
    try { dict = ((getter_fn_t)(b + RVA_GET_COMMANDS))(shell, NULL); } catch (...) { dict = NULL; }
    if (!ok_ptr((uintptr_t)dict)) return nil;

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    static const int cand[] = {0x18, 0x20, 0x10};
    uintptr_t dictp = (uintptr_t)dict;
    for (int ci = 0; ci < 3 && !out.count; ci++) {
        uintptr_t arr = *(uintptr_t *)(dictp + cand[ci]);
        if (!ok_ptr(arr)) continue;
        // array header: klass@0 must be a plausible pointer; max_length@0x18
        if (!ok_ptr(*(uintptr_t *)arr)) continue;
        int32_t cnt = (int32_t)*(int64_t *)(arr + 0x18);
        if (cnt <= 0 || cnt > 512) continue;
        for (int i = 0; i < cnt; i++) {
            uintptr_t ent = arr + 0x20 + (uintptr_t)i * 40;
            int32_t hash = *(int32_t *)ent;
            uintptr_t key = *(uintptr_t *)(ent + 8);
            if (hash < 0 || !ok_ptr(key)) continue;      // empty/deleted slot
            if (!ok_ptr(*(uintptr_t *)key)) continue;    // key->klass sane?
            int32_t slen = *(int32_t *)(key + 0x10);
            if (slen <= 0 || slen > 64) continue;
            NSString *s = [[NSString alloc] initWithCharacters:(const unichar *)(key + 0x14) length:slen];
            if (!s) continue;
            NSString *help = read_il2cpp_string(*(uintptr_t *)(ent + 32));
            NSMutableDictionary *cd = [@{@"name": s,
                @"max": @(*(int32_t *)(ent + 24)),
                @"min": @(*(int32_t *)(ent + 28))} mutableCopy];
            if (help.length) cd[@"help"] = help;
            [out addObject:cd];
        }
    }
    return out.count ? out : nil;
}

// NOTE: Toggles either write flag bytes the cave stubs read (sell/pot) or
// fire the game's own terminal commands (god/immune) — zero runtime code
// writes either way. "Active Patches" are always-on static bakes.

#pragma mark - UI

static UIWindow *g_handleWin = nil;
static UIWindow *g_panelWin = nil;
static NSArray<NSDictionary *> *g_cmds = nil;

// Design tokens — iOS semantic palette, fixed dark (HUD over a bright game).
#define DRE_GREEN   [UIColor colorWithRed:48/255.0 green:209/255.0 blue:88/255.0 alpha:1]   // systemGreen dark
#define DRE_RED     [UIColor colorWithRed:255/255.0 green:69/255.0 blue:58/255.0 alpha:1]    // systemRed dark
#define DRE_BLUE    [UIColor colorWithRed:10/255.0 green:132/255.0 blue:255/255.0 alpha:1]   // systemBlue
#define DRE_FILL    [UIColor colorWithWhite:1 alpha:0.08]                                   // tertiary fill
#define DRE_FILL_HI [UIColor colorWithWhite:1 alpha:0.16]                                   // pressed fill
#define DRE_TEXT    [UIColor colorWithWhite:1 alpha:0.92]
#define DRE_SUB     [UIColor colorWithWhite:1 alpha:0.5]
#define DRE_HAIR    [UIColor colorWithWhite:1 alpha:0.14]
#define DRE_RADIUS  12.0

static UIImage *dre_symbol(NSString *name, CGFloat pt, UIImageSymbolWeight w) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:w];
    return [UIImage systemImageNamed:name withConfiguration:c];
}
static BOOL dre_reduceMotion(void) { return UIAccessibilityIsReduceMotionEnabled(); }

// Instant touch-down feedback — press is the response, release is the
// commit. setHighlighted fires on the *down* event so every chip scales
// the moment it's touched, then springs back on release.
@interface DREButton : UIButton
@end
@implementation DREButton
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    if (dre_reduceMotion()) { self.transform = CGAffineTransformIdentity; return; }
    if (h) {
        [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut
            animations:^{ self.transform = CGAffineTransformMakeScale(0.96, 0.96); } completion:nil];
    } else {
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.62
            initialSpringVelocity:0.6 options:0
            animations:^{ self.transform = CGAffineTransformIdentity; } completion:nil];
    }
}
@end

// Haptics — fired on the causal event (the toggle commit, the snap home).
// Lazily created on the main thread; .prepare() keeps latency ~0.
static UIImpactFeedbackGenerator *g_impact = nil;
static void dre_tick(void) {
    if (!g_impact) { g_impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [g_impact prepare]; }
    [g_impact impactOccurred];
}
static UINotificationFeedbackGenerator *g_notify = nil;
static void dre_notify(UINotificationFeedbackType t) {
    if (!g_notify) { g_notify = [UINotificationFeedbackGenerator new]; [g_notify prepare]; }
    [g_notify notificationOccurred:t];
}


// Anchor a window-filling view's layer to a SCREEN point (the dot), so scale
// animations grow/shrink toward it. layer.position is in the PARENT layer's
// coordinate space = window-local, NOT screen coords — feeding screen coords
// here shifts the visible content by the window's own origin while the
// hit-test area stays put (looks fine, touches land on nothing).
static void anchor_view_to_point(UIView *v, CGPoint screenPt, CGRect winFrame) {
    CGFloat ax = MIN(MAX((screenPt.x - winFrame.origin.x) / winFrame.size.width, 0), 1);
    CGFloat ay = MIN(MAX((screenPt.y - winFrame.origin.y) / winFrame.size.height, 0), 1);
    v.layer.anchorPoint = CGPointMake(ax, ay);
    v.layer.position = CGPointMake(ax * v.bounds.size.width,
                                   ay * v.bounds.size.height);
}
static void anchor_view_reset(UIView *v) {
    v.layer.anchorPoint = CGPointMake(0.5, 0.5);
    v.layer.position = CGPointMake(v.bounds.size.width / 2,
                                   v.bounds.size.height / 2);
}

@interface DREPanel : UIViewController <UITextFieldDelegate, UIDocumentPickerDelegate>
@property (nonatomic, weak) UIWindow *win;
@end

@implementation DREPanel {
    UIScrollView *_scroll;
    UITextField *_search;
    UILabel *_sub;           // "N active" subtitle
    UIVisualEffectView *_bg;
    BOOL _showAll;           // See All disclosure on the command list
    CGFloat _lastW;          // rebuild chip layout when scroll width changes
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    // Drop shadow lives on the unmasked root view (the blur child clips).
    self.view.layer.shadowColor = UIColor.blackColor.CGColor;
    self.view.layer.shadowOpacity = 0.45;
    self.view.layer.shadowRadius = 22;
    self.view.layer.shadowOffset = CGSizeMake(0, 10);

    // Material surface — translucent layer so it reads as floating chrome.
    _bg = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _bg.frame = self.view.bounds;
    _bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _bg.layer.cornerRadius = 20;
    _bg.layer.cornerCurve = kCACornerCurveContinuous;
    _bg.layer.masksToBounds = YES;
    _bg.layer.borderWidth = 0.5;
    _bg.layer.borderColor = DRE_HAIR.CGColor;
    [self.view addSubview:_bg];

    UIView *content = _bg.contentView;
    CGFloat w = self.view.bounds.size.width;

    // Header — title + live active count + iOS-style circled close.
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 220, 20)];
    title.text = @"DREDGE";
    title.textColor = DRE_TEXT;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [content addSubview:title];

    _sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 31, 220, 14)];
    _sub.textColor = DRE_SUB;
    _sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [content addSubview:_sub];

    DREButton *close = [DREButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(w - 44, 10, 30, 30);
    close.backgroundColor = DRE_FILL;
    close.layer.cornerRadius = 15;
    close.layer.cornerCurve = kCACornerCurveContinuous;
    [close setImage:dre_symbol(@"xmark", 12, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    close.tintColor = DRE_SUB;
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [content addSubview:close];

    // Pinned filter — filters the command list live.
    UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(12, 52, w - 24, 34)];
    sw.backgroundColor = DRE_FILL;
    sw.layer.cornerRadius = 10;
    sw.layer.cornerCurve = kCACornerCurveContinuous;
    sw.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIImageView *mag = [[UIImageView alloc] initWithImage:dre_symbol(@"magnifyingglass", 13, UIImageSymbolWeightMedium)];
    mag.tintColor = DRE_SUB;
    mag.frame = CGRectMake(10, 10, 14, 14);
    [sw addSubview:mag];
    _search = [[UITextField alloc] initWithFrame:CGRectMake(32, 0, w - 24 - 44, 34)];
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _search.placeholder = @"Filter commands";
    _search.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Filter commands"
        attributes:@{NSForegroundColorAttributeName: DRE_SUB, NSFontAttributeName: [UIFont systemFontOfSize:13]}];
    _search.textColor = DRE_TEXT;
    _search.font = [UIFont systemFontOfSize:13];
    _search.clearButtonMode = UITextFieldViewModeWhileEditing;
    _search.returnKeyType = UIReturnKeyDone;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _search.delegate = self;
    [_search addTarget:self action:@selector(buildButtons) forControlEvents:UIControlEventEditingChanged];
    [sw addSubview:_search];
    [content addSubview:sw];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 94, w - 24, self.view.bounds.size.height - 106)];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [content addSubview:_scroll];
    [self buildButtons];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Explicit path so the shadow renders even though the root view is clear.
    self.view.layer.shadowPath = [UIBezierPath
        bezierPathWithRoundedRect:self.view.bounds cornerRadius:20].CGPath;
    // Chips are laid out manually — rebuild when the scroll width settles or
    // changes (first layout may differ from viewDidLoad's default bounds,
    // and rotation resizes the panel).
    CGFloat w = _scroll.bounds.size.width;
    if (w > 0 && fabs(w - _lastW) > 0.5) { _lastW = w; [self buildButtons]; }
}

- (void)buildButtons {
    CGPoint off = _scroll.contentOffset;   // rebuilds clear the scroll — keep position
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0) w = self.view.bounds.size.width - 24;
    CGFloat y = 4;
    CGFloat bw = (w - 10) / 2;

    // Live active count in the header.
    int on = 0; for (int i = 0; i < NTOGS; i++) on += g_state[i];
    _sub.text = [NSString stringWithFormat:@"%d of %d cheats active", on, NTOGS];

    // Real toggles — flag writes into the bss slot the patched stubs read.
    y = [self section:@"Cheats" icon:@"slider.horizontal.3" y:y];
    {
        int col = 0; CGFloat x = 0;
        for (int i = 0; i < NTOGS; i++) {
            DREButton *b = [DREButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(x, y, bw, 40);
            b.layer.cornerRadius = DRE_RADIUS;
            b.layer.cornerCurve = kCACornerCurveContinuous;
            b.tag = 3000 + i;
            [self paintTog:b];
            [b addTarget:self action:@selector(toggleBtn:) forControlEvents:UIControlEventTouchUpInside];
            [_scroll addSubview:b];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 46;
        }
        // Sell multiplier input on its own row under the toggle grid
        if (col) y += 46;   // odd toggle count — finish the partial row first
        DREButton *mb = [DREButton buttonWithType:UIButtonTypeCustom];
        mb.frame = CGRectMake(0, y, bw, 40);
        mb.layer.cornerRadius = DRE_RADIUS;
        mb.layer.cornerCurve = kCACornerCurveContinuous;
        [self paintMult:mb];
        [mb addTarget:self action:@selector(sellMultBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:mb];
        y += 46;
        y += 6;
    }

    if (!g_cmds) g_cmds = enum_commands();   // cached; invalidated on panel open
    NSArray<NSDictionary *> *cmds = g_cmds;
    NSString *q = _search.text.lowercaseString;
    NSArray<NSDictionary *> *visible = q.length
        ? [cmds filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *d, id b) {
            return [((NSString *)d[@"name"]).lowercaseString containsString:q];
        }]] : cmds;
    if (visible.count) {
        // Curated favorites are the default view; everything else hides
        // behind a "See All" disclosure in the section header.
        NSArray *fav = @[@"SetGodMode", @"godmode", @"SetImmuneMode", @"ToggleIcebreaker",
                         @"SetSanity", @"SetMaxSpeed", @"SetPlayerBaseMoveSpeed", @"SetPlayerBaseTurnSpeed",
                         @"TeleportPlayerToHarvestSpot", @"RestockHarvestSpot", @"DepleteHarvestSpots",
                         @"DebugAddItem", @"DebugAddItemInventory", @"DebugAddItemNet",
                         @"DebugAddItemStorage", @"DebugAddItemOverflowStorage", @"DebugAddAllCabinItems",
                         @"DebugUnlockAbility", @"DebugSetGameAsPurchased", @"SetAllDLC",
                         @"ListDestinations", @"UnlockDestination", @"Die"];
        int col = 0; CGFloat x = 0;
        if (!q.length) {
            CGFloat hy = y;
            y = [self section:@"Commands" icon:@"terminal.fill" y:y];
            if (!_showAll)
                [self textBtn:[NSString stringWithFormat:@"See All (%d)", (int)cmds.count]
                         atY:hy sel:@selector(toggleAll:) w:w];
            for (NSString *n in fav) {
                NSDictionary *c = [self cmdNamed:n in:visible];
                if (!c) continue;
                [self cmdBtn:c x:x y:y w:bw];
                col = (col + 1) % 2; x = col ? bw + 10 : 0;
                if (!col) y += 46;
            }
            if (col) y += 46;
            if (_showAll) {
                CGFloat ay = y;
                y = [self section:@"All Commands" icon:@"list.bullet" y:y];
                [self textBtn:@"Show Less" atY:ay sel:@selector(toggleAll:) w:w];
                col = 0; x = 0;
                for (NSDictionary *c in visible) {
                    if ([fav containsObject:c[@"name"]]) continue;
                    [self cmdBtn:c x:x y:y w:bw];
                    col = (col + 1) % 2; x = col ? bw + 10 : 0;
                    if (!col) y += 46;
                }
                if (col) y += 46;
            }
        } else {
            // filtering — flat result list, favorites split is skipped
            y = [self section:@"Commands" icon:@"terminal.fill" y:y];
            for (NSDictionary *c in visible) {
                [self cmdBtn:c x:x y:y w:bw];
                col = (col + 1) % 2; x = col ? bw + 10 : 0;
                if (!col) y += 46;
            }
            if (col) y += 46;
        }
    } else if (!cmds.count) {
        // fallback: static guesses if enumeration fails
        y = [self section:@"Commands (guess)" y:y];
        NSArray *guess = @[@"godmode", @"setgodmode", @"immune", @"icebreaker",
                           @"setsanity 0", @"sanity 0", @"help", @"clear"];
        int col = 0; CGFloat x = 0;
        for (NSString *n in guess) {
            [self cmdBtn:@{@"name": n, @"min": @0, @"max": @0} x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 46;
        }
        if (col) y += 46;
    } else {
        y = [self section:@"No matches" icon:@"magnifyingglass" y:y];
        y += 6;
    }

    y = [self section:@"Save" icon:@"internaldrive" y:y];
    {   // Export / Import — share-sheet out, document-picker in.
        [self chip:@"  Export" icon:@"square.and.arrow.up"
                 x:0 y:y w:bw sel:@selector(exportSave:)];
        [self chip:@"  Import" icon:@"square.and.arrow.down"
                 x:bw + 10 y:y w:bw sel:@selector(importSave:)];
        y += 46;
        // Bundled restore — the known-good save shipped inside the IPA.
        DREButton *rb = [self chip:@"  Restore bundled save" icon:@"arrow.down.doc.fill"
                                 x:0 y:y w:bw sel:@selector(restoreSave)];
        rb.backgroundColor = [UIColor colorWithRed:0.5 green:0.3 blue:0.1 alpha:0.9];
        y += 46;
    }

    _scroll.contentSize = CGSizeMake(w, y + 20);
    _scroll.contentOffset = off;   // clamps itself if the content shrank
}

- (CGFloat)section:(NSString *)t icon:(NSString *)icon y:(CGFloat)y {
    UIImageView *iv = [[UIImageView alloc] initWithImage:dre_symbol(icon, 10, UIImageSymbolWeightSemibold)];
    iv.tintColor = DRE_SUB;
    iv.frame = CGRectMake(2, y + 5, 12, 12);
    [_scroll addSubview:iv];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(18, y, _scroll.bounds.size.width - 18, 22)];
    l.attributedText = [[NSAttributedString alloc] initWithString:t.uppercaseString
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold],
                     NSForegroundColorAttributeName: DRE_SUB,
                     NSKernAttributeName: @0.9}];
    [_scroll addSubview:l];
    return y + 26;
}
- (CGFloat)section:(NSString *)t y:(CGFloat)y { return [self section:t icon:@"folder.fill" y:y]; }

// Standard left-aligned icon chip — toggle/save/command buttons all share this.
- (DREButton *)chip:(NSString *)title icon:(NSString *)icon
                  x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w sel:(SEL)sel {
    DREButton *b = [DREButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, 40);
    b.backgroundColor = DRE_FILL;
    b.layer.cornerRadius = DRE_RADIUS;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b setImage:dre_symbol(icon, 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    b.tintColor = DRE_TEXT;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    return b;
}

// Right-aligned blue text button that sits inside a section header
// (the App Store "See All" pattern).
- (void)textBtn:(NSString *)t atY:(CGFloat)hy sel:(SEL)s w:(CGFloat)w {
    DREButton *b = [DREButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(w - 120, hy - 2, 118, 26);
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitleColor:DRE_BLUE forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
}
- (void)toggleAll:(UIButton *)b { dre_tick(); _showAll = !_showAll; [self buildButtons]; }

static BOOL destructive_cmd(NSString *cmd);   // fwd — defined below

- (NSDictionary *)cmdNamed:(NSString *)n in:(NSArray<NSDictionary *> *)cmds {
    for (NSDictionary *c in cmds)
        if ([c[@"name"] isEqualToString:n]) return c;
    return nil;
}

- (void)cmdBtn:(NSDictionary *)c x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    DREButton *b = [DREButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, 40);
    BOOL destructive = destructive_cmd(c[@"name"]);
    b.backgroundColor = destructive
        ? [DRE_RED colorWithAlphaComponent:0.18] : DRE_FILL;
    b.layer.cornerRadius = DRE_RADIUS;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    if (destructive) { b.layer.borderWidth = 0.5; b.layer.borderColor = [DRE_RED colorWithAlphaComponent:0.5].CGColor; }
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    b.titleLabel.numberOfLines = 2;
    [b setTitle:c[@"name"] forState:UIControlStateNormal];
    [b setTitleColor:destructive ? DRE_RED : DRE_TEXT forState:UIControlStateNormal];
    b.tag = 2000;
    b.accessibilityIdentifier = [NSString stringWithFormat:@"%@|%@|%@|%@",
        c[@"name"], c[@"min"], c[@"max"], c[@"help"] ?: @""];
    [b addTarget:self action:@selector(runCmdBtn:) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
}

- (void)paintTog:(UIButton *)b {
    int i = (int)b.tag - 3000;
    BOOL on = g_state[i];
    b.backgroundColor = on ? [DRE_GREEN colorWithAlphaComponent:0.22] : DRE_FILL;
    b.layer.borderWidth = on ? 0.5 : 0;
    b.layer.borderColor = on ? [DRE_GREEN colorWithAlphaComponent:0.55].CGColor : nil;

    // icon + name on the left, state word on the right — reads as a control,
    // not a label.
    UIImage *img = dre_symbol(@(g_togs[i].icon), 13, UIImageSymbolWeightMedium);
    [b setImage:img forState:UIControlStateNormal];
    b.tintColor = on ? DRE_GREEN : DRE_SUB;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    [b setTitle:[NSString stringWithFormat:@" %s", g_togs[i].name] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitleColor:on ? DRE_TEXT : [UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 36);   // stay clear of the ON/OFF chip
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // trailing state chip — tiny label pinned to the button's right edge
    [[b viewWithTag:77] removeFromSuperview];
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(b.bounds.size.width - 40, 0, 34, 40)];
    st.text = on ? @"ON" : @"OFF";
    st.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    st.textColor = on ? DRE_GREEN : DRE_SUB;
    st.textAlignment = NSTextAlignmentRight;
    st.tag = 77;
    [b addSubview:st];
}

- (void)toggleBtn:(UIButton *)b {
    int i = (int)b.tag - 3000;
    const tog_t *t = &g_togs[i];
    dre_tick();
    if (t->kind == TOG_CMD) {
        // Look up the command's arg contract: if it takes an arg send 1/0,
        // else fire it bare (it's a flip-flop internally). Bool parses 1/0.
        if (!g_cmds) g_cmds = enum_commands();
        NSDictionary *c = [self cmdNamed:@(t->cmd) in:g_cmds];
        NSString *line = @(t->cmd);
        BOOL want = !g_state[i];
        if (c && [c[@"max"] intValue] > 0)
            line = [NSString stringWithFormat:@"%s %d", t->cmd, want ? 1 : 0];
        run_cmd(line.UTF8String);
    }
    g_state[i] = !g_state[i];
    flag_apply(i);
    state_persist();
    [UIView transitionWithView:b duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ [self paintTog:b]; } completion:nil];
    _sub.text = [NSString stringWithFormat:@"%d of %d cheats active",
        ({ int n = 0; for (int k = 0; k < NTOGS; k++) n += g_state[k]; n; }), NTOGS];
    [self toast:[NSString stringWithFormat:@"%s %@", g_togs[i].name, g_state[i] ? @"ON" : @"OFF"]];
}

- (void)paintMult:(UIButton *)b {
    b.backgroundColor = DRE_FILL;
    [b setImage:dre_symbol(@"multiply", 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    b.tintColor = DRE_SUB;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    [b setTitle:[NSString stringWithFormat:@" Sell ×%.1f", g_sell_mult] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
}

- (void)sellMultBtn:(UIButton *)b {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Sell Multiplier"
        message:@"Multiplier applied to sell prices" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.1f", g_sell_mult];
    }];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(id act) {
        float v = wa.textFields.firstObject.text.floatValue;
        if (v > 0) {
            g_sell_mult = v;
            flag_apply(2);
            state_persist();
            [self paintMult:b];
            [self toast:[NSString stringWithFormat:@"Sell ×%.1f", g_sell_mult]];
        } else { dre_notify(UINotificationFeedbackTypeError);
            [self toast:@"Enter a positive number" icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// Commands that do irreversible things get a confirm first (forgiveness
// over friction — but not zero-friction for destructive actions).
static BOOL destructive_cmd(NSString *cmd) {
    static NSSet *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSSet setWithArray:@[@"Die", @"DepleteHarvestSpots"]]; });
    return [d containsObject:cmd];
}

- (void)runCmdBtn:(UIButton *)b {
    NSArray *parts = [b.accessibilityIdentifier componentsSeparatedByString:@"|"];
    NSString *cmd = parts.firstObject;
    int minArg = parts.count > 1 ? [parts[1] intValue] : 0;
    int maxArg = parts.count > 2 ? [parts[2] intValue] : 0;
    NSString *help = parts.count > 3 ? parts[3] : nil;

    void (^exec)(void) = ^{
        if (maxArg == 0 && minArg == 0) {
            run_cmd(cmd.UTF8String);
            [self toast:[NSString stringWithFormat:@"%@ ✓", cmd]];
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:cmd
            message:(help.length ? help : (minArg > 0 ? @"Arguments (required):" : @"Optional arguments:"))
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:nil];
        __weak UIAlertController *wa = a;
        [a addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDefault handler:^(id act) {
            NSString *arg = wa.textFields.firstObject.text;
            NSString *full = arg.length ? [NSString stringWithFormat:@"%@ %@", cmd, arg] : cmd;
            run_cmd(full.UTF8String);
            [self toast:[NSString stringWithFormat:@"%@ ✓", full]];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    };

    if (destructive_cmd(cmd)) {
        UIAlertController *c2 = [UIAlertController alertControllerWithTitle:cmd
            message:@"This can't be undone. Run anyway?" preferredStyle:UIAlertControllerStyleAlert];
        [c2 addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDestructive handler:^(id a){ exec(); }]];
        [c2 addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:c2 animated:YES completion:nil];
        return;
    }
    exec();
}

// Scan Documents + Library for dredge-save*.bin — saves may live in
// Documents, Application Support, or a subdir we haven't seen.
- (NSArray<NSString *> *)savePaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *base in @[@"Documents", @"Library"]) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:[home stringByAppendingPathComponent:base]];
        NSString *rel;
        while ((rel = [en nextObject])) {
            NSString *lc = rel.lastPathComponent.lowercaseString;
            if ([lc hasPrefix:@"dredge-save"] && [lc hasSuffix:@".bin"])
                [hits addObject:[base stringByAppendingPathComponent:rel]];
        }
    }
    return hits;
}
// Where imports/restores write slot 0: next to the game's own save if one
// exists, else Documents.
- (NSString *)saveDestDir {
    NSArray<NSString *> *hits = [self savePaths];
    if (hits.count)
        return [[NSHomeDirectory() stringByAppendingPathComponent:hits.firstObject]
                stringByDeletingLastPathComponent];
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}
// The live save to export — prefer slot 0, else whatever exists.
- (NSString *)currentSavePath {
    NSArray<NSString *> *hits = [self savePaths];
    for (NSString *h in hits)
        if ([h.lastPathComponent isEqualToString:@"dredge-save0.bin"])
            return [NSHomeDirectory() stringByAppendingPathComponent:h];
    return hits.count ? [NSHomeDirectory() stringByAppendingPathComponent:hits.firstObject] : nil;
}

- (void)exportSave:(UIView *)src {
    NSString *p = [self currentSavePath];
    if (!p) { dre_notify(UINotificationFeedbackTypeError);
        [self toast:@"No save file found" icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; return; }
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:p]] applicationActivities:nil];
    av.popoverPresentationController.sourceView = src;   // ignored on iPhone, required on iPad
    [self presentViewController:av animated:YES completion:nil];
}

- (void)importSave:(UIView *)src {
    // asCopy:YES lands the pick in our temp container — no security-scope
    // dance needed, and non-.bin files are still selectable so we name-check
    // in the confirm instead.
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData, UTTypeItem] asCopy:YES];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSString *dst = [[self saveDestDir] stringByAppendingPathComponent:@"dredge-save0.bin"];
    BOOL isBin = [u.pathExtension.lowercaseString isEqualToString:@"bin"];
    NSString *msg = [NSString stringWithFormat:@"%@Replace save slot 0 with:\n%@?",
        isBin ? @"" : @"Not a .bin file — it may not load.\n\n", u.lastPathComponent];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Import save?"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive
        handler:^(id act){
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *tmp = [dst stringByAppendingString:@".tmp"];
            NSError *err = nil;
            [fm removeItemAtPath:tmp error:nil];
            BOOL ok = [fm copyItemAtURL:u toURL:[NSURL fileURLWithPath:tmp] error:&err];
            if (ok) { [fm removeItemAtPath:dst error:nil]; ok = [fm moveItemAtPath:tmp toPath:dst error:&err]; }
            if (ok) { dre_notify(UINotificationFeedbackTypeSuccess);
                [self toast:@"Save imported — restart the game"]; }
            else { dre_notify(UINotificationFeedbackTypeError);
                [self toast:[NSString stringWithFormat:@"Failed: %@", err.localizedDescription]
                       icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; }
        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)restoreSave {
    NSString *src = [[NSBundle mainBundle] pathForResource:@"dredge-save0" ofType:@"bin"];
    if (!src) { dre_notify(UINotificationFeedbackTypeError);
        [self toast:@"Bundled save not found" icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; return; }

    NSArray<NSString *> *hits = [self savePaths];
    NSString *dst = [[self saveDestDir] stringByAppendingPathComponent:@"dredge-save0.bin"];
    NSString *foundMsg = hits.count
        ? [NSString stringWithFormat:@"Found %d existing save(s).\nWriting next to:\n%@",
           (int)hits.count, hits.firstObject.stringByDeletingLastPathComponent]
        : @"No existing save found — writing to Documents root.\n\nThe game may use a different folder; if the save doesn't load, tell me where the game stores saves.";

    UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Restore save?"
        message:foundMsg preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive
        handler:^(id a){
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *tmp = [dst stringByAppendingString:@".tmp"];
            NSError *err = nil;
            [fm removeItemAtPath:tmp error:nil];
            BOOL ok = [fm copyItemAtPath:src toPath:tmp error:&err];
            if (ok) { [fm removeItemAtPath:dst error:nil]; ok = [fm moveItemAtPath:tmp toPath:dst error:&err]; }
            if (ok) [self toast:@"Save restored — restart the game"];
            else { dre_notify(UINotificationFeedbackTypeError);
                [self toast:[NSString stringWithFormat:@"Failed: %@", err.localizedDescription]
                       icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; }
        }]];
    [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:c animated:YES completion:nil];
}

// Transient toast — pill with SF icon, slides up with a spring and fades
// out. Interruptible: a new toast replaces the old mid-flight.
- (void)toast:(NSString *)msg { [self toast:msg icon:@"checkmark.circle.fill" tint:DRE_GREEN]; }
- (void)toast:(NSString *)msg icon:(NSString *)icon tint:(UIColor *)tint {
    static UIView *cur = nil;
    if (cur) { [cur.layer removeAllAnimations]; [cur removeFromSuperview]; }
    UIView *host = self.win.rootViewController.view;
    if (!host) return;

    UIView *pill = [[UIView alloc] init];
    pill.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    pill.layer.cornerRadius = 18;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.borderWidth = 0.5;
    pill.layer.borderColor = DRE_HAIR.CGColor;
    pill.layer.shadowColor = UIColor.blackColor.CGColor;
    pill.layer.shadowOpacity = 0.3;
    pill.layer.shadowRadius = 10;
    pill.layer.shadowOffset = CGSizeMake(0, 4);

    UIImageView *iv = [[UIImageView alloc] initWithImage:dre_symbol(icon, 14, UIImageSymbolWeightSemibold)];
    iv.tintColor = tint;
    iv.frame = CGRectMake(12, 9, 18, 18);
    [pill addSubview:iv];

    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    l.textColor = DRE_TEXT;
    l.numberOfLines = 0;
    CGFloat maxTW = MIN(host.bounds.size.width - 100, 280);
    CGSize fit = [l sizeThatFits:CGSizeMake(maxTW, CGFLOAT_MAX)];
    CGFloat tw = fit.width + 50;
    l.frame = CGRectMake(38, 0, fit.width + 6, 36);
    [pill addSubview:l];

    pill.frame = CGRectMake((host.bounds.size.width - tw) / 2,
                          host.bounds.size.height - 52, tw, 36);
    [host addSubview:pill];
    cur = pill;

    if (dre_reduceMotion()) {
        pill.alpha = 0;
        [UIView animateWithDuration:0.15 animations:^{ pill.alpha = 1; }];
    } else {
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, 14);
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.82
            initialSpringVelocity:0 options:0
            animations:^{ pill.alpha = 1; pill.transform = CGAffineTransformIdentity; } completion:nil];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (cur != pill) return;
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn
            animations:^{ pill.alpha = 0; pill.transform = CGAffineTransformMakeTranslation(0, 6); }
            completion:^(BOOL d){ [pill removeFromSuperview]; }];
    });
}

- (void)hidePanel {
    [self.view endEditing:YES];   // drop the keyboard if the filter is focused
    CGPoint dot = g_handleWin ? CGPointMake(CGRectGetMidX(g_handleWin.frame),
                                            CGRectGetMidY(g_handleWin.frame)) : self.view.center;
    if (dre_reduceMotion()) {
        [UIView animateWithDuration:0.18 animations:^{ self.view.alpha = 0; }
            completion:^(BOOL d){ self.win.hidden = YES; self.view.alpha = 1; }];
        return;
    }
    // Symmetric exit — shrink+fade back toward the handle (spatial consistency).
    anchor_view_to_point(self.view, dot, self.win.frame);
    [UIView animateWithDuration:0.26 delay:0
        usingSpringWithDamping:1.0 initialSpringVelocity:0 options:0
        animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
            self.view.alpha = 0;
        } completion:^(BOOL d){
            self.win.hidden = YES;
            self.view.transform = CGAffineTransformIdentity;
            self.view.alpha = 1;
            anchor_view_reset(self.view);
        }];
}
@end

#pragma mark - Floating handle

@interface DREGestureHost : NSObject
- (void)tap;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static UIWindowScene *find_scene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    UIWindowScene *fallback = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
        if (s.activationState != UISceneActivationStateUnattached)
            fallback = (UIWindowScene *)s;
    }
    return fallback;
}

static UIWindow *new_window(CGRect f, UIWindowLevel lvl) {
    UIWindow *w = [[UIWindow alloc] initWithFrame:f];
    w.windowScene = find_scene();
    w.windowLevel = lvl;
    w.backgroundColor = UIColor.clearColor;
    return w;
}

// Idle-fade the handle after N sec of no interaction (visibility vs obstruction).
static void schedule_fade(void);
static void wake_dot(void);
static UIView *g_dot = nil;
static int g_fadeGen = 0;

@implementation DREGestureHost
- (void)tap {
    dispatch_async(dispatch_get_main_queue(), ^{
        wake_dot();
        // Refit to the current screen every open — creation once, but the
        // frame must survive rotation while the panel was hidden.
        CGRect sb = g_handleWin.windowScene.screen.bounds;
        if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
        CGFloat pw = MIN(340, sb.size.width - 32);
        CGFloat ph = MIN(420, sb.size.height - 32);
        CGRect pf = CGRectMake((sb.size.width - pw) / 2,
                               (sb.size.height - ph) / 2, pw, ph);
        if (!g_panelWin) {
            g_panelWin = new_window(pf, UIWindowLevelAlert + 2);
            DREPanel *vc = [DREPanel new];
            vc.win = g_panelWin;
            g_panelWin.rootViewController = vc;
        }
        g_panelWin.frame = pf;
        g_panelWin.hidden = NO;
        if (!g_panelWin.windowScene) g_panelWin.windowScene = find_scene();
        DREPanel *vc = (DREPanel *)g_panelWin.rootViewController;
        g_cmds = nil;                       // re-scan commands on each open
        [vc buildButtons];

        if (dre_reduceMotion()) { anchor_view_reset(vc.view); return; }
        // Origin-aware spring open: scale+fade in from the dot's position.
        CGPoint dot = CGPointMake(CGRectGetMidX(g_handleWin.frame),
                                  CGRectGetMidY(g_handleWin.frame));
        UIView *pv = vc.view;
        anchor_view_to_point(pv, dot, g_panelWin.frame);
        pv.transform = CGAffineTransformMakeScale(0.94, 0.94);
        pv.alpha = 0;
        [UIView animateWithDuration:0.38 delay:0
            usingSpringWithDamping:0.88 initialSpringVelocity:0 options:0
            animations:^{
                pv.transform = CGAffineTransformIdentity;
                pv.alpha = 1;
            } completion:^(BOOL d){
                anchor_view_reset(pv);
            }];
    });
}
// Apple rubber-band: resistance grows the further past the bound you drag.
static CGFloat dre_rubber(CGFloat over, CGFloat dim) {
    return (over * dim * 0.55) / (dim + 0.55 * fabs(over));
}
- (void)pan:(UIPanGestureRecognizer *)g {
    if (!g_handleWin) return;
    g_fadeGen++;                    // stays awake while dragging
    g_dot.alpha = 0.9;
    CGPoint tr = [g translationInView:g_handleWin];
    CGRect f = g_handleWin.frame;
    f.origin.x += tr.x; f.origin.y += tr.y;
    CGRect bounds = g_handleWin.windowScene.screen.bounds;
    if (bounds.size.width <= 0) bounds = UIScreen.mainScreen.bounds;
    [g setTranslation:CGPointZero inView:g_handleWin];

    // Soft boundaries: beyond the edge the dot resists instead of stopping dead.
    CGFloat loX = 6, hiX = bounds.size.width - f.size.width - 6;
    CGFloat loY = 40, hiY = bounds.size.height - f.size.height - 40;
    if (f.origin.x < loX)      f.origin.x = loX - dre_rubber(loX - f.origin.x, bounds.size.width);
    else if (f.origin.x > hiX) f.origin.x = hiX + dre_rubber(f.origin.x - hiX, bounds.size.width);
    if (f.origin.y < loY)      f.origin.y = loY - dre_rubber(loY - f.origin.y, bounds.size.height);
    else if (f.origin.y > hiY) f.origin.y = hiY + dre_rubber(f.origin.y - hiY, bounds.size.height);
    g_handleWin.frame = f;

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        wake_dot();
        // Edge-snap: project with release velocity, spring to nearest x-edge.
        CGPoint vel = [g velocityInView:g_handleWin];
        CGFloat proj = f.origin.x + vel.x * 0.15;   // momentum projection
        f.origin.x = (proj < (bounds.size.width - f.size.width) / 2) ? loX : hiX;
        f.origin.y = MIN(MAX(f.origin.y, loY), hiY);
        [UIView animateWithDuration:0.5 delay:0
            usingSpringWithDamping:0.78 initialSpringVelocity:0 options:0
            animations:^{ g_handleWin.frame = f; }
            completion:^(BOOL d){
                dre_tick();
                [[NSUserDefaults standardUserDefaults]
                    setObject:@[@(f.origin.x), @(f.origin.y)] forKey:@"dre_dotpos"];
            }];
    }
}
@end

// UIGestureRecognizer targets are weak — host must be retained for taps to work.
static DREGestureHost *g_host = nil;

static void schedule_fade(void) {
    int gen = ++g_fadeGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != g_fadeGen || !g_dot) return;
        [UIView animateWithDuration:0.5 animations:^{ g_dot.alpha = 0.35; }];
    });
}
static void wake_dot(void) {
    g_fadeGen++;                 // invalidate any pending fade
    if (!g_dot) return;
    [g_dot.layer removeAllAnimations];   // interrupt an in-flight fade
    g_dot.alpha = 0.9;
    schedule_fade();
}

static void make_handle(void) {
    if (g_handleWin) {
        if (!g_handleWin.windowScene) g_handleWin.windowScene = find_scene();
        // Re-clamp to the live screen — rotation while backgrounded can
        // leave the dot offscreen or floating mid-display.
        CGRect f = g_handleWin.frame;
        CGRect sb = find_scene().screen.bounds;
        if (sb.size.width > 0) {
            f.origin.x = MIN(MAX(f.origin.x, 6), sb.size.width - f.size.width - 6);
            f.origin.y = MIN(MAX(f.origin.y, 40), sb.size.height - f.size.height - 40);
            g_handleWin.frame = f;
        }
        g_handleWin.hidden = NO;
        return;
    }
    g_host = [DREGestureHost new];
    CGRect sb = find_scene().screen.bounds;
    if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
    // Persisted position wins; else default right edge (out of steering zone).
    CGPoint org = CGPointMake(sb.size.width - 62, sb.size.height * 0.35);
    NSArray *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"dre_dotpos"];
    if (saved.count == 2) {
        org = CGPointMake(MIN(MAX([saved[0] doubleValue], 6), sb.size.width - 62),
                          MIN(MAX([saved[1] doubleValue], 40), sb.size.height - 96));
    }
    g_handleWin = new_window(CGRectMake(org.x, org.y, 56, 56), UIWindowLevelAlert + 3);
    g_handleWin.rootViewController = [UIViewController new];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    dot.backgroundColor = DRE_BLUE;
    dot.layer.cornerRadius = 28;
    dot.layer.cornerCurve = kCACornerCurveContinuous;
    dot.layer.borderWidth = 1.5;
    dot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    dot.layer.shadowColor = UIColor.blackColor.CGColor;
    dot.layer.shadowOpacity = 0.35;
    dot.layer.shadowRadius = 8;
    dot.layer.shadowOffset = CGSizeMake(0, 3);
    dot.userInteractionEnabled = YES;
    g_dot = dot;

    UIImageView *t = [[UIImageView alloc] initWithImage:dre_symbol(@"fish.fill", 20, UIImageSymbolWeightSemibold)];
    t.tintColor = UIColor.whiteColor;
    t.frame = CGRectMake(15, 15, 26, 26);
    t.contentMode = UIViewContentModeScaleAspectFit;
    [dot addSubview:t];

    [dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:g_host action:@selector(tap)]];
    [dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:g_host action:@selector(pan:)]];
    [g_handleWin.rootViewController.view addSubview:dot];
    g_handleWin.hidden = NO;
    schedule_fade();
}

#pragma mark - bootstrap

static void poll_ready(void) {
    // Write toggle flags as soon as UnityFramework is mapped — the stubs can
    // be hit by game code long before the menu/shell is ready.
    if (uf_base() && !g_flags_init) {
        g_flags_init = YES;
        state_restore();
        flags_write();
    }
    // poll on MAIN thread: g_shell() runs il2cpp code -> needs a GC-registered thread.
    if (uf_base() && g_shell() && find_scene()) { make_handle(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll_ready(); });
}

__attribute__((constructor))
static void dre_init(void) {
    // If UnityFramework is already mapped (load-time dependency), write flags
    // now — before any game code can hit the stubs and read zero flags.
    if (uf_base()) { g_flags_init = YES; state_restore(); flags_write(); }
    dispatch_async(dispatch_get_main_queue(), ^{
        poll_ready();
        // re-attach on foregrounding in case scene changed
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n){ make_handle(); }];
    });
}
