// On-screen touch controls: see runtime/ui/touch_pad.h for why this drives an SDL virtual gamepad.
#include "touch_pad.h"

#include <SDL3/SDL.h>
#include <float.h>
#include <stdlib.h>   // getenv: the test hooks
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "imgui.h"
#include "../settings.h"

// ------------------------------------------------------------------ the virtual gamepad
static SDL_Joystick *g_joy;
static SDL_JoystickID g_id;

// What a finger can grab. The pad is a small set of controls laid out in window fractions.
enum { CTL_NONE = 0, CTL_STICK, CTL_L, CTL_ZL, CTL_R, CTL_ZR, CTL_MINUS, CTL_PLUS, CTL_MENU, CTL_A, CTL_B, CTL_X, CTL_Y };

typedef struct {
    SDL_FingerID id;
    int ctl;          // CTL_*: what this finger grabbed
    float sx, sy;     // where it started (stick centre follows the layer, not the finger)
    float lx, ly;     // the stick's own axes while this finger drives it (-1..1)
} Touch;

#define MAX_TOUCH 10
static Touch g_touch[MAX_TOUCH];
static float g_stick_x, g_stick_y;   // the stick's current position (0..1 of the pad radius)
static bool g_btn[SDL_GAMEPAD_BUTTON_COUNT];

// ------------------------------------------------------------------ layout (drawable pixels)
typedef struct { float x, y; } V2;

static float g_scale = 1.0f;
static bool g_visible = true;
static bool g_drawn;
static struct {
    float w, h, unit, edge, bottom;
    float stick_r, knob_r, face_r, face_gap, small_r;
    float shoulder_w, shoulder_h, shoulder_gap, top;
    V2 stick, face;
} g_layout;

// Scale control sizes around their anchors, never the anchors themselves. Drawing and hit testing use the
// same pixel geometry, so the size slider and different screen aspect ratios cannot move the touch targets.
static void layout(float w, float h) {
    g_layout.w = w; g_layout.h = h;
    const float unit = fminf(w, h), size = unit * g_scale;
    g_layout.unit = unit;
    g_layout.edge = unit * 0.045f;
    g_layout.bottom = h - unit * 0.037f;
    g_layout.stick_r = size * 0.080f;
    g_layout.knob_r = size * 0.031f;
    g_layout.face_r = size * 0.032f;
    g_layout.face_gap = g_layout.face_r * 1.85f;
    g_layout.small_r = size * 0.022f;
    g_layout.shoulder_w = size * 0.078f;
    g_layout.shoulder_h = size * 0.039f;
    g_layout.shoulder_gap = size * 0.012f;
    g_layout.top = unit * 0.045f;
    g_layout.stick = {g_layout.edge + g_layout.stick_r, g_layout.bottom - g_layout.stick_r};
    const float reach = g_layout.face_gap + g_layout.face_r;
    g_layout.face = {w - g_layout.edge - reach, g_layout.bottom - reach};
}

static V2 face_pos(int ctl, float *r_out) {
    V2 c = g_layout.face;
    switch (ctl) {
    case CTL_A: c.x += g_layout.face_gap; break;
    case CTL_B: c.y += g_layout.face_gap; break;
    case CTL_X: c.y -= g_layout.face_gap; break;
    case CTL_Y: c.x -= g_layout.face_gap; break;
    }
    if (r_out) *r_out = g_layout.face_r;
    return c;
}

static V2 small_pos(int ctl, float *r_out) {
    V2 c = {g_layout.w * 0.5f, g_layout.top + g_layout.small_r};
    if (ctl == CTL_MINUS) c.x -= g_layout.small_r * 2.9f;
    else if (ctl == CTL_MENU) c.x += g_layout.small_r * 2.9f;
    if (r_out) *r_out = g_layout.small_r;
    return c;
}

