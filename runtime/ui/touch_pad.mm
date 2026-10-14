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

// ------------------------------------------------------------------ layout (window fractions)
typedef struct { float x, y; } V2;

static float g_scale = 1.0f;
static bool g_visible = true;      // touch_controls setting
static bool g_drawn;               // what the last draw pass did (for hit-testing consistency)

// (kept clear of the screen edges and the home-indicator area: the iPad's corners are rounded)
#define STICK_CX 0.150f
#define STICK_CY  0.635f
#define STICK_R   0.095f
#define KNOB_R    0.042f
#define FACE_CX   0.820f
#define FACE_CY   0.635f
#define FACE_D    0.068f
#define FACE_R    0.037f
#define SHOULDER_Y 0.135f
#define SHOULDER_H 0.085f
#define SHOULDER_W 0.090f
#define SMALL_R   0.030f

static float px(float frac, float size) { return frac * size * g_scale; }

// A round button's centre in window fractions.
static V2 face_pos(int ctl, float *r_out) {
    V2 c = {FACE_CX, FACE_CY};
    // The Switch's own diamond - A right, B bottom, X top, Y left - which is what the game's prompts draw (the
    // default bindings are positional: runtime/hle/bindings.c DEF_PAD binds Switch A to the controller's east button).
    switch (ctl) {
    case CTL_A: c.x += FACE_D * 1.35f; break;
    case CTL_B: c.y += FACE_D; break;
    case CTL_X: c.y -= FACE_D; break;
    case CTL_Y: c.x -= FACE_D * 1.35f; break;
    }
    if (r_out) *r_out = FACE_R;
    return c;
}

static V2 small_pos(int ctl, float *r_out) {
    V2 c = {0.5f, 0.115f};
    if (ctl == CTL_MINUS) c.x -= 0.075f;
    else if (ctl == CTL_PLUS) c.x += 0.075f;
    else c.x += 0.155f;  // the overlay menu button sits past +, away from the face buttons
    if (r_out) *r_out = SMALL_R;
    return c;
}

