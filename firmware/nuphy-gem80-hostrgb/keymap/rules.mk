# Omitting `override EXTRAFLAGS += -I$(KEYMAP_PATH)/../default` from the via keymap
# ensures rgb_matrix_user.inc resolves from this keymap rather than default.
VIA_ENABLE = yes
RGB_MATRIX_CUSTOM_USER = yes
