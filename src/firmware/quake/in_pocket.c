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

    refresh_active_pad();
    joy = (active_pad == 1) ? CONT1_JOY : CONT2_JOY;
    raw_keys = (active_pad == 1) ? CONT1_KEY : CONT2_KEY;
    keys = normalize_keys(raw_keys);

    /* Analog sticks: unsigned 0-255, center at 128 */
    if (joy == 0u) {
        /* Some digital-only controllers report 0 for JOY when idle. */
        joy = 0x00008080u;
    }
    lstick_x = (int)(joy & 0xFF) - 128;
    lstick_y = (int)((joy >> 8) & 0xFF) - 128;

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
}
