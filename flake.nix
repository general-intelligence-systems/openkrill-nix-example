{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem( system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = {
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            ruby_3_4
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
}
