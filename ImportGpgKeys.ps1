
# If there is no 1Password CLI executable, exit
if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
    Write-Host "1Password CLI not found. Please install it from https://1password.com/downloads/command-line/"
    exit 1
}

# If there is no GPG executable, exit
if (-not (Get-Command gpg -ErrorAction SilentlyContinue)) {
    Write-Host "GPG not found. Please install it from https://gnupg.org/download/"
    exit 1
}

op read "op://tjlmijoc5qxj6vypdnvxf6s2sq/gmwqu34rldszc6qtas2i3ejiaq/gpg_private.asc" | gpg --batch --import
