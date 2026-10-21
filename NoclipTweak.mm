// Noclip for Geometry Dash 2.205 (arm64, iOS 14+)
// Injected as @executable_path/Noclip.dylib by the repacked IPA.
//
// Hook target: PlayLayer::destroyPlayer(PlayerObject*, GameObject*)
//   file offset 0x120084, slot 159 of the PlayLayer vtable at 0x79b0a0.
// The base GJBaseGameLayer::destroyPlayer is an empty `ret` stub in this build,
// so the whole death handling lives in PlayLayer::destroyPlayer.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#include <stdint.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Noclip engine
// ---------------------------------------------------------------------------

#define GD_DESTROY_OFF   0x120084ULL
#define GD_VTABLE_OFF    0x79b0a0ULL
#define GD_VTABLE_SLOT   159

static BOOL        gEnabled = NO;
static BOOL        gBinaryOK = NO;
static uintptr_t   gImageBase = 0;
static void       *gOrigDestroyPlayer = NULL;

typedef void (*DestroyPlayerFn)(void *self, void *player, void *object);

static void noclip_destroy_player(void *self, void *player, void *object)
{
    if (gEnabled) return;           // noclip: swallow the death
    if (gOrigDestroyPlayer) ((DestroyPlayerFn)gOrigDestroyPlayer)(self, player, object);
}

static BOOL vm_protect_span(void *addr, size_t len, vm_prot_t prot, BOOL copy)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    vm_size_t span = ((vm_address_t)addr + len) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, FALSE,
                                  (vm_prot_t)(prot | (copy ? VM_PROT_COPY : 0)));
    return kr == KERN_SUCCESS;
}

static void gd_probe(void)
{
    gImageBase = (uintptr_t)_dyld_get_image_header(0);
    if (!gImageBase) return;

    uintptr_t fn = gImageBase + GD_DESTROY_OFF;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_VTABLE_SLOT * 8);
    if (*slot != (void *)fn) return;

    const unsigned char expect[4] = { 0xff, 0x43, 0x03, 0xd1 }; // sub sp, sp, #0xd0
    if (memcmp((void *)fn, expect, 4) != 0) return;

    gOrigDestroyPlayer = (void *)fn;
    gBinaryOK = YES;
}

static BOOL gd_install_vtable_hook(void)
{
    if (!gBinaryOK) return NO;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_VTABLE_SLOT * 8);
    if (*slot == (void *)&noclip_destroy_player) return YES;
    if (*slot != gOrigDestroyPlayer) return NO;
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return NO;
    *slot = (void *)&noclip_destroy_player;
    return YES;
}

static void noclip_set_enabled(BOOL on)
{
    gEnabled = on;
    NSLog(@"[noclip] enabled=%d (vtable hook only)", on);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"noclip.enabled"];
}

// ---------------------------------------------------------------------------
// Look & feel (Ascent-like dark panel, red accent)
// ---------------------------------------------------------------------------

static UIColor *NJAccent(void)   { return [UIColor colorWithRed:1.00 green:0.10 blue:0.10 alpha:1.0]; }
static UIColor *NJPanel(void)    { return [UIColor colorWithWhite:0.075 alpha:0.97]; }
static UIColor *NJCard(void)     { return [UIColor colorWithWhite:0.115 alpha:1.0]; }
static UIColor *NJLine(void)     { return [UIColor colorWithWhite:1.0 alpha:0.10]; }
static UIColor *NJText(void)     { return [UIColor colorWithWhite:1.0 alpha:1.0]; }
static UIColor *NJDim(void)      { return [UIColor colorWithWhite:1.0 alpha:0.42]; }
static UIColor *NJFaint(void)    { return [UIColor colorWithWhite:1.0 alpha:0.28]; }

