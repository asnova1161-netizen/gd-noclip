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
#import <objc/runtime.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>

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
#define GD_RESET_FROM_START_OFF 0x123194ULL
#define GD_PLAYER_RESET_OFF 0x22f3d4ULL
#define GD_RESTART_FLAG  0x367e
#define GD_PLAYER_DEAD   0x9da
#define GD_LAYER_DYING   0x30a2
#define GD_LEVEL_TIME    0x390

// PlayerObject::m_playLayer is at +0x7ac.  PlayerObject::playerDestroyed()
// only plays the death explosion when this flag is set (and noEffects is
// false).  Clearing it for the duration of the original destroyPlayer call is
// data-only: no executable page is modified, so iOS code-signing protection
// cannot kill the app.  The flag is restored immediately afterwards.
#define GD_PLAYER_PLAY_LAYER 0x7ac

// PlayLayer's death-sound flag (the same byte read just before explode_11.ogg
// in destroyPlayer).  Setting it only for the original call skips the sound
// without changing the normal game-over flow.
#define GD_LAYER_NO_DEATH_SOUND 0x4bc

// PlayerObject vtable slot 164 is getObjectRect().  The function at slot 164
// delegates to getObjectRect(w,h) and returns the player's collision rectangle.
// Scaling that rectangle is the hitbox multiplier: a smaller player hitbox lets
// the player sink deeper into spikes and solids before the collision triggers.
#define GD_PLAYER_VTABLE_OFF 0x7cdb10ULL
#define GD_PLAYER_RECT_OFF   0x262708ULL
#define GD_PLAYER_RECT_SLOT  164

// GameObject's primary vtable.  Its getObjectRect() is at slot 164 as well and
// points at the same implementation as PlayerObject's override.  Hooking both
// vtables is intentional: shrinking only the player did not change spike deaths
// on all builds, while shrinking the object rectangle always affects the
// collision path (and is also what makes the overlap visibly deeper).
#define GD_OBJECT_VTABLE_OFF 0x7d9708ULL
#define GD_OBJECT_RECT_SLOT  164
#define GD_OBJECT_RECT_OFF   0x262708ULL

#define GD_SPEED_MIN     0.1f
#define GD_SPEED_MAX     100.0f
#define GD_HITBOX_MIN    0.10f
#define GD_HITBOX_MAX    1.00f

static BOOL        gEnabled = NO;
static BOOL        gAutoRestart = NO;
static BOOL        gBinaryOK = NO;
static BOOL        gResetOK = NO;
static BOOL        gResetFromStartOK = NO;
static BOOL        gPlayerResetOK = NO;
static BOOL        gHitboxOK = NO;
static BOOL        gObjectHitboxOK = NO;
static BOOL        gNoDeathFx = NO;
static BOOL        gSpeedEngaged = NO;
static BOOL        gResetting = NO;
static BOOL        gResetRequested = NO;
static BOOL        gUpdateHooked = NO;
static BOOL        gNoclipHooked = NO;
static BOOL        gHitboxHooked = NO;
static BOOL        gPlayerRectHooked = NO;
static BOOL        gObjectRectHooked = NO;
static void       *gResetLayer = NULL;
static uintptr_t   gImageBase = 0;
static void       *gOrigDestroyPlayer = NULL;
static void       *gOrigUpdate = NULL;
static void       *gOrigPlayerRect = NULL;
static void       *gOrigObjectRect = NULL;
static float       gSpeed = 1.0f;
static float       gCurrentSpeed = 1.0f;
static float       gHitbox = 1.0f;

typedef void (*DestroyPlayerFn)(void *self, void *player, void *object);
typedef void (*UpdateFn)(void *self, float dt);
typedef void (*ResetLevelFn)(void *self);
typedef void (*PlayerResetFn)(void *player);
typedef struct { float x, y, w, h; } NJRect;
typedef void *(*PlayerRectFn)(void *self);

