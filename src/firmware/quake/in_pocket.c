/*
 * in_pocket.c -- PocketQuake input driver
 * Reads Analogue Pocket controller via MMIO registers
 */

#include "quakedef.h"

/* Controller MMIO registers */
#define CONT1_KEY  (*(volatile unsigned int *)0x40000050)
#define CONT1_JOY  (*(volatile unsigned int *)0x40000054)
#define CONT1_TRIG (*(volatile unsigned int *)0x40000058)
#define CONT2_KEY  (*(volatile unsigned int *)0x4000005C)
#define CONT2_JOY  (*(volatile unsigned int *)0x40000060)
#define CONT2_TRIG (*(volatile unsigned int *)0x40000064)

/* Analogizer SNAC controller MMIO registers */
#define SNAC1_BTN  (*(volatile unsigned int *)0x40000068)
#define SNAC1_JOY  (*(volatile unsigned int *)0x4000006C)
#define SNAC2_BTN  (*(volatile unsigned int *)0x40000070)
#define SNAC2_JOY  (*(volatile unsigned int *)0x40000074)

/* Key bitmap bits */
#define KEY_DPAD_UP     (1 << 0)
#define KEY_DPAD_DOWN   (1 << 1)
#define KEY_DPAD_LEFT   (1 << 2)
#define KEY_DPAD_RIGHT  (1 << 3)
#define KEY_FACE_A      (1 << 4)
#define KEY_FACE_B      (1 << 5)
#define KEY_FACE_X      (1 << 6)
#define KEY_FACE_Y      (1 << 7)
#define KEY_TRIG_L1     (1 << 8)
#define KEY_TRIG_R1     (1 << 9)
#define KEY_TRIG_L2     (1 << 10)
#define KEY_TRIG_R2     (1 << 11)
#define KEY_SELECT      (1 << 14)
#define KEY_START       (1 << 15)
#define KEY_MASK (KEY_DPAD_UP | KEY_DPAD_DOWN | KEY_DPAD_LEFT | KEY_DPAD_RIGHT | \
                  KEY_FACE_A | KEY_FACE_B | KEY_FACE_X | KEY_FACE_Y | \
                  KEY_TRIG_L1 | KEY_TRIG_R1 | KEY_TRIG_L2 | KEY_TRIG_R2 | \
                  KEY_SELECT | KEY_START)

/* SNAC button bits (PSX layout — dpad left/right swapped vs Pocket) */
#define SNAC_DPAD_UP     (1 << 0)
#define SNAC_DPAD_DOWN   (1 << 1)
#define SNAC_DPAD_RIGHT  (1 << 2)
#define SNAC_DPAD_LEFT   (1 << 3)
#define SNAC_FACE_A      (1 << 4)
#define SNAC_FACE_B      (1 << 5)
#define SNAC_FACE_X      (1 << 6)
#define SNAC_FACE_Y      (1 << 7)
#define SNAC_TRIG_L1     (1 << 8)
#define SNAC_TRIG_R1     (1 << 9)
#define SNAC_TRIG_L2     (1 << 10)
#define SNAC_TRIG_R2     (1 << 11)
#define SNAC_SELECT      (1 << 14)
#define SNAC_START       (1 << 15)

/* Remap SNAC button bits to Pocket convention (swap dpad left/right) */
static unsigned int snac_to_pocket_buttons(unsigned int snac)
{
    unsigned int out = snac & ~(SNAC_DPAD_LEFT | SNAC_DPAD_RIGHT);
    if (snac & SNAC_DPAD_LEFT)  out |= KEY_DPAD_LEFT;
    if (snac & SNAC_DPAD_RIGHT) out |= KEY_DPAD_RIGHT;
    return out;
}

/* Dock keyboard MMIO registers (cont3 slot) */
#define KB_KEY   (*(volatile unsigned int *)0x40000078)
#define KB_JOY   (*(volatile unsigned int *)0x4000007C)
#define KB_TRIG  (*(volatile unsigned int *)0x40000080)

