{lib, ...}: {
  # Some NSS modules contribute entries with a higher precedence than the
  # nixpkgs "files" entry. Normalize the merged list so /etc/hosts remains the
  # first lookup source while retaining the resolver order selected elsewhere.
  options.system.nssDatabases.hosts = lib.mkOption {
    apply = hosts: ["files"] ++ lib.filter (entry: entry != "files") hosts;
  };
}
