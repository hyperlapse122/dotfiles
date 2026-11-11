{
  # sudo_local survives macOS updates, which rewrite /etc/pam.d/sudo. reattach
  # lets Touch ID reach sudo from inside tmux or screen.
  security.pam.services.sudo_local = {
    touchIdAuth = true;
    reattach = true;
  };
}
