// SMMenu.dylib — custom cheat menu for Soccer Manager 2027 iOS (4.1.8)
// Injected via LC_LOAD_DYLIB into the SM27 executable.
// Floating mini button -> action panel -> direct calls into IL2CPP methods.
//
// Every feature is the game's OWN ad-reward path: AdMobRewardsController
// .get_Instance() -> adRewardsManager field -> Give*Reward() methods —
// the same functions invoked after a watched rewarded ad. No patching;
// we invoke the managed methods directly at their dumped RVAs.
// Player-scoped rewards read AdRewardsManager.playerId (+0x20) first.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
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

#pragma mark - Managed-call engine (direct IL2CPP method invokes)

// IL2CPP methods are plain C functions; the compiler appends an extra
// `const MethodInfo*` parameter (may be NULL) and instance methods take
// `this` as arg0. VAs below are UnityFramework image offsets from the
// 4.1.8 dump (see SM27-FINDINGS.md).
#define SMVA(off) ((void *)(uf_base() + (off)))

typedef void *(*fn_i_t)(void *);                            // (info) -> obj
typedef void  (*fn_v_t)(void *, void *);                    // (this, info)
typedef void *(*fn_s_t)(short, void *);                     // (short, info) -> obj
typedef void  (*fn_pi_t)(void *, int, void *);              // (this, int, info)
typedef void  (*fn_pip_t)(void *, int, void *, void *);     // (this,int,ptr,info)
typedef void  (*fn_fp_t)(float, void *, void *);            // (float,ptr,info) static

// AdMobRewardsController.get_Instance() -> +0x48 adRewardsManager
static void *sm_mgr(void) {
    if (!uf_base()) return NULL;
    void *c = ((fn_i_t)SMVA(0x29FE794))(NULL);
    return c ? *(void **)((char *)c + 0x48) : NULL;
}

// Squad traversal: Club.GetCurrentUserClubID() -> PlayerSquad.GetPlayers(id)
// -> players list @ +0x18; List layout: _items array @ +0x10 (elements at
// array+0x20), _size @ +0x18. Returns element pointer array; count via nOut.
static void **sm_players(int *nOut) {
    *nOut = 0;
    if (!uf_base()) return NULL;
    short cid = (short)(uintptr_t)((fn_i_t)SMVA(0x27F7150))(NULL); // GetCurrentUserClubID
    if (cid <= 0) return NULL;
    void *squad = ((fn_s_t)SMVA(0x2D035F0))(cid, NULL);
    if (!squad) return NULL;
    void *list = *(void **)((char *)squad + 0x18);
    if (!list) return NULL;
    int n = *(int *)((char *)list + 0x18);
    void *arr = *(void **)((char *)list + 0x10);
    if (!arr || n <= 0 || n > 200) return NULL;
    *nOut = n;
    return (void **)((char *)arr + 0x20);
}

// PlayerData: PersonData.Id @ +0x10, Forename @ +0x18, Surname @ +0x20
// (Il2CppString: length @ +0x10, UTF-16 chars @ +0x14)
static int sm_pid(void *p) { return p ? *(int *)((char *)p + 0x10) : 0; }
static NSString *sm_str(void *s) {
    if (!s) return @"?";
    int len = *(int *)((char *)s + 0x10);
    if (len <= 0 || len > 48) return @"?";
    return [[NSString alloc] initWithCharacters:(unichar *)((char *)s + 0x14) length:len];
}
static NSString *sm_pname(void *p) {
    if (!p) return @"?";
    return [NSString stringWithFormat:@"%@ %@",
        sm_str(*(void **)((char *)p + 0x18)), sm_str(*(void **)((char *)p + 0x20))];
}

// Target player: -1 = auto (first squad player). Tap cycles the squad.
static int g_pidx = -1;
static int sm_target_pid(int *outIdx) {
    int n = 0; void **ps = sm_players(&n);
    if (!ps || n <= 0) return 0;
    int i = (g_pidx < 0 || g_pidx >= n) ? 0 : g_pidx;
    if (outIdx) *outIdx = i;
    return sm_pid(ps[i]);
}

