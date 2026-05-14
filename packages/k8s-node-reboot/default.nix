{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "k8s-node-reboot";
  version = "0.1.0";

  src = ../../scripts/ops;

  dontBuild = true;

  installPhase = ''
    install -Dm755 k8s-node-reboot.sh $out/bin/kreboot
  '';

  meta = with lib; {
    description = "Cordon, drain, reboot, and uncordon a Kubernetes node";
    mainProgram = "kreboot";
    platforms = platforms.unix;
  };
}
