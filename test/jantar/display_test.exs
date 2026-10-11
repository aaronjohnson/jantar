defmodule Jantar.DisplayTest do
  @moduledoc """
  The display draws only while its VT is in the foreground, checked here
  with a stand-in for /sys/class/tty/tty0/active and a stand-in framebuffer
  file (no KDSETMODE for those).
  """
  # Display and Mode are global (named) state.
  use ExUnit.Case, async: false

  alias Jantar.Display.Ticker
  alias Jantar.Mode

  @moduletag :tmp_dir
  @moduletag :capture_log

  # Poll until fun returns true (the ticker checks the VT every 500 ms).
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  setup %{tmp_dir: dir} do
    active = Path.join(dir, "active")
    File.write!(active, "tty1\n")
    fb = Path.join(dir, "fb")

    for backend <- [:rust] do
      start_supervised!(
        {Jantar.Display,
         backend: backend, tty: "/dev/tty12", fb: fb, size: {320, 200}, active_file: active}
      )
    end

    on_exit(fn -> Mode.set(:visible, true) end)
    %{active: active, fb: fb}
  end

  test "hidden while another VT is in front: no frames", %{active: active} do
    Process.sleep(700)
    assert %{visible: false, frames: 0} = Ticker.stats()
    refute Mode.get().visible
    assert File.read!(active) == "tty1\n"
  end

  test "draws when its VT comes to the front, stops when it goes", %{active: active, fb: fb} do
    File.write!(active, "tty12\n")
    assert eventually(fn -> Ticker.stats().frames >= 2 end)
    assert Mode.get().visible
    # Something was drawn into the stand-in framebuffer.
    assert File.read!(fb) != :binary.copy(<<0>>, 320 * 200 * 4)

    File.write!(active, "tty3\n")
    assert eventually(fn -> not Ticker.stats().visible end)
    refute Mode.get().visible
    frames = Ticker.stats().frames
    Process.sleep(600)
    assert Ticker.stats().frames == frames
  end

  test "frame pacing: at most max_fps, at least 1 fps" do
    state = %{max_fps: 4, battery_max_fps: 2}
    # No sensors running in tests: the slow end.
    assert Ticker.frame_interval([:cpu], state) == 1000
    assert Ticker.frame_interval([], %{state | max_fps: 10}) == 1000
  end

  test "an unopenable framebuffer is one clear log line and a retry, not a crash" do
    stop_supervised!(Jantar.Display)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({Jantar.Display, backend: :rust, fb: "/dev/fb0-nonexistent", size: nil})

        Process.sleep(300)
        assert %{fb_error: "/dev/fb0-nonexistent: " <> _, frames: 0} = Ticker.stats()
      end)

    assert log =~ "will keep retrying"
    refute log =~ "MatchError"
  end

  test "permission problems are explained" do
    assert Ticker.explain("/dev/fb0", "/dev/fb0: Permission denied (os error 13)") =~
             "video group"
  end

  test "the foreground VT name", %{active: active} do
    assert Ticker.foreground_vt(active) == "tty1"
    assert Ticker.foreground_vt("/nonexistent") == nil
  end
end
