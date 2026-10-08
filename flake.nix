{
  description = "Shared Kamal deploy actions and operations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        # Ruby 3.3 and Bundler for the locked bundle, plus the tools the fast checks use.
        # The C toolchain comes from mkShell's stdenv; Kamal's SSH dependencies build native
        # extensions.
        default = pkgs.mkShell {
          packages = [
            pkgs.ruby_3_3
            # Ruby 3.3's default Bundler is older than its RubyGems and warns on every load;
            # this one matches the version Gemfile.lock is bundled with.
            (pkgs.bundler.override { ruby = pkgs.ruby_3_3; })
            pkgs.git
            pkgs.openssh
            pkgs.jq
            pkgs.shellcheck
            pkgs.actionlint
          ];
        };
      });
    };
}