// getObjectRect() returns a reference.  Keep a few stable backing rectangles so
// a caller that holds one briefly cannot be surprised by the next call.  GD's
// collision code copies the rectangle immediately, so this is sufficient.
static NJRect gPlayerRects[8];
static unsigned gPlayerRectIndex = 0;

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

    // No Death FX: temporarily mark the player as "not in a play layer".  The
    // normal death routine then skips only its playerDestroyed explosion path;
    // death state, attempts, game-over and Instant Restart continue normally.
    void *fxPlayer = player;
    if (!fxPlayer) fxPlayer = *(void **)((char *)self + 0xc90);
    uint8_t savedPlayLayer = 0;
    BOOL restorePlayLayer = NO;
    uint8_t savedDeathSound = 0;
    BOOL restoreDeathSound = NO;
    if (gNoDeathFx && self) {
        savedDeathSound = *(uint8_t *)((char *)self + GD_LAYER_NO_DEATH_SOUND);
        *(uint8_t *)((char *)self + GD_LAYER_NO_DEATH_SOUND) = 1;
        restoreDeathSound = YES;
    }
    if (gNoDeathFx && fxPlayer) {
        savedPlayLayer = *(uint8_t *)((char *)fxPlayer + GD_PLAYER_PLAY_LAYER);
        *(uint8_t *)((char *)fxPlayer + GD_PLAYER_PLAY_LAYER) = 0;
        restorePlayLayer = YES;
    }

    if (gOrigDestroyPlayer) ((DestroyPlayerFn)gOrigDestroyPlayer)(self, player, object);

    if (restorePlayLayer && fxPlayer) {
        *(uint8_t *)((char *)fxPlayer + GD_PLAYER_PLAY_LAYER) = savedPlayLayer;
    }
    if (restoreDeathSound && self) {
        *(uint8_t *)((char *)self + GD_LAYER_NO_DEATH_SOUND) = savedDeathSound;
    }

    if (!gOrigDestroyPlayer || !gAutoRestart || !gResetOK) return;
    // Any real death is enough.  Do not gate this on level time or a cooldown:
    // dying in the first half-second (including at 0%) must restart instantly
    // too, especially at 0.10x where half a second of level time is long.
    // gResetting/gResetRequested already suppress duplicate death callbacks
    // from the same death.
    if (gResetting || gResetRequested) return;

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

            // destroyPlayer always arms the game's own delayed auto-retry.
            // Cancel it before and after our immediate reset: otherwise the
            // delayed callback calls resetLevel a second time, which at very
            // low speeds turns into an endless death/reset loop.
            *((uint8_t *)self + GD_RESTART_FLAG) = 0;

            // Clear the death state *before* resetLevel.  resetLevel calls the
            // player's vtable reset and, at 0.10x, can otherwise leave the old
            // dead player at the death position; the next frame then looks
            // like an in-place death.
            *((uint8_t *)self + GD_LAYER_DYING) = 0;
            void *p1 = *(void **)((char *)self + 0xc90);
            if (p1 && *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD) = 0;
            }
            void *p2 = *(void **)((char *)self + 0xc98);
            if (p2 && p2 != p1 && *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD) = 0;
            }

            if (gResetFromStartOK) {
                ((ResetLevelFn)(gImageBase + GD_RESET_FROM_START_OFF))(self);
            } else {
                ((ResetLevelFn)(gImageBase + GD_RESET_OFF))(self);
            }
            *((uint8_t *)self + GD_RESTART_FLAG) = 0;
            *((uint8_t *)self + GD_LAYER_DYING) = 0;

            // resetLevel normally resets both players. Clear any stale dead
            // bit again after it has run.
            p1 = *(void **)((char *)self + 0xc90);
            if (p1 && *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p1 + GD_PLAYER_DEAD) = 0;
            }
            p2 = *(void **)((char *)self + 0xc98);
            if (p2 && p2 != p1 && *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD)) {
                *(uint8_t *)((char *)p2 + GD_PLAYER_DEAD) = 0;
            }

            // Run one normal-speed update after the reset.  At 0.10x the death
            // animation/retry is advanced with a tiny dt, which can leave the
            // fresh cube in the old position for several frames.  One native
            // frame lets resetLevel position and activate the player properly.
            ((UpdateFn)gOrigUpdate)(self, 1.0f / 60.0f);
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
    float blend = 1.0f - expf(-6.0f * realDt);
    if (blend < 0.0f) blend = 0.0f;
    if (blend > 1.0f) blend = 1.0f;
    gCurrentSpeed += (target - gCurrentSpeed) * blend;
    if (fabsf(target - gCurrentSpeed) < 0.0005f) gCurrentSpeed = target;

    float scale = gCurrentSpeed;
    if (!isfinite(scale) || scale < GD_SPEED_MIN || scale > GD_SPEED_MAX) scale = target;
    float scaled = dt * scale;
    if (!isfinite(scaled) || scaled < 0.0f) scaled = 0.0f;
    if (scaled > 2.0f) scaled = 2.0f; // never hand the game an absurd frame delta
    ((UpdateFn)gOrigUpdate)(self, scaled);
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
    gResetFromStartOK = (*(uint32_t *)(gImageBase + GD_RESET_FROM_START_OFF) == 0xa9bd57f6); // stp x22,x21,[sp,#-0x30]!
    gPlayerResetOK = (*(uint32_t *)(gImageBase + GD_PLAYER_RESET_OFF) == 0xa9be4ff4); // stp x20,x19,[sp,#-0x20]!

    // Validate the PlayerObject vtable and getObjectRect() slot before using
    // the hitbox multiplier.  The typeinfo name is the final safety check.
    uintptr_t playerVT = gImageBase + GD_PLAYER_VTABLE_OFF;
    uintptr_t typeInfo = *(uintptr_t *)(playerVT - sizeof(void *));
    const char *typeName = typeInfo ? *(const char **)(typeInfo + sizeof(void *)) : NULL;
    void **rectSlot = (void **)(playerVT + GD_PLAYER_RECT_SLOT * sizeof(void *));
    if (typeName && strcmp(typeName, "12PlayerObject") == 0 &&
        *rectSlot == (void *)(gImageBase + GD_PLAYER_RECT_OFF)) {
        gOrigPlayerRect = *rectSlot;
        gHitboxOK = YES;
    }

    // GameObject's primary vtable.  This is the rectangle used when a level
    // object is tested against the player.  Hooking it makes the slider work
    // even if a spike collision bypasses PlayerObject's own getObjectRect().
    uintptr_t objectVT = gImageBase + GD_OBJECT_VTABLE_OFF;
    uintptr_t objectTypeInfo = *(uintptr_t *)(objectVT - sizeof(void *));
    const char *objectName = objectTypeInfo ? *(const char **)(objectTypeInfo + sizeof(void *)) : NULL;
    void **objectRectSlot = (void **)(objectVT + GD_OBJECT_RECT_SLOT * sizeof(void *));
    if (objectName && strcmp(objectName, "10GameObject") == 0 &&
        *objectRectSlot == (void *)(gImageBase + GD_OBJECT_RECT_OFF)) {
        gOrigObjectRect = *objectRectSlot;
        gObjectHitboxOK = YES;
    }
}

