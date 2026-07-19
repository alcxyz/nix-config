{
  jq,
  lib,
  makeWrapper,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "k8s-node-reboot";
  version = "0.4.0";

  src = ../../scripts/ops;

  dontBuild = true;

  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    install -Dm755 k8s-node-reboot.sh $out/libexec/k8s-node-reboot
    makeWrapper $out/libexec/k8s-node-reboot $out/bin/kreboot \
      --set K8S_NODE_POWER_ACTION reboot \
      --prefix PATH : ${lib.makeBinPath [jq]}
    makeWrapper $out/libexec/k8s-node-reboot $out/bin/koff \
      --set K8S_NODE_POWER_ACTION off \
      --prefix PATH : ${lib.makeBinPath [jq]}
    makeWrapper $out/libexec/k8s-node-reboot $out/bin/kon \
      --set K8S_NODE_POWER_ACTION on \
      --prefix PATH : ${lib.makeBinPath [jq]}
  '';

  meta = with lib; {
    description = "Cordon, drain, reboot, and uncordon a Kubernetes node";
    mainProgram = "kreboot";
    platforms = platforms.unix;
  };
}