static UILabel *NJLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color, CGFloat kern)
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = color;
    label.numberOfLines = 1;
    if (kern != 0.0) {
        label.attributedText = [[NSAttributedString alloc] initWithString:text
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:size weight:weight],
                NSForegroundColorAttributeName: color,
                NSKernAttributeName: @(kern)
            }];
    } else {
        label.font = [UIFont systemFontOfSize:size weight:weight];
        label.text = text;
    }
    return label;
}

// ---------------------------------------------------------------------------
// Pass-through container (hosted inside the game's own window, so it inherits
// the landscape bounds and never rotates independently)
// ---------------------------------------------------------------------------

@interface NJPassView : UIView
@end

@implementation NJPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;   // empty area: let the game receive the touch
    return hit;
}
@end

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------

@interface NJMenuController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *trigger;
@property (nonatomic, strong) UILabel *triggerLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *panelHeader;
@property (nonatomic, strong) UIView *sidebar;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *indicator;
@property (nonatomic, strong) UIButton *tabNoclip;
@property (nonatomic, strong) UIButton *tabMisc;
@property (nonatomic, strong) UIView *pageNoclip;
@property (nonatomic, strong) UIView *pageMisc;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, assign) NSInteger tab;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL draggingTrigger;
@property (nonatomic, assign) BOOL draggingPanel;
- (void)layoutMenu;
@end

@implementation NJMenuController

@synthesize panelVisible = _panelVisible;

- (void)loadView
{
    NJPassView *container = [[NJPassView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    container.backgroundColor = [UIColor clearColor];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = container;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.userInteractionEnabled = YES;
    [self buildTrigger];
    [self buildPanel];
    [self selectTab:0];
    self.panel.alpha = 0.0;
    self.panel.hidden = YES;
    self.panelVisible = NO;
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutMenu];
}

- (void)layoutMenu
{
    CGRect bounds = self.view.bounds;
    CGFloat w = bounds.size.width;
    CGFloat h = bounds.size.height;

    if (!self.draggingTrigger) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        CGFloat bx = [d objectForKey:@"noclip.bx"] ? [d doubleForKey:@"noclip.bx"] : 0.93;
        CGFloat by = [d objectForKey:@"noclip.by"] ? [d doubleForKey:@"noclip.by"] : 0.50;
        CGPoint c = CGPointMake(bx * w, by * h);
        self.trigger.center = [self clampTrigger:c inBounds:bounds];
    }

    if (!self.draggingPanel) {
        self.panel.center = CGPointMake(w / 2.0, h / 2.0);
        if (self.panelVisible) self.panel.center = [self clampPanel:self.panel.center inBounds:bounds];
    }
}

- (void)buildTrigger
{
    CGFloat side = 34.0;
    self.trigger = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    self.trigger.backgroundColor = [UIColor clearColor];
    self.trigger.layer.cornerRadius = 17.0;
    self.trigger.layer.masksToBounds = YES;
    self.trigger.layer.borderWidth = 1.0;
    self.trigger.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    self.trigger.userInteractionEnabled = YES;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = CGRectMake(0, 0, side, side);
    grad.colors = @[ (id)[UIColor colorWithWhite:0.52 alpha:1.0].CGColor,
                     (id)[UIColor colorWithWhite:0.29 alpha:1.0].CGColor ];
    grad.startPoint = CGPointMake(0.5, 0.0);
    grad.endPoint = CGPointMake(0.5, 1.0);
    [self.trigger.layer insertSublayer:grad atIndex:0];

    self.triggerLabel = NJLabel(@"N", 14.0, UIFontWeightHeavy, [UIColor whiteColor], 0.0);
    self.triggerLabel.textAlignment = NSTextAlignmentCenter;
    self.triggerLabel.frame = self.trigger.bounds;
    self.triggerLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.trigger addSubview:self.triggerLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(triggerTapped:)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(triggerPanned:)];
    tap.delegate = self;
    pan.delegate = self;
    [tap requireGestureRecognizerToFail:pan];
    [self.trigger addGestureRecognizer:tap];
    [self.trigger addGestureRecognizer:pan];

    [self.view addSubview:self.trigger];
}

