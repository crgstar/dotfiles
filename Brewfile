# Nix (nix/) に移さず Homebrew に残すもの。CLI は原則 nix/ に置き、ここには理由のあるものだけ並べる
# 入れ直し: brew bundle --file=~/dotfiles/Brewfile

tap "aquaproj/aqua"
tap "nikitabobko/tap"
tap "sorafujitani/tap"
tap "steipete/tap"

# CVE 修正が nixpkgs より早く届く
brew "curl"
# nixpkgs の版が Homebrew より古いまま止まっている (work 用)
brew "argocd"
# nixpkgs に無い
brew "sorafujitani/tap/ccsession", trusted: true
# nixpkgs から外れた
brew "python@3.10"
# npm -g / pipx で入れたツールがこちら側の prefix にある
brew "node"
brew "pipx"

cask "aquaproj/aqua/aqua", trusted: true
cask "nikitabobko/tap/aerospace", trusted: true
cask "steipete/tap/codexbar", trusted: true
cask "font-udev-gothic-nf"
cask "ghostty"
cask "sourcegit"
cask "thaw"
cask "visual-studio-code"
cask "zed"