// Some TrollStore/patched builds end up with a CADisplayLink capped at 30 Hz
// (or the game lowers it itself).  Speedhack must not change the render rate:
// slowing/speeding is done in PlayLayer::update, while the display link stays
// at 60.  Swizzle CCDirectorCaller's display-link callback and pin it to 60.
static IMP gOrigDoCaller = NULL;

static void noclip_do_caller(id self, SEL _cmd, id sender)
{
    if (sender &&
        [sender respondsToSelector:@selector(preferredFramesPerSecond)] &&
        [sender respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        if ([sender preferredFramesPerSecond] != 60) {
            [sender setPreferredFramesPerSecond:60];
        }
    }
    if (gOrigDoCaller) ((void (*)(id, SEL, id))gOrigDoCaller)(self, _cmd, sender);
}

static void gd_install_fps_hook(void)
{
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"CCDirectorCaller");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, @selector(doCaller:));
    if (!method) return;
    gOrigDoCaller = method_setImplementation(method, (IMP)noclip_do_caller);
    installed = YES;
    NSLog(@"[noclip] CCDirectorCaller hooked for 60 FPS");
}

static BOOL gd_install_noclip_hook(void)
{
    if (!gBinaryOK) return NO;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_VTABLE_SLOT * 8);
    if (*slot == (void *)&noclip_destroy_player) {
        gNoclipHooked = YES;
        return YES;
    }
    if (*slot != gOrigDestroyPlayer) return NO;
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return NO;
    *slot = (void *)&noclip_destroy_player;
    gNoclipHooked = YES;
    return YES;
}

