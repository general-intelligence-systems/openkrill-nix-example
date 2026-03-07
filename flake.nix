{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";
    nixhelm = {
      url = "github:n-at-han-k/nixhelm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-kube-generators, nixhelm, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      # Build a NixOS system configuration for a given architecture.
      # Used for both the QCOW2 image and the dev VM.
      mkSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };

      # System configs per architecture
      systems = nixpkgs.lib.genAttrs supportedSystems mkSystem;
    in
    {
      # ── Reusable NixOS module ──────────────────────────────────────
      # Import this into your own configuration.nix:
      #
      #   { inputs, ... }: {
      #     imports = [ inputs.openkrill.nixosModules.openkrill ];
      #     services.openkrill.enable = true;
      #   }
      nixosModules.openkrill = import ./modules/openkrill.nix;
      nixosModules.cluster = import ./modules/cluster {
        inherit nix-kube-generators nixhelm;
      };
      nixosModules.default = self.nixosModules.openkrill;

      # ── NixOS configurations ──────────────────────────────────────
      nixosConfigurations = {
        openkrill-x86_64  = systems.x86_64-linux;
        openkrill-aarch64 = systems.aarch64-linux;
      };

      # ── Packages ──────────────────────────────────────────────────
      packages = forAllSystems (system:
        let
          # Helper: build an image variant by layering extra modules
          # on top of configuration.nix.
          mkImage = extraModules: (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ ./configuration.nix ] ++ extraModules;
          }).config.system.build.image;

          # Dev VM runner -- run with: nix run .#vm
          nixos-vm = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ./configuration.nix
              ./vm.nix
            ];
          };
        in
        {
          # Standalone QCOW2 -- for libvirt, Incus, Proxmox, plain QEMU
          qcow2 = mkImage [
            "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
            {
              image.baseName = "openkrill";
              image.format = "qcow2";
              image.efiSupport = false;
              virtualisation.diskSize = 20480; # 20GB
            }
          ];

          # DigitalOcean -- compressed QCOW2 for DO custom images
          digitalocean = mkImage [
            "${nixpkgs}/nixos/modules/virtualisation/digital-ocean-image.nix"
            {
              image.baseName = "openkrill-digitalocean";
              virtualisation.diskSize = 4096; # 4GB, auto-grows on DO
            }
          ];

          # Google Compute Engine -- raw disk tarball for GCE custom images
          google-compute = mkImage [
            "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
            {
              image.baseName = "openkrill-google-compute";
              virtualisation.diskSize = 4096; # 4GB, auto-grows on GCE
            }
          ];

          # Incus VM -- QCOW2 with guest agent, EFI, virtio, serial console
          # Uses system.build.qemuImage (not system.build.image, which is
          # the LXC metadata tarball in this module stack).
          incus-vm = (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ./configuration.nix
              "${nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
            ];
          }).config.system.build.qemuImage;

          # Bootable live ISO -- boots k3s directly from USB/CD.
          # Includes nixos-install so the user can install to disk.
          iso = mkImage [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            { image.baseName = nixpkgs.lib.mkForce "openkrill"; }
          ];

          # Dev VM runner
          vm = nixos-vm.config.system.build.vm;

          default = self.packages.${system}.qcow2;
        }
      );

      # ── Checks (nix flake check) ─────────────────────────────────
      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          k3s-test = import ./tests/k3s-test.nix {
            inherit pkgs;
            openkrill-module = self.nixosModules.openkrill;
          };
        }
      );

      # ── Dev shells ────────────────────────────────────────────────
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              git
              ruby_3_4
              #kubectl
              #kubernetes-helm
              #k9s
            ];
            shellHook = ''
              export BUNDLE_PATH=".bundler"
              export GEM_PATH=".bundler/ruby/3.4.0"

              export PATH="$PWD/bin:$PATH"
              export PATH=".bundler/ruby/3.4.0/bin:$PATH"
            '';
          };
        }
      );
    };
}
