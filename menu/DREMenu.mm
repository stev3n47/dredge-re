// DREMenu.dylib — custom cheat menu for DREDGE iOS (build 246)
// Injected via LC_LOAD_DYLIB into the DREDGE executable.
// Floating mini button -> cheat panel -> calls Terminal.Shell.RunCommand("...")
// and applies runtime byte patches for always-on toggles.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

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

#pragma mark - Runtime byte patches (always-on toggles)

// Each patch is a variable-length sequence of words written at the function start.
// Float-returning methods must return in s0, not w0.
// Pattern for float consts: ldr s0,[pc,#8]; b +8; .float v
typedef struct {
    uint32_t rva;
    uint32_t code[4];
    int      nwords;
    uint32_t orig[4];
    const char *name;
} patchdef;

// Only audited targets ship: wrong-register/unverified RVAs were dropped after
// review (GetPlayerSanity is a dialogue helper where 0=insane; CheckAbilityCooldown
// is UI-only; GetMissingDurabilityAmount is repair-side; 0x14A3AF8 is a float
// interpolation fn, not boat speed).
static patchdef g_patches[] = {
    // bool: mov w0,#1; ret
    {0x125E7EC, {0x52800020, 0xD65F03C0}, 2, {0}, "God Mode"},
    {0x125E7FC, {0x52800020, 0xD65F03C0}, 2, {0}, "Immune (Equip Dmg)"},
    // int 0: mov w0,#0; ret
    {0x134C5B8, {0x52800000, 0xD65F03C0}, 2, {0}, "Free Research"},
    // float consts via literal pool: ldr s0,[pc,#8]; ret; .float v
    {0x134BEAC, {0x1C000040, 0xD65F03C0, 0x40A00000}, 3, {0}, "Catch Rate 5.0"},
    {0x13C07E4, {0x1C000040, 0xD65F03C0, 0x40800000}, 3, {0}, "Sell 4x"},
};
static const int g_npatches = sizeof(g_patches)/sizeof(g_patches[0]);
static BOOL g_state[32] = {0};

static BOOL patch_apply(int i, BOOL on);

// Persist toggle state across relaunch; re-applied once UF is mapped.
static void state_persist(void) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:g_npatches];
    for (int i = 0; i < g_npatches; i++) [a addObject:@(g_state[i])];
    [NSUserDefaults.standardUserDefaults setObject:a forKey:@"dre_toggles"];
}
static void state_restore(void) {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:@"dre_toggles"];
    if (a.count != g_npatches) return;
    for (int i = 0; i < g_npatches; i++)
        if ([a[i] boolValue] && patch_apply(i, YES)) g_state[i] = YES;
}

static BOOL patch_apply(int i, BOOL on) {
    uintptr_t b = uf_base();
    if (!b) return NO;
    patchdef *p = &g_patches[i];
    uint32_t *addr = (uint32_t *)(b + p->rva);
    if (p->orig[0] == 0)
        memcpy(p->orig, addr, p->nwords * 4);
    uintptr_t page = ((uintptr_t)addr) & ~0xFFFULL;
    size_t pgsz = (size_t)sysconf(_SC_PAGESIZE);
    if (mprotect((void *)page, pgsz, PROT_READ | PROT_WRITE | PROT_EXEC) != 0)
        return NO;
    if (on) memcpy(addr, p->code, p->nwords * 4);
    else    memcpy(addr, p->orig, p->nwords * 4);
    sys_icache_invalidate(addr, p->nwords * 4);
    mprotect((void *)page, pgsz, PROT_READ | PROT_EXEC);
    return YES;
}

#pragma mark - UI

static UIWindow *g_handleWin = nil;
static UIWindow *g_panelWin = nil;

@interface DREPanel : UIViewController
@property (nonatomic, weak) UIWindow *win;
@end

