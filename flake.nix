{
  description = "agentic.nvim's test suite, with its nvim and mini.nvim from nixpkgs";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system}
        );
      packages = pkgs: [
        pkgs.neovim-unwrapped
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
      # `nix develop -c make test NVIM=nvim`: NVIM, as the Makefile names its
      # binary, is also the socket of an enclosing nvim; VIM/VIMRUNTIME it
      # exports would point this nvim at that one's runtime.
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = packages pkgs;
          shellHook = "unset VIM VIMRUNTIME; ${copyMini pkgs}";
        };
      });

      # `nix flake check`, from a git checkout as `make test` runs in: rg only
      # honours .gitignore (deps/) inside one.
      checks = forEachSystem (pkgs: {
        test = pkgs.runCommand "agentic-tests" { nativeBuildInputs = packages pkgs; }
          "cp -r ${self} src && chmod -R u+w src && cd src && git init -q && ${copyMini pkgs} && HOME=$TMPDIR make test NVIM=nvim && touch $out";
      });
    };
}
