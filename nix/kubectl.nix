# kubectl はクラスタとの版差が ±1 マイナーまでしかサポートされない。nixpkgs は最新の版しか
# 持たないので、作業対象のクラスタに合わせた版を公式の配布物から固定して入れる
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
}:
let
  version = "1.35.9";
  # why: dl.k8s.io の kubectl.sha256 と照合済み。版を上げるときは全プラットフォーム分を取り直す
  #   (nix store prefetch-file https://dl.k8s.io/release/v<版>/bin/<os>/<arch>/kubectl)
  sources = {
    x86_64-linux = {
      platform = "linux/amd64";
      hash = "sha256-PP6vgL5IK0NbCqIUr/bgssMS7iPA/yCBDHVRe2AExus=";
    };
    aarch64-darwin = {
      platform = "darwin/arm64";
      hash = "sha256-ZSVI5qlAUmbFrNJxlwO8jTa++kbnnhUaDWRpBKoyyJs=";
    };
  };
  # why: 属性参照が meta.platforms の判定より先に評価されるので、未登録の環境では
  #   "attribute missing" という原因の読めないエラーになる。何を足せばよいかをここで伝える
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "kubectl.nix: ${stdenvNoCC.hostPlatform.system} 用の配布物が sources に未登録です");
in
stdenvNoCC.mkDerivation {
  pname = "kubectl";
  inherit version;

  src = fetchurl {
    url = "https://dl.k8s.io/release/v${version}/bin/${source.platform}/kubectl";
    inherit (source) hash;
  };

  dontUnpack = true;
  nativeBuildInputs = [ installShellFiles ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/kubectl
    runHook postInstall
  '';

  # why: nixpkgs や Homebrew の kubectl と同じく補完を同梱する。読み込むのはシェル側の設定
  postInstall = ''
    installShellCompletion --cmd kubectl \
      --bash <($out/bin/kubectl completion bash) \
      --zsh <($out/bin/kubectl completion zsh)
  '';

  meta = {
    description = "Kubernetes CLI (公式配布のバイナリを版固定で入れる)";
    homepage = "https://kubernetes.io/";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames sources;
    mainProgram = "kubectl";
  };
}