@implementation DREPanel {
    UIScrollView *_scroll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
    self.view.layer.cornerRadius = 14;
    self.view.layer.masksToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 260, 26)];
    title.text = @"DREDGE";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 50, 6, 44, 30);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.view addSubview:close];

    CGFloat w = self.view.bounds.size.width - 24;
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 40, w, self.view.bounds.size.height - 52)];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_scroll];
    [self buildButtons];
}

- (void)buildButtons {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0) w = self.view.bounds.size.width - 24;
    CGFloat y = 4;
    CGFloat bw = (w - 10) / 2;

    // Toggles first — highest-frequency section shouldn't sit at the bottom.
    y = [self section:@"Toggles" y:y];
    int col = 0; CGFloat x = 0;
    for (int i = 0; i < g_npatches; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, y, bw, 36);
        b.layer.cornerRadius = 9;
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        b.showsTouchWhenHighlighted = YES;
        [b setTitle:[NSString stringWithFormat:@"%s %@", g_patches[i].name,
                     g_state[i] ? @"ON" : @"OFF"] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.tag = 1000 + i;
        b.backgroundColor = g_state[i] ? [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:1]
                                       : [UIColor colorWithWhite:0.28 alpha:1];
        [b addTarget:self action:@selector(toggleBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        col = (col + 1) % 2; x = col ? bw + 10 : 0;
        if (!col) y += 42;
    }
    if (col) y += 42;
    y += 4;

    NSArray<NSDictionary *> *cmds = enum_commands();
    if (cmds.count) {
        y = [self section:@"Game Commands" y:y];
        // Curated favorites first, then everything else registered
        NSArray *fav = @[@"SetGodMode", @"godmode", @"SetImmuneMode", @"ToggleIcebreaker",
                         @"SetSanity", @"SetMaxSpeed", @"SetPlayerBaseMoveSpeed", @"SetPlayerBaseTurnSpeed",
                         @"TeleportPlayerToHarvestSpot", @"RestockHarvestSpot", @"DepleteHarvestSpots",
                         @"DebugAddItem", @"DebugAddItemInventory", @"DebugAddItemNet",
                         @"DebugAddItemStorage", @"DebugAddItemOverflowStorage", @"DebugAddAllCabinItems",
                         @"DebugUnlockAbility", @"DebugSetGameAsPurchased", @"SetAllDLC",
                         @"ListDestinations", @"UnlockDestination", @"Die"];
        int col = 0; CGFloat x = 0;
        for (NSString *n in fav) {
            NSDictionary *c = [self cmdNamed:n in:cmds];
            if (!c) continue;
            [self cmdBtn:c x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 42;
        }
        if (col) y += 42;
        y = [self section:@"All Commands" y:y];
        col = 0; x = 0;
        for (NSDictionary *c in cmds) {
            if ([fav containsObject:c[@"name"]]) continue;
            [self cmdBtn:c x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 42;
        }
        if (col) y += 42;
    } else {
        // fallback: static guesses if enumeration fails
        y = [self section:@"Commands (guess)" y:y];
        NSArray *guess = @[@"godmode", @"setgodmode", @"immune", @"icebreaker",
                           @"setsanity 0", @"sanity 0", @"help", @"clear"];
        int col = 0; CGFloat x = 0;
        for (NSString *n in guess) {
            [self cmdBtn:@{@"name": n, @"min": @0, @"max": @0} x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 42;
        }
        if (col) y += 42;
    }

    y = [self section:@"Save" y:y];
    {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, y, bw, 36);
        b.backgroundColor = [UIColor colorWithRed:0.5 green:0.3 blue:0.1 alpha:1];
        b.layer.cornerRadius = 9;
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        b.showsTouchWhenHighlighted = YES;
        [b setTitle:@"Restore Bundled Save" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(restoreSave) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        y += 42;
    }

    _scroll.contentSize = CGSizeMake(w, y + 20);
}

- (CGFloat)section:(NSString *)t y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, y, _scroll.bounds.size.width, 22)];
    l.text = t;
    l.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1];
    l.font = [UIFont boldSystemFontOfSize:13];
    [_scroll addSubview:l];
    return y + 24;
}

