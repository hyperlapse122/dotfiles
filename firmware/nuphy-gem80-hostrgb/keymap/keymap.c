#include "../default/keymap.c"

#define HOSTRGB_CMD 0x60
#define HOSTRGB_PROTOCOL 0x01
#define HOSTRGB_LEDS_PER_PACKET 9

enum hostrgb_sub {
    HOSTRGB_SUB_PROBE = 0x00,
    HOSTRGB_SUB_MODE  = 0x01,
    HOSTRGB_SUB_SET   = 0x02,
};

uint8_t hostrgb_buf[RGB_MATRIX_LED_COUNT][3];

bool via_command_kb(uint8_t *data, uint8_t length) {
    if (length < 2 || data[0] != HOSTRGB_CMD) {
        return false;
    }

    switch (data[1]) {
        case HOSTRGB_SUB_PROBE:
            data[2] = HOSTRGB_PROTOCOL;
            data[3] = RGB_MATRIX_LED_COUNT;
            data[4] = HOSTRGB_LEDS_PER_PACKET;
            return true;

        case HOSTRGB_SUB_MODE:
            if (data[2]) {
                rgb_matrix_mode_noeeprom(RGB_MATRIX_CUSTOM_host_direct);
            } else {
                rgb_matrix_reload_from_eeprom();
            }
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
                hostrgb_buf[led][0] = data[4 + i * 3];
                hostrgb_buf[led][1] = data[5 + i * 3];
                hostrgb_buf[led][2] = data[6 + i * 3];
            }
            return true;
        }
    }

    return false;
}
