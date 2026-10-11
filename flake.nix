{
  description = "beam-hud: a BEAM (Gleam + Elixir) system monitor dashboard";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # One BEAM for everything: Elixir and rebar3 built against the same OTP.
      beam = pkgs.beam28Packages;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          beam.erlang
          beam.elixir
          beam.rebar3
          pkgs.gleam
          # Later milestones: the Rust NIF (Rustler) and the C/cairo port.
          pkgs.cargo
          pkgs.rustc
          pkgs.cairo
          pkgs.pkg-config
        ];

        shellHook = ''
          # Keep Mix and Hex state inside the project, not in ~/.mix.
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export ERL_AFLAGS="-kernel shell_history enabled"
        '';
      };
    };
}
