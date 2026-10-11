# services.jantar: the dashboard on a VT of its own (Ctrl+Alt+F12 by
# default), shown with no login. Imported by the flake as
# nixosModules.default.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.jantar;
  tty = "tty${toString cfg.tty}";
  inherit (lib) mkOption mkEnableOption types;

  # Group read access to the RAPL energy counters (udev at boot, and again
  # on every start, since a switch doesn't re-run udev).
  powercapAccess = pkgs.writeShellScript "jantar-powercap" ''
    for f in /sys/class/powercap/intel-rapl:*/energy_uj; do
      [ -e "$f" ] || continue
      ${pkgs.coreutils}/bin/chgrp jantar "$f"
      ${pkgs.coreutils}/bin/chmod g+r "$f"
    done
  '';
in
{
  options.services.jantar = {
    enable = mkEnableOption "the jantar system dashboard on a text console";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "jantar.packages.\${system}.default";
      description = "The jantar release to run.";
    };

    tty = mkOption {
      type = types.ints.between 1 63;
      default = 12;
      description = ''
        The virtual terminal to own and draw on (Ctrl+Alt+F<tty>). It must not
        have a getty: logind starts them on tty1-6 only by default, and this
        service conflicts with getty@/autovt@ on its tty.
      '';
    };

    framebuffer = mkOption {
      type = types.str;
      default = "/dev/fb0";
      description = "The framebuffer device to draw into.";
    };

    backend = mkOption {
      type = types.enum [
        "cairo"
        "rust"
      ];
      default = "cairo";
      description = ''
        Renderer: "cairo" (a C program in its own process, so a crash in it
        can't take the VM down, and the faster of the two) or "rust" (a NIF
        inside the VM).
      '';
    };

    theme = mkOption {
      type = types.enum [
        "dark"
        "light"
      ];
      default = "dark";
      description = "Solarized dark or light, unless themeFile is set.";
    };

    themeFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/jantar-theme";
      description = ''
        Follow a file containing "dark" or "light", read every minute. The
        service can't ask a user's desktop (gsettings) itself; a user service
        or the bar's sunrise/sunset switch can write this file instead.
      '';
    };

    maxFps = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "Frame rate cap while the dashboard is on screen.";
    };

    batteryMaxFps = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Frame rate cap on battery.";
    };

    usbBays = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        "3-3" = "port1";
      };
      description = ''
        Which USB-C port (typec portN) each USB device path sits behind, for
        the PORTS panel. Firmware often doesn't say, so find it by plugging a
        device into each bay and reading its path from /sys/bus/usb/devices
        (a USB 3 device may also appear on a second path).
      '';
    };

    powercap = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Let jantar read Intel RAPL energy counters
        (/sys/class/powercap/intel-rapl:*/energy_uj) to show where power goes:
        platform, CPU package, cores, graphics, memory. The kernel makes them
        root-only because fine-grained power readings can leak secrets (the
        "Platypus" attack); this gives the jantar group read access to them.
      '';
    };

    extraGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "github-runner" ];
      description = ''
        More groups for the service user, for sources that need them: e.g.
        "github-runner" to read the CI runner's
        /run/github-runner/<name>/ci-status.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.jantar = {
      isSystemUser = true;
      group = "jantar";
      # video: /dev/fb0 is root:video 0660.
      extraGroups = [ "video" ] ++ cfg.extraGroups;
      description = "jantar dashboard";
    };
    users.groups.jantar = { };

    # The dashboard's tty belongs to the service user (as a login's tty
    # belongs to whoever logs in), so it can open it to set KD_GRAPHICS.
    services.udev.extraRules =
      ''
        SUBSYSTEM=="tty", KERNEL=="${tty}", OWNER="jantar", MODE="0600"
      ''
      + lib.optionalString cfg.powercap ''
        SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="${powercapAccess}"
      '';

    systemd.services.jantar = {
      description = "jantar dashboard on ${tty}";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];
      conflicts = [
        "getty@${tty}.service"
        "autovt@${tty}.service"
      ];

      # Tools the wifi and CI sensors run.
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gawk
        pkgs.iw
        pkgs.networkmanager
        config.systemd.package
      ];

      environment = {
        JANTAR_DISPLAY = "1";
        JANTAR_TTY = "/dev/${tty}";
        JANTAR_FB = cfg.framebuffer;
        JANTAR_BACKEND = cfg.backend;
        JANTAR_THEME = if cfg.themeFile != null then "file:${cfg.themeFile}" else cfg.theme;
        JANTAR_MAX_FPS = toString cfg.maxFps;
        JANTAR_BATTERY_MAX_FPS = toString cfg.batteryMaxFps;
        JANTAR_USB_BAYS = lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") cfg.usbBays);
        RELEASE_TMP = "/run/jantar";
        LANG = "C.UTF-8";
      };

      serviceConfig = {
        User = "jantar";
        Group = "jantar";
        ExecStart = "${cfg.package}/bin/jantar start";
        # The udev rule only applies when the tty device is (re)added, i.e.
        # at boot; also hand it over now, so the first switch works.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/chown jantar /dev/${tty}"
        ]
        ++ lib.optional cfg.powercap "+${powercapAccess}";
        # Whatever happened (stop, crash, kill), give the VT back its text.
        ExecStopPost = "+${cfg.package.passthru.cairoPort}/bin/cairo_port --kd-mode text /dev/${tty}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "jantar";
        # History is saved here on stop and loaded on start (STATE_DIRECTORY).
        StateDirectory = "jantar";

        # The tty becomes the service's controlling terminal, as with a
        # getty. The kernel lets a process set KDSETMODE on its own
        # controlling terminal, so no CAP_SYS_TTY_CONFIG is needed.
        StandardInput = "tty";
        StandardOutput = "journal";
        StandardError = "journal";
        TTYPath = "/dev/${tty}";
        TTYReset = true;
        TTYVHangup = true;

        # Hardening. Sensors only read /proc and /sys; the wifi sensor talks
        # to NetworkManager over D-Bus (AF_UNIX) and to nl80211 (AF_NETLINK).
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = false;
        IPAddressDeny = "any";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
        DevicePolicy = "closed";
        DeviceAllow = [
          "${cfg.framebuffer} rw"
          "/dev/${tty} rw"
        ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        UMask = "0077";
        # Not MemoryDenyWriteExecute: the BEAM's JIT writes machine code.
      };
    };
  };
}