static bool shoulder_rect(int ctl, float *x, float *y, float *w, float *h) {
    *y = g_layout.top;
    *h = g_layout.shoulder_h;
    *w = g_layout.shoulder_w;
    const float pair = *w + g_layout.shoulder_gap;
    switch (ctl) {
    case CTL_L:  *x = g_layout.edge; return true;
    case CTL_ZL: *x = g_layout.edge + pair; return true;
    case CTL_R:  *x = g_layout.w - g_layout.edge - *w; return true;
    case CTL_ZR: *x = g_layout.w - g_layout.edge - *w - pair; return true;
    }
    return false;
}

// ------------------------------------------------------------------ control names
static const struct { const char *name; int ctl; } CTL_NAMES[] = {
    {"A", CTL_A}, {"B", CTL_B}, {"X", CTL_X}, {"Y", CTL_Y}, {"L", CTL_L}, {"R", CTL_R}, {"ZL", CTL_ZL}, {"ZR", CTL_ZR},
    {"-", CTL_MINUS}, {"+", CTL_PLUS}, {"menu", CTL_MENU},
};
static const char *ctl_name(int ctl) {
    for (size_t i = 0; i < sizeof CTL_NAMES / sizeof *CTL_NAMES; i++)
        if (CTL_NAMES[i].ctl == ctl) return CTL_NAMES[i].name;
    return ctl == CTL_STICK ? "stick" : "?";
}
static int ctl_from_name(const char *n) {
    for (size_t i = 0; i < sizeof CTL_NAMES / sizeof *CTL_NAMES; i++)
        if (!strcasecmp(CTL_NAMES[i].name, n)) return CTL_NAMES[i].ctl;
    return CTL_NONE;
}
// Synthetic finger events use SDL's normalized window coordinates, just like physical touches.
static V2 ctl_centre(int ctl) {
    float r, x, y, w, h;
    V2 c = g_layout.stick;
    if (ctl >= CTL_A && ctl <= CTL_Y) c = face_pos(ctl, &r);
    else if (ctl == CTL_MINUS || ctl == CTL_PLUS || ctl == CTL_MENU) c = small_pos(ctl, &r);
    else if (shoulder_rect(ctl, &x, &y, &w, &h)) c = {x + w * 0.5f, y + h * 0.5f};
    return {c.x / g_layout.w, c.y / g_layout.h};
}


void touch_pad_init(void) {
    if (g_joy) return;
    if (!SDL_WasInit(SDL_INIT_JOYSTICK) && !SDL_InitSubSystem(SDL_INIT_JOYSTICK)) {
        fprintf(stderr, "[touch] no joystick subsystem: %s\n", SDL_GetError());
        return;
    }
    SDL_VirtualJoystickDesc d;
    SDL_INIT_INTERFACE(&d);
    d.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    d.naxes = SDL_GAMEPAD_AXIS_COUNT;
    d.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    // Every button and axis, not just the ones the pad draws. SDL numbers a virtual joystick's buttons (and axes)
    // *sequentially over the set mask bits* - the gamepad mapping it generates for them counts the bits up in
    // SDL_GAMEPAD_BUTTON_* order - so any bit left out shifts every index after it and SDL_SetJoystickVirtualButton()
    // quietly writes a button the gamepad mapping doesn't cover. With the full mask the joystick's indices *are* the
    // SDL_GAMEPAD_* ones, which is what the code below passes. (A sparse mask is what kept L / R / ZL / ZR dead: the
    // face buttons happen to line up either way, which is exactly why A worked.)
    d.button_mask = 0x03FFFFFFu;  // (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1
    d.axis_mask = 0x3Fu;          // (1u << SDL_GAMEPAD_AXIS_COUNT) - 1
    d.name = "Touch controls";
    d.vendor_id = 0x0A5C;   // (not a real one: SDL then calls it "Nintendo / other", whose prompts are the Switch's)
    d.product_id = 0x0001;
    g_id = SDL_AttachVirtualJoystick(&d);
    if (!g_id) {
        fprintf(stderr, "[touch] SDL_AttachVirtualJoystick: %s\n", SDL_GetError());
        return;
    }
    g_joy = SDL_OpenJoystick(g_id);
    if (!g_joy) {
        fprintf(stderr, "[touch] SDL_OpenJoystick(%u): %s\n", (unsigned)g_id, SDL_GetError());
        SDL_DetachVirtualJoystick(g_id);
        g_id = 0;
        return;
    }
    fprintf(stderr, "[touch] virtual gamepad attached (id %u)\n", (unsigned)g_id);
}

