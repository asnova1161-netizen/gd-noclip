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
#include <math.h>

// ---------------------------------------------------------------------------
// Noclip engine
// ---------------------------------------------------------------------------

#define GD_DESTROY_OFF   0x120084ULL
#define GD_VTABLE_OFF    0x79b0a0ULL
#define GD_VTABLE_SLOT   159

#define GD_UPDATE_OFF    0x202c74ULL
#define GD_UPDATE_SLOT   5

#define GD_RESET_OFF     0x11a550ULL
#define GD_PLAYER_RESET_OFF 0x22f3d4ULL
#define GD_RESTART_FLAG  0x367e
#define GD_PLAYER_DEAD   0x9da
#define GD_LAYER_DYING   0x30a2

#define GD_SPEED_MIN     0.1f
#define GD_SPEED_MAX     100.0f

static BOOL        gEnabled = NO;
static BOOL        gAutoRestart = NO;
static BOOL        gBinaryOK = NO;
static BOOL        gResetOK = NO;
static BOOL        gPlayerResetOK = NO;
static BOOL        gResetting = NO;
static BOOL        gResetRequested = NO;
static void       *gResetLayer = NULL;
static CFTimeInterval gLastReset = 0.0;
static CFTimeInterval gNoRestartUntil = 0.0;
static uintptr_t   gImageBase = 0;
static void       *gOrigDestroyPlayer = NULL;
static void       *gOrigUpdate = NULL;
static float       gSpeed = 1.0f;
static float       gCurrentSpeed = 1.0f;

typedef void (*DestroyPlayerFn)(void *self, void *player, void *object);
typedef void (*UpdateFn)(void *self, float dt);
typedef void (*ResetLevelFn)(void *self);
typedef void (*PlayerResetFn)(void *player);

static float NJSpeedToSlider(float speed)
{
    if (speed < GD_SPEED_MIN) speed = GD_SPEED_MIN;
    if (speed > GD_SPEED_MAX) speed = GD_SPEED_MAX;
    return logf(speed / GD_SPEED_MIN) / logf(GD_SPEED_MAX / GD_SPEED_MIN);
}

static float NJSliderToSpeed(float value)
{
    if (value < 0.0f) value = 0.0f;
    if (value > 1.0f) value = 1.0f;
    float speed = GD_SPEED_MIN * powf(GD_SPEED_MAX / GD_SPEED_MIN, value);
    if (speed < GD_SPEED_MIN) speed = GD_SPEED_MIN;
    if (speed > GD_SPEED_MAX) speed = GD_SPEED_MAX;
    return speed;
}

static NSString *NJSpeedText(float speed)
{
    if (speed < 10.0f) return [NSString stringWithFormat:@"%.2f\u00d7", speed];
    return [NSString stringWithFormat:@"%.0f\u00d7", speed];
}

static void noclip_destroy_player(void *self, void *player, void *object)
{
    if (gEnabled) return;           // noclip: swallow the death
    if (gResetting) return;         // ignore deaths caused by our own reset

    // Detect whether this is a fresh death. If the player is already dead (or
    // the layer is already in its death sequence), this call is a replay of an
    // old death (for example from resetLevel), not a new one. Never arm an
    // instant respawn for those, otherwise enabling the toggle can start a
    // reset loop.
    void *player1 = *(void **)((char *)self + 0xc90);
    BOOL wasDead = player1 && *(uint8_t *)((char *)player1 + GD_PLAYER_DEAD);
    BOOL wasDying = *(uint8_t *)((char *)self + GD_LAYER_DYING);

    if (gOrigDestroyPlayer) ((DestroyPlayerFn)gOrigDestroyPlayer)(self, player, object);

    if (!gOrigDestroyPlayer || !gAutoRestart || !gResetOK) return;
    if (gResetting || gResetRequested || wasDead || wasDying) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now < gNoRestartUntil) return;
    if (now - gLastReset < 0.10) return;

    // The game schedules its own auto-retry (the +0x367e flag) after a death.
    // We perform the reset ourselves on the next PlayLayer update and clear
    // that flag there, so the delayed retry cannot reset the level a second
    // time after we have already respawned the player.
    gResetLayer = self;
    gResetRequested = YES;
}