typedef struct {
    const char *name;
    const char *icon;
    uintptr_t va;
    BOOL player;          // uses mgr->playerId
} act_t;
static const act_t g_squad[] = {   // club/squad-scoped rewards
    {"Cash Injection",   "banknote.fill",        0x2A02D40, NO},
    {"Team Fitness",     "heart.fill",           0x2A02A84, NO},
    {"Facility Reduce",  "hammer.fill",          0x2A02088, NO},
    {"Stadium Reduce",   "sportscourt.fill",     0x2A030F0, NO},
    {"Suspension Boost", "pause.circle.fill",    0x2A026C4, NO},
    {"Scout Report",     "magnifyingglass",      0x2A02CD8, NO},
    {"Profile Scout",    "person.crop.rectangle",0x2A02C70, NO},
};
static const act_t g_player[] = {  // playerId-scoped rewards
    {"Training",         "figure.run",           0x2A02EF4, YES},
    {"Chemistry",        "link",                 0x2A027B4, YES},
    {"Heal",             "cross.case.fill",      0x2A025A4, YES},
    {"Fitness Boost",    "bolt.heart.fill",      0x2A023EC, YES},
    {"Morale Boost",     "face.smiling.fill",    0x2A02234, YES},
    {"Pre-match Boost",  "flame.fill",           0x2A01EEC, YES},
};
#define NACT_S 7
#define NACT_P 6

// Fire a Give*Reward on AdRewardsManager. Player-scoped rewards write
// playerId first; playerId=0 risks a null player deref inside the game,
// so they refuse to fire without a resolved target.
static NSString *sm_give(const act_t *a) {
    void *m = sm_mgr();
    if (!m) return @"Rewards not ready — get in-game first";
    if (a->player) {
        int pid = sm_target_pid(NULL);
        if (!pid) return @"No squad loaded — pick a save first";
        *(int *)((char *)m + 0x20) = pid;
    }
    ((fn_v_t)SMVA(a->va))(m, NULL);
    return nil;
}

// CustomerDataController.Instance — Unity-6 il2cpp stores class statics
// behind the runtime class object: *(uf+0x84906F0) = Il2CppClass*,
// +0xb8 = static_fields, and Instance sits at statics+0x48 (dump field
// offset 0x48; verified: Awake stores `this` via str x19,[x8,#0x48]).
static void *sm_cdc(void) {
    if (!uf_base()) return NULL;
    void *cls = *(void **)((char *)uf_base() + 0x84906F0);
    if (!cls) return NULL;
    void *stat = *(void **)((char *)cls + 0xb8);
    return stat ? *(void **)((char *)stat + 0x48) : NULL;
}
// cdc->CustomerDataHolder(+0x20)->CustomerData(+0x10): gold@+0xb8,
// boosts@+0x108, cashTokens@+0x48, traits@+0xd4; +0x10 = SpecialEditionStatus
// (enhanced@+0x10, ultimate/VIP@+0x11), +0xe0->+0x64 = XP (from getters).
static void *sm_cdata(void) {
    void *c = sm_cdc();
    if (!c) return NULL;
    void *h = *(void **)((char *)c + 0x20);
    return h ? *(void **)((char *)h + 0x10) : NULL;
}
// 0=+10k gold (AddCredits fires OnCreditBalanceChanged) 1=boosts
// 2=cash tokens 3=traits 4=XP 5=VIP+Enhanced flags
static NSString *sm_wealth(int which) {
    void *cdc = sm_cdc();
    if (!cdc) return @"Account not loaded — get in-game first";
    void *d = sm_cdata();
    if (!d) return @"Customer data not ready yet";
    switch (which) {
        case 0: ((fn_pi_t)SMVA(0x2A18808))(cdc, 10000, NULL); break; // AddCredits
        case 1: ((fn_pi_t)SMVA(0x2A188A4))(cdc, 999, NULL);   break; // SetCurUserBoostAmount
        case 2: ((fn_pi_t)SMVA(0x2A18938))(cdc, 999, NULL);   break; // SetCashTokenAmount
        case 3: ((fn_pi_t)SMVA(0x2A189CC))(cdc, 99, NULL);    break; // SetManagerTraitPointsAmount
        case 4: {
            void *xp = *(void **)((char *)d + 0xe0);
            if (!xp) return @"XP data not ready yet";
            *(int *)((char *)xp + 0x64) = 1000000;
            ((fn_pi_t)SMVA(0x2A18808))(cdc, 0, NULL); // AddCredits(0): fire OnCreditBalanceChanged
            break;
        }
        case 5: {
            void *se = *(void **)((char *)d + 0x10);
            if (!se) return @"Edition data not ready yet";
            ((char *)se)[0x10] = 1;  // IsEnhancedEditionUser
            ((char *)se)[0x11] = 1;  // IsUltimateEditionUser == IsVIPUser
            ((fn_pi_t)SMVA(0x2A18808))(cdc, 0, NULL);
            break;
        }
    }
    return nil;
}

