# The Gleam core, built offline: every Hex package in manifest.toml is
# fetched by its locked checksum (Hex's "outer checksum" is the SHA-256 of
# the package tarball), unpacked where gleam expects downloaded packages, and
# the project exported as an Erlang shipment (one ebin directory per package).
{
  lib,
  stdenvNoCC,
  fetchurl,
  gleam,
  erlang,
}:

let
  root = ../gleam/hud_core;
  manifest = lib.importTOML (root + "/manifest.toml");
  hexPackages = builtins.filter (p: p.source == "hex") manifest.packages;

  tarball =
    p:
    fetchurl {
      url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
      sha256 = lib.toLower p.outer_checksum;
    };

  # A Hex tarball holds metadata and contents.tar.gz, the package's files.
  unpack = p: ''
    mkdir -p build/packages/${p.name}
    tar -xOf ${tarball p} contents.tar.gz | tar -xz -C build/packages/${p.name}
  '';

  # How gleam records which package versions are already downloaded.
  packagesToml = ''
    [packages]
    ${lib.concatMapStrings (p: "${p.name} = \"${p.version}\"\n") hexPackages}
  '';
in
stdenvNoCC.mkDerivation {
  pname = "hud-core";
  version = (lib.importTOML (root + "/gleam.toml")).version;

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/gleam.toml")
      (root + "/manifest.toml")
      (root + "/src")
    ];
  };

  nativeBuildInputs = [
    gleam
    erlang
  ];

  configurePhase = ''
    runHook preConfigure
    export HOME=$TMPDIR
    ${lib.concatMapStrings unpack hexPackages}
    cat > build/packages/packages.toml <<'TOML'
    ${packagesToml}
    TOML
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    gleam export erlang-shipment
    runHook postBuild
  '';

  # $out/<package>/ebin/*.beam, which is what HUD_CORE_BUILD expects.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    for dir in build/erlang-shipment/*/; do
      [ -d "$dir/ebin" ] && cp -r "$dir" $out/
    done
    runHook postInstall
  '';
}