static void noclip_update(void *self, float dt)
{
    if (!gOrigUpdate) return;

    if (gResetRequested) {
        void *layer = gResetLayer;
        gResetRequested = NO;
        gResetLayer = NULL;
        if (layer == self && gAutoRestart && gResetOK && !gResetting) {
            gResetting = YES;
            CFTimeInterval now = CACurrentMediaTime();

            // destroyPlayer always arms the game's own delayed auto-retry.
            // Cancel it before and after our immediate reset: otherwise the
            // delayed callback calls resetLevel a second time, which at very
            // low speeds turns into an endless death/reset loop.
            *((uint8_t *)self + GD_RESTART_FLAG) = 0;
            ((ResetLevelFn)(gImageBase + GD_RESET_OFF))(self);
            *((uint8_t *)self + GD_RESTART_FLAG) = 0;

            // resetLevel normally resets both player objects. If the old death
            // state is still present at a slow speed, only clear the dead bit.
            // Do not call PlayerObject::reset here: that zeroes the player's
            // position and can make the freshly spawned cube die in place.
            void *p1 = *(void **)((char *)self + 0xc90);
            if (p1 && *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD) = 0;
            }
            void *p2 = *(void **)((char *)self + 0xc98);
            if (p2 && p2 != p1 && *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD) = 0;
            }

            gLastReset = now;
            // Give the new attempt a moment to settle. If something still
            // kills the player on the first frame, fall back to the game's
            // normal delayed retry instead of requesting a reset every frame.
            gNoRestartUntil = now + 0.35;
            gResetting = NO;
            return; // skip the old death update for this frame
        }
    }

    // Smoothly approach the slider value instead of snapping the game speed.
    float target = gSpeed;
    if (target < GD_SPEED_MIN || target > GD_SPEED_MAX) target = 1.0f;
    if (gCurrentSpeed < GD_SPEED_MIN || gCurrentSpeed > GD_SPEED_MAX) {
        gCurrentSpeed = target;
    }
    float realDt = dt;
    if (!isfinite(realDt) || realDt <= 0.0f) realDt = 1.0f / 60.0f;
    if (realDt > 0.25f) realDt = 0.25f;
    float blend = 1.0f - expf(-12.0f * realDt);
    if (blend < 0.0f) blend = 0.0f;
    if (blend > 1.0f) blend = 1.0f;
    gCurrentSpeed += (target - gCurrentSpeed) * blend;
    if (fabsf(target - gCurrentSpeed) < 0.0005f) gCurrentSpeed = target;

    float scale = gCurrentSpeed;
    if (scale < GD_SPEED_MIN || scale > GD_SPEED_MAX) scale = target;
    ((UpdateFn)gOrigUpdate)(self, dt * scale);
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

    void **updateSlot = (void **)(gImageBase + GD_VTABLE_OFF + GD_UPDATE_SLOT * 8);
    if (*updateSlot != (void *)(gImageBase + GD_UPDATE_OFF)) return;

    const unsigned char expect[4] = { 0xff, 0x43, 0x03, 0xd1 }; // sub sp, sp, #0xd0
    if (memcmp((void *)fn, expect, 4) != 0) return;

    gOrigDestroyPlayer = (void *)fn;
    gBinaryOK = YES;
    gResetOK = (*(uint32_t *)(gImageBase + GD_RESET_OFF) == 0xd10303ff); // sub sp, sp, #0xc0
    gPlayerResetOK = (*(uint32_t *)(gImageBase + GD_PLAYER_RESET_OFF) == 0xa9be4ff4); // stp x20,x19,[sp,#-0x20]!
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

static BOOL gd_install_update_hook(void)
{
    if (!gBinaryOK) return NO;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_UPDATE_SLOT * 8);
    if (*slot == (void *)&noclip_update) return YES;
    if (*slot != (void *)(gImageBase + GD_UPDATE_OFF)) return NO;
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return NO;
    gOrigUpdate = *slot;
    *slot = (void *)&noclip_update;
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
static UIColor *NJLine(void)     { return [UIColor colorWithWhite:1.0 alpha:0.10]; }
static UIColor *NJText(void)     { return [UIColor colorWithWhite:1.0 alpha:1.0]; }
static UIColor *NJDim(void)      { return [UIColor colorWithWhite:1.0 alpha:0.42]; }

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

@interface NJTriggerView : UIView
@end

@implementation NJTriggerView
// Slightly larger hit area than the 34pt circle, so the button is easy to grab.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return CGRectContainsPoint(CGRectInset(self.bounds, -10.0, -10.0), point);
}
@end

