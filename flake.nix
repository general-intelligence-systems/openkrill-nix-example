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
    in
    {
      # ── Reusable NixOS modules ─────────────────────────────────
      #
      # openkrill — k3s service module
      #   { inputs, ... }: {
      #     imports = [ inputs.openkrill.nixosModules.openkrill ];
      #     services.openkrill.enable = true;
      #   }
      #
      # cluster — app module framework (cert-manager, argocd, etc.)
      #   { inputs, ... }: {
      #     imports = [ inputs.openkrill.nixosModules.cluster ];
      #     cluster.domain = "mycompany.com";
      #     cluster.apps.cert-manager.enable = true;
      #   }
      #
      # See examples/ for complete usage patterns.
      nixosModules.openkrill = import ./modules/openkrill.nix;
      nixosModules.cluster = import ./modules/cluster {
        inherit nix-kube-generators nixhelm;
      };
      nixosModules.default = self.nixosModules.openkrill;

      # ── Library helpers ─────────────────────────────────────────
      #
      # buildImages — create standard image variants from a base system.
      #
      #   let
      #     base = nixpkgs.lib.nixosSystem { ... };
      #     images = openkrill.lib.buildImages { inherit nixpkgs; system = base; };
      #   in {
      #     packages.x86_64-linux.qcow2 = images.qcow2.image;
      #     packages.x86_64-linux.vm    = images.vm.image;
      #   }
      #
      lib.buildImages = { nixpkgs, system }:
        import ./lib/images.nix { inherit nixpkgs system; };

      # ── Checks (nix flake check) ──────────────────────────────
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

      # ── Dev shells ─────────────────────────────────────────────
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