- (void)buildPanel
{
    CGFloat pw = 332.0;
    CGFloat ph = 208.0;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    self.panel.backgroundColor = NJPanel();
    self.panel.layer.cornerRadius = 16.0;
    self.panel.layer.borderWidth = 1.0;
    self.panel.layer.borderColor = NJLine().CGColor;
    self.panel.userInteractionEnabled = YES;

    // Header
    self.panelHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 50)];
    self.panelHeader.backgroundColor = [UIColor clearColor];
    [self.panel addSubview:self.panelHeader];

    UILabel *title = NJLabel(@"noclip", 14.0, UIFontWeightHeavy, NJText(), 0.6);
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, 12, pw, 18);
    [self.panelHeader addSubview:title];

    UILabel *sub = NJLabel(@"geometry dash 2.205", 8.0, UIFontWeightMedium, NJFaint(), 1.1);
    sub.textAlignment = NSTextAlignmentCenter;
    sub.frame = CGRectMake(0, 31, pw, 11);
    [self.panelHeader addSubview:sub];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pw - 40, 8, 32, 32);
    close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [close setTitle:@"\u00d7" forState:UIControlStateNormal];
    [close setTitleColor:NJDim() forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.panelHeader addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPanned:)];
    pan.delegate = self;
    [self.panelHeader addGestureRecognizer:pan];

    // Sidebar (vertical tab rail, Ascent style)
    self.sidebar = [[UIView alloc] initWithFrame:CGRectMake(10, 56, 82, ph - 68)];
    self.sidebar.backgroundColor = NJCard();
    self.sidebar.layer.cornerRadius = 10.0;
    [self.panel addSubview:self.sidebar];

    self.tabNoclip = [self makeTab:@"Noclip" tag:0];
    self.tabMisc   = [self makeTab:@"Misc"   tag:1];
    [self.sidebar addSubview:self.tabNoclip];
    [self.sidebar addSubview:self.tabMisc];

    self.indicator = [[UIView alloc] initWithFrame:CGRectZero];
    self.indicator.backgroundColor = NJAccent();
    self.indicator.layer.cornerRadius = 1.5;
    [self.sidebar addSubview:self.indicator];

    // Content card
    self.content = [[UIView alloc] initWithFrame:CGRectMake(100, 56, pw - 110, ph - 68)];
    self.content.backgroundColor = NJCard();
    self.content.layer.cornerRadius = 10.0;
    self.content.clipsToBounds = YES;
    [self.panel addSubview:self.content];

    [self buildNoclipPage];
    [self buildMiscPage];

    [self.view addSubview:self.panel];
}

- (UIButton *)makeTab:(NSString *)text tag:(NSInteger)tag
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 8 + tag * 34, 82, 30);
    button.tag = 200 + tag;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 0);
    button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [button setTitle:text forState:UIControlStateNormal];
    [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildNoclipPage
{
    self.pageNoclip = [[UIView alloc] initWithFrame:self.content.bounds];
    self.pageNoclip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.content addSubview:self.pageNoclip];

    UILabel *title = NJLabel(@"Enable", 14.0, UIFontWeightSemibold, NJText(), 0.0);
    title.frame = CGRectMake(14, 15, 150, 18);
    [self.pageNoclip addSubview:title];

    UILabel *sub = NJLabel(@"pass through obstacles and spikes", 9.5, UIFontWeightRegular, NJDim(), 0.1);
    sub.frame = CGRectMake(14, 35, 160, 13);
    [self.pageNoclip addSubview:sub];

    self.toggle = [[UISwitch alloc] initWithFrame:CGRectMake(self.content.bounds.size.width - 65, 16, 51, 31)];
    self.toggle.onTintColor = NJAccent();
    self.toggle.thumbTintColor = [UIColor whiteColor];
    self.toggle.on = gEnabled;
    [self.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    self.toggle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.pageNoclip addSubview:self.toggle];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, 62, self.content.bounds.size.width - 28, 1)];
    line.backgroundColor = NJLine();
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.pageNoclip addSubview:line];

    UILabel *note = NJLabel(@"the player no longer dies on impact", 9.5, UIFontWeightRegular, NJFaint(), 0.0);
    note.frame = CGRectMake(14, 74, self.content.bounds.size.width - 28, 13);
    note.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.pageNoclip addSubview:note];
}