static void gd_uninstall_noclip_hook(void)
{
    if (!gNoclipHooked || !gOrigDestroyPlayer) return;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_VTABLE_SLOT * 8);
    if (*slot != (void *)&noclip_destroy_player) { gNoclipHooked = NO; return; }
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return;
    *slot = gOrigDestroyPlayer;
    gNoclipHooked = NO;
}

// destroyPlayer is needed by all three death-related features: Noclip swallows
// the death, Instant Restart observes a real death, and No Death FX temporarily
// clears m_playLayer around the original call.  Keep the hook installed when
// any of them is on.
static void gd_sync_noclip_hook(void)
{
    if (!gBinaryOK || (!gEnabled && !gAutoRestart && !gNoDeathFx)) {
        gd_uninstall_noclip_hook();
    } else {
        gd_install_noclip_hook();
    }
}

static void *noclip_scale_rect(void *self, PlayerRectFn original)
{
    if (!original) return NULL;
    NJRect *src = (NJRect *)original(self);
    if (!src) return NULL;

    NJRect *out = &gPlayerRects[gPlayerRectIndex++ & 7u];
    *out = *src;

    float scale = gHitbox;
    if (!isfinite(scale) || scale < GD_HITBOX_MIN) scale = GD_HITBOX_MIN;
    if (scale > GD_HITBOX_MAX) scale = GD_HITBOX_MAX;
    if (scale < GD_HITBOX_MAX - 0.0005f) {
        float cx = out->x + out->w * 0.5f;
        float cy = out->y + out->h * 0.5f;
        out->w *= scale;
        out->h *= scale;
        out->x = cx - out->w * 0.5f;
        out->y = cy - out->h * 0.5f;
    }
    return out;
}

static void *noclip_player_rect(void *self)
{
    return noclip_scale_rect(self, (PlayerRectFn)gOrigPlayerRect);
}

static void *noclip_object_rect(void *self)
{
    return noclip_scale_rect(self, (PlayerRectFn)gOrigObjectRect);
}

static BOOL gd_install_rect_hook(uintptr_t vtoff, void *original, void *replacement, BOOL *installed)
{
    if (!gBinaryOK || !original) return NO;
    void **slot = (void **)(gImageBase + vtoff + GD_PLAYER_RECT_SLOT * sizeof(void *));
    if (*slot == replacement) {
        *installed = YES;
        return YES;
    }
    if (*slot != original) return NO;
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return NO;
    *slot = replacement;
    *installed = YES;
    return YES;
}

static void gd_uninstall_rect_hook(uintptr_t vtoff, void *original, void *replacement, BOOL *installed)
{
    if (!*installed || !original) return;
    void **slot = (void **)(gImageBase + vtoff + GD_PLAYER_RECT_SLOT * sizeof(void *));
    if (*slot != replacement) { *installed = NO; return; }
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return;
    *slot = original;
    *installed = NO;
}

