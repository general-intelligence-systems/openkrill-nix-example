# Central registry of all cluster app modules.
# Add new modules here — they will be automatically loaded by the cluster
# module framework. Each module should use mkEnableOption so it's disabled
# by default.
#
# This follows the same pattern as nixpkgs' nixos/modules/module-list.nix.
[
  ../argocd
  ../authelia
  ../cert-manager
  ../cloudnative-pg
  ../opencloud
  ../theia-ide
  ../trust-manager
]
