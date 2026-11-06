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

static NSArray<NSString *> *enum_commands(void) {
    uintptr_t b = uf_base();
    void *shell = g_shell();
    if (!b || !shell) return nil;
    void *dict = NULL;
    try { dict = ((getter_fn_t)(b + RVA_GET_COMMANDS))(shell, NULL); } catch (...) { dict = NULL; }
    if (!ok_ptr((uintptr_t)dict)) return nil;

    NSMutableArray<NSString *> *out = [NSMutableArray array];
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
            uintptr_t ent = arr + 0x20 + (uintptr_t)i * 24;
            int32_t hash = *(int32_t *)ent;
            uintptr_t key = *(uintptr_t *)(ent + 8);
            if (hash < 0 || !ok_ptr(key)) continue;      // empty/deleted slot
            if (!ok_ptr(*(uintptr_t *)key)) continue;    // key->klass sane?
            int32_t slen = *(int32_t *)(key + 0x10);
            if (slen <= 0 || slen > 64) continue;
            NSString *s = [[NSString alloc] initWithCharacters:(const unichar *)(key + 0x14) length:slen];
            if (s) [out addObject:s];
        }
        if (!out.count) continue;   // try next candidate only if nothing found
        break;
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

static patchdef g_patches[] = {
    // bool: mov w0,#1; ret
    {0x125E7EC, {0x52800020, 0xD65F03C0}, 2, {0}, "God Mode"},
    {0x125E7FC, {0x52800020, 0xD65F03C0}, 2, {0}, "Immune (Equip Dmg)"},
    // float 0.0f: fmov s0,wzr; ret
    {0x135BFE4, {0x1E2703E0, 0xD65F03C0}, 2, {0}, "Zero Sanity"},
    {0x127B134, {0x1E2703E0, 0xD65F03C0}, 2, {0}, "No Durability Loss"},
    // int 0: mov w0,#0; ret
    {0x134C5B8, {0x52800000, 0xD65F03C0}, 2, {0}, "Free Research"},
    // void no-op: ret
    {0x1295D74, {0xD65F03C0},            1, {0}, "No Cooldowns"},
    // float consts via literal pool: ldr s0,[pc,#8]; ret; .float v
    {0x134BEAC, {0x1C000040, 0xD65F03C0, 0x40A00000}, 3, {0}, "Catch Rate 5.0"},
    {0x13C07E4, {0x1C000040, 0xD65F03C0, 0x40800000}, 3, {0}, "Sell 4x"},
    {0x14A3AF8, {0x1C000040, 0xD65F03C0, 0x41A00000}, 3, {0}, "Boat Speed 20"},
};
static const int g_npatches = sizeof(g_patches)/sizeof(g_patches[0]);
static BOOL g_state[32] = {0};

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

@interface DREPanel : UIViewController
@property (nonatomic, strong) UIWindow *win;
@end

