// iPadOS UI bits that need UIKit (the rest of the host layer is plain C: runtime/platform/ios.c).
//
// The game is a 16:9 landscape title: its screen, the movie placement and the overlay UI all assume a wide frame.
// iPadOS 26 hands apps a resizable window and does not enforce the orientations declared in Info.plist, so an app
// started with the iPad held upright gets a tall portrait window and its 16:9 image becomes a letterboxed band in
// the middle of it (which, with the window sitting in a corner of a landscape screen, reads as "a box in the
// corner"). Two things fix that, both on the window scene:
//   - request an interface orientation of landscape (iOS 16+), and
//   - constrain the window's size with UISceneSizeRestrictions (the iOS 26 API for exactly this): the minimum is a
//     landscape 16:9 rectangle, so the window cannot be a narrow portrait one, and the maximum is the screen's
//     landscape bounds, so the player can still fill the screen.
// Together the window is a wide rectangle, the game fills it, and the movies are centred in it.
#import <UIKit/UIKit.h>
#include <stdio.h>

// The player is watching a game, not reading a menu: keep the screen from dimming and locking while it runs (iPadOS
// otherwise sleeps after a couple of minutes without touches - which also stops a scripted/automated run dead, since
// a backgrounded app may not submit GPU work at all). Called from the window setup, on the main thread.
void plat_ios_keep_awake(void) {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

void plat_ios_lock_landscape(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        // (diagnostics: what the window really is, versus what SDL reports - the two are not always the same)
        CGSize screen = UIScreen.mainScreen.bounds.size;
        fprintf(stderr, "[ios] screen %.0fx%.0f, scene bounds %.0fx%.0f, orientation %ld, window %.0fx%.0f\n",
                screen.width, screen.height, ws.coordinateSpace.bounds.size.width, ws.coordinateSpace.bounds.size.height,
                (long)ws.interfaceOrientation, ws.keyWindow.bounds.size.width, ws.keyWindow.bounds.size.height);
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS *prefs =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
            [ws requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                fprintf(stderr, "[ios] landscape request refused: %s\n", error.localizedDescription.UTF8String);
            }];
        }
        // A landscape 16:9 rectangle as the smallest window: the screen's long side, 9/16 of it as the height.
        CGFloat long_side = MAX(screen.width, screen.height), short_side = MIN(screen.width, screen.height);
        UISceneSizeRestrictions *r = ws.sizeRestrictions;
        if (r) {
            CGSize old_min = r.minimumSize, old_max = r.maximumSize;
            r.minimumSize = CGSizeMake(long_side, long_side * 9.0 / 16.0);
            r.maximumSize = CGSizeMake(long_side, short_side);
            fprintf(stderr, "[ios] window size limits min %.0fx%.0f max %.0fx%.0f (were %.0fx%.0f / %.0fx%.0f)\n",
                    r.minimumSize.width, r.minimumSize.height, r.maximumSize.width, r.maximumSize.height,
                    old_min.width, old_min.height, old_max.width, old_max.height);
        } else {
            fprintf(stderr, "[ios] no sizeRestrictions on this window scene (window stays as it is)\n");
        }
    }
}

// What SDL reports for the window (points and pixels) next to what UIKit says, so a window/appearance mismatch is
// visible in the log instead of guessed at.
void plat_ios_log_geometry(int point_w, int point_h, int pixel_w, int pixel_h) {
    UIWindowScene *ws = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) ws = (UIWindowScene *)s;
    fprintf(stderr, "[ios] SDL window %dx%d pt / %dx%d px; UIKit screen %.0fx%.0f pt, scene %.0fx%.0f pt, orientation %ld\n",
            point_w, point_h, pixel_w, pixel_h, UIScreen.mainScreen.bounds.size.width,
            UIScreen.mainScreen.bounds.size.height, ws ? ws.coordinateSpace.bounds.size.width : 0.0,
            ws ? ws.coordinateSpace.bounds.size.height : 0.0, ws ? (long)ws.interfaceOrientation : -1L);
}

// The window scene's size in points (iPadOS 26: the app's window lives in a scene whose bounds are the real window
// size; SDL's UIKit backend predates that and sizes its window from UIScreen.bounds, which on a portrait-held iPad
// is the portrait size even when the scene is landscape).
void plat_ios_scene_size(int *w, int *h) {
    *w = *h = 0;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        CGSize size = ((UIWindowScene *)s).coordinateSpace.bounds.size;
        if (size.width > 0 && size.height > 0) { *w = (int)size.width; *h = (int)size.height; return; }
    }
    CGSize screen = UIScreen.mainScreen.bounds.size;  // fall back to the screen, longest side first
    *w = (int)MAX(screen.width, screen.height);
    *h = (int)MIN(screen.width, screen.height);
}
