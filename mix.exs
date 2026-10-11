defmodule Mix.Tasks.Compile.HudCore do
  @moduledoc """
  Builds the Gleam core (gleam/hud_core) and copies its compiled modules
  (`:hud_core@parse`, `:gleam@list`, ...) into beam_hud's own ebin, so they
  are part of this application: on the code path in development, and
  included in a `mix release` like any module of ours.

  It is defined here in mix.exs, not under lib/, because Mix needs the
  compiler before it compiles anything in lib/.

  If `HUD_CORE_BUILD` is set (the Nix package builds the Gleam project in its
  own derivation, with `gleam export erlang-shipment`), no Gleam toolchain is
  needed: the `.beam` files under `$HUD_CORE_BUILD/*/ebin` are used instead.
  """
  use Mix.Task.Compiler

  @gleam_project "gleam/hud_core"
  # Test-only packages that don't belong in the app.
  @skip ["gleeunit"]

  @impl Mix.Task.Compiler
  def run(_args) do
    with {:ok, build} <- build() do
      dest = Mix.Project.compile_path()
      File.mkdir_p!(dest)

      for ebin <- Path.wildcard(Path.join(build, "*/ebin")),
          Path.basename(Path.dirname(ebin)) not in @skip,
          beam <- Path.wildcard(Path.join(ebin, "*.beam")) do
        # Copies from the Nix store are read-only; keep ours writable.
        target = Path.join(dest, Path.basename(beam))
        File.rm(target)
        File.cp!(beam, target)
        File.chmod!(target, 0o644)
      end

      Code.prepend_path(dest)
      {:ok, []}
    end
  end

  defp build do
    case System.get_env("HUD_CORE_BUILD") do
      nil -> gleam_build()
      dir -> {:ok, dir}
    end
  end

  defp gleam_build do
    case System.cmd("gleam", ["build", "--target", "erlang"],
           cd: @gleam_project,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, Path.join(@gleam_project, "build/dev/erlang")}

      {output, _status} ->
        Mix.shell().error(output)

        diagnostic = %Mix.Task.Compiler.Diagnostic{
          compiler_name: "hud_core",
          file: Path.expand(@gleam_project),
          message: "gleam build failed",
          position: 0,
          severity: :error
        }

        {:error, [diagnostic]}
    end
  end
end

defmodule Mix.Tasks.Compile.CairoPort do
  @moduledoc """
  Builds the C renderer (c/cairo_port) with make, into the app's priv
  directory, where `BeamHud.Render.Cairo` starts it from. If `CAIRO_PORT_BIN`
  is set (the Nix package builds it separately), that binary is copied
  instead.
  """
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_args) do
    out = Path.join(Mix.Project.app_path(), "priv/cairo_port")
    File.mkdir_p!(Path.dirname(out))

    case System.get_env("CAIRO_PORT_BIN") do
      nil -> make(out)
      bin -> copy(bin, out)
    end
  end

  defp make(out) do
    case System.cmd("make", ["-s", "-C", "c/cairo_port", "OUT=#{out}"], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, []}

      {output, _} ->
        Mix.shell().error(output)
        {:error, []}
    end
  end

  defp copy(bin, out) do
    File.rm(out)
    File.cp!(bin, out)
    File.chmod!(out, 0o755)
    {:ok, []}
  end
end

defmodule BeamHud.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_hud,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Build the Gleam core and the C port first, then the usual compilers
      # (Rustler builds the NIF when BeamHud.Render.Native is compiled).
      compilers: [:hud_core, :cairo_port | Mix.compilers()],
      deps: deps(),
      releases: [
        beam_hud: [
          # VM flags (battery-friendly scheduler settings, -noinput) are in
          # rel/vm.args.eex; environment defaults in rel/env.sh.eex.
          include_executables_for: [:unix],
          strip_beams: true
        ]
      ]
    ]
  end

  # Rustler builds the Rust NIF (native/hud_render) with cargo at compile time.
  defp deps do
    [{:rustler, "~> 0.38", runtime: false}]
  end

  def application do
    [
      mod: {BeamHud.Application, []},
      extra_applications: [:logger]
    ]
  end
end
