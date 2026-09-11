{
  lib,
  pkgs,
  browserCfg,
}: let
  wolfRevision = "d6d41dec9cf758b086768e19a7dc02c20ffce22c";
  wolfPatchSet = "altgr-idle-presentation-interpipe-media-pointer-process-live-switch-v15";
  wolfBaseImage = "ghcr.io/games-on-whales/wolf@sha256:8515dd1a88fa6c4a39a814c7c2f7eee4106d5b60c8140be6d0ef689324a079a2";
  wolfPatchedImage = "nixbox/wolf:${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}";
  wolfSource = pkgs.fetchFromGitHub {
    owner = "games-on-whales";
    repo = "wolf";
    rev = wolfRevision;
    hash = "sha256-5dcMiIgOPY9JtrVpmEUMoETha/cc+tShdaqe8j5ytp8=";
  };
  patchedWolfSource = pkgs.applyPatches {
    name = "wolf-${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}-source";
    src = wolfSource;
    patches = [
      ./wolf-image/altgr.patch
      ./wolf-image/client-presentation-scale.patch
      ./wolf-image/idle-session-timeout.patch
      ./wolf-image/reset-interpipe-on-producer-switch.patch
      ./wolf-image/app-producer-buffer-caps.patch
      ./wolf-image/media-keys.patch
      ./wolf-image/cooperative-pointer-lease.patch
      ./wolf-image/process-runner-closed-stdin.patch
    ];
  };
  gstInterpipeSource = pkgs.fetchFromGitHub {
    owner = "RidgeRun";
    repo = "gst-interpipe";
    rev = "v1.1.10";
    hash = "sha256-Z7yeUxsTebKPynYzhtst2rlApoXzU1u/32ZqzBvQ6eY=";
  };
  patchedGstInterpipeSource = pkgs.applyPatches {
    name = "gst-interpipe-1.1.10-fixed-equivalent-caps-source";
    src = gstInterpipeSource;
    patches = [./wolf-image/gst-interpipe-equivalent-caps.patch];
  };
  wolfBuildContext =
    pkgs.runCommand "wolf-${builtins.substring 0 12 wolfRevision}-${wolfPatchSet}-image-context" {}
    ''
      cp -r ${patchedWolfSource} "$out"
      chmod -R u+w "$out"
      cp -r ${patchedGstInterpipeSource} "$out/gst-interpipe"
      printf '\n!gst-interpipe\n!gst-interpipe/**\n' >> "$out/.dockerignore"
      cp ${./wolf-image/Dockerfile} "$out/Dockerfile"
    '';
  browserBaseImage = "ghcr.io/games-on-whales/base-app@sha256:1d7b61da242e767bc5c80c5fe897392b6a9e6854345d3dea6d2f799e7ea98a14";
  wolfUiImage = "ghcr.io/games-on-whales/wolf-ui@sha256:f483f79fcc5f39294067a5029f8de55e5867f74c709a3d55cd6163e4a5f0cf6b";
  browserImageBuildContextLabel = "io.nixbox.wolf-browser.context";
  heliumVersion = "0.14.7.1";
  heliumImageTag = "${heliumVersion}-pointer-v2";
  heliumDeb = pkgs.fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${heliumVersion}/helium-bin_${heliumVersion}-1_amd64.deb";
    hash = "sha256-FSSqAA2q64ubpGTBcd6l2VGK4DmSY0FVRNRhu4ZOfIc=";
  };
  mkBrowserContext = {
    name,
    deb,
  }:
    pkgs.runCommand "wolf-${name}-image-context" {} ''
      mkdir -p "$out"
      cp ${./browser-image/Dockerfile} "$out/Dockerfile"
      cp ${./browser-image/startup.sh} "$out/startup.sh"
      cp ${./browser-image/desktop-session.sh} "$out/desktop-session.sh"
      cp ${./browser-image/kdeconnect-session.sh} "$out/kdeconnect-session.sh"
      cp ${./browser-image/kde-pointer-bridge.py} "$out/kde-pointer-bridge.py"
      cp ${./browser-image/waybar.jsonc} "$out/waybar.jsonc"
      cp ${./browser-image/waybar.css} "$out/waybar.css"
      cp ${deb} "$out/browser.deb"
    '';
  mkNixBrowserContext = {
    name,
    package,
  }: let
    closure = pkgs.closureInfo {rootPaths = [package];};
  in
    pkgs.runCommand "wolf-${name}-image-context" {nativeBuildInputs = [pkgs.gnutar];} ''
      mkdir -p "$out"
      cp ${./browser-image/Dockerfile.nix-store} "$out/Dockerfile"
      cp ${./browser-image/startup.sh} "$out/startup.sh"
      cp ${./browser-image/desktop-session.sh} "$out/desktop-session.sh"
      cp ${./browser-image/kdeconnect-session.sh} "$out/kdeconnect-session.sh"
      cp ${./browser-image/kde-pointer-bridge.py} "$out/kde-pointer-bridge.py"
      cp ${./browser-image/waybar.jsonc} "$out/waybar.jsonc"
      cp ${./browser-image/waybar.css} "$out/waybar.css"
      tar \
        --create \
        --file="$out/browser-store.tar" \
        --directory=/ \
        --verbatim-files-from \
        --files-from=${closure}/store-paths
    '';
  allBrowserImages = [
    {
      enable = browserCfg.helium.enable;
      name = "helium";
      image = browserCfg.helium.image;
      version = heliumVersion;
      executable = "/usr/bin/helium";
      family = "chromium";
      source = "https://github.com/imputnet/helium-linux";
      desktopPackages = lib.optional browserCfg.helium.kdeConnect.enable "kdeconnect=24.12.3-0ubuntu2.1";
      context = mkBrowserContext {
        name = "helium";
        deb = heliumDeb;
      };
    }
    {
      enable = browserCfg.brave.enable;
      name = "brave";
      image = browserCfg.brave.image;
      version = pkgs.brave.version;
      executable = "/usr/bin/brave-browser-stable";
      family = "chromium";
      source = "https://github.com/brave/brave-browser";
      desktopPackages = [];
      context = mkBrowserContext {
        name = "brave";
        deb = pkgs.brave.src;
      };
    }
    {
      enable = browserCfg.chromium.enable;
      name = "chromium";
      image = browserCfg.chromium.image;
      version = pkgs.chromium.version;
      executable = "${pkgs.chromium}/bin/chromium";
      family = "chromium";
      source = "https://chromium.googlesource.com/chromium/src";
      desktopPackages = [];
      context = mkNixBrowserContext {
        name = "chromium";
        package = pkgs.chromium;
      };
    }
    {
      enable = browserCfg.firefox.enable;
      name = "firefox";
      image = browserCfg.firefox.image;
      version = pkgs.firefox.version;
      executable = "${pkgs.firefox}/bin/firefox";
      family = "firefox";
      source = "https://hg.mozilla.org/mozilla-unified";
      desktopPackages = [];
      context = mkNixBrowserContext {
        name = "firefox";
        package = pkgs.firefox;
      };
    }
    {
      enable = browserCfg.zen.enable;
      name = "zen";
      image = browserCfg.zen.image;
      version = pkgs.zen-browser.version;
      executable = "${pkgs.zen-browser}/bin/zen";
      family = "firefox";
      source = "https://github.com/zen-browser/desktop";
      desktopPackages = [];
      context = mkNixBrowserContext {
        name = "zen";
        package = pkgs.zen-browser;
      };
    }
  ];
  browserImages = lib.filter (image: image.enable) allBrowserImages;
in {
  inherit
    wolfBaseImage
    wolfPatchedImage
    wolfBuildContext
    browserBaseImage
    wolfUiImage
    browserImageBuildContextLabel
    heliumImageTag
    allBrowserImages
    browserImages
    ;
}
