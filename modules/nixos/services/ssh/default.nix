# modules/nixos/services/ssh/default.nix

{
  config,
  lib,
  username,
  ...
}:

with lib;

let
  cfg = config.services.openssh;
  alc_xyz_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9g7HJbiqvmCZRZF5z5g9J/VLI91p7RpXipA9eWHX2q alc@xyz";
  alc_mac_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@mac";
  alc_iphone_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhgqS6A8n44Azg65g9u7a2mQ+RwqYo8dBW/4CHfua+0";
  alc_nux_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0jGXFKy82JnUagVgPVbBuUBlYqfbFGwcLoOnaabG+S alc@nux";
  root_nux_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmkdBBUyxWpdARfACmw6+P3yOfo0RKfK3JfRJMX+NYW root@nux";
  docker_app_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKkMvn8LGAG3tBwNmABBXifXKVTs54TzE1cpX4TcadT";
in
{
  config = mkIf cfg.enable {
    services.openssh = {
      #enable = true;
      ports = [ 22 ];
      settings.PermitRootLogin = "prohibit-password";
      settings.PasswordAuthentication = false;
      openFirewall = true;
      settings.PubkeyAuthentication = true;
    };

    # This is the correct, idiomatic way to do this in NixOS.
    users.users = {
      root.openssh.authorizedKeys.keys = [ alc_mac_key ];
      ${username}.openssh.authorizedKeys.keys = [
        alc_xyz_key
        alc_mac_key
        alc_iphone_key
        alc_nux_key
        root_nux_key
        docker_app_key
      ];
    };
  };
}
