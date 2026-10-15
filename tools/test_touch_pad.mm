// Geometry and real SDL virtual-gamepad checks; no game files or GPU are needed.
#include "../runtime/ui/touch_pad.mm"
#include <assert.h>
#include <initializer_list>

Settings g_settings = {};

static void finger(Uint32 type, int ctl, SDL_FingerID id) {
    V2 p = ctl_centre(ctl);
    SDL_Event e = {}; e.type = type; e.tfinger.fingerID = id;
    e.tfinger.x = p.x; e.tfinger.y = p.y;
    assert(touch_pad_event(&e));
}

static void draw(float w, float h, float scale, bool menu = false) {
    ImGui::GetIO().DisplaySize = ImVec2(w, h);
    g_settings.touch_scale = scale;
    ImGui::NewFrame();
    touch_pad_draw(w, h, menu, true);
    ImGui::Render();
}

int main(void) {
    assert(SDL_Init(SDL_INIT_EVENTS | SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD));
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = NULL;
    ImGui::GetIO().DeltaTime = 1.0f / 60.0f;
    unsigned char *pixels; int fw, fh;
    ImGui::GetIO().Fonts->GetTexDataAsRGBA32(&pixels, &fw, &fh);
    g_settings.touch_controls = TOUCH_ON;
    touch_pad_init(); assert(g_joy);
    int layouts = 0;
    const V2 sizes[] = {{2732, 2048}, {2048, 1536}, {1920, 1080}, {2556, 1179}};
    for (V2 size : sizes) for (float scale : {0.6f, 1.0f, 1.6f}) {
        draw(size.x, size.y, scale);
        for (int ctl = CTL_STICK; ctl <= CTL_Y; ctl++) {
            V2 c = ctl_centre(ctl);
            assert(c.x > 0 && c.x < 1 && c.y > 0 && c.y < 1);
            assert(hit(c.x, c.y) == ctl);
        }
        float r; V2 b = face_pos(CTL_B, &r);
        assert(b.y + r <= g_layout.h - g_layout.unit * 0.03f);
        assert(g_layout.stick.y > g_layout.h * 0.75f);
        assert(g_layout.stick.x - g_layout.stick_r > 0);
        assert(g_layout.stick.y + g_layout.stick_r < g_layout.h);
        layouts++;
    }
    draw(2732, 2048, 1);
    finger(SDL_EVENT_FINGER_DOWN, CTL_L, 1);
    finger(SDL_EVENT_FINGER_DOWN, CTL_R, 2);
    SDL_UpdateJoysticks();
    assert(SDL_GetJoystickButton(g_joy, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER));
    assert(SDL_GetJoystickButton(g_joy, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
    finger(SDL_EVENT_FINGER_UP, CTL_L, 1);
    finger(SDL_EVENT_FINGER_UP, CTL_R, 2);
    finger(SDL_EVENT_FINGER_DOWN, CTL_A, 3);
    finger(SDL_EVENT_FINGER_DOWN, CTL_STICK, 4);
    V2 p = ctl_centre(CTL_STICK);
    float distance = g_layout.stick_r * 0.62f * 0.5f;
    SDL_Event e = {}; e.type = SDL_EVENT_FINGER_MOTION; e.tfinger.fingerID = 4;
    e.tfinger.x = p.x + distance / g_layout.w;
    e.tfinger.y = p.y + distance / g_layout.h;
    assert(touch_pad_event(&e)); SDL_UpdateJoysticks();
    assert(SDL_GetJoystickButton(g_joy, SDL_GAMEPAD_BUTTON_EAST));
    int x = SDL_GetJoystickAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTX);
    int y = SDL_GetJoystickAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTY);
    assert(abs(x - 16384) < 4 && abs(y - 16384) < 4);
    draw(2732, 2048, 1, true); SDL_UpdateJoysticks();
    assert(!SDL_GetJoystickButton(g_joy, SDL_GAMEPAD_BUTTON_EAST));
    assert(SDL_GetJoystickAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTX) == 0);
    assert(SDL_GetJoystickAxis(g_joy, SDL_GAMEPAD_AXIS_LEFTY) == 0);
    printf("%d layouts: visible hit targets, bottom anchors, L+R, stick+A and menu release passed\n", layouts);
    ImGui::DestroyContext(); SDL_CloseJoystick(g_joy); SDL_DetachVirtualJoystick(g_id); SDL_Quit();
    return 0;
}
