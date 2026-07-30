{
  pkgs,
}:
pkgs.runCommand "wolf-nvrtc-runtime" {} ''
  mkdir -p "$out/lib"
  cp ${pkgs.cudaPackages.cuda_nvrtc.src}/lib/libnvrtc.so.* "$out/lib/"
  cp ${pkgs.cudaPackages.cuda_nvrtc.src}/lib/libnvrtc-builtins.so.* "$out/lib/"

  for library in libnvrtc libnvrtc-builtins; do
    set -- "$out/lib/$library.so."*
    ln -s "$(basename "$1")" "$out/lib/$library.so"
  done
''