@interface NJMenuController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *trigger;
@property (nonatomic, strong) UILabel *triggerLabel;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *panelHeader;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UISwitch *restartToggle;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedValue;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL draggingTrigger;
@property (nonatomic, assign) BOOL draggingPanel;
@property (nonatomic, assign) CGPoint dragOffset;
@property (nonatomic, weak) UIView *hostView;
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
    UIView *host = self.hostView;
    if (host) {
        CGRect hb = host.bounds;
        if (hb.size.width > 0.0 && hb.size.height > 0.0 && !CGRectEqualToRect(self.view.frame, hb)) {
            self.view.frame = hb;
        }
    }

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
    self.trigger = [[NJTriggerView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    self.trigger.backgroundColor = [UIColor clearColor];
    self.trigger.layer.cornerRadius = 17.0;
    self.trigger.layer.masksToBounds = YES;
    self.trigger.layer.borderWidth = 1.0;
    self.trigger.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    self.trigger.layer.shouldRasterize = YES;
    self.trigger.layer.rasterizationScale = [UIScreen mainScreen].scale;
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
    tap.delaysTouchesBegan = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;
    [tap requireGestureRecognizerToFail:pan];
    [self.trigger addGestureRecognizer:tap];
    [self.trigger addGestureRecognizer:pan];

    [self.view addSubview:self.trigger];
}

- (void)buildPanel
{
    CGFloat pw = 300.0;
    CGFloat ph = 180.0;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    self.panel.backgroundColor = NJPanel();
    self.panel.layer.cornerRadius = 16.0;
    self.panel.layer.borderWidth = 1.0;
    self.panel.layer.borderColor = NJLine().CGColor;
    self.panel.userInteractionEnabled = YES;

    // Header (also the drag handle)
    self.panelHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 44)];
    self.panelHeader.backgroundColor = [UIColor clearColor];
    [self.panel addSubview:self.panelHeader];

    UILabel *title = NJLabel(@"NOCLIP", 13.0, UIFontWeightHeavy, NJText(), 1.4);
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, 13, pw, 18);
    [self.panelHeader addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(pw - 38, 6, 32, 32);
    close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [close setTitle:@"\u00d7" forState:UIControlStateNormal];
    [close setTitleColor:NJDim() forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.panelHeader addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPanned:)];
    pan.delegate = self;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;
    [self.panelHeader addGestureRecognizer:pan];

    UIView *line1 = [[UIView alloc] initWithFrame:CGRectMake(16, 44, pw - 32, 1)];
    line1.backgroundColor = NJLine();
    [self.panel addSubview:line1];

    // Noclip row
    UILabel *noclipLabel = NJLabel(@"Noclip", 13.0, UIFontWeightSemibold, NJText(), 0.0);
    noclipLabel.frame = CGRectMake(16, 56, 120, 18);
    [self.panel addSubview:noclipLabel];

    self.toggle = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 67, 50, 51, 31)];
    self.toggle.onTintColor = NJAccent();
    self.toggle.thumbTintColor = [UIColor whiteColor];
    self.toggle.on = gEnabled;
    [self.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.toggle];

    UIView *line2 = [[UIView alloc] initWithFrame:CGRectMake(16, 86, pw - 32, 1)];
    line2.backgroundColor = NJLine();
    [self.panel addSubview:line2];

    // Speedhack row
    UILabel *speedLabel = NJLabel(@"Speedhack", 12.0, UIFontWeightSemibold, NJText(), 0.0);
    speedLabel.frame = CGRectMake(16, 98, 82, 18);
    [self.panel addSubview:speedLabel];

    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(102, 91, 116, 31)];
    self.speedSlider.minimumValue = 0.0f;
    self.speedSlider.maximumValue = 1.0f;
    self.speedSlider.value = NJSpeedToSlider(gSpeed);
    self.speedSlider.minimumTrackTintColor = NJAccent();
    self.speedSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    self.speedSlider.thumbTintColor = [UIColor whiteColor];
    self.speedSlider.continuous = YES;
    [self.speedSlider addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    [self.speedSlider addTarget:self action:@selector(speedCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.panel addSubview:self.speedSlider];

    self.speedValue = NJLabel(NJSpeedText(gSpeed), 12.0, UIFontWeightSemibold, NJText(), 0.0);
    self.speedValue.textAlignment = NSTextAlignmentRight;
    self.speedValue.frame = CGRectMake(pw - 72, 98, 56, 18);
    [self.panel addSubview:self.speedValue];

    UIView *line3 = [[UIView alloc] initWithFrame:CGRectMake(16, 128, pw - 32, 1)];
    line3.backgroundColor = NJLine();
    [self.panel addSubview:line3];

    // Instant restart row
    UILabel *restartLabel = NJLabel(@"Instant Restart", 13.0, UIFontWeightSemibold, NJText(), 0.0);
    restartLabel.frame = CGRectMake(16, 140, 180, 18);
    [self.panel addSubview:restartLabel];

    self.restartToggle = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 67, 134, 51, 31)];
    self.restartToggle.onTintColor = NJAccent();
    self.restartToggle.thumbTintColor = [UIColor whiteColor];
    self.restartToggle.on = gAutoRestart;
    [self.restartToggle addTarget:self action:@selector(restartChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.restartToggle];

    [self.view addSubview:self.panel];
}

