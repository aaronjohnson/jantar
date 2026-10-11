# A NixOS VM with services.beam-hud: the service starts, draws when VT12 is
# switched to (a screenshot is saved as the test's output), stops drawing
# when it isn't, survives the cairo port segfaulting, and puts the console
# back in text mode when stopped.
#
#   nix build .#checks.x86_64-linux.vm -L     (screenshot in ./result)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "beam-hud";

  nodes.machine = {
    imports = [ self.nixosModules.default ];
    services.beam-hud.enable = true;
    virtualisation.memorySize = 1024;
    # 1440x960, like the laptop's panel at half size.
    virtualisation.resolution = {
      x = 1440;
      y = 960;
    };
  };

  testScript = ''
    machine.wait_for_unit("beam-hud.service")
    machine.succeed("test -c /dev/fb0")
    # The service owns its tty, and has no capabilities.
    machine.succeed("stat -c %U /dev/tty12 | grep -x beam-hud")
    machine.succeed("grep -q '^CapEff:\\s*0*$' /proc/$(systemctl show -p MainPID --value beam-hud)/status")

    with subtest("draws only while tty12 is in the foreground"):
        machine.succeed("chvt 12")
        machine.wait_until_succeeds("journalctl -u beam-hud | grep -q 'tty12 is in the foreground: drawing'")
        machine.sleep(4)
        machine.screenshot("dashboard")
        machine.fail("journalctl -u beam-hud | grep -Eiq 'KDSETMODE|permission denied|frame not drawn'")
        machine.succeed("chvt 1")
        machine.wait_until_succeeds("journalctl -u beam-hud | grep -q 'not drawing'")

    with subtest("a segfaulting renderer is restarted; the service keeps running"):
        pid = machine.succeed("systemctl show -p MainPID --value beam-hud").strip()
        machine.succeed("pkill -SEGV -x cairo_port")
        machine.wait_until_succeeds("journalctl -u beam-hud | grep -q 'cairo_port exited with status 139'")
        machine.wait_until_succeeds("pgrep -x cairo_port")
        assert machine.succeed("systemctl show -p MainPID --value beam-hud").strip() == pid

    with subtest("stopping gives the console back"):
        machine.succeed("chvt 12")
        machine.wait_until_succeeds("journalctl -u beam-hud | grep -c 'is in the foreground' | grep -q 2")
        machine.succeed("systemctl stop beam-hud")
        machine.fail("journalctl -u beam-hud | grep -q 'KDSETMODE text'")
        machine.sleep(1)
        machine.screenshot("after-stop")
  '';
}