/* Dock mouse MMIO registers (cont4 slot) */
#define MOUSE_KEY  (*(volatile unsigned int *)0x40000084)
#define MOUSE_JOY  (*(volatile unsigned int *)0x40000088)
#define MOUSE_TRIG (*(volatile unsigned int *)0x4000008C)

/* USB HID modifier bits (cont3_key[15:0]) */
#define HID_MOD_LCTRL   (1 << 0)
#define HID_MOD_LSHIFT  (1 << 1)
#define HID_MOD_LALT    (1 << 2)
#define HID_MOD_RCTRL   (1 << 4)
#define HID_MOD_RSHIFT  (1 << 5)
#define HID_MOD_RALT    (1 << 6)

/* USB HID scancode to Quake key mapping */
static int hid_to_quake(unsigned int scancode)
{
    if (scancode == 0) return 0;
    /* Letters a-z: HID 0x04-0x1D */
    if (scancode >= 0x04 && scancode <= 0x1D)
        return 'a' + (scancode - 0x04);
    /* Numbers 1-9: HID 0x1E-0x26 */
    if (scancode >= 0x1E && scancode <= 0x26)
        return '1' + (scancode - 0x1E);
    /* Number 0: HID 0x27 */
    if (scancode == 0x27) return '0';

    switch (scancode) {
    case 0x28: return K_ENTER;
    case 0x29: return K_ESCAPE;
    case 0x2A: return K_BACKSPACE;
    case 0x2B: return K_TAB;
    case 0x2C: return K_SPACE;
    case 0x2D: return '-';
    case 0x2E: return '=';
    case 0x2F: return '[';
    case 0x30: return ']';
    case 0x31: return '\\';
    case 0x33: return ';';
    case 0x34: return '\'';
    case 0x35: return '`';
    case 0x36: return ',';
    case 0x37: return '.';
    case 0x38: return '/';
    /* F1-F12: HID 0x3A-0x45 */
    case 0x3A: return K_F1;
    case 0x3B: return K_F2;
    case 0x3C: return K_F3;
    case 0x3D: return K_F4;
    case 0x3E: return K_F5;
    case 0x3F: return K_F6;
    case 0x40: return K_F7;
    case 0x41: return K_F8;
    case 0x42: return K_F9;
    case 0x43: return K_F10;
    case 0x44: return K_F11;
    case 0x45: return K_F12;
    /* Navigation */
    case 0x49: return K_INS;
    case 0x4A: return K_HOME;
    case 0x4B: return K_PGUP;
    case 0x4C: return K_DEL;
    case 0x4D: return K_END;
    case 0x4E: return K_PGDN;
    case 0x4F: return K_RIGHTARROW;
    case 0x50: return K_LEFTARROW;
    case 0x51: return K_DOWNARROW;
    case 0x52: return K_UPARROW;
    case 0x48: return K_PAUSE;
    default:   return 0;
    }
}

#define MAX_HID_KEYS 6
static unsigned int prev_hid_scancodes[MAX_HID_KEYS];
static unsigned int prev_hid_mods;
static unsigned int prev_mouse_report;
static unsigned int prev_mouse_buttons;

static unsigned int prev_keys = 0;
static unsigned int prev_raw_key_bits = 0;
static qboolean key_idle_known = false;
static unsigned int key_idle_bits = 0;
static int key_debug_logs = 0;
static int key_poll_logs = 0;
static unsigned int key_poll_count = 0;
static int active_pad = 1;
static int face_a_down_key = 0;
static int face_b_down_key = 0;
static qboolean dpad_up_nav_down = false;
static qboolean dpad_down_nav_down = false;
static qboolean dpad_up_game_down = false;
static qboolean dpad_down_game_down = false;


static unsigned int normalize_keys(unsigned int raw_keys)
{
    unsigned int key_bits;
    unsigned int non_key_bits;

    if (!key_idle_known) {
        /* Capture per-button idle level once, then treat changes from idle as presses.
         * This handles mixed polarity and buttons that may be hard-wired inactive. */
        key_idle_bits = raw_keys & KEY_MASK;
        key_idle_known = true;
    }

    key_bits = raw_keys & KEY_MASK;
    key_bits = (key_bits ^ key_idle_bits) & KEY_MASK;

    non_key_bits = raw_keys & ~KEY_MASK;
    return non_key_bits | key_bits;
}

