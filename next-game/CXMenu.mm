// CXMenu.dylib — custom cheat menu for CarX Drift Racing 3 iOS (1.18.1)
// Injected via LC_LOAD_DYLIB into the CarXDriftRacing3 executable.
// Floating mini button -> cheat panel -> flag bytes the baked stubs read.
// Cheats are static patches baked at build time (see tools/inject_carx.py).
//
// Seam: Dr3PlayerResourcesUtils.AddResource computes
//   newBalance = delta*factor + balance   (madd @0x283D660)
// factor is +1 for earns, -1 for spends — every Soft/Hard/Fans/Fuel
// update flows through it. flag+0 multiplies earns by an i32 at flag+4,
// flag+1 makes spends write back the unchanged balance.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
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

#pragma mark - Toggle flags (data writes into UnityFramework __DATA dead page)

// Same signing constraint as DREDGE: runtime code patching needs
// dynamic-codesigning (TrollStore-only). inject_carx.py bakes a `b <stub>`
// at the AddResource madd site — the stub lives in __TEXT segment-tail
// page padding (0x69974D0) and reads flag bytes from __DATA segment-tail
// padding at uf_base+FLAG_RVA (past __common, mapped zero-fill, no xrefs).
// Toggling = writing a byte — always legal.
#define FLAG_RVA 0x7B47000
static uint8_t *flag_base(void) {
    uintptr_t b = uf_base();
    return b ? (uint8_t *)(b + FLAG_RVA) : NULL;
}

typedef struct {
    const char *name;
    const char *icon;      // SF Symbol name
    uint32_t off;          // flag byte offset
} tog_t;
static const tog_t g_togs[] = {
    {"Cash Boost",     "banknote.fill",         0},
    {"Free Purchases", "cart.fill",             1},
};
#define NTOGS 2
static BOOL g_state[NTOGS] = {YES, YES};
static BOOL g_flags_init = NO;
static int32_t g_mult = 10000;   // i32 at flag+4 — earn multiplier

static void flag_apply(int i) {
    uint8_t *f = flag_base();
    if (!f) return;
    f[g_togs[i].off] = g_state[i] ? 1 : 0;
}
static void mult_write(void) {
    uint8_t *f = flag_base();
    if (f) *(int32_t *)(f + 4) = g_mult;
}
static void flags_write(void) {
    for (int i = 0; i < NTOGS; i++) flag_apply(i);
    mult_write();
}

static void state_persist(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:@[@(g_state[0]), @(g_state[1])] forKey:@"cx_toggles"];
    [d setInteger:g_mult forKey:@"cx_mult"];
}
static void state_restore(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *a = [d objectForKey:@"cx_toggles"];
    for (NSUInteger i = 0; i < a.count && i < NTOGS; i++)
        g_state[i] = [a[i] boolValue];
    if ([d objectForKey:@"cx_mult"]) g_mult = (int32_t)[d integerForKey:@"cx_mult"];
    if (g_mult <= 0) g_mult = 10000;
}

#pragma mark - UI

static UIWindow *g_handleWin = nil;
static UIWindow *g_panelWin = nil;

// Design tokens — iOS semantic palette, fixed dark (HUD over a bright game).
#define DRE_GREEN   [UIColor colorWithRed:48/255.0 green:209/255.0 blue:88/255.0 alpha:1]
#define DRE_RED     [UIColor colorWithRed:255/255.0 green:69/255.0 blue:58/255.0 alpha:1]
#define DRE_BLUE    [UIColor colorWithRed:10/255.0 green:132/255.0 blue:255/255.0 alpha:1]
#define DRE_FILL    [UIColor colorWithWhite:1 alpha:0.08]
#define DRE_TEXT    [UIColor colorWithWhite:1 alpha:0.92]
#define DRE_SUB     [UIColor colorWithWhite:1 alpha:0.5]
#define DRE_HAIR    [UIColor colorWithWhite:1 alpha:0.14]
#define DRE_RADIUS  12.0

