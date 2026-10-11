defmodule BeamHud.NativeFailureTest do
  @moduledoc """
  What happens when native code fails, in each backend.

    * cairo (a Port): the C program segfaults, the port closes, the backend
      process exits, its supervisor starts a new one with a new OS process.
    * Rust (a NIF): a Rust panic is caught by Rustler at the NIF boundary and
      raised in the calling process. (A real segfault in a NIF would take
      the whole VM down; that isn't something to test.)
  """
  use ExUnit.Case, async: true

  alias BeamHud.Render.Cairo

  test "the port protocol round-trips arbitrary bytes" do
    server = start_supervised!({Cairo, []})
    bytes = :crypto.strong_rand_bytes(100_000)
    assert Cairo.echo(server, bytes) == {:ok, bytes}
    assert Cairo.echo(server, "") == {:ok, ""}
  end

  test "crash is refused unless allowed" do
    server = start_supervised!({Cairo, []})
    pid = Cairo.os_pid(server)
    assert Cairo.crash(server) == {:error, "CRASH needs --allow-crash"}
    # Still the same program, still answering.
    assert Cairo.echo(server, "ok") == {:ok, "ok"}
    assert Cairo.os_pid(server) == pid
  end

  @tag :capture_log
  test "a segfaulting port is restarted by its supervisor; the test process lives on" do
    children = [{Cairo, [name: :crashy_cairo, allow_crash: true]}]

    start_supervised!(%{
      id: :sup,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    })

    old = Process.whereis(:crashy_cairo)
    old_os_pid = Cairo.os_pid(old)
    ref = Process.monitor(old)
    assert Cairo.crash(old) == :crashed

    # SIGSEGV is signal 11; the port reports exit status 128 + 11.
    assert_receive {:DOWN, ^ref, :process, ^old, {:port_exited, 139}}, 5000

    new = wait_for(fn -> Process.whereis(:crashy_cairo) end)
    assert new != old
    assert Cairo.os_pid(new) != old_os_pid
    assert Cairo.echo(new, "alive") == {:ok, "alive"}
  end

  test "a Rust panic becomes an Erlang error in the caller" do
    assert_raise ErlangError, fn -> BeamHud.Render.Native.panic_demo() end
    # And the NIF still works afterwards.
    assert {:error, _} = BeamHud.Render.Native.new("/nonexistent", "/nonexistent")
  end

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end
end