static qboolean controller_live(unsigned int key, unsigned int joy, unsigned int trig)
{
    if ((key & KEY_MASK) != 0u) return true;
    if (joy != 0u) return true;
    if ((trig & 0xFFFFu) != 0u) return true;
    return false;
}

static void refresh_active_pad(void)
{
    unsigned int k1 = CONT1_KEY;
    unsigned int j1 = CONT1_JOY;
    unsigned int t1 = CONT1_TRIG;
    unsigned int k2 = CONT2_KEY;
    unsigned int j2 = CONT2_JOY;
    unsigned int t2 = CONT2_TRIG;
    qboolean live1 = controller_live(k1, j1, t1);
    qboolean live2 = controller_live(k2, j2, t2);
    int new_pad = active_pad;
    unsigned int raw_keys;

    if (!live1 && live2) new_pad = 2;
    if (!live2 && live1) new_pad = 1;

    if (new_pad != active_pad) {
        active_pad = new_pad;
        raw_keys = (active_pad == 1) ? k1 : k2;
        key_idle_known = false;
        prev_keys = normalize_keys(raw_keys);
        prev_raw_key_bits = raw_keys & KEY_MASK;
        if (0) Con_Printf("IN switch CONT%d (c1 k=%08x j=%08x c2 k=%08x j=%08x)\n",
                          active_pad, k1, j1, k2, j2);
    }
}

/* Map Pocket buttons to Quake keys */
typedef struct {
    unsigned int pocket_mask;
    int quake_key;
} keymap_t;

static const keymap_t keymap[] = {
    { KEY_DPAD_LEFT,   K_LEFTARROW },  /* Turn left */
    { KEY_DPAD_RIGHT,  K_RIGHTARROW }, /* Turn right */
    { KEY_FACE_X,      K_UPARROW },    /* Move forward (top) */
    { KEY_FACE_Y,      ',' },          /* Strafe left (left) */
    { KEY_TRIG_L1,     K_SPACE },      /* Jump (left shoulder) */
    { KEY_TRIG_R1,     K_CTRL },       /* Fire (right shoulder) */
    { KEY_SELECT,      '/' },          /* Change weapon (left of Analogue) */
    { KEY_START,       K_ESCAPE },     /* Menu */
    { 0, 0 }
};

void IN_Init(void)
{
    unsigned int raw_keys;
    unsigned int c1k = CONT1_KEY;
    unsigned int c1j = CONT1_JOY;
    unsigned int c1t = CONT1_TRIG;
    unsigned int c2k = CONT2_KEY;
    unsigned int c2j = CONT2_JOY;
    unsigned int c2t = CONT2_TRIG;

    active_pad = (controller_live(c1k, c1j, c1t) || !controller_live(c2k, c2j, c2t)) ? 1 : 2;
    raw_keys = (active_pad == 1) ? c1k : c2k;
    key_idle_known = false;
    prev_keys = normalize_keys(raw_keys);
    prev_raw_key_bits = raw_keys & KEY_MASK;
    key_debug_logs = 0;
    key_poll_logs = 0;
    key_poll_count = 0;
    face_a_down_key = 0;
    face_b_down_key = 0;
    dpad_up_nav_down = false;
    dpad_down_nav_down = false;
    dpad_up_game_down = false;
    dpad_down_game_down = false;
    /* Initialize keyboard/mouse state */
    for (int i = 0; i < MAX_HID_KEYS; i++)
        prev_hid_scancodes[i] = 0;
    prev_hid_mods = 0;
    prev_mouse_report = 0;
    prev_mouse_buttons = 0;
    if (0) Con_Printf("IN init CONT%d c1(k=%08x j=%08x) c2(k=%08x j=%08x) raw=%08x norm=%08x active_%s\n",
                      active_pad, c1k, c1j, c2k, c2j, raw_keys, prev_keys,
                      "calibrated");
}

void IN_Shutdown(void)
{
}

void IN_Commands(void)
{
}

