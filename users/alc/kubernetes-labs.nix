{
  config,
  ...
}: {
  # Dedicated files keep local Minikube labs out of the default kubeconfig
  # while making them available to the managed Kubernetes command wrappers.
  # Missing files are ignored until the corresponding lab is created.
  programs.kubernetes.managed.extraKubeconfigs = [
    "${config.home.homeDirectory}/.kube/local-bullet-platform-lab-config"
    "${config.home.homeDirectory}/.kube/local-funhouse-lab-config"
  ];
}
