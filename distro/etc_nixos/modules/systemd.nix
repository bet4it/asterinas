{ config, lib, pkgs, ... }:

{
  systemd.package = pkgs.aster_systemd;

  # TODO: The following services currently do not work and
  # may affect systemd startup or cause performance issues.
  # Enable them after they can run successfully.
  networking.resolvconf.enable = false;
  systemd.coredump.enable = false;
  systemd.oomd.enable = false;
  systemd.services.logrotate.enable = false;
  systemd.services.network-setup.enable = false;
  systemd.services.resolvconf.enable = false;
  systemd.services.systemd-random-seed.enable = false;
  systemd.services.systemd-tmpfiles-clean.enable = false;
  systemd.services.systemd-tmpfiles-setup.enable = false;
  services.timesyncd.enable = false;
  services.udev.enable = false;

  services.getty.autologinUser = "root";
  users.users.root = {
    shell = "${pkgs.bash}/bin/bash";
    hashedPassword = null;
  };

  systemd.services.asterinas-console-shell = lib.mkIf (config.aster_nixos.console == "hvc0") {
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    # Asterinas exposes hvc0 as the system console, but not as a full Linux tty.
    # Open it as a console file so `make run_nixos` still gets an interactive root shell.
    serviceConfig = {
      ExecStart = "${pkgs.bashInteractive}/bin/bash -li";
      Restart = "always";
      StandardInput = "file:/dev/console";
      StandardOutput = "file:/dev/console";
      StandardError = "file:/dev/console";
    };
  };

  systemd.targets.getty.wants = lib.mkForce (
    # tty1: provide text login on the virtual console when X server is disabled.
    lib.optional (!config.services.xserver.enable && config.aster_nixos.console == "tty0")
      "autovt@tty1.service"
  );

  systemd.settings.Manager = {
    LogLevel = "crit";
    ShowStatus = "no";
  };
}
