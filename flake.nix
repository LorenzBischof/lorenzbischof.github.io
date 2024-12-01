{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    hugo-papermod = {
      url = "github:adityatelange/hugo-papermod";
      flake = false;
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      hugo-papermod,
      treefmt-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        name = "hugo-blog";
        src = self;
        configurePhase = ''
          mkdir -p themes/papermod
          cp -r ${hugo-papermod}/* themes/papermod
        '';
        buildPhase = ''
          ${pkgs.hugo}/bin/hugo --minify
        '';
        installPhase = "cp -r public $out";
      };
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          hugo
        ];
        shellHook = ''
          mkdir -p themes
          ln -sfn ${hugo-papermod} themes/papermod
        '';
      };
      formatter.${system} = treefmtEval.config.build.wrapper;
      checks.${system}.formatting = treefmtEval.config.build.check self;
    };
}
