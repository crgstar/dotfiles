# 全 env 共通の CLI ツール
{ pkgs, ... }:
{
  # ccsession は nixpkgs に無く、Python 3.10 は nixpkgs から外れたので、それぞれ Homebrew / mise に残す。
  # curl は CVE 修正が Homebrew のほうが早く届くので Homebrew に残す。
  # node / pipx は npm -g・pipx で入れたツールが Homebrew 側の prefix にあるので Homebrew に残す
  # (Nix 版が先に見つかると npm -g の書き込み先が読み取り専用の /nix/store になる)
  home.packages = with pkgs; [
    # why: hook は `#!/usr/bin/env bash` で動き、macOS 同梱の bash 3.2 だと遅い。Homebrew の bash 5 の代わり
    bashInteractive
    bat
    delta
    direnv
    eza
    fzf
    gh
    git
    git-filter-repo
    git-lfs
    github-copilot-cli
    # why: macOS 同梱の make は 3.81 と古く、Linux では最初から入っていないこともあるので、版を揃える
    gnumake
    # why: Homebrew の go と同じく最新版を追う。nixpkgs の go は 1 つ前の版を指す
    go_latest
    herdr
    jq
    jujutsu
    lazygit
    mise
    ripgrep
    sox
    uv
    watch
    wget
    zoxide
  ];
}
