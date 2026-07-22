{
  config,
  hostName,
  lib,
  ...
}: let
  cfg = config.alc.distributedBuildClient;
  buildKeyPath = "/root/.ssh/id_distributed_build";
  primaryBuilders = [
    {
      hostName = "xev";
      speedFactor = 3;
      maxJobs = 12;
    }
    {
      hostName = "xyz";
      speedFactor = 2;
      maxJobs = 8;
    }
  ];
  buildMachines =
    map
    (builder: {
      inherit (builder) hostName speedFactor maxJobs;
      sshUser = "root";
      sshKey = buildKeyPath;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      supportedFeatures = [
        "big-parallel"
        "kvm"
      ];
      protocol = "ssh";
    })
    (
      lib.filter (
        builder: builder.hostName != hostName && builtins.elem builder.hostName cfg.builders
      )
      primaryBuilders
    );
in {
  options.alc.distributedBuildClient = {
    enable = lib.mkEnableOption "distributed builds through the configured build hosts";

    builders = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (map (builder: builder.hostName) primaryBuilders));
      default = map (builder: builder.hostName) primaryBuilders;
      description = "Build hosts this client may use.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /root/.ssh 0700 root root - -"
    ];

    sops.secrets = {
      distributed_build_private_key = {
        key = "ssh_buildhost_xyz";
        path = buildKeyPath;
        owner = "root";
        group = "root";
        mode = "0600";
      };
      distributed_build_public_key = {
        key = "ssh_buildhost_xyz.pub";
        path = "${buildKeyPath}.pub";
        owner = "root";
        group = "root";
        mode = "0644";
      };
    };

    nix = {
      distributedBuilds = true;
      inherit buildMachines;
      settings."builders-use-substitutes" = true;
    };
  };
}