- (void)toggleChanged:(UISwitch *)sender
{
    noclip_set_enabled(sender.isOn);
}

- (void)speedChanged:(UISlider *)sender
{
    // Do not assign sender.value from inside this callback and do not snap to
    // 1.0 while the finger is down: both make the thumb jump under a slow drag.
    float value = NJSliderToSpeed(sender.value);
    gSpeed = value;
    self.speedValue.text = NJSpeedText(value);
}

- (void)speedCommitted:(UISlider *)sender
{
    [[NSUserDefaults standardUserDefaults] setFloat:gSpeed forKey:@"noclip.speed"];
}

- (void)restartChanged:(UISwitch *)sender
{
    gAutoRestart = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:gAutoRestart forKey:@"noclip.instantRestart"];
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
    CGPoint p = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.draggingTrigger = YES;
        self.dragOffset = CGPointMake(self.trigger.center.x - p.x, self.trigger.center.y - p.y);
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(p.x + self.dragOffset.x, p.y + self.dragOffset.y);
        self.trigger.center = [self clampTrigger:c inBounds:self.view.bounds];
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
    CGPoint p = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.draggingPanel = YES;
        self.dragOffset = CGPointMake(self.panel.center.x - p.x, self.panel.center.y - p.y);
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = CGPointMake(p.x + self.dragOffset.x, p.y + self.dragOffset.y);
        self.panel.center = [self clampPanel:c inBounds:self.view.bounds];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.draggingPanel = NO;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"bounds"] && object == self.hostView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self layoutMenu];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)dealloc
{
    UIView *h = self.hostView;
    if (h) [h removeObserver:self forKeyPath:@"bounds"];
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
static UIView *gHostView = nil;

static void NJInstallMenu(void)
{
    if (gController) return;

    // Wait for the game's own landscape window; hosting the overlay inside its
    // root view guarantees the exact landscape coordinate space.
    UIWindow *host = [UIApplication sharedApplication].keyWindow;
    if (!host || host.hidden || host.bounds.size.width <= host.bounds.size.height) {
        host = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.bounds.size.width > w.bounds.size.height) { host = w; break; }
        }
    }
    if (!host || host.bounds.size.width <= host.bounds.size.height) return;

    UIView *hostView = host.rootViewController.view;
    if (!hostView) hostView = host;
    if (!hostView || hostView.bounds.size.width <= hostView.bounds.size.height) return;
    gHostView = hostView;

    gController = [[NJMenuController alloc] initWithNibName:nil bundle:nil];
    gController.hostView = hostView;
    UIView *menu = gController.view;
    menu.frame = hostView.bounds;
    menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [hostView addSubview:menu];
    [hostView bringSubviewToFront:menu];
    [gController layoutMenu];

    // The root view can still be between layout passes when we install; keep the
    // positions correct even if its bounds change right after us.
    [hostView addObserver:gController forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:NULL];
    for (NSNumber *delay in @[ @0.4, @1.2, @2.4 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [gController layoutMenu];
        });
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        UIView *h = gHostView;
        if (h && gController) {
            gController.view.frame = h.bounds;
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
            gAutoRestart = [[NSUserDefaults standardUserDefaults] boolForKey:@"noclip.instantRestart"];
            gSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"noclip.speed"];
            if (gSpeed <= 0.0f) gSpeed = 1.0f;
            if (gSpeed < GD_SPEED_MIN) gSpeed = GD_SPEED_MIN;
            if (gSpeed > GD_SPEED_MAX) gSpeed = GD_SPEED_MAX;
            gCurrentSpeed = gSpeed;

            dispatch_async(dispatch_get_main_queue(), ^{
                gd_probe();
                BOOL hooked = gd_install_vtable_hook();
                BOOL speedHooked = gd_install_update_hook();
                NSLog(@"[noclip] probe=%d vtableHook=%d speedHook=%d reset=%d enabled=%d restart=%d speed=%.2f",
                      gBinaryOK, hooked, speedHooked, gResetOK, gEnabled, gAutoRestart, gSpeed);

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

