# Development VM + image builder — local k3s cluster with image outputs.
#
# Run a local dev VM:   nix run .#vm
# Build a QCOW2 image:  nix build .#qcow2
# Build a DO image:     nix build .#digitalocean
# Build an ISO:         nix build .#iso
# Flash to USB:         sudo dd if=result/iso/openkrill.iso of=/dev/sdX bs=4M status=progress conv=fsync
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      # Shared base configuration for all image variants.
      # Boot loader is NOT set here — each image module sets its own
      # to avoid grub/systemd-boot/direct-boot conflicts.
      baseConfig = { lib, ... }: {
        imports = [
          openkrill.nixosModules.openkrill
          openkrill.nixosModules.cluster
        ];

        services.openkrill.enable = true;
        networking.hostName = "openkrill";

        cluster.domain = "example.com";
        cluster.manifestsDir = "/var/lib/rancher/k3s/server/manifests";
        cluster.apps.cert-manager.enable = true;

        # Fallback root filesystem — image modules override this at
        # higher priority with their own disk layout.
        fileSystems."/" = lib.mkOverride 1500 {
          device = "/dev/vda1";
          fsType = "ext4";
        };

        system.stateVersion = "25.11";
      };

      # Helper: build an image variant by layering extra modules on
      # top of the base configuration.
      mkImage = extraModules: (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ baseConfig ] ++ extraModules;
      }).config.system.build.image;
    in
    {
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          baseConfig
          {
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
          }
        ];
      };

      packages.${system} = {
        # ── Disk images ───────────────────────────────────────────

        # Generic QCOW2 — for libvirt, Incus, Proxmox, plain QEMU
        qcow2 = mkImage [
          "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
          {
            image.baseName = "openkrill";
            image.format = "qcow2";
            image.efiSupport = false;
            virtualisation.diskSize = 20480; # 20GB
          }
        ];

        # DigitalOcean — compressed QCOW2 for DO custom images
        digitalocean = mkImage [
          "${nixpkgs}/nixos/modules/virtualisation/digital-ocean-image.nix"
          {
            image.baseName = "openkrill-digitalocean";
            virtualisation.diskSize = 4096; # 4GB, auto-grows on DO
          }
        ];

        # Google Compute Engine — raw disk tarball for GCE custom images
        google-compute = mkImage [
          "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
          {
            image.baseName = "openkrill-google-compute";
            virtualisation.diskSize = 4096; # 4GB, auto-grows on GCE
          }
        ];

        # Incus VM — QCOW2 with guest agent, EFI, virtio, serial console.
        # Uses system.build.qemuImage (not system.build.image, which is
        # the LXC metadata tarball in this module stack).
        incus-vm = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            baseConfig
            "${nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
          ];
        }).config.system.build.qemuImage;

        # Bootable live ISO — boots k3s directly from USB/CD.
        # Includes nixos-install so the user can install to disk.
        iso = mkImage [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          { image.baseName = nixpkgs.lib.mkForce "openkrill"; }
        ];

        # ── Dev VM ────────────────────────────────────────────────

        # Local QEMU VM with port forwarding for kubectl.
        # Run: nix run .#vm
        vm = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            baseConfig
            ({ modulesPath, lib, ... }: {
              imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
              boot.loader.grub.enable = lib.mkForce false;
              virtualisation = {
                memorySize = 4096;
                cores = 2;
                diskSize = 20480;
                forwardPorts = [
                  { from = "host"; host.port = 6443; guest.port = 6443; }
                ];
                graphics = false;
              };
            })
          ];
        }).config.system.build.vm;

        default = self.packages.${system}.qcow2;
      };
    };
}
