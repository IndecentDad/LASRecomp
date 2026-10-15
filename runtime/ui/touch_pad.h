// On-screen touch controls (runtime/ui/touch_pad.mm): a virtual gamepad the player drives with their fingers.
//
// Why a *virtual gamepad* instead of feeding the input layer directly: SDL's virtual joystick appears to the rest of
// the app exactly like a real controller, so the existing binding table (runtime/input_bind.h), the Controls tab's
// remapping, the button-prompt textures and the in-game menu's controller navigation all keep working unchanged -
// and a physically connected controller is handled by the very same code path.
//
// Layout (shared pixel geometry for drawing and hit-testing): a stick bottom-left, the four face buttons
// bottom-right, L/ZL and R/ZR along the top edges, and -/+ plus the overlay-menu button top centre. Touches are
// tracked per finger, so the stick and a button can be held at the same time; a finger that slides off a button
// releases it. Control sizes scale around fixed edge anchors. Auto mode hides the pad with a real controller.
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

union SDL_Event;
struct ImVec2;

// Creates the virtual gamepad (once). Called from the window setup.
void touch_pad_init(void);
// Finger events: true when the touch was used by the pad (the caller then skips the menu/game handlers).
bool touch_pad_event(const union SDL_Event *e);
// Per presented frame: the LARECOMP_TOUCH_TEST hook (see the .mm) - a no-op without it.
void touch_pad_frame(unsigned long long frame);
// Draw the pad. in_game: only while playing (not on the start screen); menu_open: hide it behind the overlay.
void touch_pad_draw(float display_w, float display_h, bool menu_open, bool in_game);
// Would touch_pad_draw() draw anything? (lets the renderer skip its ImGui frame entirely)
bool touch_pad_wanted(bool menu_open, bool in_game);
// larecomp.ini: touch_controls (0 off, 1 on, 2 on unless a real controller is connected), touch_scale.
bool touch_pad_enabled(void);
void touch_pad_set_enabled(bool on);
float touch_pad_scale(void);
void touch_pad_set_scale(float s);

#ifdef __cplusplus
}
#endif
