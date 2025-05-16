{ options
, config
, lib
, ...
}:
with lib;
with lib.custom; let
  cfg = config.services.ssh;
in
{
  options.services.ssh = with types; {
    enable = mkBoolOpt false "Enable ssh";
  };

  config = mkIf cfg.enable {
    services.openssh = {
      enable = true;
      ports = [ 22 ];
      #PermitRootLogin = "prohibit-password";
      settings.PasswordAuthentication = false;
      openFirewall = true;
    };

    users.users =
      let
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@AM-VYH2F56CR6"; # Enter your ssh public key
      in
      {
        root.openssh.authorizedKeys.keys = [
          publicKey
        ];
        ${config.user.name}.openssh.authorizedKeys.keys = [
          publicKey
        ];
      };

    home.file.".ssh/config".text = ''
      Host rpi*
        User root

      Host github
        Hostname github.com
        User git

      Host vps
        Hostname 46.202.150.96
        User root

      Host *
        identityfile ~/.ssh/key
    '';
  };
}
