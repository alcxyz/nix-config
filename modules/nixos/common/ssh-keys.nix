{
  keys = {
    alc_xyz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9g7HJbiqvmCZRZF5z5g9J/VLI91p7RpXipA9eWHX2q alc@xyz";
    alc_mac = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@mac";
    alc_iphone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhgqS6A8n44Azg65g9u7a2mQ+RwqYo8dBW/4CHfua+0 terminus@iphone";
    alc_nux = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0jGXFKy82JnUagVgPVbBuUBlYqfbFGwcLoOnaabG+S alc@nux";
    alc_nex = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIME9egqxg1z9e+Ef8M6866vlmjV7erNpfKJvSg+x/btI alc@nex";
    alc_rpi0 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO+l1wZzNjZ8vyopSUTGqziqif96bdfDoGJf0Iz82VHM alc@rpi0";
    alc_xps = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVSl1Tsy5xsIbV5R4Dnn4+Qk5qbfy3pOkRqZSGpWrNg alc@xps";
    alc_yubikey_sk = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMDqhZG24+O0aJzsfiRY1AbNHcb62apx2F7DPTAJf9olAAAABHNzaDo=";
    nux_buildhost_xyz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOCqmPEzDy4Nc2ZcRggLVAfYsay6dMoPJrVBR52MskrD nix-build@nux-to-xyz";
    nex_buildhost_xyz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8qgxpjQ82ktYwBKBatdI0bQlfFx0UPwCpJ6maVuhQL nix-build@nex-to-xyz";
    rpi0_buildhost_xyz = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtfjE0ipO2T87jT0FB+CpMDpKPCSrehWlYmKUZN6txF nix-build@rpi0-to-xyz";
    xyz_host_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEztyNrJk03TzMyLgwYd0BmUtUR5acWpgJf8obeGG1bS";
    nux_host_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGoS0qOGAZsbkOZYqhk2X+G81SMhOJiAmMnonlBZZ1km";
    nex_host_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHDD69n8CTSvA2av9tqMSfas5Q5C7gBuQVq/Vm94lSUk";
    xev_host_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFj/fFTJv9FmOeCFS04iDAFxjw3O6w5wXi+43Du0lCE";
    docker_app = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKkMvn8LGAG3tBwNmABBXifXKVTs54TzE1cpX4TcadT docker@iphone";
  };

  groups = {
    humanLogin = keys: [
      keys.alc_xyz
      keys.alc_nux
      keys.alc_nex
      keys.alc_rpi0
      keys.alc_xps
      keys.alc_mac
      keys.alc_yubikey_sk
    ];

    mobileApps = keys: [
      keys.alc_iphone
      keys.docker_app
    ];

    distributedBuildClients = keys: [
      keys.nux_buildhost_xyz
      keys.nex_buildhost_xyz
      keys.rpi0_buildhost_xyz
    ];

    xyzDistributedBuildClients = keys: [
      keys.nux_buildhost_xyz
      keys.nex_buildhost_xyz
      keys.rpi0_buildhost_xyz
    ];
  };
}
