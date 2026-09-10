#include "../default/keymap.c"
#include "raw_hid.h"

#define HOSTRGB_CMD 0x60
#define HOSTRGB_PROTOCOL 0x01
#define HOSTRGB_LEDS_PER_PACKET 9

enum hostrgb_sub {
    HOSTRGB_SUB_PROBE = 0x00,
    HOSTRGB_SUB_MODE  = 0x01,
    HOSTRGB_SUB_SET   = 0x02,
};

rgb_t hostrgb_buf[RGB_MATRIX_LED_COUNT];

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
            data[3] = RGB_MATRIX_LED_COUNT;
            data[4] = HOSTRGB_LEDS_PER_PACKET;
            raw_hid_send(data, length);
            return true;

        case HOSTRGB_SUB_MODE:
            if (data[2]) {
                rgb_matrix_enable_noeeprom();
                rgb_matrix_mode_noeeprom(RGB_MATRIX_CUSTOM_host_direct);
            } else {
                rgb_matrix_reload_from_eeprom();
            }
            raw_hid_send(data, length);
            return true;

        case HOSTRGB_SUB_SET: {
            uint8_t start = data[2];
            uint8_t count = data[3];
            if (count > HOSTRGB_LEDS_PER_PACKET) {
                count = HOSTRGB_LEDS_PER_PACKET;
            }
            for (uint8_t i = 0; i < count; i++) {
                uint8_t led = start + i;
                if (led >= RGB_MATRIX_LED_COUNT) {
                    break;
                }
                hostrgb_buf[led].r = data[4 + i * 3];
                hostrgb_buf[led].g = data[5 + i * 3];
                hostrgb_buf[led].b = data[6 + i * 3];
            }
            raw_hid_send(data, length);
            return true;
        }
    }

    return false;
}
