#!/usr/bin/env zsh

set -xeuo pipefail

defaults write "com.apple.HIToolbox" "AppleGlobalTextInputProperties" '{TextInputGlobalPropertyPerContextInput=1;}'
defaults write NSGlobalDomain "NSAutomaticDashSubstitutionEnabled" -bool false
defaults write NSGlobalDomain "NSAutomaticQuoteSubstitutionEnabled" -bool false
defaults write NSGlobalDomain "ApplePressAndHoldEnabled" -bool "false"
defaults write NSGlobalDomain "AppleShowAllExtensions" -bool "true"
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true

defaults write com.apple.dock "show-recents" -bool "false"
defaults write com.apple.dock "mineffect" -string "scale"
defaults write com.apple.dock "tilesize" -int "36"
killall Dock || echo "Skipping killall Dock..."

defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
defaults write com.apple.finder "_FXSortFoldersFirst" -bool "true"
defaults write com.apple.finder "ShowPathbar" -bool "true"
defaults write com.apple.finder "FXRemoveOldTrashItems" -bool "true"
defaults write com.apple.finder "FXEnableExtensionChangeWarning" -bool "false"
killall Finder || echo "Skipping killall Finder..."

defaults write com.apple.dt.Xcode "ShowBuildOperationDuration" -bool "true"
killall Xcode || echo "Skipping killall Xcode..."

