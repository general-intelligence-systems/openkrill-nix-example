# Minimal k3s server — bare-bones single-node Kubernetes.
#
# This is the simplest possible openkrill deployment: a NixOS system
# running k3s with no cluster apps. Good starting point for learning
# or building a custom stack.
#
# Build:  nix build .#qcow2
# Run VM: nix run .#vm
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          openkrill.nixosModules.openkrill
          {
            services.openkrill.enable = true;

            # Networking
            networking.hostName = "k3s-minimal";

            # Disk & boot (adjust for your target hardware)
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";

            system.stateVersion = "25.11";
          }
        ];
      };

      # Build a QCOW2 disk image
      packages.${system}.qcow2 = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          openkrill.nixosModules.openkrill
          "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
          {
            services.openkrill.enable = true;
            networking.hostName = "k3s-minimal";
            image.baseName = "k3s-minimal";
            image.format = "qcow2";
            virtualisation.diskSize = 20480;
            system.stateVersion = "25.11";
          }
        ];
      }).config.system.build.image;

      packages.${system}.default = self.packages.${system}.qcow2;
    };
}
