# A NixOS VM with services.jantar: the service starts, draws when VT12 is
# switched to (a screenshot is saved as the test's output), stops drawing
# when it isn't, survives the cairo port segfaulting, and puts the console
# back in text mode when stopped.
#
#   nix build .#checks.x86_64-linux.vm -L     (screenshot in ./result)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "jantar";

  nodes.machine = {
    imports = [ self.nixosModules.default ];
    services.jantar.enable = true;
    virtualisation.memorySize = 1024;
    # 1440x960, like the laptop's panel at half size.
    virtualisation.resolution = {
      x = 1440;
      y = 960;
    };
  };

  testScript = ''
    machine.wait_for_unit("jantar.service")
    machine.succeed("test -c /dev/fb0")
    # The service owns its tty, and has no capabilities.
    machine.succeed("stat -c %U /dev/tty12 | grep -x jantar")
    machine.succeed("grep -q '^CapEff:\\s*0*$' /proc/$(systemctl show -p MainPID --value jantar)/status")

    with subtest("draws only while tty12 is in the foreground"):
        machine.succeed("timeout 10 chvt 12")
        machine.wait_until_succeeds("journalctl -u jantar | grep -q 'tty12 is in the foreground: drawing'")
        machine.sleep(4)
        machine.screenshot("dashboard")
        machine.fail("journalctl -u jantar | grep -Eiq 'KDSETMODE|permission denied|frame not drawn'")
        machine.succeed("timeout 10 chvt 1")
        machine.wait_until_succeeds("journalctl -u jantar | grep -q 'not drawing'")

    with subtest("switching back and forth keeps working, and redraws each time"):
        for _ in range(3):
            machine.succeed("timeout 10 chvt 12")
            machine.wait_until_succeeds("test \"$(cat /sys/class/tty/tty0/active)\" = tty12")
            machine.succeed("timeout 10 chvt 2")
            machine.wait_until_succeeds("test \"$(cat /sys/class/tty/tty0/active)\" = tty2")
        machine.fail("journalctl -u jantar | grep -Eq 'VT_SETMODE|VT_RELDISP'")

    with subtest("a segfaulting renderer is restarted; the service keeps running"):
        pid = machine.succeed("systemctl show -p MainPID --value jantar").strip()
        machine.succeed("pkill -SEGV -x cairo_port")
        machine.wait_until_succeeds("journalctl -u jantar | grep -q 'cairo_port exited with status 139'")
        machine.wait_until_succeeds("pgrep -x cairo_port")
        assert machine.succeed("systemctl show -p MainPID --value jantar").strip() == pid

    def drawing():
        machine.wait_until_succeeds(
            "journalctl -u jantar | grep -E 'in the (fore|back)ground' | tail -1 | grep -q foreground"
        )

    with subtest("a killed jantar doesn't trap anyone on its console"):
        machine.succeed("timeout 10 chvt 12")
        drawing()
        machine.succeed("systemctl kill -s KILL jantar")
        machine.succeed("timeout 10 chvt 1")
        machine.wait_until_succeeds("test \"$(cat /sys/class/tty/tty0/active)\" = tty1")
        machine.wait_for_unit("jantar.service")

    with subtest("stopping gives the console back"):
        machine.succeed("timeout 10 chvt 12")
        drawing()
        machine.succeed("systemctl stop jantar")
        machine.succeed("timeout 10 chvt 1")
        machine.succeed("timeout 10 chvt 12")
        machine.fail("journalctl -u jantar | grep -q 'KDSETMODE text'")
        machine.sleep(1)
        machine.screenshot("after-stop")
  '';
}
