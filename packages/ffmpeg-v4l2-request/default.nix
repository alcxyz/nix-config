{
  ffmpeg,
  fetchFromGitHub,
  linuxHeaders,
  systemdLibs,
}:
ffmpeg.overrideAttrs (old: {
  pname = "ffmpeg-v4l2-request";
  version = "8.1-v4l2-request-2026-04-20";

  # Mainline Rockchip kernels expose stateless media decoders through the
  # V4L2 Request API. This maintained downstream branch carries the FFmpeg
  # support that has not landed upstream yet.
  src = fetchFromGitHub {
    owner = "Kwiboo";
    repo = "FFmpeg";
    rev = "b57fbbe50c9b2656fad86a1a7eeabfd2b2a50935";
    hash = "sha256-+4PV7b3EdgYW3VX9dIPhK/pCgiVlC84RkJzSYTE4QKA=";
  };

  # The nixpkgs patches target its upstream FFmpeg source revision and are not
  # applicable to this downstream branch.
  patches = [];
  buildInputs =
    (old.buildInputs or [])
    ++ [
      linuxHeaders
      systemdLibs
    ];
  configureFlags = old.configureFlags ++ ["--enable-v4l2-request"];

  # The full FFmpeg FATE suite is prohibitively expensive under aarch64
  # emulation and cannot exercise the target's V4L2 hardware. Validate this
  # package with an actual hardware-decode probe on the RK3399 instead.
  doCheck = false;
})