- (void)buildMiscPage
{
    self.pageMisc = [[UIView alloc] initWithFrame:self.content.bounds];
    self.pageMisc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.pageMisc.hidden = YES;
    [self.content addSubview:self.pageMisc];

    UILabel *title = NJLabel(@"Reset position", 14.0, UIFontWeightSemibold, NJText(), 0.0);
    title.frame = CGRectMake(14, 15, 170, 18);
    [self.pageMisc addSubview:title];

    UILabel *sub = NJLabel(@"move the button back to the edge", 9.5, UIFontWeightRegular, NJDim(), 0.1);
    sub.frame = CGRectMake(14, 35, 180, 13);
    [self.pageMisc addSubview:sub];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(14, 60, 120, 30);
    reset.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    reset.layer.cornerRadius = 8.0;
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    [reset setTitleColor:NJText() forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    [reset addTarget:self action:@selector(resetTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.pageMisc addSubview:reset];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, 100, self.content.bounds.size.width - 28, 1)];
    line.backgroundColor = NJLine();
    [self.pageMisc addSubview:line];

    UILabel *hint = NJLabel(@"drag the N button anywhere", 9.5, UIFontWeightRegular, NJFaint(), 0.0);
    hint.frame = CGRectMake(14, 110, self.content.bounds.size.width - 28, 13);
    [self.pageMisc addSubview:hint];
}

- (void)selectTab:(NSInteger)tab
{
    self.tab = tab;
    BOOL noclip = (tab == 0);
    self.pageNoclip.hidden = !noclip;
    self.pageMisc.hidden = noclip;
    [self.tabNoclip setTitleColor:(noclip ? NJText() : NJDim()) forState:UIControlStateNormal];
    [self.tabMisc setTitleColor:(noclip ? NJDim() : NJText()) forState:UIControlStateNormal];
    [self.sidebar bringSubviewToFront:self.indicator];
    [UIView animateWithDuration:0.16 animations:^{
        self.indicator.frame = CGRectMake(3, (noclip ? 8 : 42) + 6, 3, 18);
    }];
}

- (void)tabTapped:(UIButton *)sender
{
    [self selectTab:sender.tag - 200];
}

- (void)toggleChanged:(UISwitch *)sender
{
    noclip_set_enabled(sender.isOn);
}

- (void)resetTapped:(id)sender
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:0.93 forKey:@"noclip.bx"];
    [d setDouble:0.50 forKey:@"noclip.by"];
    CGRect b = self.view.bounds;
    self.trigger.center = [self clampTrigger:CGPointMake(b.size.width * 0.93, b.size.height * 0.50) inBounds:b];
}

- (void)closeTapped:(id)sender
{
    [self setPanelVisible:NO];
}

- (void)setPanelVisible:(BOOL)visible
{
    if (_panelVisible == visible) return;
    _panelVisible = visible;
    if (visible) {
        self.panel.hidden = NO;
        self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
        self.panel.alpha = 0.0;
        [self.view bringSubviewToFront:self.panel];
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            self.panel.alpha = 0.0;
            self.panel.transform = CGAffineTransformMakeScale(0.97, 0.97);
        } completion:^(BOOL done) {
            self.panel.hidden = YES;
            self.panel.transform = CGAffineTransformIdentity;
        }];
    }
}

- (void)triggerTapped:(id)sender
{
    [self setPanelVisible:!self.panelVisible];
}

