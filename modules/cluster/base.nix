# Single source of truth for yaml/k8s module arguments.
# Analogous to nixpkgs' misc/nixpkgs.nix which injects `pkgs` via _module.args.
#
# This module is imported exactly once by default.nix. All app modules
# receive `yaml`, `k8s`, and `istio` via their function signatures
# (e.g. { config, lib, yaml, k8s, ... }:) without any manual wiring.
{ nix-kube-generators, nixhelm }:

{ config, lib, pkgs, ... }:
let
  kubelib = nix-kube-generators.lib { inherit pkgs; };
  charts = nixhelm.chartsDerivations.${pkgs.system};
  yaml = import ../../lib/yaml.nix { inherit pkgs kubelib charts; };
  k8s = import ../../lib/k8s.nix { inherit pkgs yaml; };
in
{
  config._module.args = { inherit yaml k8s; istio = {}; };
}