void IN_Move(usercmd_t *cmd)
{
    unsigned int joy;
    unsigned int raw_keys;
    unsigned int keys;
    int lstick_x, lstick_y;
    unsigned int snac_joy;
    int snac_lx, snac_ly;
    int snac_rx, snac_ry;

    refresh_active_pad();
    joy = (active_pad == 1) ? CONT1_JOY : CONT2_JOY;
    raw_keys = (active_pad == 1) ? CONT1_KEY : CONT2_KEY;

    /* Merge SNAC buttons (remapped to Pocket convention) */
    raw_keys |= snac_to_pocket_buttons(SNAC1_BTN);

    keys = normalize_keys(raw_keys);

    /* Analog sticks: unsigned 0-255, center at 128 */
    if (joy == 0u) {
        /* Some digital-only controllers report 0 for JOY when idle. */
        joy = 0x00008080u;
    }
    lstick_x = (int)(joy & 0xFF) - 128;
    lstick_y = (int)((joy >> 8) & 0xFF) - 128;

    /* Merge SNAC analog sticks (PSX DualShock: lstick for movement) */
    snac_joy = SNAC1_JOY;
    if (snac_joy != 0x80808080u && snac_joy != 0u) {
        snac_lx = (int)(snac_joy & 0xFF) - 128;
        snac_ly = (int)((snac_joy >> 8) & 0xFF) - 128; 
        if (snac_lx > 16 || snac_lx < -16) lstick_x += snac_lx;
        if (snac_ly > 16 || snac_ly < -16) lstick_y -= snac_ly; /* fix up-down movement*/

        /* Right stick for look (view angles) */
        snac_rx = (int)((snac_joy >> 16) & 0xFF) - 128;
        snac_ry = (int)((snac_joy >> 24) & 0xFF) - 128;
        if (snac_rx > 16 || snac_rx < -16)
            cl.viewangles[YAW] -= snac_rx * 0.03f;
        if (snac_ry > 16 || snac_ry < -16)
            cl.viewangles[PITCH] += snac_ry * 0.03f;
    }

    /* Dead zone */
    if (lstick_x > -16 && lstick_x < 16) lstick_x = 0;
    if (lstick_y > -16 && lstick_y < 16) lstick_y = 0;

    /* Scale analog input to Quake movement */
    cmd->forwardmove += lstick_y * cl_forwardspeed.value / 128.0f;
    cmd->sidemove += lstick_x * cl_sidespeed.value / 128.0f;

    /* D-pad is look (handled via key events in IN_SendKeyEvents).
     * L2/R2 analog triggers for strafe if available. */
    if (key_dest == key_game) {
        if (keys & KEY_TRIG_L2)   cmd->sidemove -= cl_sidespeed.value;
        if (keys & KEY_TRIG_R2)   cmd->sidemove += cl_sidespeed.value;
    }

    /* Dock USB mouse: delta movement → view angles.
     * IN_SendKeyEvents (runs first) handles button events without updating
     * prev_mouse_report. We consume the delta and update the counter here. */
    {
        unsigned int mouse_report = MOUSE_KEY & 0xFFFF;
        if (mouse_report != prev_mouse_report) {
            unsigned int mouse_joy = MOUSE_JOY;
            unsigned int mouse_trig = MOUSE_TRIG;
            short delta_x = (short)(mouse_joy & 0xFFFF);
            short delta_y = (short)(mouse_trig & 0xFFFF);

            if (key_dest == key_game) {
                cl.viewangles[YAW] -= delta_x * sensitivity.value * 0.022f;
                cl.viewangles[PITCH] += delta_y * sensitivity.value * 0.022f;
            }
            prev_mouse_report = mouse_report;
        }
    }
}