- (NSDictionary *)cmdNamed:(NSString *)n in:(NSArray<NSDictionary *> *)cmds {
    for (NSDictionary *c in cmds)
        if ([c[@"name"] isEqualToString:n]) return c;
    return nil;
}

- (void)cmdBtn:(NSDictionary *)c x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, 36);
    b.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1];
    b.layer.cornerRadius = 9;
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    b.titleLabel.numberOfLines = 2;
    b.showsTouchWhenHighlighted = YES;
    [b setTitle:c[@"name"] forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.tag = 2000;
    b.accessibilityIdentifier = [NSString stringWithFormat:@"%@|%@|%@|%@",
        c[@"name"], c[@"min"], c[@"max"], c[@"help"] ?: @""];
    [b addTarget:self action:@selector(runCmdBtn:) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
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

- (void)restoreSave {
    NSString *src = [[NSBundle mainBundle] pathForResource:@"dredge-save0" ofType:@"bin"];
    if (!src) { [self toast:@"bundled save not found in .app"]; return; }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();

    // Scan the whole app container — saves may live in Documents,
    // Library/Application Support, or a subdir we haven't seen.
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *base in @[@"Documents", @"Library"]) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:[home stringByAppendingPathComponent:base]];
        NSString *rel;
        while ((rel = [en nextObject])) {
            NSString *lc = rel.lastPathComponent.lowercaseString;
            if ([lc hasPrefix:@"dredge-save"] && [lc hasSuffix:@".bin"])
                [hits addObject:[base stringByAppendingPathComponent:rel]];
        }
    }

    NSString *destDir;
    if (hits.count) {
        // put ours next to the first existing save the game made
        destDir = [[home stringByAppendingPathComponent:hits.firstObject]
                   stringByDeletingLastPathComponent];
    } else {
        destDir = [home stringByAppendingPathComponent:@"Documents"];
    }
    NSString *dst = [destDir stringByAppendingPathComponent:@"dredge-save0.bin"];

    NSString *foundMsg = hits.count
        ? [NSString stringWithFormat:@"Found %d existing save(s).\nWriting next to:\n%@",
           (int)hits.count, hits.firstObject.stringByDeletingLastPathComponent]
        : @"No existing save found — writing to Documents root.\n\nThe game may use a different folder; if the save doesn't load, tell me where the game stores saves.";

    UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Restore save?"
        message:foundMsg preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive
        handler:^(id a){
            NSString *tmp = [dst stringByAppendingString:@".tmp"];
            NSError *err = nil;
            [fm removeItemAtPath:tmp error:nil];
            BOOL ok = [fm copyItemAtPath:src toPath:tmp error:&err];
            if (ok) { [fm removeItemAtPath:dst error:nil]; ok = [fm moveItemAtPath:tmp toPath:dst error:&err]; }
            [self toast:ok ? [NSString stringWithFormat:@"restored → %@", dst.lastPathComponent]
                           : [NSString stringWithFormat:@"failed: %@", err.localizedDescription]];
        }]];
    [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:c animated:YES completion:nil];
}

// Transient toast — non-blocking, auto-dismisses. Lives on the panel window
// so it's visible above the panel but below nothing that steals focus.
- (void)toast:(NSString *)msg {
    static UILabel *tl = nil;
    if (tl) [tl removeFromSuperview];
    UIView *host = self.win.rootViewController.view;
    if (!host) return;

    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.layer.cornerRadius = 10;
    l.layer.masksToBounds = YES;

    CGFloat w = MIN(host.bounds.size.width - 40, 300);
    CGSize fit = [l sizeThatFits:CGSizeMake(w - 24, CGFLOAT_MAX)];
    l.frame = CGRectMake((host.bounds.size.width - w) / 2,
                         host.bounds.size.height - fit.height - 28,
                         w, fit.height + 16);
    l.alpha = 0;
    [host addSubview:l];
    tl = l;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut
        animations:^{ l.alpha = 1; } completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (tl != l) return;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn
            animations:^{ l.alpha = 0; } completion:^(BOOL d){ [l removeFromSuperview]; }];
    });
}

