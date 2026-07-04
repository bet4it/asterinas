{ pkgs ? import <nixpkgs> { }, autoInstall ? false, extra-substituters ? ""
, config-file-name ? "configuration.nix", extra-trusted-public-keys ? ""
, target_platform ? "x86_64-linux", version ? "", config-path ? ""
, console ? "hvc0", installerConsole ? "hvc0"
, aster-kernel-path ? ../../target/osdk/iso_root/boot/aster-kernel-osdk-bin
, ... }:
let
  installer = pkgs.callPackage ../aster_nixos_installer {
    inherit extra-substituters extra-trusted-public-keys config-file-name
      target_platform config-path console aster-kernel-path;
  };
  configuration = {
    imports = [
      "${pkgs.path}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      "${pkgs.path}/nixos/modules/installer/cd-dvd/channel.nix"
    ];

    system.nixos.distroName = "Asterinas NixOS";
    system.nixos.label = "${version}";
    boot.kernelParams =
      pkgs.lib.optionals (installerConsole == "ttyS0") [ "console=ttyS0,115200n8" ];
    isoImage.appendToMenuLabel = " Installer";

    services.getty.autologinUser = pkgs.lib.mkForce "root";
    environment.systemPackages = [ installer ];
    environment.loginShellInit = ''
      if [ ! -e "$HOME/configuration.nix" ]; then
        # Create an editable copy of configuration.nix in user's home.
        cp -L ${installer}/etc_nixos/configuration.nix $HOME && chmod u+w $HOME/configuration.nix
      fi

      ${pkgs.lib.optionalString autoInstall ''
        case "$(tty)" in
          /dev/hvc0|/dev/ttyS0)
            echo "The installer automatically runs on $(tty)!"
            aster-nixos-install --config $HOME/configuration.nix --disk /dev/vda --force-format-disk || true
            poweroff
            ;;
        esac
      ''}
    '';
  };
in (pkgs.nixos configuration).config.system.build.isoImage