static BOOL gd_install_hitbox_hook(void)
{
    if (!gBinaryOK || gHitbox >= GD_HITBOX_MAX - 0.0005f) return NO;
    BOOL any = NO;
    if (gHitboxOK) {
        any |= gd_install_rect_hook(GD_PLAYER_VTABLE_OFF, gOrigPlayerRect,
                                   (void *)&noclip_player_rect, &gPlayerRectHooked);
    }
    if (gObjectHitboxOK) {
        any |= gd_install_rect_hook(GD_OBJECT_VTABLE_OFF, gOrigObjectRect,
                                   (void *)&noclip_object_rect, &gObjectRectHooked);
    }
    gHitboxHooked = any;
    return any;
}

static void gd_uninstall_hitbox_hook(void)
{
    gd_uninstall_rect_hook(GD_PLAYER_VTABLE_OFF, gOrigPlayerRect,
                           (void *)&noclip_player_rect, &gPlayerRectHooked);
    gd_uninstall_rect_hook(GD_OBJECT_VTABLE_OFF, gOrigObjectRect,
                           (void *)&noclip_object_rect, &gObjectRectHooked);
    gHitboxHooked = NO;
}

static void gd_sync_hitbox_hook(void)
{
    if (!gBinaryOK || (!gHitboxOK && !gObjectHitboxOK) ||
        gHitbox >= GD_HITBOX_MAX - 0.0005f) {
        gd_uninstall_hitbox_hook();
    } else {
        gd_install_hitbox_hook();
    }
}

static BOOL gd_install_update_hook(void)
{
    if (!gBinaryOK) return NO;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_UPDATE_SLOT * 8);
    if (*slot == (void *)&noclip_update) {
        gUpdateHooked = YES;
        return YES;
    }
    if (*slot != (void *)(gImageBase + GD_UPDATE_OFF)) return NO;
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return NO;
    gOrigUpdate = *slot;
    *slot = (void *)&noclip_update;
    gUpdateHooked = YES;
    return YES;
}

static void gd_uninstall_update_hook(void)
{
    if (!gUpdateHooked || !gOrigUpdate) return;
    void **slot = (void **)(gImageBase + GD_VTABLE_OFF + GD_UPDATE_SLOT * 8);
    if (*slot != (void *)&noclip_update) { gUpdateHooked = NO; return; }
    if (!vm_protect_span(slot, sizeof(void *), VM_PROT_READ | VM_PROT_WRITE, NO)) return;
    *slot = gOrigUpdate;
    gUpdateHooked = NO;
}

// The update intercept is only needed for a non-default speed or for instant
// restart. Leaving the original PlayLayer::update untouched at 1.00x keeps the
// game on its exact native timing path.
static BOOL gd_update_hook_needed(void)
{
    // Keep the update hook installed after the user has used the speed slider
    // until the app is restarted.  Uninstalling it while gCurrentSpeed is still
    // catching up to 1.00x would make the game jump abruptly to full speed.
    return gAutoRestart || gSpeedEngaged ||
           fabsf(gSpeed - 1.0f) > 0.0001f ||
           fabsf(gCurrentSpeed - 1.0f) > 0.0001f;
}

static void gd_sync_update_hook(void)
{
    if (!gBinaryOK) return;
    if (gd_update_hook_needed()) {
        gd_install_update_hook();
    } else {
        gd_uninstall_update_hook();
    }
}