static void set_button(int btn, bool down) {
    if (!g_joy || btn < 0 || btn >= SDL_GAMEPAD_BUTTON_COUNT) return;
    if (g_btn[btn] == down) return;
    g_btn[btn] = down;
    SDL_SetJoystickVirtualButton(g_joy, (Uint8)btn, down);
}

static void button_for(int ctl, int *btn);  // (defined below; ctl_down needs it)

// ZL/ZR are analog triggers (SDL_GAMEPAD_AXIS_LEFT/RIGHT_TRIGGER), as on a real pad.
static float g_trigger[2];
static void set_trigger(int which, bool down) {
    if (!g_joy || which < 0 || which > 1) return;
    float v = down ? 32767.0f : 0.0f;
    if (g_trigger[which] == v) return;
    g_trigger[which] = v;
    SDL_SetJoystickVirtualAxis(g_joy, (Uint8)(which == 0 ? SDL_GAMEPAD_AXIS_LEFT_TRIGGER : SDL_GAMEPAD_AXIS_RIGHT_TRIGGER),
                               (Sint16)v);
}

static bool ctl_down(int ctl) {
    if (ctl == CTL_ZL) return g_trigger[0] > 0;
    if (ctl == CTL_ZR) return g_trigger[1] > 0;
    int btn;
    button_for(ctl, &btn);
    return btn >= 0 && g_btn[btn];
}

static void set_axes(void) {
    if (!g_joy) return;
    Sint16 x = (Sint16)lrintf(fmaxf(-1.0f, fminf(1.0f, g_stick_x)) * 32767.0f);
    Sint16 y = (Sint16)lrintf(fmaxf(-1.0f, fminf(1.0f, g_stick_y)) * 32767.0f);
    SDL_SetJoystickVirtualAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTX, x);
    SDL_SetJoystickVirtualAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTY, y);
}

// ------------------------------------------------------------------ settings
bool touch_pad_enabled(void) { return g_visible; }
void touch_pad_set_enabled(bool on) { g_visible = on; }
float touch_pad_scale(void) { return g_scale; }
void touch_pad_set_scale(float s) { g_scale = s < 0.5f ? 0.5f : s > 2.0f ? 2.0f : s; }

// A real controller (not this virtual one) takes over: the pad gets out of the way.
static bool real_controller(void) {
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    bool found = false;
    for (int i = 0; i < n; i++)
        if (ids[i] != g_id) found = true;
    SDL_free(ids);
    return found;
}

static bool visible_in(bool menu_open, bool in_game) {
    if (!g_visible || !in_game || menu_open) return false;
    if (g_settings.touch_controls == TOUCH_OFF) return false;
    if (g_settings.touch_controls == TOUCH_AUTO && real_controller()) return false;  // "hide when a controller is used"
    return true;
}

bool touch_pad_wanted(bool menu_open, bool in_game) { return visible_in(menu_open, in_game); }

// ------------------------------------------------------------------ touches
static Touch *touch_find(SDL_FingerID id, bool create) {
    for (int i = 0; i < MAX_TOUCH; i++)
        if (g_touch[i].ctl && g_touch[i].id == id) return &g_touch[i];
    if (!create) return NULL;
    for (int i = 0; i < MAX_TOUCH; i++)
        if (!g_touch[i].ctl) { memset(&g_touch[i], 0, sizeof g_touch[i]); g_touch[i].id = id; return &g_touch[i]; }
    return NULL;
}

