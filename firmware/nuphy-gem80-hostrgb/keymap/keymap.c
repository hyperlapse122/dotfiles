#include "../default/keymap.c"
#include "raw_hid.h"
#include "common/core/keyboard.h"

#define HOSTRGB_CMD 0x60
#define HOSTRGB_PROTOCOL 0x02
#define HOSTRGB_LEDS_PER_PACKET 9

// The side chain is a second WS2812 string that RGB_MATRIX_LED_COUNT does not
// cover. Lengths mirror keyboards/nuphy/gem80/side.h: SIDE_LINE 5 top strip
// followed by LOGO_LINE 7, so side_leds[] and this buffer share an index.
#define HOSTRGB_SIDE_STRIP_COUNT 5
#define HOSTRGB_SIDE_LOGO_COUNT 7
#define HOSTRGB_SIDE_LED_COUNT (HOSTRGB_SIDE_STRIP_COUNT + HOSTRGB_SIDE_LOGO_COUNT)
#define HOSTRGB_SIDE_FIRST RGB_MATRIX_LED_COUNT
#define HOSTRGB_LED_COUNT (RGB_MATRIX_LED_COUNT + HOSTRGB_SIDE_LED_COUNT)

#define HOSTRGB_DEADLINE_UNIT_MS 10

// A rejected command echoes with this bit set on the subcommand byte, so the
// host can tell "refused" from "done". Without it a refusal is indistinguishable
// from success and a host would believe it holds a region it never entered.
#define HOSTRGB_SUB_REJECTED 0x80

enum hostrgb_sub {
    HOSTRGB_SUB_PROBE     = 0x00,
    HOSTRGB_SUB_MODE      = 0x01,
    HOSTRGB_SUB_SET       = 0x02,
    HOSTRGB_SUB_HEARTBEAT = 0x03,
};

enum hostrgb_region {
    HOSTRGB_REGION_KEYS = 1 << 0,
    HOSTRGB_REGION_SIDE = 1 << 1,
    HOSTRGB_REGION_ALL  = HOSTRGB_REGION_KEYS | HOSTRGB_REGION_SIDE,
};

void side_rgb_set_color(int index, uint8_t red, uint8_t green, uint8_t blue);

rgb_t hostrgb_buf[RGB_MATRIX_LED_COUNT];
rgb_t hostrgb_side_buf[HOSTRGB_SIDE_LED_COUNT];

static uint8_t  hostrgb_regions      = 0;
static uint16_t hostrgb_deadline     = 0; // in HOSTRGB_DEADLINE_UNIT_MS units
static uint32_t hostrgb_signal_timer = 0;

// The RGB matrix mode is global, so only the KEYS bit may switch it. Reacting
// to a non-zero mask instead would take the 89 stored key effects away from a
// client that asked for SIDE alone.
static void hostrgb_apply_regions(uint8_t mask) {
    hostrgb_regions = mask;

    if (mask & HOSTRGB_REGION_KEYS) {
        rgb_matrix_enable_noeeprom();
        rgb_matrix_mode_noeeprom(RGB_MATRIX_CUSTOM_host_direct);
    } else {
        rgb_matrix_reload_from_eeprom();
    }
}

// The explicit exit and the watchdog share this path so both land on the same
// state: the user's stored effect, and a deadline that a later entry cannot
// inherit.
static void hostrgb_leave_direct(void) {
    hostrgb_apply_regions(0);
    hostrgb_deadline     = 0;
    hostrgb_signal_timer = 0;
}

static void hostrgb_arm(uint16_t deadline) {
    hostrgb_deadline     = deadline;
    hostrgb_signal_timer = timer_read32();
}

// Returning true tells quantum/via.c the command was fully handled *including*
// the reply, so each handled branch must call raw_hid_send() itself. Returning
// true without it makes the device swallow the command and answer nothing --
// not even VIA's id_unhandled, which is what an unknown command id returns.
bool via_command_kb(uint8_t *data, uint8_t length) {
    if (length < 2 || data[0] != HOSTRGB_CMD) {
        return false;
    }

    switch (data[1]) {
        case HOSTRGB_SUB_PROBE:
            data[2] = HOSTRGB_PROTOCOL;
            data[3] = HOSTRGB_LED_COUNT;
            data[4] = HOSTRGB_LEDS_PER_PACKET;
            data[5] = HOSTRGB_SIDE_FIRST;
            raw_hid_send(data, length);
            return true;

        case HOSTRGB_SUB_MODE: {
            uint8_t mask = data[2] & HOSTRGB_REGION_ALL;

            if (mask) {
                uint16_t deadline = (uint16_t)data[3] | ((uint16_t)data[4] << 8);
                // A zero deadline would enter direct mode unarmed, which is the
                // stuck-frame state the watchdog exists to prevent.
                if (deadline) {
                    hostrgb_apply_regions(mask);
                    hostrgb_arm(deadline);
                } else {
                    data[1] |= HOSTRGB_SUB_REJECTED;
                }
            } else {
                hostrgb_leave_direct();
            }

            raw_hid_send(data, length);
            return true;
        }

        case HOSTRGB_SUB_SET: {
            uint8_t start = data[2];
            uint8_t count = data[3];
            if (count > HOSTRGB_LEDS_PER_PACKET) {
                count = HOSTRGB_LEDS_PER_PACKET;
            }
            for (uint8_t i = 0; i < count; i++) {
                uint16_t led = (uint16_t)start + i;
                if (led >= HOSTRGB_LED_COUNT) {
                    break;
                }
                rgb_t *pixel = (led < HOSTRGB_SIDE_FIRST) ? &hostrgb_buf[led] : &hostrgb_side_buf[led - HOSTRGB_SIDE_FIRST];
                pixel->r     = data[4 + i * 3];
                pixel->g     = data[5 + i * 3];
                pixel->b     = data[6 + i * 3];
            }
            raw_hid_send(data, length);
            return true;
        }

        case HOSTRGB_SUB_HEARTBEAT: {
            uint16_t deadline = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
            if (deadline) {
                hostrgb_arm(deadline);
            } else {
                data[1] |= HOSTRGB_SUB_REJECTED;
            }
            raw_hid_send(data, length);
            return true;
        }
    }

    return false;
}

// gem80-common.c calls this from housekeeping_task_kb() after the nuphy hook,
// so the keymap gets every loop tick without touching shared code.
void housekeeping_task_user(void) {
    if (!hostrgb_regions) {
        return;
    }

    if (timer_elapsed32(hostrgb_signal_timer) >= (uint32_t)hostrgb_deadline * HOSTRGB_DEADLINE_UNIT_MS) {
        // No raw_hid_send() here: this answers no host request.
        hostrgb_leave_direct();
    }
}

// Strong overrides of the weak hooks the patches/ side-chain patch defines.
bool hostrgb_side_direct_active(void) {
    return (hostrgb_regions & HOSTRGB_REGION_SIDE) != 0;
}

void hostrgb_side_direct_show(uint8_t first, uint8_t count) {
    for (uint8_t i = 0; i < count; i++) {
        uint8_t led = first + i;
        if (led >= HOSTRGB_SIDE_LED_COUNT) {
            break;
        }
        side_rgb_set_color(led, hostrgb_side_buf[led].r, hostrgb_side_buf[led].g, hostrgb_side_buf[led].b);
    }
}