static bool shoulder_rect(int ctl, float *x, float *y, float *w, float *h) {
    *y = SHOULDER_Y - SHOULDER_H * 0.5f;
    *h = SHOULDER_H;
    *w = SHOULDER_W;
    switch (ctl) {
    case CTL_L:  *x = 0.085f - SHOULDER_W * 0.5f; return true;
    case CTL_ZL: *x = 0.205f - SHOULDER_W * 0.5f; return true;
    case CTL_R:  *x = 0.915f - SHOULDER_W * 0.5f; return true;
    case CTL_ZR: *x = 0.795f - SHOULDER_W * 0.5f; return true;
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
static V2 ctl_centre(int ctl) {
    float r;
    if (ctl >= CTL_A && ctl <= CTL_Y) return face_pos(ctl, &r);
    if (ctl == CTL_MINUS || ctl == CTL_PLUS || ctl == CTL_MENU) return small_pos(ctl, &r);
    if (ctl == CTL_STICK) { V2 c = {STICK_CX, STICK_CY}; return c; }
    float x, y, w, h;
    if (shoulder_rect(ctl, &x, &y, &w, &h)) { V2 c = {x + w * 0.5f, y + h * 0.5f}; return c; }
    V2 c = {0.5f, 0.5f};
    return c;
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

// Which control is at this point (window fractions)? Buttons win over the stick area.
static int hit(float x, float y) {
    float r;
    static const int faces[] = {CTL_A, CTL_B, CTL_X, CTL_Y, CTL_MINUS, CTL_PLUS, CTL_MENU};
    for (size_t i = 0; i < sizeof faces / sizeof *faces; i++) {
        // (the enum puts the small buttons *before* the face buttons, so this is a range test, not a <= one)
        V2 c = faces[i] >= CTL_A ? face_pos(faces[i], &r) : small_pos(faces[i], &r);
        float dx = (x - c.x), dy = (y - c.y) * 0.75f;  // (iPad screens are wider than tall: keep the hit area round)
        if (dx * dx + dy * dy <= (r * 1.35f) * (r * 1.35f)) return faces[i];
    }
    float bx, by, bw, bh;
    static const int sh[] = {CTL_L, CTL_ZL, CTL_R, CTL_ZR};
    for (size_t i = 0; i < sizeof sh / sizeof *sh; i++)
        if (shoulder_rect(sh[i], &bx, &by, &bw, &bh) && x >= bx - bw * 0.1f && x <= bx + bw * 1.1f &&
            y >= by - bh * 0.3f && y <= by + bh * 1.3f)
            return sh[i];
    {
        float dx = (x - STICK_CX), dy = (y - STICK_CY) * 0.75f;
        if (dx * dx + dy * dy <= (STICK_R * 1.5f) * (STICK_R * 1.5f)) return CTL_STICK;
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
            float dx = (e->tfinger.x - t->sx) / (STICK_R * g_scale), dy = (e->tfinger.y - t->sy) / (STICK_R * g_scale);
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
        if (!release_at) { e.tfinger.x = STICK_CX; e.tfinger.y = STICK_CY; }
        else { e.tfinger.x = STICK_CX + x * STICK_R; e.tfinger.y = STICK_CY + y * STICK_R; }
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

static void rrect(ImDrawList *dl, float x, float y, float w, float h, ImU32 fill, ImU32 line, float th) {
    ImVec2 a(px(x, ImGui::GetIO().DisplaySize.x), px(y, ImGui::GetIO().DisplaySize.y));
    ImVec2 b(px(x + w, ImGui::GetIO().DisplaySize.x), px(y + h, ImGui::GetIO().DisplaySize.y));
    dl->AddRectFilled(a, b, fill, 12 * g_scale);
    dl->AddRect(a, b, line, 12 * g_scale, 0, th);
}

void touch_pad_draw(float dw, float dh, bool menu_open, bool in_game) {
    g_scale = g_settings.touch_scale > 0.3f ? g_settings.touch_scale : 1.0f;
    g_drawn = visible_in(menu_open, in_game);
    if (!g_drawn) return;
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    const float size = fminf(dw, dh);  // one scale for both axes: circles stay round on a 4:3 screen
    const float fade = 0.30f;
    const ImU32 fill = IM_COL32(20, 24, 32, (int)(255 * fade));
    const ImU32 line = IM_COL32(215, 220, 230, (int)(255 * fade * 2.1f));
    const ImU32 text = IM_COL32(235, 238, 245, (int)(255 * fade * 2.6f));
    const float th = 2.0f * g_scale;
    const ImU32 press = IM_COL32(250, 205, 90, (int)(255 * fade * 2.4f));

    // stick
    {
        ImVec2 c(px(STICK_CX, dw), px(STICK_CY, dh));
        float r = px(STICK_R, size);
        dl->AddCircleFilled(c, r, fill, 48);
        dl->AddCircle(c, r, line, 48, th);
        ImVec2 k(c.x + g_stick_x * r * 0.62f, c.y + g_stick_y * r * 0.62f);
        bool held = fabsf(g_stick_x) > 0.02f || fabsf(g_stick_y) > 0.02f;
        ring(dl, k, px(KNOB_R, size), held ? IM_COL32(250, 205, 90, 150) : fill, held ? press : line, th);
    }
    // face buttons
    static const struct { int ctl; const char *name; } faces[] = {{CTL_A, "A"}, {CTL_B, "B"}, {CTL_X, "X"}, {CTL_Y, "Y"}};
    for (size_t i = 0; i < sizeof faces / sizeof *faces; i++) {
        float r;
        V2 p = face_pos(faces[i].ctl, &r);
        bool down = ctl_down(faces[i].ctl);
        ImVec2 c(px(p.x, dw), px(p.y, dh));
        ring(dl, c, px(r, size), down ? IM_COL32(250, 205, 90, 170) : fill, down ? press : line, th);
        label(dl, c, faces[i].name, px(r, size) * 1.05f, text);
    }
    // shoulders
    static const struct { int ctl; const char *name; } sh[] = {{CTL_L, "L"}, {CTL_ZL, "ZL"}, {CTL_R, "R"}, {CTL_ZR, "ZR"}};
    for (size_t i = 0; i < sizeof sh / sizeof *sh; i++) {
        float x, y, w, h;
        if (!shoulder_rect(sh[i].ctl, &x, &y, &w, &h)) continue;
        bool down = ctl_down(sh[i].ctl);
        rrect(dl, x, y, w, h, down ? IM_COL32(250, 205, 90, 170) : fill, down ? press : line, th);
        label(dl, ImVec2(px(x + w * 0.5f, dw), px(y + h * 0.5f, dh)), sh[i].name, px(SHOULDER_H, size) * 0.62f, text);
    }
    // - + and the overlay menu
    static const struct { int ctl; const char *name; } small[] = {{CTL_MINUS, "-"}, {CTL_PLUS, "+"}, {CTL_MENU, "="}};
    for (size_t i = 0; i < sizeof small / sizeof *small; i++) {
        float r;
        V2 p = small_pos(small[i].ctl, &r);
        bool down = ctl_down(small[i].ctl);
        ImVec2 c(px(p.x, dw), px(p.y, dh));
        ring(dl, c, px(r, size), down ? IM_COL32(250, 205, 90, 170) : fill, down ? press : line, th);
        label(dl, c, small[i].name, px(r, size) * 1.05f, text);
    }
}
