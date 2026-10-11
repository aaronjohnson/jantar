{
  description = "jantar: a BEAM (Gleam + Elixir) system monitor dashboard";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # One BEAM for everything: Elixir and rebar3 built against the same OTP.
      beam = pkgs.beam28Packages;
    in
    {
      packages.${system} = rec {
        jantar = pkgs.callPackage ./nix/package.nix { beamPackages = beam; };
        default = jantar;
      };

      nixosModules.default = import ./nix/module.nix self;

      checks.${system} = {
        package = self.packages.${system}.default;
        vm = import ./nix/vm-test.nix { inherit pkgs self; };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          beam.erlang
          beam.elixir
          beam.rebar3
          pkgs.gleam
          # Renderers: the Rust NIF (Rustler) and the C/cairo port.
          pkgs.cargo
          pkgs.rustc
          pkgs.cairo
          pkgs.freetype
          pkgs.fontconfig
          pkgs.pkg-config
          pkgs.gnumake
          pkgs.gcc
          pkgs.dejavu_fonts
        ];

        shellHook = ''
          # Keep Mix and Hex state inside the project, not in ~/.mix.
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export ERL_AFLAGS="-kernel shell_history enabled"
          # The font both renderers draw with (the same one hud --fb uses).
          export JANTAR_FONT_DIR=${pkgs.dejavu_fonts}/share/fonts/truetype
        '';
      };
    };
}
