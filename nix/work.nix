# work env だけで使うインフラ・クラウド系 CLI
{ pkgs, pinned, ... }:
{
  # argocd は nixpkgs が Homebrew より古い版で止まっているので Homebrew に残す
  home.packages = with pkgs; [
    # why: 拡張を束ねると公式キャッシュに無くビルドが要るので、拡張なしで入れる。
    #   Nix 版の az は pip を同梱せず az extension add で後から足せないので、要るときは
    #   pinned.azure-cli.withExtensions [ pinned.azure-cli.extensions.<名前> ] に変える
    pinned.azure-cli
    google-cloud-sdk
    pinned.kubectl
    kubectx
    # Azure 版。int128 版は kubelogin-oidc という別パッケージ
    kubelogin
    kustomize
    postgresql_16
    sops
  ];
}