- (void)toggleBtn:(UIButton *)b {
    int i = (int)b.tag - 1000;
    BOOL want = !g_state[i];
    if (!patch_apply(i, want)) {
        [self toast:@"patch failed (memory not writable)"];
        return;
    }
    g_state[i] = want;
    state_persist();
    b.backgroundColor = g_state[i] ? [UIColor colorWithRed:0.13 green:0.52 blue:0.24 alpha:1]
                                   : [UIColor colorWithWhite:0.28 alpha:1];
    [b setTitle:[NSString stringWithFormat:@"%s %@", g_patches[i].name,
                 g_state[i] ? @"ON" : @"OFF"] forState:UIControlStateNormal];
    [self toast:[NSString stringWithFormat:@"%s %@", g_patches[i].name, g_state[i] ? "on" : "off"]];
}

- (void)hidePanel {
    // Symmetric exit — shrink+fade back toward the handle (spatial consistency).
    CGPoint dot = g_handleWin ? CGPointMake(CGRectGetMidX(g_handleWin.frame),
                                            CGRectGetMidY(g_handleWin.frame)) : self.view.center;
    CGRect pf = self.win.frame;
    CGFloat ax = MIN(MAX((dot.x - pf.origin.x) / pf.size.width, 0), 1);
    CGFloat ay = MIN(MAX((dot.y - pf.origin.y) / pf.size.height, 0), 1);
    self.view.layer.anchorPoint = CGPointMake(ax, ay);
    self.view.layer.position = CGPointMake(pf.origin.x + ax * pf.size.width,
                                           pf.origin.y + ay * pf.size.height);
    [UIView animateWithDuration:0.28 delay:0
        usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0
        animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.9, 0.9);
            self.view.alpha = 0;
        } completion:^(BOOL d){
            self.win.hidden = YES;
            self.view.transform = CGAffineTransformIdentity;
            self.view.alpha = 1;
            self.view.layer.anchorPoint = CGPointMake(0.5, 0.5);
            self.view.layer.position = CGPointMake(pf.origin.x + pf.size.width / 2,
                                                   pf.origin.y + pf.size.height / 2);
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

@implementation DREGestureHost
- (void)tap {
    dispatch_async(dispatch_get_main_queue(), ^{
        wake_dot();
        if (!g_panelWin) {
            // Clamp panel to the screen so landscape iPhone doesn't clip it.
            CGRect sb = g_handleWin.windowScene.screen.bounds;
            if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
            CGFloat pw = MIN(340, sb.size.width - 32);
            CGFloat ph = MIN(420, sb.size.height - 32);
            g_panelWin = new_window(CGRectMake((sb.size.width - pw) / 2,
                                               (sb.size.height - ph) / 2, pw, ph),
                                    UIWindowLevelAlert + 2);
            DREPanel *vc = [DREPanel new];
            vc.win = g_panelWin;
            g_panelWin.rootViewController = vc;
        }
        g_panelWin.hidden = NO;
        if (!g_panelWin.windowScene) g_panelWin.windowScene = find_scene();
        DREPanel *vc = (DREPanel *)g_panelWin.rootViewController;
        [vc buildButtons];

        // Origin-aware spring open: scale+fade in from the dot's position.
        CGPoint dot = CGPointMake(CGRectGetMidX(g_handleWin.frame),
                                  CGRectGetMidY(g_handleWin.frame));
        CGRect pf = g_panelWin.frame;
        CGFloat ax = MIN(MAX((dot.x - pf.origin.x) / pf.size.width, 0), 1);
        CGFloat ay = MIN(MAX((dot.y - pf.origin.y) / pf.size.height, 0), 1);
        UIView *pv = vc.view;
        pv.layer.anchorPoint = CGPointMake(ax, ay);
        pv.layer.position = CGPointMake(pf.origin.x + ax * pf.size.width,
                                        pf.origin.y + ay * pf.size.height);
        pv.transform = CGAffineTransformMakeScale(0.92, 0.92);
        pv.alpha = 0;
        [UIView animateWithDuration:0.32 delay:0
            usingSpringWithDamping:0.82 initialSpringVelocity:0 options:0
            animations:^{
                pv.transform = CGAffineTransformIdentity;
                pv.alpha = 1;
            } completion:^(BOOL d){
                pv.layer.anchorPoint = CGPointMake(0.5, 0.5);
                pv.layer.position = CGPointMake(pf.origin.x + pf.size.width / 2,
                                                pf.origin.y + pf.size.height / 2);
            }];
    });
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
    CGFloat m = 8;
    f.origin.x = MIN(MAX(f.origin.x, m - f.size.width), bounds.size.width - m);
    f.origin.y = MIN(MAX(f.origin.y, m - f.size.height), bounds.size.height - m);
    g_handleWin.frame = f;
    [g setTranslation:CGPointZero inView:g_handleWin];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        wake_dot();
        // Edge-snap: project with release velocity, spring to nearest x-edge.
        CGPoint vel = [g velocityInView:g_handleWin];
        CGFloat proj = f.origin.x + vel.x * 0.15;   // momentum projection
        CGFloat left = 6, right = bounds.size.width - f.size.width - 6;
        f.origin.x = (proj < (bounds.size.width - f.size.width) / 2) ? left : right;
        f.origin.y = MIN(MAX(f.origin.y, 40), bounds.size.height - f.size.height - 40);
        [UIView animateWithDuration:0.4 delay:0
            usingSpringWithDamping:0.78 initialSpringVelocity:0 options:0
            animations:^{ g_handleWin.frame = f; } completion:nil];
    }
}
@end