- (void)triggerPanned:(UIPanGestureRecognizer *)pan
{
    CGPoint t = [pan translationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.draggingTrigger = YES;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.trigger.center.x + t.x, self.trigger.center.y + t.y);
        self.trigger.center = [self clampTrigger:c inBounds:self.view.bounds];
        [pan setTranslation:CGPointZero inView:self.view];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.draggingTrigger = NO;
        CGRect b = self.view.bounds;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setDouble:(b.size.width  > 0 ? self.trigger.center.x / b.size.width  : 0.93) forKey:@"noclip.bx"];
        [d setDouble:(b.size.height > 0 ? self.trigger.center.y / b.size.height : 0.50) forKey:@"noclip.by"];
    }
}

- (void)panelPanned:(UIPanGestureRecognizer *)pan
{
    CGPoint t = [pan translationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.draggingPanel = YES;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y);
        self.panel.center = [self clampPanel:c inBounds:self.view.bounds];
        [pan setTranslation:CGPointZero inView:self.view];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.draggingPanel = NO;
    }
}

- (CGPoint)clampTrigger:(CGPoint)c inBounds:(CGRect)b
{
    CGFloat half = 17.0;
    CGFloat margin = 6.0;
    CGFloat minX = margin + half, maxX = b.size.width  - margin - half;
    CGFloat minY = margin + half, maxY = b.size.height - margin - half;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    c.x = MIN(MAX(c.x, minX), maxX);
    c.y = MIN(MAX(c.y, minY), maxY);
    return c;
}

- (CGPoint)clampPanel:(CGPoint)c inBounds:(CGRect)b
{
    CGFloat hw = self.panel.bounds.size.width / 2.0;
    CGFloat hh = self.panel.bounds.size.height / 2.0;
    CGFloat minX = hw + 6.0, maxX = b.size.width - hw - 6.0;
    CGFloat minY = hh + 6.0, maxY = b.size.height - hh - 6.0;
    if (maxX < minX) { c.x = b.size.width / 2.0; } else { c.x = MIN(MAX(c.x, minX), maxX); }
    if (maxY < minY) { c.y = b.size.height / 2.0; } else { c.y = MIN(MAX(c.y, minY), maxY); }
    return c;
}

@end

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

static NJMenuController *gController = nil;

static void NJInstallMenu(void)
{
    if (gController) return;

    // Wait for the game's own landscape window; hosting the overlay there makes
    // it inherit the exact bounds and keeps panning in the same coordinate space.
    UIWindow *host = [UIApplication sharedApplication].keyWindow;
    if (!host || host.hidden || host.bounds.size.width <= host.bounds.size.height) {
        host = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.bounds.size.width > w.bounds.size.height) { host = w; break; }
        }
    }
    if (!host || host.bounds.size.width <= host.bounds.size.height) return;

    gController = [[NJMenuController alloc] initWithNibName:nil bundle:nil];
    UIView *menu = gController.view;
    menu.frame = host.bounds;
    menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:menu];
    [host bringSubviewToFront:menu];
    [gController layoutMenu];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w && gController) {
            gController.view.frame = w.bounds;
            [gController layoutMenu];
        }
    }];
}

static void noclip_boot(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            gImageBase = (uintptr_t)_dyld_get_image_header(0);
            gEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"noclip.enabled"];

            dispatch_async(dispatch_get_main_queue(), ^{
                gd_probe();
                BOOL hooked = gd_install_vtable_hook();
                NSLog(@"[noclip] probe=%d vtableHook=%d enabled=%d", gBinaryOK, hooked, gEnabled);

                __block NSInteger tries = 0;
                void (^tryInstall)(void) = ^{
                    NJInstallMenu();
                    if (!gController && ++tries < 120) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), tryInstall);
                    }
                };
                tryInstall();
            });
        }
    });
}

__attribute__((constructor))
static void noclip_ctor(void)
{
    noclip_boot();
}

// +load is the most portable early entry point for an injected dylib:
// it does not depend on __init_offsets/__mod_init_func support in dyld.
@interface NJBootstrap : NSObject
@end

@implementation NJBootstrap
+ (void)load
{
    noclip_boot();
}
@end

