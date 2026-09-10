RGB_MATRIX_EFFECT(game_mode)
RGB_MATRIX_EFFECT(position_mode)
RGB_MATRIX_EFFECT(host_direct)

#ifdef RGB_MATRIX_CUSTOM_EFFECT_IMPLS

extern rgb_config_t rgb_matrix_config;
extern rgb_t        hostrgb_buf[RGB_MATRIX_LED_COUNT];

static bool game_mode(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);

    for (uint8_t i = led_min; i < led_max; i++) {
        rgb_matrix_set_color(i, 0x00, 0x00, 0x00);
    }

    RGB rgb = hsv_to_rgb(rgb_matrix_config.hsv);
    rgb_matrix_set_color(0, rgb.r, rgb.g, rgb.b);       // ESC

    rgb_matrix_set_color(36, rgb.r, rgb.g, rgb.b);      // W
    rgb_matrix_set_color(60, rgb.r, rgb.g, rgb.b);      // D
    rgb_matrix_set_color(61, rgb.r, rgb.g, rgb.b);      // S
    rgb_matrix_set_color(62, rgb.r, rgb.g, rgb.b);      // A

    rgb_matrix_set_color(76, rgb.r, rgb.g, rgb.b);      // up
    rgb_matrix_set_color(77, rgb.r, rgb.g, rgb.b);      // right
    rgb_matrix_set_color(78, rgb.r, rgb.g, rgb.b);      // down
    rgb_matrix_set_color(79, rgb.r, rgb.g, rgb.b);      // left

    return rgb_matrix_check_finished_leds(led_max);
}

static bool position_mode(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);

    for (uint8_t i = led_min; i < led_max; i++) {
        rgb_matrix_set_color(i, 0x00, 0x00, 0x00);
    }

    RGB rgb = hsv_to_rgb(rgb_matrix_config.hsv);

    rgb_matrix_set_color(56, rgb.r, rgb.g, rgb.b);      // J
    rgb_matrix_set_color(59, rgb.r, rgb.g, rgb.b);      // D
    rgb_matrix_set_color(76, rgb.r, rgb.g, rgb.b);

    return rgb_matrix_check_finished_leds(led_max);
}

static bool host_direct(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);

    for (uint8_t i = led_min; i < led_max; i++) {
        rgb_matrix_set_color(i, hostrgb_buf[i].r, hostrgb_buf[i].g, hostrgb_buf[i].b);
    }

    return rgb_matrix_check_finished_leds(led_max);
}

#endif // RGB_MATRIX_CUSTOM_EFFECT_IMPLS
