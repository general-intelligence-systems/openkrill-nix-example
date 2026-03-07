# NixOS VM integration test for the openkrill k3s module.
#
# Verifies that k3s boots, the API server becomes ready, and the
# node reports Ready status.
#
# Run via:  nix flake check          (runs all checks including this)
# Run via:  nix build .#checks.x86_64-linux.k3s-test
#
# Interactive debugging:
#   nix build .#checks.x86_64-linux.k3s-test.driverInteractive
#   ./result/bin/nixos-test-driver
{ pkgs, openkrill-module }:

pkgs.testers.runNixOSTest {
  name = "k3s-test";

  nodes.machine = { lib, ... }: {
    imports = [ openkrill-module ];

    services.openkrill.enable = true;

    # k3s needs adequate resources
    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 4096;
    };
  };

  testScript = ''
    machine.start()

    # Wait for k3s systemd service to start
    machine.wait_for_unit("k3s.service", timeout=120)

    # Wait for the Kubernetes API server to respond
    machine.wait_until_succeeds("kubectl get nodes", timeout=120)

    # Verify the node reaches Ready status
    machine.wait_until_succeeds(
        "kubectl get nodes | grep ' Ready '",
        timeout=180,
    )

    # Verify the node name matches our hostname
    machine.succeed("kubectl get nodes -o name | grep 'node/openkrill'")
  '';
}