// Max-all: iterate the squad list and apply the stat method per player.
static int sm_maxall(int which) { // 0=fitness 1=morale 2=chemistry
    int n = 0; void **ps = sm_players(&n);
    if (!ps) return -1;
    for (int i = 0; i < n; i++) {
        void *p = ps[i];
        if (!p) continue;
        if (which == 0)      ((fn_pi_t) SMVA(0x2888C78))(p, 100, NULL);      // SetFitness
        else if (which == 1) ((fn_pip_t)SMVA(0x28896D4))(p, 20, NULL, NULL); // ApplyMoraleBoost
        else                 ((fn_fp_t) SMVA(0x27D8C44))(1.0f, p, NULL);     // ApplyTeamChemistryIncrease
    }
    return n;
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
    title.text = @"SOCCER MANAGER 27";
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

    _sub.text = @"Ad-reward methods, fired directly";

    y = [self section:@"Club" icon:@"building.2.fill" y:y];
    y = [self grid:g_squad n:NACT_S base:3000 y:y bw:bw];

    y = [self section:@"Player" icon:@"person.fill" y:y];
    {
        // Target selector — full-width row; tap cycles the squad.
        CXButton *tb = [CXButton buttonWithType:UIButtonTypeCustom];
        tb.frame = CGRectMake(0, y, w, 40);
        tb.layer.cornerRadius = DRE_RADIUS;
        tb.layer.cornerCurve = kCACornerCurveContinuous;
        [self paintTarget:tb];
        [tb addTarget:self action:@selector(targetBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:tb];
        y += 46;
    }
    y = [self grid:g_player n:NACT_P base:3100 y:y bw:bw];

    y = [self section:@"Squad Max" icon:@"arrow.up.to.line" y:y];
    {
        const char *names[] = {"All Fitness", "All Morale", "All Chemistry"};
        const char *icons[] = {"heart.fill", "face.smiling.fill", "link"};
        for (int i = 0; i < 3; i++) {
            CXButton *b = [CXButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(i % 2 ? bw + 10 : 0, y, bw, 40);
            b.layer.cornerRadius = DRE_RADIUS;
            b.layer.cornerCurve = kCACornerCurveContinuous;
            b.tag = 3200 + i;
            b.backgroundColor = DRE_FILL;
            [b setImage:dre_symbol(@(icons[i]), 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
            b.tintColor = DRE_SUB;
            b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
            [b setTitle:[NSString stringWithFormat:@" %s", names[i]] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
            [b addTarget:self action:@selector(maxBtn:) forControlEvents:UIControlEventTouchUpInside];
            [_scroll addSubview:b];
            if (i % 2) y += 46;
        }
        y += 52;
    }

    y = [self section:@"Wealth" icon:@"banknote.fill" y:y];
    {
        const char *names[] = {"+10k Gold", "999 Boosts", "999 Tokens", "99 Traits", "Max XP", "Unlock VIP"};
        const char *icons[] = {"dollarsign.circle.fill", "bolt.fill", "ticket.fill", "star.fill", "chart.line.uptrend.xyaxis", "crown.fill"};
        for (int i = 0; i < 6; i++) {
            CXButton *b = [CXButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(i % 2 ? bw + 10 : 0, y, bw, 40);
            b.layer.cornerRadius = DRE_RADIUS;
            b.layer.cornerCurve = kCACornerCurveContinuous;
            b.tag = 3300 + i;
            b.backgroundColor = DRE_FILL;
            [b setImage:dre_symbol(@(icons[i]), 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
            b.tintColor = (i >= 4) ? DRE_BLUE : DRE_SUB;
            b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
            [b setTitle:[NSString stringWithFormat:@" %s", names[i]] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
            [b addTarget:self action:@selector(wealthBtn:) forControlEvents:UIControlEventTouchUpInside];
            [_scroll addSubview:b];
            if (i % 2) y += 46;
        }
        y += 52;
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

// Two-column action-button grid; returns the y after it.
- (CGFloat)grid:(const act_t *)acts n:(int)n base:(int)base y:(CGFloat)y bw:(CGFloat)bw {
    int col = 0;
    for (int i = 0; i < n; i++) {
        CXButton *b = [CXButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(col ? bw + 10 : 0, y, bw, 40);
        b.layer.cornerRadius = DRE_RADIUS;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.tag = base + i;
        [self paintAct:b act:&acts[i]];
        [b addTarget:self action:@selector(actBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        if (col) y += 46;
        col = (col + 1) % 2;
    }
    return y + (col ? 46 : 0) + 6;
}

- (void)paintAct:(UIButton *)b act:(const act_t *)a {
    b.backgroundColor = DRE_FILL;
    [b setImage:dre_symbol(@(a->icon), 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    b.tintColor = a->player ? DRE_BLUE : DRE_SUB;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    [b setTitle:[NSString stringWithFormat:@" %s", a->name] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
}

- (void)actBtn:(UIButton *)b {
    dre_tick();
    const act_t *a = (b.tag < 3100) ? &g_squad[b.tag - 3000] : &g_player[b.tag - 3100];
    NSString *err = sm_give(a);
    if (!err) {
        [self toast:[NSString stringWithFormat:@"%s fired", a->name]];
    } else {
        dre_notify(UINotificationFeedbackTypeError);
        [self toast:err icon:@"exclamationmark.triangle.fill" tint:DRE_RED];
    }
}

// Target selector: shows the player that playerId-scoped rewards will hit.
- (void)paintTarget:(UIButton *)b {
    b.backgroundColor = [DRE_BLUE colorWithAlphaComponent:0.16];
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [DRE_BLUE colorWithAlphaComponent:0.5].CGColor;
    [b setImage:dre_symbol(@"person.crop.circle", 13, UIImageSymbolWeightMedium) forState:UIControlStateNormal];
    b.tintColor = DRE_BLUE;
    b.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    NSString *label = @"Target: auto (first squad player)";
    int n = 0; void **ps = sm_players(&n);
    if (ps && n > 0) {
        int i = (g_pidx < 0 || g_pidx >= n) ? 0 : g_pidx;
        label = [NSString stringWithFormat:@"Target: %@%@", sm_pname(ps[i]),
                 (g_pidx < 0) ? @" (auto)" : @""];
    } else {
        label = @"Target: — (no squad yet)";
    }
    [b setTitle:[NSString stringWithFormat:@" %@", label] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [b setTitleColor:DRE_TEXT forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
}

- (void)targetBtn:(UIButton *)b {
    dre_tick();
    int n = 0; sm_players(&n);
    if (n <= 0) { [self toast:@"No squad loaded" icon:@"exclamationmark.triangle.fill" tint:DRE_RED]; return; }
    g_pidx = (g_pidx + 1 > n - 1) ? -1 : g_pidx + 1;   // wrap to auto
    [UIView transitionWithView:b duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ [self paintTarget:b]; } completion:nil];
}

- (void)maxBtn:(UIButton *)b {
    dre_tick();
    int which = (int)b.tag - 3200;
    int n = sm_maxall(which);
    const char *what[] = {"fitness", "morale", "chemistry"};
    if (n > 0) {
        [self toast:[NSString stringWithFormat:@"%s maxed on %d players", what[which], n]];
    } else {
        dre_notify(UINotificationFeedbackTypeError);
        [self toast:n == 0 ? @"Squad empty" : @"Squad not loaded — get in-game first"
               icon:@"exclamationmark.triangle.fill" tint:DRE_RED];
    }
}

- (void)wealthBtn:(UIButton *)b {
    dre_tick();
    int which = (int)b.tag - 3300;
    NSString *err = sm_wealth(which);
    if (!err) {
        const char *what[] = {"+10k gold", "boosts set to 999", "tokens set to 999", "traits set to 99", "XP maxed", "VIP + Enhanced unlocked"};
        [self toast:[NSString stringWithFormat:@"%s — check balance", what[which]]];
    } else {
        dre_notify(UINotificationFeedbackTypeError);
        [self toast:err icon:@"exclamationmark.triangle.fill" tint:DRE_RED];
    }
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
        CGFloat ph = MIN(460, sb.size.height - 32);
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
                    setObject:@[@(f.origin.x), @(f.origin.y)] forKey:@"sm_dotpos"];
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
    NSArray *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"sm_dotpos"];
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

    UIImageView *t = [[UIImageView alloc] initWithImage:dre_symbol(@"soccerball", 20, UIImageSymbolWeightSemibold)];
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
    if (uf_base() && find_scene()) { make_handle(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll_ready(); });
}

__attribute__((constructor))
static void sm_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        poll_ready();
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n){ make_handle(); }];
    });
}
