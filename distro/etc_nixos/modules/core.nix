{ config, lib, pkgs, options, ... }:
let
  kernel = builtins.path {
    name = "aster-kernel-osdk-bin";
    path = config.aster_nixos.kernel;
  };
  stage-1-init = pkgs.writeShellScript "stage-1-init" ''
    #!/bin/sh
    # SPDX-License-Identifier: MPL-2.0

    mkdir -p /dev /dev/pts /dev/shm
    mknod /dev/console c 5 1 2>/dev/null; chmod 666 /dev/console
    mknod /dev/tty c 5 0 2>/dev/null; chmod 666 /dev/tty
    mknod /dev/tty0 c 4 0 2>/dev/null; chmod 622 /dev/tty0
    mknod /dev/ttyS0 c 4 64 2>/dev/null; chmod 660 /dev/ttyS0
    mknod /dev/hvc0 c 229 0 2>/dev/null; chmod 666 /dev/hvc0
    mknod /dev/hvc1 c 229 1 2>/dev/null; chmod 660 /dev/hvc1
    mknod /dev/hvc2 c 229 2 2>/dev/null; chmod 660 /dev/hvc2
    mknod /dev/hvc3 c 229 3 2>/dev/null; chmod 660 /dev/hvc3
    mknod /dev/null c 1 3 2>/dev/null; chmod 666 /dev/null
    mknod /dev/zero c 1 5 2>/dev/null; chmod 666 /dev/zero
    mknod /dev/full c 1 7 2>/dev/null; chmod 666 /dev/full
    mknod /dev/random c 1 8 2>/dev/null; chmod 666 /dev/random
    mknod /dev/urandom c 1 9 2>/dev/null; chmod 666 /dev/urandom
    mknod /dev/ptmx c 5 2 2>/dev/null; chmod 666 /dev/ptmx
    mknod /dev/tty1 c 4 1 2>/dev/null; chmod 620 /dev/tty1
    mknod /dev/tty2 c 4 2 2>/dev/null; chmod 620 /dev/tty2
    mknod /dev/tty3 c 4 3 2>/dev/null; chmod 620 /dev/tty3
    mknod /dev/tty4 c 4 4 2>/dev/null; chmod 620 /dev/tty4
    mknod /dev/tty5 c 4 5 2>/dev/null; chmod 620 /dev/tty5
    mknod /dev/tty6 c 4 6 2>/dev/null; chmod 620 /dev/tty6
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr

    NEW_ROOT=""
    NEW_INIT=""
    BREAK=""
    ARGS=""

    for arg in "$@"; do
      case "$arg" in
        root=*)
          NEW_ROOT=''${arg#root=}
          ;;
        init=*)
          NEW_INIT=''${arg#init=}
          ;;
        rd.break=*)
          BREAK=''${arg#rd.break=}
          ;;
        *)
          ARGS="$ARGS $arg"
          ;;
      esac
    done

    if [ "$BREAK" = "1" ]; then
      echo "Breaking into initramfs shell..."
      exec /bin/sh
    fi

    if [ -z "$NEW_ROOT" ] || [ -z "$NEW_INIT" ]; then
      echo "Error: 'root=' and 'init=' parameters are required."
      exit 1
    fi

    mkdir /sysroot
    mount -t ext2 "$NEW_ROOT" /sysroot
    mkdir -p /sysroot/proc /sysroot/dev /sysroot/run/initramfs/dev
    mkdir -p /sysroot/var/log /sysroot/var/run
    touch /sysroot/var/log/lastlog /sysroot/var/run/utmp /sysroot/var/log/wtmp
    mount -t proc none /sysroot/proc
    mount -o bind /dev /sysroot/run/initramfs/dev
    mount --move /dev /sysroot/dev

    exec switch_root /sysroot "$NEW_INIT" "$ARGS"
  '';

  initramfs = pkgs.makeInitrd {
    contents = [
      {
        object = "${pkgs.busybox}/bin";
        symlink = "/bin";
      }
      {
        object = stage-1-init;
        symlink = "/init";
      }
    ];
  };
  kernelParams =
    "PATH=/bin:/nix/var/nix/profiles/system/sw/bin ostd.log_level=${config.aster_nixos.log-level} console=${config.aster_nixos.console} init=/init -- root=/dev/vda2 init=/nix/var/nix/profiles/system/stage-2-init rd.break=${
      if config.aster_nixos.break-into-stage-1-shell then "1" else "0"
    }";
in {
  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.extraConfig =
    lib.mkIf (config.aster_nixos.console == "ttyS0") ''
      serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
      terminal_input serial console
      terminal_output serial console
    '';
  boot.initrd.enable = false;
  boot.kernel.enable = false;
  # Hook function will be called in stage-2-init and before running systemd.
  boot.postBootCommands = ''
    echo "Executing postBootCommands..."
    if [ "${config.aster_nixos.disable-systemd}" = "true" ]; then
      ${config.aster_nixos.stage-2-hook}
    fi
  '';
  # Suppress error and warning messages of systemd.
  # TODO: Fix errors and warnings from systemd and remove this setting.
  environment.sessionVariables = { SYSTEMD_LOG_LEVEL = "crit"; };
  systemd.services.restore-devices = {
    description = "Restore kernel-created block devices";
    wantedBy = [ "sysinit.target" ];
    before = [ "local-fs-pre.target" "systemd-tmpfiles-setup-dev.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart =
        "${pkgs.bash}/bin/bash -c 'if [ -d /run/initramfs/dev ]; then cp -a /run/initramfs/dev/vd* /dev/ 2>/dev/null || true; cp -a /run/initramfs/dev/nvme* /dev/ 2>/dev/null || true; fi'";
    };
  };
  system.systemBuilderCommands = ''
    echo "${kernelParams}" > $out/kernel-params
    mv $out/init $out/stage-2-init
    sed -i 's_^\([[:space:]]*\)\(exec > >(tee -i /run/log/stage-2-init.log) 2>&1\)$_\1# \2_' $out/stage-2-init
    if [ "${config.aster_nixos.disable-systemd}" = "true" ]; then
      sed -i 's/^[[:space:]]*echo "starting systemd..."$/# &/' $out/stage-2-init
      sed -i 's/^[[:space:]]*exec \/run\/current-system\/systemd\/lib\/systemd\/systemd "$@"$/# &/' $out/stage-2-init
    fi
    rm -rf $out/init
    ln -s /bin/busybox $out/init
    ln -s ${kernel} $out/kernel
    ln -s ${initramfs}/initrd $out/initrd
  '';
  system.activationScripts.modprobe = lib.mkForce "";

  nix.nixPath = options.nix.nixPath.default
    ++ [ "nixpkgs-overlays=/etc/nixos/overlays" ];
  nix.settings = {
    filter-syscalls = false;
    require-sigs = false;
    sandbox = false;
    # FIXME: Support Nix build users (nixbld*) and remove this setting. For detailed gaps, see
    # <https://github.com/asterinas/asterinas/issues/2672>.
    build-users-group = "";
    substituters = [ "${config.aster_nixos.substituters}" ];
    trusted-public-keys = [ "${config.aster_nixos.trusted-public-keys}" ];
  };

  # FIXME: Currently, during `nixos-rebuild`, `texinfo/install-info` encounters a `SIGBUS`.
  documentation.info.enable = false;
}