@implementation DREPanel {
    UIScrollView *_scroll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
    self.view.layer.cornerRadius = 14;
    self.view.layer.masksToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 260, 26)];
    title.text = @"DREDGE MENU";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 50, 6, 44, 30);
    [close setTitle:@"X" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
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

    NSArray *cmds = enum_commands();
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
            if (![cmds containsObject:n]) continue;
            [self cmdBtn:n x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 40;
        }
        if (col) y += 40;
        y = [self section:@"All Commands" y:y];
        col = 0; x = 0;
        for (NSString *n in cmds) {
            if ([fav containsObject:n]) continue;
            [self cmdBtn:n x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 40;
        }
        if (col) y += 40;
    } else {
        // fallback: static guesses if enumeration fails
        y = [self section:@"Commands (guess)" y:y];
        NSArray *guess = @[@"godmode", @"setgodmode", @"immune", @"icebreaker",
                           @"setsanity 0", @"sanity 0", @"help", @"clear"];
        int col = 0; CGFloat x = 0;
        for (NSString *n in guess) {
            [self cmdBtn:n x:x y:y w:bw];
            col = (col + 1) % 2; x = col ? bw + 10 : 0;
            if (!col) y += 40;
        }
        if (col) y += 40;
    }

    y = [self section:@"Save" y:y];
    {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, y, bw, 34);
        b.backgroundColor = [UIColor colorWithRed:0.5 green:0.3 blue:0.1 alpha:1];
        b.layer.cornerRadius = 8;
        b.titleLabel.font = [UIFont systemFontOfSize:10];
        [b setTitle:@"Restore Bundled Save" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(restoreSave) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        y += 40;
    }

    y = [self section:@"Toggles" y:y];
    int col = 0; CGFloat x = 0;
    for (int i = 0; i < g_npatches; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, y, bw, 34);
        b.layer.cornerRadius = 8;
        b.titleLabel.font = [UIFont systemFontOfSize:10];
        [b setTitle:[NSString stringWithFormat:@"%s", g_patches[i].name] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.tag = 1000 + i;
        b.backgroundColor = g_state[i] ? [UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:1]
                                       : [UIColor darkGrayColor];
        [b addTarget:self action:@selector(toggleBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        col = (col + 1) % 2; x = col ? bw + 10 : 0;
        if (!col) y += 40;
    }
    if (col) y += 40;

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

- (void)cmdBtn:(NSString *)n x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, 34);
    b.backgroundColor = [UIColor darkGrayColor];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:10];
    b.titleLabel.numberOfLines = 2;
    [b setTitle:n forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(runCmdBtn:) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
}

- (void)runCmdBtn:(UIButton *)b {
    NSString *cmd = b.titleLabel.text;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:cmd
        message:@"Optional arguments:" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:nil];
    [a addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDefault handler:^(id act) {
        NSString *arg = a.textFields.firstObject.text;
        NSString *full = arg.length ? [NSString stringWithFormat:@"%@ %@", cmd, arg] : cmd;
        run_cmd(full.UTF8String);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)restoreSave {
    NSString *src = [[NSBundle mainBundle] pathForResource:@"dredge-save0" ofType:@"bin"];
    if (!src) { [self toast:@"bundled save not found in .app"]; return; }

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = NSFileManager.defaultManager;

    // find an existing dredge-save*.bin anywhere under Documents to learn the folder
    NSString *destDir = nil;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:docs];
    NSString *rel;
    while ((rel = [en nextObject])) {
        NSString *base = rel.lastPathComponent.lowercaseString;
        if ([base hasPrefix:@"dredge-save"] && [base hasSuffix:@".bin"]) {
            destDir = [docs stringByAppendingPathComponent:rel.stringByDeletingLastPathComponent];
            break;
        }
        // also learn from a folder literally named like the save dir
        BOOL isDir = NO;
        [fm fileExistsAtPath:[docs stringByAppendingPathComponent:rel] isDirectory:&isDir];
        if (isDir && [base containsString:@"save"]) destDir = destDir ?: [docs stringByAppendingPathComponent:rel];
    }
    if (!destDir) destDir = docs;

    NSString *dst = [destDir stringByAppendingPathComponent:@"dredge-save0.bin"];
    NSString *tmp = [dst stringByAppendingString:@".tmp"];
    NSError *err = nil;
    [fm removeItemAtPath:tmp error:nil];
    // copy to .tmp first, then swap — never delete the existing save before copy succeeds
    BOOL ok = [fm copyItemAtPath:src toPath:tmp error:&err];
    if (ok) {
        [fm removeItemAtPath:dst error:nil];
        ok = [fm moveItemAtPath:tmp toPath:dst error:&err];
    }
    [self toast:ok ? [NSString stringWithFormat:@"restored -> %@", dst]
                   : [NSString stringWithFormat:@"failed: %@", err.localizedDescription]];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save" message:msg
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)toggleBtn:(UIButton *)b {
    int i = (int)b.tag - 1000;
    BOOL want = !g_state[i];
    if (!patch_apply(i, want)) {
        [self toast:@"patch failed (memory not writable)"];
        return;
    }
    g_state[i] = want;
    b.backgroundColor = g_state[i] ? [UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:1]
                                   : [UIColor darkGrayColor];
    [b setTitle:[NSString stringWithFormat:@"%s %@", g_patches[i].name, g_state[i]?@"✓":@""] forState:UIControlStateNormal];
}

- (void)hidePanel {
    self.win.hidden = YES;
}
@end

#pragma mark - Floating handle

static UIWindow *g_handleWin = nil;
static UIWindow *g_panelWin = nil;

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

@implementation DREGestureHost
- (void)tap {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_panelWin) {
            g_panelWin = new_window(CGRectMake(30, 80, 340, 420), UIWindowLevelAlert + 2);
            DREPanel *vc = [DREPanel new];
            vc.win = g_panelWin;
            g_panelWin.rootViewController = vc;
        }
        g_panelWin.hidden = NO;
        if (!g_panelWin.windowScene) g_panelWin.windowScene = find_scene();
        [((DREPanel *)g_panelWin.rootViewController) buildButtons];
    });
}
- (void)pan:(UIPanGestureRecognizer *)g {
    if (!g_handleWin) return;
    CGPoint tr = [g translationInView:g_handleWin];
    CGRect f = g_handleWin.frame;
    f.origin.x += tr.x; f.origin.y += tr.y;
    // clamp inside the scene's screen bounds so the dot can't be dragged offscreen
    CGRect bounds = g_handleWin.windowScene.screen.bounds;
    if (bounds.size.width <= 0) bounds = UIScreen.mainScreen.bounds;
    CGFloat m = 8;
    f.origin.x = MIN(MAX(f.origin.x, m - f.size.width), bounds.size.width - m);
    f.origin.y = MIN(MAX(f.origin.y, m - f.size.height), bounds.size.height - m);
    g_handleWin.frame = f;
    [g setTranslation:CGPointZero inView:g_handleWin];
}
@end

// UIGestureRecognizer targets are weak — host must be retained for taps to work.
static DREGestureHost *g_host = nil;

static void make_handle(void) {
    if (g_handleWin) {
        if (!g_handleWin.windowScene) g_handleWin.windowScene = find_scene();
        g_handleWin.hidden = NO;
        return;
    }
    g_host = [DREGestureHost new];
    g_handleWin = new_window(CGRectMake(8, 120, 54, 54), UIWindowLevelAlert + 3);
    g_handleWin.rootViewController = [UIViewController new];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 54, 54)];
    dot.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1 alpha:0.85];
    dot.layer.cornerRadius = 27;
    dot.layer.borderWidth = 2;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.userInteractionEnabled = YES;

    UILabel *t = [[UILabel alloc] initWithFrame:dot.bounds];
    t.text = @"M"; t.textAlignment = NSTextAlignmentCenter;
    t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:22];
    [dot addSubview:t];

    [dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:g_host action:@selector(tap)]];
    [dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:g_host action:@selector(pan:)]];
    [g_handleWin.rootViewController.view addSubview:dot];
    g_handleWin.hidden = NO;
}

#pragma mark - bootstrap

static void poll_ready(void) {
    // poll on MAIN thread: g_shell() runs il2cpp code -> needs a GC-registered thread.
    if (uf_base() && g_shell() && find_scene()) { make_handle(); return; }
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
