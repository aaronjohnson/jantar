defmodule Jantar.Display.VtSignal do
  @moduledoc """
  Forwards SIGUSR2 to `Jantar.Display.Ticker`, which holds its VT in process
  mode with SIGUSR2 as the kernel's "release" and "acquire" signal.

  A handler on `:erl_signal_server`, the gen_event the VM sends OS signals
  to once `:os.set_signal(:sigusr2, :handle)` is on. The VM's own handler
  ignores SIGUSR2, so this one is the only thing that acts on it.
  """
  @behaviour :gen_event

  @signal :sigusr2
  # SIGUSR2's number on Linux, for VT_SETMODE.
  @signal_number 12

  @doc "The signal number to give VT_SETMODE."
  def number, do: @signal_number

  @doc "Route SIGUSR2 to the Ticker (idempotent)."
  def install do
    :ok = :os.set_signal(@signal, :handle)

    if __MODULE__ in :gen_event.which_handlers(:erl_signal_server),
      do: :ok,
      else: :gen_event.add_handler(:erl_signal_server, __MODULE__, [])
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_event(@signal, state) do
    # By name: the Ticker may have restarted since this was installed.
    if pid = Process.whereis(Jantar.Display.Ticker), do: send(pid, :vt_signal)
    {:ok, state}
  end

  def handle_event(_other, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}
end