static UIImage *dre_symbol(NSString *name, CGFloat pt, UIImageSymbolWeight w) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:w];
    return [UIImage systemImageNamed:name withConfiguration:c];
}
static BOOL dre_reduceMotion(void) { return UIAccessibilityIsReduceMotionEnabled(); }

// Instant touch-down feedback — press is the response, release is the commit.
@interface CXButton : UIButton
@end
@implementation CXButton
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

// Direct-manipulation handle: presses dent it (0.88), drags lift it
// (1.08 + deeper shadow) like moving a Home Screen icon.
@interface CXDot : UIView
@property (nonatomic) BOOL lifted;
@end
@implementation CXDot
- (void)applyScale:(CGFloat)s {
    if (dre_reduceMotion()) { self.transform = CGAffineTransformMakeScale(s, s); return; }
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.65
        initialSpringVelocity:0 options:0
        animations:^{ self.transform = CGAffineTransformMakeScale(s, s); } completion:nil];
}
- (void)setLifted:(BOOL)l {
    _lifted = l;
    self.layer.shadowOpacity = l ? 0.55 : 0.35;
    self.layer.shadowRadius = l ? 14 : 8;
    [self applyScale:l ? 1.08 : 1.0];
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [super touchesBegan:t withEvent:e];
    if (dre_reduceMotion()) return;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut
        animations:^{ self.transform = CGAffineTransformMakeScale(0.88, 0.88); } completion:nil];
}
- (void)settle { [self applyScale:self.lifted ? 1.08 : 1.0]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [super touchesEnded:t withEvent:e]; [self settle];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [super touchesCancelled:t withEvent:e]; [self settle];
}
@end

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

// Anchor a window-filling view's layer to a SCREEN point (the dot) so
// scale animations grow/shrink toward it.
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

@interface CXPanel : UIViewController
@property (nonatomic, weak) UIWindow *win;
@end

@implementation CXPanel {
    UIScrollView *_scroll;
    UILabel *_sub;
    UIVisualEffectView *_bg;
    CGFloat _lastW;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.layer.shadowColor = UIColor.blackColor.CGColor;
    self.view.layer.shadowOpacity = 0.45;
    self.view.layer.shadowRadius = 22;
    self.view.layer.shadowOffset = CGSizeMake(0, 10);

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

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 220, 20)];
    title.text = @"CARX DRIFT 3";
    title.textColor = DRE_TEXT;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [content addSubview:title];

    _sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 31, 220, 14)];
    _sub.textColor = DRE_SUB;
    _sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [content addSubview:_sub];

    CXButton *close = [CXButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(w - 44, 10, 30, 30);
    close.backgroundColor = DRE_FILL;
    close.layer.cornerRadius = 15;
    close.layer.cornerCurve = kCACornerCurveContinuous;
    [close setImage:dre_symbol(@"xmark", 12, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    close.tintColor = DRE_SUB;
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [content addSubview:close];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 52, w - 24, self.view.bounds.size.height - 64)];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    _scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [content addSubview:_scroll];
    [self buildButtons];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.view.layer.shadowPath = [UIBezierPath
        bezierPathWithRoundedRect:self.view.bounds cornerRadius:20].CGPath;
    CGFloat w = _scroll.bounds.size.width;
    if (w > 0 && fabs(w - _lastW) > 0.5) { _lastW = w; [self buildButtons]; }
}

