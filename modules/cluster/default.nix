# Cluster app module framework.
#
# Entry point that loads the base injection module, shared options,
# and all registered app modules from module-list.nix.
#
# This follows the same pattern as nixpkgs: a central module-list.nix
# registers every module, and they're all loaded into the module system
# at once (each gated by mkEnableOption so they're disabled by default).
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
#     cluster.domain = "mycompany.com";
#     cluster.apps.cert-manager.enable = true;
#   }
{ nix-kube-generators, nixhelm }:

{
  imports = [
    (import ./base.nix { inherit nix-kube-generators nixhelm; })
    ./options.nix
  ] ++ import ./module-list.nix;
}