void IN_SendKeyEvents(void)
{
    unsigned int raw_keys;
    unsigned int joy;
    unsigned int keys;
    unsigned int changed;
    unsigned int raw_key_bits;
    qboolean nav_context;
    qboolean up_down;
    qboolean down_down;
    const keymap_t *km;

    refresh_active_pad();
    raw_keys = (active_pad == 1) ? CONT1_KEY : CONT2_KEY;
    joy = (active_pad == 1) ? CONT1_JOY : CONT2_JOY;

    /* Merge SNAC buttons (remapped to Pocket convention) */
    raw_keys |= snac_to_pocket_buttons(SNAC1_BTN);

    keys = normalize_keys(raw_keys);
    changed = keys ^ prev_keys;
    raw_key_bits = raw_keys & KEY_MASK;

    key_poll_count++;
    if ((key_poll_count & 127u) == 0u && key_poll_logs < 16) {
        if (0) Con_Printf("IN poll CONT%d raw=%08x norm=%08x joy=%08x c1(k=%08x j=%08x) c2(k=%08x j=%08x)\n",
                   active_pad, raw_keys, keys, joy, CONT1_KEY, CONT1_JOY, CONT2_KEY, CONT2_JOY);
        key_poll_logs++;
    }

    if (raw_key_bits != prev_raw_key_bits && key_debug_logs < 24) {
        if (0) Con_Printf("IN raw CONT%d=%08x norm=%08x joy=%08x\n", active_pad, raw_keys, keys, joy);
        key_debug_logs++;
        prev_raw_key_bits = raw_key_bits;
    }

    /* D-pad up/down: menu = K_UPARROW/K_DOWNARROW, game = 'a'/'z' (look up/down) */
    nav_context = (key_dest == key_menu) || (key_dest == key_console);
    up_down = (keys & KEY_DPAD_UP) ? true : false;
    down_down = (keys & KEY_DPAD_DOWN) ? true : false;

    if (nav_context) {
        /* Release game-mode look keys when entering menus */
        if (dpad_up_game_down) { Key_Event('a', false); dpad_up_game_down = false; }
        if (dpad_down_game_down) { Key_Event('z', false); dpad_down_game_down = false; }

        if (up_down && !dpad_up_nav_down) {
            Key_Event(K_UPARROW, true);
            dpad_up_nav_down = true;
        } else if (!up_down && dpad_up_nav_down) {
            Key_Event(K_UPARROW, false);
            dpad_up_nav_down = false;
        }

        if (down_down && !dpad_down_nav_down) {
            Key_Event(K_DOWNARROW, true);
            dpad_down_nav_down = true;
        } else if (!down_down && dpad_down_nav_down) {
            Key_Event(K_DOWNARROW, false);
            dpad_down_nav_down = false;
        }
    } else {
        /* Release nav keys when entering game */
        if (dpad_up_nav_down) { Key_Event(K_UPARROW, false); dpad_up_nav_down = false; }
        if (dpad_down_nav_down) { Key_Event(K_DOWNARROW, false); dpad_down_nav_down = false; }

        if (up_down && !dpad_up_game_down) {
            Key_Event('a', true);
            dpad_up_game_down = true;
        } else if (!up_down && dpad_up_game_down) {
            Key_Event('a', false);
            dpad_up_game_down = false;
        }

        if (down_down && !dpad_down_game_down) {
            Key_Event('z', true);
            dpad_down_game_down = true;
        } else if (!down_down && dpad_down_game_down) {
            Key_Event('z', false);
            dpad_down_game_down = false;
        }
    }

    /* Face A (right): menu = K_ENTER, game = strafe right */
    if (changed & KEY_FACE_A) {
        qboolean down = (keys & KEY_FACE_A) ? true : false;
        if (down) {
            face_a_down_key = (key_dest == key_menu) ? K_ENTER : '.';
            Key_Event(face_a_down_key, true);
        } else {
            if (face_a_down_key == 0)
                face_a_down_key = (key_dest == key_menu) ? K_ENTER : '.';
            Key_Event(face_a_down_key, false);
            face_a_down_key = 0;
        }
    }

    /* Face B (bottom): menu = K_ENTER, game = walk backward */
    if (changed & KEY_FACE_B) {
        qboolean down = (keys & KEY_FACE_B) ? true : false;
        if (down) {
            face_b_down_key = (key_dest == key_menu) ? K_ENTER : K_DOWNARROW;
            Key_Event(face_b_down_key, true);
        } else {
            if (face_b_down_key == 0)
                face_b_down_key = (key_dest == key_menu) ? K_ENTER : K_DOWNARROW;
            Key_Event(face_b_down_key, false);
            face_b_down_key = 0;
        }
    }

    for (km = keymap; km->pocket_mask; km++) {
        if (changed & km->pocket_mask) {
            Key_Event(km->quake_key, (keys & km->pocket_mask) ? true : false);
        }
    }

    prev_keys = keys;

    /* ---- Dock USB keyboard (cont3) ---- */
    {
        unsigned int kb_key = KB_KEY;
        unsigned int kb_type = (kb_key >> 28) & 0xF;
        if (kb_type == 0x4) {
            unsigned int kb_joy = KB_JOY;
            unsigned int kb_trig = KB_TRIG;
            unsigned int mods = kb_key & 0xFFFF;
            unsigned int cur_scancodes[MAX_HID_KEYS];
            int i, j, qk;
            qboolean found;

            /* Extract 6 scancodes from joy (4) and trig (2) */
            cur_scancodes[0] = (kb_joy >> 24) & 0xFF;
            cur_scancodes[1] = (kb_joy >> 16) & 0xFF;
            cur_scancodes[2] = (kb_joy >> 8) & 0xFF;
            cur_scancodes[3] = kb_joy & 0xFF;
            cur_scancodes[4] = (kb_trig >> 8) & 0xFF;
            cur_scancodes[5] = kb_trig & 0xFF;

            /* Key releases: scancodes in prev but not in cur */
            for (i = 0; i < MAX_HID_KEYS; i++) {
                if (prev_hid_scancodes[i] == 0) continue;
                found = false;
                for (j = 0; j < MAX_HID_KEYS; j++) {
                    if (cur_scancodes[j] == prev_hid_scancodes[i]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    qk = hid_to_quake(prev_hid_scancodes[i]);
                    if (qk) Key_Event(qk, false);
                }
            }

            /* Key presses: scancodes in cur but not in prev */
            for (i = 0; i < MAX_HID_KEYS; i++) {
                if (cur_scancodes[i] == 0) continue;
                found = false;
                for (j = 0; j < MAX_HID_KEYS; j++) {
                    if (prev_hid_scancodes[j] == cur_scancodes[i]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    qk = hid_to_quake(cur_scancodes[i]);
                    if (qk) Key_Event(qk, true);
                }
            }

            /* Modifier key events */
            if ((mods ^ prev_hid_mods) & (HID_MOD_LCTRL | HID_MOD_RCTRL))
                Key_Event(K_CTRL, (mods & (HID_MOD_LCTRL | HID_MOD_RCTRL)) ? true : false);
            if ((mods ^ prev_hid_mods) & (HID_MOD_LSHIFT | HID_MOD_RSHIFT))
                Key_Event(K_SHIFT, (mods & (HID_MOD_LSHIFT | HID_MOD_RSHIFT)) ? true : false);
            if ((mods ^ prev_hid_mods) & (HID_MOD_LALT | HID_MOD_RALT))
                Key_Event(K_ALT, (mods & (HID_MOD_LALT | HID_MOD_RALT)) ? true : false);

            for (i = 0; i < MAX_HID_KEYS; i++)
                prev_hid_scancodes[i] = cur_scancodes[i];
            prev_hid_mods = mods;
        }
    }

    /* ---- Dock USB mouse buttons (cont4) ---- */
    /* Note: prev_mouse_report is updated in IN_Move (runs after this),
     * so both functions see the same new-report condition per frame. */
    {
        unsigned int mouse_report = MOUSE_KEY & 0xFFFF;
        if (mouse_report != prev_mouse_report) {
            unsigned int mouse_joy = MOUSE_JOY;
            unsigned int buttons = (mouse_joy >> 16) & 0xFFFF;
            unsigned int btn_changed = buttons ^ prev_mouse_buttons;

            if (btn_changed & 1)
                Key_Event(K_MOUSE1, (buttons & 1) ? true : false);
            if (btn_changed & 2)
                Key_Event(K_MOUSE2, (buttons & 2) ? true : false);
            if (btn_changed & 4)
                Key_Event(K_MOUSE3, (buttons & 4) ? true : false);

            prev_mouse_buttons = buttons;
        }
    }
}
