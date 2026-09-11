{
  lib,
  pkgs,
  productNames ? [
    "wolf"
    "helium"
    "brave"
    "chromium"
    "firefox"
    "zen"
  ],
}: let
  # This generic configuration selects every reusable image definition without
  # importing a host configuration or the private nix-secrets input. KDE
  # Connect remains part of Helium because it is part of the deployed image's
  # established runtime and input contract.
  browserCfg = {
    helium = {
      enable = true;
      image = "nixbox/wolf-helium:export";
      kdeConnect.enable = true;
    };
    brave = {
      enable = true;
      image = "nixbox/wolf-brave:export";
    };
    chromium = {
      enable = true;
      image = "nixbox/wolf-chromium:export";
    };
    firefox = {
      enable = true;
      image = "nixbox/wolf-firefox:export";
    };
    zen = {
      enable = true;
      image = "nixbox/wolf-zen:export";
    };
  };
  assembly = import ./images.nix {inherit lib pkgs browserCfg;};
  browserProducts =
    map (image: {
      inherit (image) name context;
      buildArgs = {
        BASE_APP_IMAGE = assembly.browserBaseImage;
        BROWSER_EXECUTABLE = image.executable;
        BROWSER_FAMILY = image.family;
        DESKTOP_PACKAGES = lib.concatStringsSep " " image.desktopPackages;
        IMAGE_SOURCE = image.source;
        IMAGE_VERSION = image.version;
      };
      labels = {
        ${assembly.browserImageBuildContextLabel} = toString image.context;
      };
    })
    assembly.allBrowserImages;
  products =
    [
      {
        name = "wolf";
        context = assembly.wolfBuildContext;
        buildArgs.RUNTIME_IMAGE = assembly.wolfBaseImage;
        labels = {};
      }
    ]
    ++ browserProducts;
  selected = lib.filter (product: builtins.elem product.name productNames) products;
  unknown = lib.subtractLists (map (product: product.name) products) productNames;
  manifest = pkgs.writeText "wolf-image-products.json" (builtins.toJSON {
    schemaVersion = 1;
    products = selected;
  });
in
  assert lib.assertMsg (unknown == []) "unknown Wolf image product: ${lib.concatStringsSep ", " unknown}";
    pkgs.runCommand "wolf-image-products" {} ''
      mkdir -p "$out"
      ln -s ${manifest} "$out/manifest.json"
    ''