- (void)buildButtons {
    CGPoint off = _scroll.contentOffset;
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    CGFloat w = _scroll.bounds.size.width;
    if (w <= 0) w = self.view.bounds.size.width - 24;
    CGFloat y = 4;
    CGFloat bw = (w - 10) / 2;

    int on = 0; for (int i = 0; i < NTOGS; i++) on += g_state[i];
    _sub.text = [NSString stringWithFormat:@"%d of %d cheats active", on, NTOGS];

    y = [self section:@"Cheats" icon:@"slider.horizontal.3" y:y];
    {
        int col = 0; CGFloat x = 0;
        for (int i = 0; i < NTOGS; i++) {
            CXButton *b = [CXButton buttonWithType:UIButtonTypeCustom];
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
        if (col) y += 46;
        // Earn multiplier — own row under the toggle grid.
        CXButton *mb = [CXButton buttonWithType:UIButtonTypeCustom];
        mb.frame = CGRectMake(0, y, bw, 40);
        mb.layer.cornerRadius = DRE_RADIUS;
        mb.layer.cornerCurve = kCACornerCurveContinuous;
        [self paintMult:mb];
        [mb addTarget:self action:@selector(multBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:mb];
        y += 46;
        y += 6;
    }

    y = [self section:@"Diagnostics" icon:@"stethoscope" y:y];
    {
        CXButton *db = [CXButton buttonWithType:UIButtonTypeCustom];
        db.frame = CGRectMake(0, y, bw, 40);
        db.layer.cornerRadius = DRE_RADIUS;
        db.layer.cornerCurve = kCACornerCurveContinuous;
        db.backgroundColor = DRE_FILL;
        [db setImage:dre_symbol(@"doc.on.clipboard", 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
        db.tintColor = DRE_SUB;
        db.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
        [db setTitle:@" Copy UI tree" forState:UIControlStateNormal];
        db.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [db setTitleColor:DRE_TEXT forState:UIControlStateNormal];
        db.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        db.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
        [db addTarget:self action:@selector(dumpBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:db];
        y += 46;
    }
    _scroll.contentSize = CGSizeMake(w, y + 20);
    _scroll.contentOffset = off;
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

- (void)paintTog:(UIButton *)b {
    int i = (int)b.tag - 3000;
    BOOL on = g_state[i];
    b.backgroundColor = on ? [DRE_GREEN colorWithAlphaComponent:0.22] : DRE_FILL;
    b.layer.borderWidth = on ? 0.5 : 0;
    b.layer.borderColor = on ? [DRE_GREEN colorWithAlphaComponent:0.55].CGColor : nil;

    UIImage *img = dre_symbol(@(g_togs[i].icon), 13, UIImageSymbolWeightMedium);
    [b setImage:img forState:UIControlStateNormal];
    b.tintColor = on ? DRE_GREEN : DRE_SUB;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    [b setTitle:[NSString stringWithFormat:@" %s", g_togs[i].name] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitleColor:on ? DRE_TEXT : [UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 36);
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

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
    dre_tick();
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
    [b setTitle:[NSString stringWithFormat:@" Boost ×%d", (int)g_mult] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
}

- (void)multBtn:(UIButton *)b {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Cash Boost"
        message:@"Multiplier applied to every earn" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%d", (int)g_mult];
    }];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(id act) {
        int v = wa.textFields.firstObject.text.intValue;
        if (v > 0) {
            g_mult = v;
            mult_write();
            state_persist();
            [self paintMult:b];
            [self toast:[NSString stringWithFormat:@"Boost ×%d", (int)g_mult]];
        } else { dre_notify(UINotificationFeedbackTypeError);
            [self toast:@"Enter a positive number" icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)dumpVC:(UIViewController *)vc into:(NSMutableString *)s depth:(int)d {
    int guard = 0;
    for (UIViewController *c = vc; c && guard++ < 20; c = c.presentedViewController) {
        [s appendFormat:@"%*sVC %@ presenting=%@\n", d, "",
            NSStringFromClass(c.class), NSStringFromClass(c.presentedViewController.class)];
        for (UIViewController *ch in c.childViewControllers)
            [self dumpVC:ch into:s depth:d + 2];
    }
}

- (void)dumpView:(UIView *)v into:(NSMutableString *)s depth:(int)d {
    if (d > 24) return;
    [s appendFormat:@"%*sV %@ hid=%d f=%@\n", d, "",
        NSStringFromClass(v.class), v.hidden, NSStringFromCGRect(v.frame)];
    for (UIView *sv in v.subviews) [self dumpView:sv into:s depth:d + 2];
}

- (void)dumpBtn:(UIButton *)b {
    NSMutableString *s = [NSMutableString new];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        [s appendFormat:@"SCENE %@ act=%ld wins=%lu\n", NSStringFromClass(sc.class),
            (long)sc.activationState, (unsigned long)ws.windows.count];
        for (UIWindow *w in ws.windows) {
            [s appendFormat:@" WIN %@ lvl=%.0f hid=%d userInt=%d sz=%@ rootVC=%@\n",
                NSStringFromClass(w.class), w.windowLevel, w.hidden,
                w.userInteractionEnabled, NSStringFromCGSize(w.bounds.size),
                NSStringFromClass(w.rootViewController.class)];
            if (w == g_handleWin || w == g_panelWin) continue;
            [self dumpVC:w.rootViewController.presentedViewController into:s depth:4];
            for (UIViewController *ch in w.rootViewController.childViewControllers)
                [self dumpVC:ch into:s depth:4];
            [self dumpView:w into:s depth:4];
        }
    }
    UIPasteboard.generalPasteboard.string = s;
    [self toast:@"UI tree copied to clipboard" icon:@"doc.on.clipboard" tint:DRE_GREEN];
}

// Transient toast — pill with SF icon, slides up with a spring, interruptible.
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
    CGPoint dot = g_handleWin ? CGPointMake(CGRectGetMidX(g_handleWin.frame),
                                            CGRectGetMidY(g_handleWin.frame)) : self.view.center;
    if (dre_reduceMotion()) {
        [UIView animateWithDuration:0.18 animations:^{ self.view.alpha = 0; }
            completion:^(BOOL d){ self.win.hidden = YES; self.view.alpha = 1; }];
        return;
    }
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

@interface CXGestureHost : NSObject
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

static void schedule_fade(void);
static void wake_dot(void);
static CXDot *g_dot = nil;
static int g_fadeGen = 0;

@implementation CXGestureHost
- (void)tap {
    dispatch_async(dispatch_get_main_queue(), ^{
        wake_dot();
        if (g_panelWin && !g_panelWin.hidden) {
            [(CXPanel *)g_panelWin.rootViewController hidePanel];
            return;
        }
        CGRect sb = g_handleWin.windowScene.screen.bounds;
        if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
        CGFloat pw = MIN(340, sb.size.width - 32);
        CGFloat ph = MIN(300, sb.size.height - 32);
        CGRect pf = CGRectMake((sb.size.width - pw) / 2,
                               (sb.size.height - ph) / 2, pw, ph);
        if (!g_panelWin) {
            g_panelWin = new_window(pf, UIWindowLevelAlert + 2);
            CXPanel *vc = [CXPanel new];
            vc.win = g_panelWin;
            g_panelWin.rootViewController = vc;
        }
        g_panelWin.frame = pf;
        g_panelWin.hidden = NO;
        if (!g_panelWin.windowScene) g_panelWin.windowScene = find_scene();
        CXPanel *vc = (CXPanel *)g_panelWin.rootViewController;
        [vc buildButtons];

        if (dre_reduceMotion()) { anchor_view_reset(vc.view); return; }
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
    g_fadeGen++;
    g_dot.alpha = 0.9;
    g_dot.lifted = YES;
    CGPoint tr = [g translationInView:g_handleWin];
    CGRect f = g_handleWin.frame;
    f.origin.x += tr.x; f.origin.y += tr.y;
    CGRect bounds = g_handleWin.windowScene.screen.bounds;
    if (bounds.size.width <= 0) bounds = UIScreen.mainScreen.bounds;
    [g setTranslation:CGPointZero inView:g_handleWin];

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
        g_dot.lifted = NO;
        CGPoint vel = [g velocityInView:g_handleWin];
        CGFloat proj = f.origin.x + vel.x * 0.15;
        f.origin.x = (proj < (bounds.size.width - f.size.width) / 2) ? loX : hiX;
        f.origin.y = MIN(MAX(f.origin.y, loY), hiY);
        [UIView animateWithDuration:0.5 delay:0
            usingSpringWithDamping:0.78 initialSpringVelocity:0 options:0
            animations:^{ g_handleWin.frame = f; }
            completion:^(BOOL d){
                dre_tick();
                [[NSUserDefaults standardUserDefaults]
                    setObject:@[@(f.origin.x), @(f.origin.y)] forKey:@"cx_dotpos"];
            }];
    }
}
@end

// UIGestureRecognizer targets are weak — host must be retained for taps to work.
static CXGestureHost *g_host = nil;

static void schedule_fade(void) {
    int gen = ++g_fadeGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != g_fadeGen || !g_dot) return;
        [UIView animateWithDuration:0.5 animations:^{ g_dot.alpha = 0.35; }];
    });
}
static void wake_dot(void) {
    g_fadeGen++;
    if (!g_dot) return;
    [g_dot.layer removeAllAnimations];
    g_dot.alpha = 0.9;
    schedule_fade();
}

static void make_handle(void) {
    if (g_handleWin) {
        if (!g_handleWin.windowScene) g_handleWin.windowScene = find_scene();
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
    g_host = [CXGestureHost new];
    CGRect sb = find_scene().screen.bounds;
    if (sb.size.width <= 0) sb = UIScreen.mainScreen.bounds;
    CGPoint org = CGPointMake(sb.size.width - 62, sb.size.height * 0.35);
    NSArray *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"cx_dotpos"];
    if (saved.count == 2) {
        org = CGPointMake(MIN(MAX([saved[0] doubleValue], 6), sb.size.width - 62),
                          MIN(MAX([saved[1] doubleValue], 40), sb.size.height - 96));
    }
    g_handleWin = new_window(CGRectMake(org.x, org.y, 56, 56), UIWindowLevelAlert + 3);
    g_handleWin.rootViewController = [UIViewController new];

    CXDot *dot = [[CXDot alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    dot.backgroundColor = UIColor.clearColor;
    dot.layer.cornerRadius = 28;
    dot.layer.borderWidth = 1.0;
    dot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    dot.layer.shadowColor = UIColor.blackColor.CGColor;
    dot.layer.shadowOpacity = 0.35;
    dot.layer.shadowRadius = 8;
    dot.layer.shadowOffset = CGSizeMake(0, 3);
    dot.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:dot.bounds].CGPath;
    dot.userInteractionEnabled = YES;
    g_dot = dot;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    blur.frame = dot.bounds;
    blur.layer.cornerRadius = 28;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    blur.userInteractionEnabled = NO;
    [dot addSubview:blur];

    UIImageView *t = [[UIImageView alloc] initWithImage:dre_symbol(@"car.fill", 20, UIImageSymbolWeightSemibold)];
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

#pragma mark - iOSGods auth-wall sweeper

// libcarx's login wall is a SwiftUI view (AuthUI.LegacyAuthToastView) rendered
// by a hosting controller in its own window or a presented VC. ObjC runtime
// names for generic Swift classes embed the module + type names, so substring
// matching survives the mod's ObjC-class obfuscation.
static BOOL cx_wall_name(NSString *n) {
    // Known iOSGods wall identifiers — plain names, mangled ObjC names
    // (module/type names survive as substrings), and the obfuscated class
    // names observed in the live UI dump (libcarx 1.18.1 build).
    return n && ([n containsString:@"AuthUI"] ||
                 [n containsString:@"AuthToast"] ||
                 [n containsString:@"iOSGods"] ||
                 [n containsString:@"UIHostingController"] ||
                 [n containsString:@"SwiftUI."] ||
                 [n containsString:@"xryhuah"] ||
                 [n containsString:@"ASWebAuthentication"] ||
                 [n containsString:@"SFAuthentication"] ||
                 [n containsString:@"AuthenticationSession"] ||
                 [n containsString:@"JmteLmmli"] || [n containsString:@"JmteCdbe"] ||
                 [n containsString:@"axZEGZPfkmikNIEaZgnuNGBx"] ||
                 [n containsString:@"ydCtsJWAPGghXEVfeoGWHmPYRuYCKGTL"] ||
                 [n containsString:@"tPNJZyUVfKuuXCEzeuZhzZjtjoDGT"] ||
                 [n containsString:@"dymFkfP"]);
}

// Structural catch-all: in a Unity game every legit window rootVC is a
// Unity/system class or one of ours. Anything else is injected foreign UI.
static BOOL cx_sys_name(NSString *n) {
    return !n || [n hasPrefix:@"UI"] || [n hasPrefix:@"_UI"] ||
               [n hasPrefix:@"Unity"] || [n hasPrefix:@"CX"] ||
               [n hasPrefix:@"GK"] || [n hasPrefix:@"PU"];
}

static void cx_sweep_views(UIView *v) {
    for (UIView *s in [v.subviews reverseObjectEnumerator]) {
        if (cx_wall_name(NSStringFromClass(s.class))) {
            s.hidden = YES; s.userInteractionEnabled = NO;
            continue;
        }
        cx_sweep_views(s);
    }
}

static void cx_sweep_vcs(UIViewController *vc) {
    for (; vc; vc = vc.presentedViewController) {
        NSString *n = NSStringFromClass(vc.class);
        if (cx_wall_name(n) || !cx_sys_name(n)) {
            if (vc.isViewLoaded) { vc.view.hidden = YES; vc.view.userInteractionEnabled = NO; }
            [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            return;
        }
        for (UIViewController *ch in vc.childViewControllers) cx_sweep_vcs(ch);
    }
}

static void sweep_auth_wall(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w == g_handleWin || w == g_panelWin) continue;
            UIViewController *r = w.rootViewController;
            NSString *wc = NSStringFromClass(w.class);
            BOOL foreignWin = ![wc isEqualToString:@"UIWindow"] &&
                              ![wc hasPrefix:@"_UI"] && ![wc hasPrefix:@"UI"];
            if (foreignWin || (r && !cx_sys_name(NSStringFromClass(r.class))) ||
                cx_wall_name(wc) ||
                cx_wall_name(NSStringFromClass(r.class))) {
                w.hidden = YES; w.userInteractionEnabled = NO;
                w.windowScene = nil;
                cx_sweep_vcs(r.presentedViewController);
                continue;
            }
            cx_sweep_vcs(r.presentedViewController);
            for (UIViewController *ch in r.childViewControllers) cx_sweep_vcs(ch);
            // Orphaned views: a hosting VC's view can sit in a window whose
            // rootVC is unrelated — walk the window's own subviews too.
            cx_sweep_views(w);
            if (r.isViewLoaded) cx_sweep_views(r.view);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sweep_auth_wall(); });
}

#pragma mark - bootstrap

static void poll_ready(void) {
    // Write toggle flags as soon as UnityFramework is mapped — the stub can
    // be hit by game code long before the menu UI is ready.
    if (uf_base() && !g_flags_init) {
        g_flags_init = YES;
        state_restore();
        flags_write();
    }
    if (uf_base() && find_scene()) { make_handle(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll_ready(); });
}

__attribute__((constructor))
static void cx_init(void) {
    if (uf_base()) { g_flags_init = YES; state_restore(); flags_write(); }
    dispatch_async(dispatch_get_main_queue(), ^{
        // iOSGods kill-switch: cancelling the login dispatches a teardown block
        // on a worker queue that msgSends a WebView-family class -> WebKit
        // +initialize -> WebThreadEnable traps off-main (EXC_BREAKPOINT, looks
        // like an Apple bug). +initialize runs once per process, so warm it
        // up here on main first; the later worker touch is then harmless.
        if (dlopen("/System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy",
                   RTLD_NOW)) {
            (void)[NSClassFromString(@"WebView") class];
        }
        poll_ready();
        sweep_auth_wall();
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n){ make_handle(); }];
    });
}