static void noclip_set_enabled(BOOL on)
{
    gEnabled = on;
    gd_sync_noclip_hook();
    NSLog(@"[noclip] enabled=%d hook=%d", on, gNoclipHooked);
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
@property (nonatomic, strong) UISwitch *deathFxToggle;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedValue;
@property (nonatomic, strong) UISlider *hitboxSlider;
@property (nonatomic, strong) UILabel *hitboxValue;
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
    CGFloat ph = 262.0;
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

    UIView *line4 = [[UIView alloc] initWithFrame:CGRectMake(16, 170, pw - 32, 1)];
    line4.backgroundColor = NJLine();
    [self.panel addSubview:line4];

    // Death-effect row.  ON keeps the normal death/retry logic but skips the
    // explosion animation, particles, and death sound.
    UILabel *deathFxLabel = NJLabel(@"No Death FX", 13.0, UIFontWeightSemibold, NJText(), 0.0);
    deathFxLabel.frame = CGRectMake(16, 182, 180, 18);
    [self.panel addSubview:deathFxLabel];

    self.deathFxToggle = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 67, 176, 51, 31)];
    self.deathFxToggle.onTintColor = NJAccent();
    self.deathFxToggle.thumbTintColor = [UIColor whiteColor];
    self.deathFxToggle.on = gNoDeathFx;
    [self.deathFxToggle addTarget:self action:@selector(deathFxChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.deathFxToggle];

    UIView *line5 = [[UIView alloc] initWithFrame:CGRectMake(16, 212, pw - 32, 1)];
    line5.backgroundColor = NJLine();
    [self.panel addSubview:line5];

    // Hitbox multiplier: 1.00x is the untouched player hitbox.  Moving the
    // slider left shrinks only the player's collision rectangle, so spikes and
    // solid obstacles can overlap the sprite before a death is triggered.
    UILabel *hitboxLabel = NJLabel(@"Hitbox", 13.0, UIFontWeightSemibold, NJText(), 0.0);
    hitboxLabel.frame = CGRectMake(16, 224, 82, 18);
    [self.panel addSubview:hitboxLabel];

    self.hitboxSlider = [[UISlider alloc] initWithFrame:CGRectMake(102, 217, 116, 31)];
    self.hitboxSlider.minimumValue = GD_HITBOX_MIN;
    self.hitboxSlider.maximumValue = GD_HITBOX_MAX;
    self.hitboxSlider.value = gHitbox;
    self.hitboxSlider.minimumTrackTintColor = NJAccent();
    self.hitboxSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    self.hitboxSlider.thumbTintColor = [UIColor whiteColor];
    self.hitboxSlider.continuous = YES;
    [self.hitboxSlider addTarget:self action:@selector(hitboxChanged:) forControlEvents:UIControlEventValueChanged];
    [self.hitboxSlider addTarget:self action:@selector(hitboxCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.panel addSubview:self.hitboxSlider];

    self.hitboxValue = NJLabel([NSString stringWithFormat:@"%.2f\u00d7", gHitbox], 12.0, UIFontWeightSemibold, NJText(), 0.0);
    self.hitboxValue.textAlignment = NSTextAlignmentRight;
    self.hitboxValue.frame = CGRectMake(pw - 72, 224, 56, 18);
    [self.panel addSubview:self.hitboxValue];

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
    if (!isfinite(value)) value = 1.0f;
    gSpeed = value;
    gSpeedEngaged = YES;
    self.speedValue.text = NJSpeedText(value);
    gd_sync_update_hook();
}

- (void)speedCommitted:(UISlider *)sender
{
    [[NSUserDefaults standardUserDefaults] setFloat:gSpeed forKey:@"noclip.speed"];
}

- (void)restartChanged:(UISwitch *)sender
{
    gAutoRestart = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:gAutoRestart forKey:@"noclip.instantRestart"];
    gd_sync_noclip_hook();
    gd_sync_update_hook();
}

- (void)deathFxChanged:(UISwitch *)sender
{
    gNoDeathFx = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:gNoDeathFx forKey:@"noclip.noDeathFx"];
    gd_sync_noclip_hook();
    gd_sync_update_hook();
    NSLog(@"[noclip] noDeathFx=%d deathHook=%d", gNoDeathFx, gNoclipHooked);
}

