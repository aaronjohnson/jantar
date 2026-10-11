defmodule Mix.Tasks.Compile.HudCore do
  @moduledoc """
  Builds the Gleam core (gleam/hud_core) and puts its compiled modules on the
  code path, so Elixir can call them as `:hud_core@parse`, `:hud_core@rate`...

  It is defined here in mix.exs, not under lib/, because Mix needs the
  compiler before it compiles anything in lib/.

  If `HUD_CORE_BUILD` is set (e.g. by a Nix derivation that built the Gleam
  package separately), no Gleam toolchain is needed: every `*/ebin` directory
  under that path is added instead.
  """
  use Mix.Task.Compiler

  @gleam_project "gleam/hud_core"

  @impl Mix.Task.Compiler
  def run(_args) do
    with {:ok, build} <- build() do
      for ebin <- Path.wildcard(Path.join(build, "*/ebin")) do
        Code.prepend_path(ebin)
      end

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

defmodule BeamHud.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_hud,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Build the Gleam core first, then the usual Elixir compilers.
      compilers: [:hud_core | Mix.compilers()],
      deps: []
    ]
  end

  def application do
    [
      mod: {BeamHud.Application, []},
      extra_applications: [:logger]
    ]
  end
end
