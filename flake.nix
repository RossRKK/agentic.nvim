{
  description = "agentic.nvim's test suite, with nightly nvim and mini.nvim, rg, fd and git from nixpkgs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # The plugin needs nvim 0.13, which is only a nightly until it is released.
    neovim-nightly.url = "github:nix-community/neovim-nightly-overlay";
  };

  outputs =
    { self, nixpkgs, neovim-nightly }:
    let
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system} neovim-nightly.packages.${system}.default
        );
      packages = pkgs: nvim: [
        nvim
        pkgs.gnumake
        # The file picker's tests run its real listing commands, as upstream's CI installs them.
        pkgs.ripgrep
        pkgs.fd
        pkgs.git
      ];
      # tests/init.lua clones mini.nvim into deps/ unless it's already there. A
      # copy, not a link: the file picker's tests resolve a link out of deps/.
      copyMini = pkgs: "[ -e deps/mini.nvim ] || { mkdir -p deps && cp -r ${pkgs.vimPlugins.mini-nvim} deps/mini.nvim && chmod -R u+w deps; }";
    in
    {
      # `nix develop -c make test`: the VIM/VIMRUNTIME an enclosing nvim
      # exports would point this nvim at that one's runtime.
      devShells = forEachSystem (
        pkgs: nvim: {
          default = pkgs.mkShell {
            packages = packages pkgs nvim;
            shellHook = "unset VIM VIMRUNTIME; ${copyMini pkgs}";
          };
        }
      );

      # `nix flake check`, from a git checkout as `make test` runs in: rg only
      # honours .gitignore (deps/) inside one.
      checks = forEachSystem (
        pkgs: nvim: {
          test = pkgs.runCommand "agentic-tests" { nativeBuildInputs = packages pkgs nvim; }
            "cp -r ${self} src && chmod -R u+w src && cd src && git init -q && ${copyMini pkgs} && HOME=$TMPDIR make test && touch $out";
        }
      );
    };
}