- (void)hitboxChanged:(UISlider *)sender
{
    float value = sender.value;
    if (!isfinite(value)) value = GD_HITBOX_MAX;
    if (value < GD_HITBOX_MIN) value = GD_HITBOX_MIN;
    if (value > GD_HITBOX_MAX) value = GD_HITBOX_MAX;
    gHitbox = value;
    self.hitboxValue.text = [NSString stringWithFormat:@"%.2f\u00d7", value];
    gd_sync_hitbox_hook();
}

- (void)hitboxCommitted:(UISlider *)sender
{
    [[NSUserDefaults standardUserDefaults] setFloat:gHitbox forKey:@"noclip.hitbox"];
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

            // One-time recovery from builds that could leave an extreme saved
            // speed / instant-restart / noclip state behind.  This revision
            // starts with every hook disabled: if a level still hangs at 0%,
            // the tweak is not touching the game at all.
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            if ([defaults integerForKey:@"noclip.safeBootRevision"] < 4) {
                [defaults setInteger:4 forKey:@"noclip.safeBootRevision"];
                [defaults setFloat:1.0f forKey:@"noclip.speed"];
                [defaults setFloat:1.0f forKey:@"noclip.hitbox"];
                [defaults setBool:NO forKey:@"noclip.enabled"];
                [defaults setBool:NO forKey:@"noclip.instantRestart"];
                [defaults synchronize];
            }

            // 2.2.1.3 moved No Death FX from an executable-page patch to a
            // data-only field around the original death call.  The previous
            // build may have left the toggle on together with a corrupted
            // code page, so reset it once after installing this build.
            if ([defaults integerForKey:@"noclip.noDeathFxRevision"] < 1) {
                [defaults setInteger:1 forKey:@"noclip.noDeathFxRevision"];
                [defaults setBool:NO forKey:@"noclip.noDeathFx"];
                [defaults synchronize];
            }

            gEnabled = [defaults boolForKey:@"noclip.enabled"];
            gAutoRestart = [defaults boolForKey:@"noclip.instantRestart"];
            gSpeed = [defaults floatForKey:@"noclip.speed"];
            if (!isfinite(gSpeed) || gSpeed <= 0.0f) gSpeed = 1.0f;
            if (gSpeed < GD_SPEED_MIN) gSpeed = GD_SPEED_MIN;
            if (gSpeed > GD_SPEED_MAX) gSpeed = GD_SPEED_MAX;
            gCurrentSpeed = gSpeed;
            gSpeedEngaged = (fabsf(gSpeed - 1.0f) > 0.0001f);
            gHitbox = [defaults floatForKey:@"noclip.hitbox"];
            if (!isfinite(gHitbox) || gHitbox <= 0.0f) gHitbox = GD_HITBOX_MAX;
            if (gHitbox < GD_HITBOX_MIN) gHitbox = GD_HITBOX_MIN;
            if (gHitbox > GD_HITBOX_MAX) gHitbox = GD_HITBOX_MAX;
            gNoDeathFx = [defaults boolForKey:@"noclip.noDeathFx"];

            dispatch_async(dispatch_get_main_queue(), ^{
                gd_install_fps_hook();
                gd_probe();
                gd_sync_noclip_hook();
                gd_sync_hitbox_hook();
                gd_sync_update_hook();
                NSLog(@"[noclip] probe=%d noclipHook=%d hitboxHook=%d speedHook=%d reset=%d enabled=%d restart=%d noDeathFx=%d speed=%.2f hitbox=%.2f",
                      gBinaryOK, gNoclipHooked, gHitboxHooked, gUpdateHooked, gResetOK,
                      gEnabled, gAutoRestart, gNoDeathFx, gSpeed, gHitbox);

                __block NSInteger tries = 0;
                void (^tryInstall)(void) = ^{
                    gd_install_fps_hook();
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

