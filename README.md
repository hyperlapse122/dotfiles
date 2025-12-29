# Dotfiles

```shell
curl "https://raw.githubusercontent.com/hyperlapse122/dotfiles/refs/heads/main/bootstrap.sh" | zsh
```

# Archinstall

```shell
# Update archinstall
pacman -Sy archinstall

# Run archinstall with configuration
# Set users and LUKS encrypt password by own.
archinstall --advanced --config-url https://dotfiles.h82.dev/archinstall/user_configuration.json
```