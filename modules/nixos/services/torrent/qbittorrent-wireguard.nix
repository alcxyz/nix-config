# modules/nixos/services/torrent/qbittorrent-wireguard.nix
{ config, lib, pkgs, ... }:

let
  # --- WireGuard VPN Parameters (from your ProtonVPN .conf) ---
  # IMPORTANT: Do NOT hardcode your WireGuard private key here.
  # Use your gopass/age setup to decrypt the key to a file (e.g.,
  # /run/secrets/protonvpn_wg_private_key) at boot, and then read it from there.
  # Replace "/run/secrets/protonvpn_wg_private_key" with the actual path if different.
  wgPrivateKey = lib.readFile "/run/secrets/protonvpn_wg_private_key";

  # Values extracted directly from your provided ProtonVPN .conf file:
  wgAddress = "10.2.0.2/32";          # From [Interface].Address
  wgDNS = "10.2.0.1";                 # From [Interface].DNS
  wgPeerPublicKey = "Hp2v99abdPDC2F255DDEO65Kf1yD/wgVcxiDqmMw+RA="; # From [Peer].PublicKey
  wgEndpoint = "185.183.33.219:51820"; # From [Peer].Endpoint
  wgAllowedIPs = [ "0.0.0.0/0" ];     # From [Peer].AllowedIPs
  wgPersistentKeepalive = 25;         # Common default for PersistentKeepalive

  # Network namespace name for qBittorrent
  qbNamespaceName = "qbittorrent_ns";
  qbNamespacePath = "/run/netns/${qbNamespaceName}"; # Path for namespace-specific files

  # Name for the WireGuard interface
  wgInterfaceName = "wg-pvpn"; # e.g., wg-protonvpn-torrent
in {

  options.services.torrent.wireguardVPN.enable =
    lib.mkEnableOption "Enable qBittorrent traffic through WireGuard VPN";

  config = lib.mkIf config.services.torrent.wireguardVPN.enable {

    # Ensure iproute2 (for `ip netns`) and coreutils (for `mkdir`, `echo`)
    # are available if they aren't pulled in by other dependencies.
    environment.systemPackages = with pkgs; [
      iproute2
      coreutils
    ];

    ######################################################################
    # 1. Define the WireGuard Interface on the Host
    #    This interface is created by NixOS, then moved into the
    #    network namespace by a custom systemd service.
    ######################################################################
    networking.wireguard.interfaces.${wgInterfaceName} = {
      privateKey = wgPrivateKey;
      addresses = [ wgAddress ]; # The internal IP address within the VPN
      peers = [
        {
          publicKey = wgPeerPublicKey;
          endpoint = wgEndpoint;
          # We specify AllowedIPs here, but the actual routing
          # within the namespace will handle forcing all traffic.
          allowedIPs = wgAllowedIPs;
          persistentKeepalive = wgPersistentKeepalive;
        }
      ];
      # No PostUp/PostDown commands here; the namespace setup handles routing.
    };

    ######################################################################
    # 2. Setup the Network Namespace for qBittorrent
    #    This systemd service creates the isolated network environment,
    #    moves the WireGuard interface into it, and configures routing/DNS.
    ######################################################################
    # Create the directory where the namespace's resolv.conf will live
    systemd.tmpfiles.rules = [
      "d ${qbNamespacePath} 0755 root root -"
    ];

    systemd.services.qbittorrent-netns-setup = {
      description = "Setup network namespace for qBittorrent";
      # Ensure this service starts AFTER the WireGuard interface itself is up.
      after = [ "network-online.target" "${wgInterfaceName}.service" ];
      requires = [ "${wgInterfaceName}.service" ];
      wantedBy = [ "multi-user.target" ]; # Start with multi-user services

      # Type=oneshot with RemainAfterExit=true keeps the namespace alive
      # after this setup script finishes executing.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          # Create the new network namespace
          ${pkgs.iproute2}/bin/ip netns add ${qbNamespaceName}

          # Bring up the loopback device inside the namespace
          ${pkgs.iproute2}/bin/ip netns exec ${qbNamespaceName} \
            ${pkgs.iproute2}/bin/ip link set lo up

          # Move the WireGuard interface from the host to the new namespace
          ${pkgs.iproute2}/bin/ip link set ${wgInterfaceName} netns ${qbNamespaceName}
          ${pkgs.iproute2}/bin/ip netns exec ${qbNamespaceName} \
            ${pkgs.iproute2}/bin/ip link set ${wgInterfaceName} up

          # Set the default route in the namespace to go through the WireGuard interface
          ${pkgs.iproute2}/bin/ip netns exec ${qbNamespaceName} \
            ${pkgs.iproute2}/bin/ip route add default dev ${wgInterfaceName}

          # Configure DNS resolver for the namespace
          # This writes directly to the /run/netns/<namespace>/resolv.conf path
          ${pkgs.coreutils}/bin/echo "nameserver ${wgDNS}" \
            > ${qbNamespacePath}/resolv.conf

          # Optional: Disable Reverse Path Filtering (often needed for VPNs/namespaces)
          # Note: We need to use sysctl within the namespace for its own settings
          ${pkgs.iproute2}/bin/ip netns exec ${qbNamespaceName} \
            ${pkks.writeText "disable-rp-filter" ''
              net.ipv4.conf.all.rp_filter = 0
              net.ipv4.conf.${wgInterfaceName}.rp_filter = 0
            ''}/bin/sysctl -p /dev/stdin
        '';
        ExecStop = ''
          # Clean up the network namespace on service stop
          ${pkgs.iproute2}/bin/ip netns del ${qbNamespaceName}
        '';
      };
    };

    ######################################################################
    # 3. Modify the qBittorrent-nox Service
    #    This overrides specific options of the qBittorrent-nox service
    #    that is defined in your `qbittorrent-flood.nix` module.
    ######################################################################
    systemd.services.qbittorrent-nox = {
      # This crucial option tells systemd to run qBittorrent-nox inside
      # the isolated network namespace.
      serviceConfig.NetworkNamespacePath = qbNamespacePath;

      # Ensure qBittorrent-nox starts only AFTER the namespace and VPN
      # setup service has successfully completed.
      after = [ "qbittorrent-netns-setup.service" ];
      requires = [ "qbittorrent-netns-setup.service" ];
    };

    ######################################################################
    # 4. Configure Firewall Rules for the Host
    #    Only allow traffic for the WireGuard connection itself.
    #    qBittorrent's torrenting port (51413) will be handled *within*
    #    the VPN tunnel, so it does NOT need to be opened on the host.
    #    Flood's UI and qBittorrent's WebUI (8112, 8080) are typically
    #    still needed on the host for local access.
    ######################################################################
    networking.firewall.allowedUDPPorts =
      lib.mkForce [ 51820 ]; # Allow the WireGuard connection's UDP port

    # Recommendation for your `qbittorrent-flood.nix` (main module):
    # Adjust the firewall rules there to ONLY open ports for Flood's UI
    # and qBittorrent's WebUI, and remove the torrentPort.
    # E.g., in qbittorrent-flood.nix:
    # networking.firewall.allowedTCPPorts = [ floodPort qbWebUIPort ];
    # networking.firewall.allowedUDPPorts = [ ];
  };
}
