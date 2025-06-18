# /modules/nixos/services/postgresql/default.nix
{ config, lib, pkgs, ... }:

{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql;
    
    # Create databases for both services
    ensureDatabases = [ 
      "paperless" 
      "seafile" 
    ];
    
    # Create users for both services
    ensureUsers = [
      {
        name = "paperless";
        ensureDBOwnership = true;
      }
      {
        name = "seafile";
        ensureDBOwnership = true;
      }
    ];
    
    # Basic security settings
    settings = {
      listen_addresses = "127.0.0.1";
      log_connections = true;
      log_disconnections = true;
    };
    
    # Authentication configuration
    authentication = ''
      # Local connections
      local all all trust
      # localhost connections  
      host all all 127.0.0.1/32 md5
      # Docker bridge (if needed)
      host all all 172.17.0.0/16 md5
    '';
  };
}