// SDL supplies normalized coordinates; convert once into the exact geometry that was drawn.
static int hit(float x, float y) {
    x *= g_layout.w; y *= g_layout.h;
    float r;
    static const int faces[] = {CTL_A, CTL_B, CTL_X, CTL_Y, CTL_MINUS, CTL_PLUS, CTL_MENU};
    for (size_t i = 0; i < sizeof faces / sizeof *faces; i++) {
        // (the enum puts the small buttons *before* the face buttons, so this is a range test, not a <= one)
        V2 c = faces[i] >= CTL_A ? face_pos(faces[i], &r) : small_pos(faces[i], &r);
        float dx = x - c.x, dy = y - c.y;
        if (dx * dx + dy * dy <= (r * 1.18f) * (r * 1.18f)) return faces[i];
    }
    float bx, by, bw, bh;
    static const int sh[] = {CTL_L, CTL_ZL, CTL_R, CTL_ZR};
    for (size_t i = 0; i < sizeof sh / sizeof *sh; i++)
        if (shoulder_rect(sh[i], &bx, &by, &bw, &bh) && x >= bx - bw * 0.1f && x <= bx + bw * 1.1f &&
            y >= by - bh * 0.3f && y <= by + bh * 1.3f)
            return sh[i];
    {
        float dx = x - g_layout.stick.x, dy = y - g_layout.stick.y;
        if (dx * dx + dy * dy <= (g_layout.stick_r * 1.2f) * (g_layout.stick_r * 1.2f)) return CTL_STICK;
    }
    return CTL_NONE;
}

static void button_for(int ctl, int *btn) {
    switch (ctl) {
    // by position, matching runtime/hle/bindings.c DEF_PAD: Switch A is the east button, B the south one, X north
    // (the Switch's own layout - see face_pos())
    case CTL_A: *btn = SDL_GAMEPAD_BUTTON_EAST; break;
    case CTL_B: *btn = SDL_GAMEPAD_BUTTON_SOUTH; break;
    case CTL_X: *btn = SDL_GAMEPAD_BUTTON_NORTH; break;
    case CTL_Y: *btn = SDL_GAMEPAD_BUTTON_WEST; break;
    case CTL_L: *btn = SDL_GAMEPAD_BUTTON_LEFT_SHOULDER; break;
    case CTL_R: *btn = SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER; break;
    case CTL_ZL: case CTL_ZR: *btn = -1; break;   // the triggers are axes: see set_trigger()
    case CTL_MINUS: *btn = SDL_GAMEPAD_BUTTON_BACK; break;
    case CTL_PLUS: *btn = SDL_GAMEPAD_BUTTON_START; break;
    default: *btn = -1; break;
    }
}

