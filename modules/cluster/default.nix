# Cluster app module framework.
#
# This is a module factory: it takes flake inputs and returns a standard
# NixOS module. The returned module injects `yaml`, `k8s`, and `istio`
# into the module argument set via _module.args, so all sub-modules
# receive them automatically — consumers don't need to set up specialArgs.
#
# Usage in flake.nix:
#
#   nixosModules.cluster = import ./modules/cluster {
#     inherit nix-kube-generators nixhelm;
#   };
#
# Usage in a consumer's configuration.nix:
#
#   { inputs, ... }: {
#     imports = [ inputs.openkrill.nixosModules.cluster ];
#     cluster.apps.cert-manager.enable = true;
#   }
{ nix-kube-generators, nixhelm }:

# Standard NixOS module
{ config, lib, pkgs, ... }:
let
  kubelib = nix-kube-generators.lib { inherit pkgs; };
  charts = nixhelm.chartsDerivations.${pkgs.system};
  yaml = import ../../lib/yaml.nix { inherit pkgs kubelib charts; };
  k8s = import ../../lib/k8s.nix { inherit pkgs yaml; };
in
{
  imports = [
    ./options.nix
    ../argocd
    ../authelia
    ../cert-manager
    ../cloudnative-pg
    ../opencloud
    ../theia-ide
    ../trust-manager
  ];

  # Inject yaml, k8s, istio into module args so sub-modules receive
  # them via their { config, lib, yaml, k8s, ... }: signatures.
  config._module.args = {
    inherit yaml k8s;
    istio = {}; # deprecated, kept for compatibility
  };
}
