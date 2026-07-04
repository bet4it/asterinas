{ pkgs ? import <nixpkgs> { }, diskSize ? 8192, extra-substituters ? ""
, config-file-name ? "configuration.nix", extra-trusted-public-keys ? ""
, target_platform ? "x86_64-linux", config-path ? "", console ? "hvc0"
, aster-kernel-path ? ../../target/osdk/iso_root/boot/aster-kernel-osdk-bin, ...
}:
let
  lib = pkgs.lib;
  installer = pkgs.callPackage ../aster_nixos_installer {
    inherit extra-substituters extra-trusted-public-keys config-file-name
      target_platform config-path console aster-kernel-path;
  };
  nixos =
    pkgs.nixos { imports = [ "${installer}/etc_nixos/configuration.nix" ]; };
  system = nixos.config.system.build.toplevel;
  closureInfo = pkgs.closureInfo { rootPaths = [ system ]; };
  grubTarget = {
    x86_64-linux = "x86_64-efi";
  }.${target_platform} or (throw
    "Unsupported NixOS image target platform: ${target_platform}");
  grubEfiName = {
    x86_64-linux = "BOOTX64.EFI";
  }.${target_platform} or (throw
    "Unsupported NixOS image target platform: ${target_platform}");
  binPath = lib.makeBinPath (with pkgs; [
    coreutils
    dosfstools
    e2fsprogs
    findutils
    gawk
    gnugrep
    gnused
    grub2_efi
    lkl
    mtools
    nix
    nixos.config.system.build.nixos-install
    parted
    rsync
    util-linux
  ]);
in pkgs.runCommand "asterinas-nixos-image" {
  nativeBuildInputs = [ pkgs.makeWrapper ];
  passthru = { inherit system; };
} ''
    set -euo pipefail

    export PATH=${binPath}:$PATH
    export HOME=$TMPDIR
    export NIX_STATE_DIR=$TMPDIR/state
    export MTOOLS_SKIP_CHECK=1

    sectors_to_kilobytes() {
      echo $(( ( "$1" * 512 ) / 1024 ))
    }

    sectors_to_bytes() {
      echo $(( "$1" * 512 ))
    }

    mkdir -p "$out"

    root="$PWD/root"
    mkdir -p "$root/etc/nixos"
    cp ${installer}/etc_nixos/configuration.nix "$root/etc/nixos/configuration.nix"
    cp ${installer}/etc_nixos/aster_configuration.nix \
      "$root/etc/nixos/aster_configuration.nix"
    cp -r ${installer}/etc_nixos/modules "$root/etc/nixos/modules"
    cp -r ${installer}/etc_nixos/overlays "$root/etc/nixos/overlays"

    nix-store --load-db < ${closureInfo}/registration
    chmod 755 "$TMPDIR"

    nixos-install \
      --root "$root" \
      --no-bootloader \
      --no-channel-copy \
      --no-root-passwd \
      --system ${system} \
      --substituters ""

    disk_image=asterinas.img
    truncate -s ${toString diskSize}M "$disk_image"
    parted --script "$disk_image" -- \
      mklabel gpt \
      mkpart ESP fat32 1MiB 512MiB \
      set 1 esp on \
      mkpart root ext2 512MiB 100% \
      align-check optimal 1 \
      align-check optimal 2 \
      print

    eval "$(partx "$disk_image" -o START,SECTORS --nr 1 --pairs)"
    boot_start="$START"
    boot_sectors="$SECTORS"

    eval "$(partx "$disk_image" -o START,SECTORS --nr 2 --pairs)"
    root_start="$START"
    root_sectors="$SECTORS"

    mkfs.ext2 \
      -b 4096 \
      -F \
      -L nixos \
      "$disk_image" \
      -E offset="$(sectors_to_bytes "$root_start")" \
      "$(sectors_to_kilobytes "$root_sectors")K"

    cptofs \
      -P 2 \
      -t ext2 \
      -i "$disk_image" \
      "$root"/* /

    kernel_params="$(cat ${system}/kernel-params)"
    cat > grub.cfg <<EOF
  set default=0
  set timeout=0
  search --no-floppy --file --set=root /asterinas/kernel

  serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
  terminal_input serial console
  terminal_output serial console

  menuentry "Asterinas NixOS" {
      linux /asterinas/kernel $kernel_params
      initrd /asterinas/initrd
  }
  EOF

    grub-mkstandalone \
      -O ${grubTarget} \
      -o ${grubEfiName} \
    --fonts="" \
    --locales="" \
    --modules="part_gpt fat linux normal search search_fs_file serial terminal" \
      "boot/grub/grub.cfg=grub.cfg"

    boot_image=esp.img
    truncate -s "$(sectors_to_bytes "$boot_sectors")" "$boot_image"
    mkfs.fat -F 32 -n boot "$boot_image"
    mmd -i "$boot_image" ::/EFI ::/EFI/BOOT ::/asterinas ::/boot ::/boot/grub
    mcopy -i "$boot_image" ${grubEfiName} ::/EFI/BOOT/${grubEfiName}
    mcopy -i "$boot_image" grub.cfg ::/boot/grub/grub.cfg
    mcopy -i "$boot_image" ${system}/kernel ::/asterinas/kernel
    mcopy -i "$boot_image" ${system}/initrd ::/asterinas/initrd

    dd \
      if="$boot_image" \
      of="$disk_image" \
      bs=512 \
      seek="$boot_start" \
      conv=notrunc \
      status=none

    mv "$disk_image" "$out/asterinas.img"
    mkdir -p "$out/nix-support"
    echo "file raw-image $out/asterinas.img" \
      > "$out/nix-support/hydra-build-products"
''
