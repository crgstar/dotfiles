# 手順書の作業だけを行うマシン用。手順書が呼ぶツールだけを入れる。
# docker はデーモンが OS のサービスで Home Manager では入れられないので、OS 側で入れる
{ pkgs, pinned, ... }:
{
  home.packages = with pkgs; [
    # why: 拡張を束ねると公式キャッシュに無くビルドが要るので、拡張なしで入れる
    pinned.azure-cli
    pinned.kubectl
    # Azure 版。int128 版は kubelogin-oidc という別パッケージ
    kubelogin
    gnumake
    # npx を使うため
    nodejs_latest
  ];
}