bool touch_pad_event(const SDL_Event *e) {
    if (!g_joy || !g_drawn) return false;
    switch (e->type) {
    case SDL_EVENT_FINGER_DOWN: {
        Touch *t = touch_find(e->tfinger.fingerID, true);
        int ctl = hit(e->tfinger.x, e->tfinger.y);
        if (!t || ctl == CTL_NONE) return false;
        t->ctl = ctl;
        t->sx = e->tfinger.x;
        t->sy = e->tfinger.y;
        if (ctl == CTL_MENU) {  // the overlay menu: same path as F1 / Minus+Plus
            SDL_Event key = {0};
            key.type = SDL_EVENT_KEY_DOWN;
            key.key.scancode = SDL_SCANCODE_F1;
            key.key.key = SDLK_F1;
            SDL_PushEvent(&key);
            return true;
        }
        if (ctl == CTL_STICK) { g_stick_x = g_stick_y = 0; set_axes(); return true; }
        if (ctl == CTL_ZL || ctl == CTL_ZR) set_trigger(ctl == CTL_ZL ? 0 : 1, true);
        else {
            int btn;
            button_for(ctl, &btn);
            set_button(btn, true);
        }
        fprintf(stderr, "[touch] %s down at %.3f,%.3f\n", ctl_name(ctl), e->tfinger.x, e->tfinger.y);
        return true;
    }
    case SDL_EVENT_FINGER_MOTION: {
        Touch *t = touch_find(e->tfinger.fingerID, false);
        if (!t) return false;
        if (t->ctl == CTL_STICK) {
            float travel = g_layout.stick_r * 0.62f;
            float dx = (e->tfinger.x - t->sx) * g_layout.w / travel;
            float dy = (e->tfinger.y - t->sy) * g_layout.h / travel;
            float len = sqrtf(dx * dx + dy * dy);
            if (len > 1.0f) { dx /= len; dy /= len; }
            g_stick_x = dx;
            g_stick_y = dy;
            set_axes();
            return true;
        }
        // a button: sliding off it releases (and sliding onto its neighbour would need a new touch)
        int now = hit(e->tfinger.x, e->tfinger.y);
        if (now != t->ctl) {
            if (t->ctl == CTL_ZL || t->ctl == CTL_ZR) set_trigger(t->ctl == CTL_ZL ? 0 : 1, false);
            else {
                int btn;
                button_for(t->ctl, &btn);
                set_button(btn, false);
            }
            t->ctl = CTL_NONE;
        }
        return true;
    }
    case SDL_EVENT_FINGER_UP:
    case SDL_EVENT_FINGER_CANCELED: {
        Touch *t = touch_find(e->tfinger.fingerID, false);
        if (!t) return false;
        if (t->ctl == CTL_STICK) {
            g_stick_x = g_stick_y = 0;
            set_axes();
        } else if (t->ctl != CTL_MENU) {
            if (t->ctl == CTL_ZL || t->ctl == CTL_ZR) set_trigger(t->ctl == CTL_ZL ? 0 : 1, false);
            else {
                int btn;
                button_for(t->ctl, &btn);
                set_button(btn, false);
            }
        }
        t->ctl = CTL_NONE;
        return true;
    }
    }
    return false;
}

// LARECOMP_TOUCH_TEST=<frame>:<A|B|X|Y|L|R|ZL|ZR|-|+|menu> (test, comma separated for more): presses that control
// at that frame for LARECOMP_TOUCH_HOLD frames (default 30), by feeding the same finger events a real touch would
// produce, so the whole chain (finger -> virtual gamepad -> SDL gamepad events -> runtime/hle/input.c -> the game) can
// be exercised without a finger on the glass. Controls joined by & are held *together*, each on its own finger, the
// way two thumbs would press them ("1500:L&R"); a later entry releases what came before it.
// LARECOMP_TOUCH_TEST_STICK=<frame>:<x>,<y> does the same for the stick.
void touch_pad_frame(uint64_t frame) {
    static const char *spec, *stick_spec;
    static int init;
    static long hold = -1;
    static uint64_t release_at;
    static struct { int ctl; SDL_FingerID id; } down[8];
    static int ndown;
    if (!init) {
        init = 1;
        spec = getenv("LARECOMP_TOUCH_TEST");
        stick_spec = getenv("LARECOMP_TOUCH_TEST_STICK");
        const char *h = getenv("LARECOMP_TOUCH_HOLD");
        hold = h ? atol(h) : 30;
    }
    if (release_at && frame >= release_at) {
        // (delivered to the pad directly: SDL_PushEvent refuses synthetic finger events, which only come from the
        // platform's touch driver)
        for (int i = 0; i < ndown; i++) {
            SDL_Event e = {0};
            e.type = SDL_EVENT_FINGER_UP;
            e.tfinger.fingerID = down[i].id;
            touch_pad_event(&e);
        }
        ndown = 0;
        release_at = 0;
    }
    for (const char *sp = stick_spec; sp && *sp;) {
        long at;
        float x, y;
        if (sscanf(sp, "%ld:%f,%f", &at, &x, &y) != 3 || (long)frame < at) break;
        stick_spec = strchr(sp, ';');
        if (stick_spec) stick_spec++;
        SDL_Event e = {0};
        e.type = release_at ? SDL_EVENT_FINGER_MOTION : SDL_EVENT_FINGER_DOWN;
        e.tfinger.fingerID = 9002;
        V2 centre = ctl_centre(CTL_STICK);
        e.tfinger.x = centre.x; e.tfinger.y = centre.y;
        if (release_at) {
            e.tfinger.x += x * g_layout.stick_r * 0.62f / g_layout.w;
            e.tfinger.y += y * g_layout.stick_r * 0.62f / g_layout.h;
        }
        touch_pad_event(&e);
        release_at = frame + 60;
        break;
    }
    if (!spec || !*spec) return;
    long at;
    char what[64];
    if (sscanf(spec, "%ld:%63[^,;]", &at, what) != 2 || (long)frame < at) return;
    spec = strchr(spec, ',');
    if (spec) spec++;
    else spec = "";
    for (char *tok = strtok(what, "&"); tok && ndown < 8; tok = strtok(NULL, "&")) {
        int ctl = ctl_from_name(tok);
        if (ctl == CTL_NONE) continue;
        V2 c = ctl_centre(ctl);
        SDL_FingerID id = (SDL_FingerID)(9001 + ndown);  // (one finger per control, as two thumbs would)
        SDL_Event e = {0};
        e.type = SDL_EVENT_FINGER_DOWN;
        e.tfinger.fingerID = id;
        e.tfinger.x = c.x;
        e.tfinger.y = c.y;
        if (touch_pad_event(&e)) { down[ndown].ctl = ctl; down[ndown].id = id; ndown++; }
    }
    if (ndown) release_at = frame + (uint64_t)hold;  // (a tap: long enough for the game to see it, not to stick)
}

