defmodule Mix.Tasks.Compile.JantarCore do
  @moduledoc """
  Builds the Gleam core (gleam/jantar_core) and copies its compiled modules
  (`:jantar_core@parse`, `:gleam@list`, ...) into jantar's own ebin, so they
  are part of this application: on the code path in development, and
  included in a `mix release` like any module of ours.

  It is defined here in mix.exs, not under lib/, because Mix needs the
  compiler before it compiles anything in lib/.

  If `JANTAR_CORE_BUILD` is set (the Nix package builds the Gleam project in its
  own derivation, with `gleam export erlang-shipment`), no Gleam toolchain is
  needed: the `.beam` files under `$JANTAR_CORE_BUILD/*/ebin` are used instead.
  """
  use Mix.Task.Compiler

  @gleam_project "gleam/jantar_core"
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
    case System.get_env("JANTAR_CORE_BUILD") do
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
          compiler_name: "jantar_core",
          file: Path.expand(@gleam_project),
          message: "gleam build failed",
          position: 0,
          severity: :error
        }

        {:error, [diagnostic]}
    end
  end
end

defmodule Mix.Tasks.Compile.CPorts do
  @moduledoc """
  Builds the C programs run as Ports, with make, into the app's priv
  directory: the renderer (c/cairo_port, started by `Jantar.Render.Cairo`)
  and the NPU counters (c/npu_port, started by `Jantar.NpuPort`). If
  `CAIRO_PORT_BIN` or `NPU_PORT_BIN` is set (the Nix package builds them
  separately), that binary is copied instead.
  """
  use Mix.Task.Compiler

  @ports [{"cairo_port", "CAIRO_PORT_BIN"}, {"npu_port", "NPU_PORT_BIN"}]

  @impl Mix.Task.Compiler
  def run(_args) do
    results =
      for {name, var} <- @ports do
        out = Path.join(Mix.Project.app_path(), "priv/" <> name)
        File.mkdir_p!(Path.dirname(out))

        case System.get_env(var) do
          nil -> make(name, out)
          bin -> copy(bin, out)
        end
      end

    Enum.find(results, {:ok, []}, &match?({:error, _}, &1))
  end

  defp make(name, out) do
    case System.cmd("make", ["-s", "-C", "c/" <> name, "OUT=#{out}"], stderr_to_stdout: true) do
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

defmodule Jantar.MixProject do
  use Mix.Project

  def project do
    [
      app: :jantar,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Build the Gleam core and the C ports first, then the usual compilers
      # (Rustler builds the NIF when Jantar.Render.Native is compiled).
      compilers: [:jantar_core, :c_ports | Mix.compilers()],
      deps: deps(),
      releases: [
        jantar: [
          # VM flags (battery-friendly scheduler settings, -noinput) are in
          # rel/vm.args.eex; environment defaults in rel/env.sh.eex.
          include_executables_for: [:unix],
          strip_beams: true
        ]
      ]
    ]
  end

  # Rustler builds the Rust NIF (native/jantar_render) with cargo at compile time.
  defp deps do
    [{:rustler, "~> 0.38", runtime: false}]
  end

  def application do
    [
      mod: {Jantar.Application, []},
      extra_applications: [:logger]
    ]
  end
end