// UIGestureRecognizer targets are weak — host must be retained for taps to work.
static DREGestureHost *g_host = nil;
static UIView *g_dot = nil;
static int g_fadeGen = 0;

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
        g_handleWin.hidden = NO;
        return;
    }
    g_host = [DREGestureHost new];
    // Default: right edge, out of the left-thumb steering zone.
    CGRect sb = find_scene().screen.bounds;
    if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
    g_handleWin = new_window(CGRectMake(sb.size.width - 62, sb.size.height * 0.35, 56, 56),
                             UIWindowLevelAlert + 3);
    g_handleWin.rootViewController = [UIViewController new];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    dot.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1 alpha:0.9];
    dot.layer.cornerRadius = 28;
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.8].CGColor;
    dot.userInteractionEnabled = YES;
    g_dot = dot;

    UILabel *t = [[UILabel alloc] initWithFrame:dot.bounds];
    t.text = @"M"; t.textAlignment = NSTextAlignmentCenter;
    t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:22];
    [dot addSubview:t];

    [dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:g_host action:@selector(tap)]];
    [dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:g_host action:@selector(pan:)]];
    [g_handleWin.rootViewController.view addSubview:dot];
    g_handleWin.hidden = NO;
    schedule_fade();
}

#pragma mark - bootstrap

static void poll_ready(void) {
    // poll on MAIN thread: g_shell() runs il2cpp code -> needs a GC-registered thread.
    if (uf_base() && g_shell() && find_scene()) { state_restore(); make_handle(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll_ready(); });
}

__attribute__((constructor))
static void dre_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        poll_ready();
        // re-attach on foregrounding in case scene changed
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n){ make_handle(); }];
    });
}