// ------------------------------------------------------------------ drawing
static void ring(ImDrawList *dl, ImVec2 c, float r, ImU32 fill, ImU32 line, float th) {
    dl->AddCircleFilled(c, r, fill, 40);
    dl->AddCircle(c, r, line, 40, th);
}

static void label(ImDrawList *dl, ImVec2 c, const char *s, float size, ImU32 col) {
    ImVec2 ts = ImGui::GetFont()->CalcTextSizeA(size, FLT_MAX, 0, s);
    dl->AddText(ImGui::GetFont(), size, ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), col, s);
}

// Thin glass outlines and a restrained warm accent keep the controls readable over bright scenery.
static float g_press[CTL_Y + 1];
static ImU32 mix_color(ImU32 a, ImU32 b, float t) {
    ImVec4 x = ImGui::ColorConvertU32ToFloat4(a), y = ImGui::ColorConvertU32ToFloat4(b);
    return ImGui::ColorConvertFloat4ToU32(ImVec4(x.x + (y.x-x.x)*t, x.y + (y.y-x.y)*t,
                                               x.z + (y.z-x.z)*t, x.w + (y.w-x.w)*t));
}

void touch_pad_draw(float dw, float dh, bool menu_open, bool in_game) {
    touch_pad_set_scale(g_settings.touch_scale > 0.3f ? g_settings.touch_scale : 1.0f);
    bool shown = visible_in(menu_open, in_game);
    if (!shown && g_drawn) {
        // Opening the menu or connecting a controller must not leave a captured touch held down.
        for (int i = 0; i < MAX_TOUCH; i++) if (g_touch[i].ctl) {
            SDL_Event e = {}; e.type = SDL_EVENT_FINGER_CANCELED; e.tfinger.fingerID = g_touch[i].id;
            touch_pad_event(&e);
        }
    }
    g_drawn = shown;
    if (!g_drawn) return;
    layout(dw, dh);
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    const float u = g_layout.unit, th = fmaxf(1.0f, u * 0.0010f);
    const ImU32 fill = IM_COL32(20, 26, 31, 92), line = IM_COL32(235, 238, 231, 78);
    const ImU32 text = IM_COL32(246, 245, 235, 215), accent = IM_COL32(235, 196, 115, 220);
    const ImU32 pressed = IM_COL32(124, 100, 48, 155);
    const float blend = fminf(1.0f, ImGui::GetIO().DeltaTime * 18.0f);
    for (int ctl = CTL_L; ctl <= CTL_Y; ctl++)
        g_press[ctl] += ((ctl_down(ctl) ? 1.0f : 0.0f) - g_press[ctl]) * blend;

    // The lower anchors use the bottom letterbox space instead of covering the middle of the game.
    ImVec2 c(g_layout.stick.x, g_layout.stick.y);
    float r = g_layout.stick_r;
    const bool held = fabsf(g_stick_x) > 0.02f || fabsf(g_stick_y) > 0.02f;
    ring(dl, c, r, IM_COL32(15, 21, 27, 48), IM_COL32(235, 238, 231, 62), th);
    dl->AddCircle(c, r * 0.74f, IM_COL32(235, 238, 231, 22), 48, th);
    for (int i = 0; i < 4; i++) {
        float a = i * 1.570796327f;
        ImVec2 p(c.x + cosf(a) * r * 0.85f, c.y + sinf(a) * r * 0.85f);
        ImVec2 q(c.x + cosf(a) * r * 0.92f, c.y + sinf(a) * r * 0.92f);
        dl->AddLine(p, q, line, th);
    }
    ImVec2 k(c.x + g_stick_x * r * 0.62f, c.y + g_stick_y * r * 0.62f);
    dl->AddCircleFilled(ImVec2(k.x, k.y + th * 2), g_layout.knob_r + th, IM_COL32(0, 0, 0, 30), 40);
    ring(dl, k, g_layout.knob_r, held ? pressed : fill, held ? accent : line, th);
    dl->AddCircleFilled(k, th * 1.8f, held ? accent : IM_COL32(246, 245, 235, 90), 12);

    static const int faces[] = {CTL_A, CTL_B, CTL_X, CTL_Y};
    for (int ctl : faces) {
        V2 p = face_pos(ctl, &r); c = ImVec2(p.x, p.y);
        float active = g_press[ctl];
        ImU32 outline = ctl == CTL_A ? IM_COL32(235, 196, 115, 125) : line;
        dl->AddCircleFilled(ImVec2(c.x, c.y + th * 2), r + th, IM_COL32(0, 0, 0, 26), 40);
        ring(dl, c, r, mix_color(fill, pressed, active), mix_color(outline, accent, active), th);
        label(dl, c, ctl_name(ctl), r * 0.90f, mix_color(text, accent, active));
    }
    static const int shoulders[] = {CTL_L, CTL_ZL, CTL_R, CTL_ZR};
    for (int ctl : shoulders) {
        float x, y, w, h;
        shoulder_rect(ctl, &x, &y, &w, &h);
        const float active = g_press[ctl], rounding = h * 0.5f;
        dl->AddRectFilled(ImVec2(x, y), ImVec2(x+w, y+h), mix_color(fill, pressed, active), rounding);
        dl->AddRect(ImVec2(x, y), ImVec2(x+w, y+h), mix_color(line, accent, active), rounding, 0, th);
        label(dl, ImVec2(x+w*0.5f, y+h*0.5f), ctl_name(ctl), h * 0.47f, text);
    }
    static const int small[] = {CTL_MINUS, CTL_PLUS, CTL_MENU};
    for (int ctl : small) {
        V2 p = small_pos(ctl, &r); c = ImVec2(p.x, p.y);
        ring(dl, c, r, mix_color(fill, pressed, g_press[ctl]), mix_color(line, accent, g_press[ctl]), th);
        if (ctl != CTL_MENU) label(dl, c, ctl_name(ctl), r * 1.05f, text);
        else for (int i = -1; i <= 1; i++) {
            float y = c.y + i * r * 0.27f;
            dl->AddLine(ImVec2(c.x-r*0.34f, y), ImVec2(c.x+r*0.34f, y), text, th * 1.2f);
        }
    }
}
