# work env だけで使うインフラ・クラウド系 CLI
{ pkgs, pinned, ... }:
{
  home.packages = with pkgs; [
    # why: Nix 版の az は pip を同梱せず az extension add で後から足せないので、拡張はここで束ねる
    (pinned.azure-cli.withExtensions [ pinned.azure-cli.extensions.resource-graph ])
    argocd
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
