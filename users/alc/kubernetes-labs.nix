{config, ...}: {
  # Dedicated files keep local Minikube labs out of the default kubeconfig
  # while making them available to the managed Kubernetes command wrappers.
  # Missing files are ignored until the corresponding lab is created. The
  # private operator modules add their own labs.
  programs.kubernetes.managed.extraKubeconfigs = [
    "${config.home.homeDirectory}/.kube/local-funhouse-lab-config"
    # Minikube writes its profiles (for example the PAW QA cluster) here.
    "${config.home.homeDirectory}/.kube/config"
  ];
}
