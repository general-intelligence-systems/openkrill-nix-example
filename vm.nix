# VM configuration for local development
# Provides QEMU VM settings for running the k3s cluster locally.
# Works on Linux (KVM) and macOS Apple Silicon (HVF via aarch64-linux guest).
#
# This module imports the NixOS QEMU VM infrastructure directly, so the
# nixosConfiguration *is* the VM -- no separate vmVariant indirection.
{ modulesPath, lib, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
  ];

  # QEMU VM uses direct kernel boot, not grub
  boot.loader.grub.enable = lib.mkForce false;

  virtualisation = {
    # k3s needs at least 2GB, 4GB is comfortable
    memorySize = 4096;
    cores = 2;

    # Persistent disk for k3s data (/var/lib/rancher, etcd, etc.)
    diskSize = 20480; # 20GB

    # Forward k8s API port so kubectl works from the host
    forwardPorts = [
      { from = "host"; host.port = 6443; guest.port = 6443; }
    ];

    # Graphics not needed for a headless k3s server
    graphics = false;
  };
}
