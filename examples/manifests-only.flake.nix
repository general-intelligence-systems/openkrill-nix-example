# Manifest generation only — no k3s, no NixOS system.
#
# Uses the cluster module framework purely to generate Kubernetes
# YAML manifests as files. Useful when you already have a cluster
# and just want the app manifests.
#
# Build: nix build .#manifests
# Then:  ls result/   →   cert-manager.yaml  trust-manager.yaml
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      # Evaluate the cluster modules to get manifestsPackage.
      # We use nixosSystem but stub out the NixOS-specific bits since
      # we only care about the cluster.manifestsPackage output.
      evaluated = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          openkrill.nixosModules.cluster
          {
            # ── Cluster config ────────────────────────────────────
            cluster.domain = "example.com";

            # ── Enable the apps you want manifests for ────────────
            cluster.apps.cert-manager.enable = true;
            cluster.apps.trust-manager = {
              enable = true;
              caSecretName = "my-ca-secret";
            };

            # ── NixOS stubs (required by nixosSystem, not used) ───
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            boot.loader.grub.enable = false;
            system.stateVersion = "25.11";
          }
        ];
      };
    in
    {
      # nix build .#manifests → result/cert-manager.yaml, result/trust-manager.yaml
      packages.${system}.manifests = evaluated.config.cluster.manifestsPackage;
      packages.${system}.default = self.packages.${system}.manifests;
    };
}
