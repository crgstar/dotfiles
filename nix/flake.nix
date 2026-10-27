{
  description = "dotfiles の CLI ツールを Home Manager で入れる";

  inputs = {
    # why: az / gcloud のようなクラウド CLI は新しい版が早く欲しいので、安定版ではなく unstable を追う
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # why: unstable で壊れているパッケージだけを、直るまで安定版から取るため。安定版のチャンネルは
    #   OS ごとに別のテストを通って進むので、OS ごとにテスト済みのものを使う
    nixpkgs-stable-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixpkgs-stable-linux.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-stable-darwin,
      nixpkgs-stable-linux,
      home-manager,
      ...
    }:
    let
      # why: 公開リポなのでユーザ名・ホームの絶対パス・アーキテクチャを書かず、実行環境から取る。
      #   そのため home-manager switch には --impure が要る。付け忘れると空文字のまま進んで
      #   分かりにくいエラーになるので、ここで止める
      requireImpure =
        name: value:
        if value == "" || value == null then
          throw "${name} を取得できません。home-manager switch に --impure を付けてください"
        else
          value;
      system = requireImpure "system" (builtins.currentSystem or null);

      nixpkgsConfig = {
        # why: unfree を一括で許すと意図しない unfree が混ざっても気づけないので、名前で 1 つずつ許す
        allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "github-copilot-cli" ];
      };
      pkgs = import nixpkgs {
        inherit system;
        config = nixpkgsConfig;
      };
      pkgs-stable =
        import (if nixpkgs.lib.hasSuffix "-darwin" system then nixpkgs-stable-darwin else nixpkgs-stable-linux)
          {
            inherit system;
            config = nixpkgsConfig;
          };

      # why: 複数の構成で同じ版を使うものはここで決める。直すときに構成ごとに版がずれないように
      pinned = {
        # why: unstable の azure-cli は依存の fabric が broken 扱いで評価できないので、修正
        #   (https://github.com/NixOS/nixpkgs/pull/576874) が unstable に入るまで安定版から取る
        azure-cli = pkgs-stable.azure-cli;
        kubectl = pkgs.callPackage ./kubectl.nix { };
      };

      mkHome =
        envModules:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit pinned; };
          modules = [
            {
              home.username = requireImpure "USER" (builtins.getEnv "USER");
              home.homeDirectory = requireImpure "HOME" (builtins.getEnv "HOME");

              # why: 初回導入時の Home Manager の版。上げると互換性のない既定値の変更を受け入れることになるので、
              #   上げるときは Home Manager のリリースノートを読んでから
              home.stateVersion = "26.11";

              # why: 2 回目以降の switch で home-manager コマンドを使えるようにする
              programs.home-manager.enable = true;
            }
          ]
          ++ envModules;
        };
    in
    {
      # `#<名前>` で選ぶ。home / work は setup.sh の env 名と揃える
      homeConfigurations = {
        home = mkHome [ ./common.nix ];
        work = mkHome [
          ./common.nix
          ./work.nix
        ];
        # why: 手順書の作業だけを行うマシン用。普段の CLI 一式を入れるとダウンロードとビルドが重いので分ける
        ops = mkHome [ ./ops.nix ];
      };
    };
}
