{ ... }:
{
  # force = true: the legacy dotfiles installed these same paths, and a leftover
  # unmanaged copy would otherwise abort activation or be skipped unmanaged.
  home.file.".face" = {
    source = ../assets/face.png;
    force = true;
  };
  home.file.".face.icon" = {
    source = ../assets/face.png;
    force = true;
  };
}
