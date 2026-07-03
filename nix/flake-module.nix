{ inputs, ... }: {
  perSystem = { system, lib, ... }:
    let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };

      version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);

      rustToolchain = pkgs.rust-bin.nightly."2026-04-03".complete.override {
        extensions = [ "llvm-tools-preview" "rust-src" "rustc-dev" ];
        targets = [
          "loongarch64-unknown-none-softfloat"
          "riscv64imac-unknown-none-elf"
          "x86_64-unknown-none"
        ];
      };

      rustPlatform = pkgs.makeRustPlatform {
        cargo = rustToolchain;
        rustc = rustToolchain;
      };

      cargoOsdk = rustPlatform.buildRustPackage {
        pname = "cargo-osdk";
        inherit version;

        src = ../.;

        cargoLock.lockFile = ../osdk/Cargo.lock;
        cargoBuildFlags = [ "--manifest-path" "osdk/Cargo.toml" ];
        doCheck = false;

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.openssl ];

        postPatch = ''
          cp osdk/Cargo.lock Cargo.lock
        '';

        installPhase = ''
          runHook preInstall
          cargo_osdk_bin="$(find . -type f -name cargo-osdk -perm -0100 | head -n 1)"
          if [ -z "$cargo_osdk_bin" ]; then
            echo "Error: built cargo-osdk binary not found." >&2
            exit 1
          fi
          install -Dm755 "$cargo_osdk_bin" $out/bin/cargo-osdk
          runHook postInstall
        '';

        env.OSDK_LOCAL_DEV = "1";
      };

      hostTools = with pkgs; [
        bash
        cargoOsdk
        coreutils
        curl
        diffutils
        dosfstools
        e2fsprogs
        exfatprogs
        file
        findutils
        gawk
        git
        gnumake
        gnused
        gnutar
        gptfdisk
        grub2
        grub2_efi
        gzip
        jq
        mtools
        nix
        nixos-install-tools
        nixfmt-classic
        openssl
        parted
        patch
        pkg-config
        qemu
        rustToolchain
        typos
        util-linux
        which
        xorriso
        xz
        zstd
      ];

      initramfsPackagesFor = target:
        import ../test/initramfs/nix {
          inherit target;
          dnsServer = "8.8.8.8";
          hostSystem = system;
        };

      mkApp = name: description: text:
        let
          program = pkgs.writeShellApplication {
            inherit name text;
            runtimeInputs = hostTools;
          };
        in {
          type = "app";
          program = "${program}/bin/${name}";
          meta.description = description;
        };

      appPrelude = ''
        set -euo pipefail

        if [ -z "''${ASTERINAS_DIR:-}" ]; then
          ASTERINAS_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        fi

        if [ ! -f "$ASTERINAS_DIR/VERSION" ]; then
          echo "Error: run this command from an Asterinas checkout or set ASTERINAS_DIR." >&2
          exit 1
        fi

        export ASTERINAS_DIR
        export OSDK_LOCAL_DEV_ROOT="''${OSDK_LOCAL_DEV_ROOT:-$ASTERINAS_DIR}"
        export NIX_PATH="nixpkgs=${inputs.nixpkgs}"
        export OSDK_TARGET_ARCH="''${TARGET_ARCH:-x86_64}"
        export VDSO_LIBRARY_DIR="''${VDSO_LIBRARY_DIR:-${inputs.linux-vdso}}"
        export OVMF_CODE="''${OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF.fd}"
        export OVMF_VARS="''${OVMF_VARS:-${pkgs.OVMF.fd}/FV/OVMF_VARS.fd}"
        export MICROVM_OVMF="''${MICROVM_OVMF:-$OVMF_CODE}"
        export NIX_RUN_DIR="''${NIX_RUN_DIR:-$ASTERINAS_DIR/.nix-run}"
        export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$NIX_RUN_DIR/cargo-target}"
        export INITRAMFS_BUILD_DIR="''${INITRAMFS_BUILD_DIR:-$NIX_RUN_DIR/initramfs}"

        target_nix_system() {
          case "$1" in
            x86_64) echo "x86_64-linux" ;;
            aarch64) echo "aarch64-linux" ;;
            riscv64) echo "riscv64-linux" ;;
            loongarch64) echo "loongarch64-linux" ;;
            *) echo "Unsupported target architecture: $1" >&2; return 1 ;;
          esac
        }
      '';

      kvmFlag = ''
        KVM_ARG=""
        if [ "''${ENABLE_KVM:-1}" = "1" ] && [ "''${TARGET_ARCH:-x86_64}" = "x86_64" ] && [ -e /dev/kvm ]; then
          KVM_ARG="--qemu-args=-accel kvm"
        fi
      '';

      configureAutoTest = ''
        EXTRA_OSDK_ARGS=()

        case "''${AUTO_TEST:-none}" in
          conformance)
            export ENABLE_CONFORMANCE_TEST=true
            EXTRA_OSDK_ARGS+=(
              --kcmd-args="CONFORMANCE_TEST_SUITE=''${CONFORMANCE_TEST_SUITE:-ltp}"
              --kcmd-args="CONFORMANCE_TEST_WORKDIR=''${CONFORMANCE_TEST_WORKDIR:-/tmp}"
              --kcmd-args="EXTRA_BLOCKLISTS=''${EXTRA_BLOCKLISTS:-}"
              --init-args="/opt/run_conformance_test.sh"
            )
            if [ "''${CONFORMANCE_TEST_SUITE:-ltp}" = "xfstests" ]; then
              EXTRA_OSDK_ARGS+=(
                --kcmd-args="XFSTESTS_RUNLIST=''${XFSTESTS_RUNLIST:-/opt/xfstests/short.list}"
                --kcmd-args="XFSTESTS_TEST_DEV=''${XFSTESTS_TEST_DEV:-/dev/vdc}"
                --kcmd-args="XFSTESTS_SCRATCH_DEV=''${XFSTESTS_SCRATCH_DEV:-/dev/vdd}"
              )
            fi
            ;;
          regression)
            export ENABLE_REGRESSION_TEST=true
            EXTRA_OSDK_ARGS+=(
              --kcmd-args="INTEL_TDX=''${INTEL_TDX:-0}"
              --init-args="/test/run_regression_test.sh"
            )
            ;;
          boot)
            EXTRA_OSDK_ARGS+=(--init-args="/test/boot_hello.sh")
            ;;
          vsock)
            export ENABLE_REGRESSION_TEST=true
            export VSOCK=on
            EXTRA_OSDK_ARGS+=(--init-args="/test/run_vsock_test.sh")
            ;;
          none | "")
            ;;
          *)
            echo "Error: unsupported AUTO_TEST=''${AUTO_TEST}." >&2
            exit 1
            ;;
        esac
      '';

      buildArgs = ''
        --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}" \
        --kcmd-args="console=''${CONSOLE:-hvc0}" \
        --boot-method="''${BOOT_METHOD:-grub-rescue-iso}" \
        --grub-boot-protocol="''${BOOT_PROTOCOL:-multiboot2}" \
        --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue" \
        --initramfs="''${OSDK_INITRAMFS_PATH:-$INITRAMFS_BUILD_DIR/initramfs.cpio.gz}" \
        "$KVM_ARG"
      '';

      ensureInitramfs = ''
        BUILD_DIR="$INITRAMFS_BUILD_DIR"
        TARGET="''${TARGET_ARCH:-x86_64}"
        SMP_VALUE="''${SMP:-1}"
        mkdir -p "$BUILD_DIR"

        if [ "''${INITRAMFS_SKIP_GZIP:-0}" = "1" ]; then
          INITRAMFS_IMAGE="$BUILD_DIR/initramfs.cpio"
          INITRAMFS_COMPRESSED=false
        else
          INITRAMFS_IMAGE="$BUILD_DIR/initramfs.cpio.gz"
          INITRAMFS_COMPRESSED=true
        fi
        export OSDK_INITRAMFS_PATH="$INITRAMFS_IMAGE"

        ENABLE_BENCHMARK_TEST=false
        if [ "''${BENCHMARK:-none}" != "none" ]; then
          ENABLE_BENCHMARK_TEST=true
        fi

        if [ "$TARGET" = "loongarch64" ]; then
          touch "$INITRAMFS_IMAGE"
        else
          nix-build "$ASTERINAS_DIR/test/initramfs/nix" \
            --argstr target "$TARGET" \
            --arg enableBenchmarkTest "$ENABLE_BENCHMARK_TEST" \
            --arg enableConformanceTest "''${ENABLE_CONFORMANCE_TEST:-false}" \
            --arg enableRegressionTest "''${ENABLE_REGRESSION_TEST:-false}" \
            --argstr conformanceTestSuite "''${CONFORMANCE_TEST_SUITE:-ltp}" \
            --argstr conformanceTestWorkDir "''${CONFORMANCE_TEST_WORKDIR:-/tmp}" \
            --argstr regressionTestPlatform "''${REGRESSION_TEST_PLATFORM:-asterinas}" \
            --argstr dnsServer "''${DNS_SERVER:-8.8.8.8}" \
            --arg initramfsCompressed "$INITRAMFS_COMPRESSED" \
            --arg smp "$SMP_VALUE" \
            --out-link "$INITRAMFS_IMAGE" \
            -A initramfs-image
        fi

        if [ ! -e "$BUILD_DIR/ext2.img" ]; then
          truncate -s 2G "$BUILD_DIR/ext2.img"
          mke2fs -F "$BUILD_DIR/ext2.img" >/dev/null
        fi

        if [ ! -e "$BUILD_DIR/exfat.img" ]; then
          truncate -s 512M "$BUILD_DIR/exfat.img"
          mkfs.exfat "$BUILD_DIR/exfat.img" >/dev/null
        fi

        if [ ! -e "$BUILD_DIR/nvme0n1.img" ]; then
          truncate -s 256M "$BUILD_DIR/nvme0n1.img"
          mke2fs -t ext2 -F "$BUILD_DIR/nvme0n1.img" >/dev/null
        fi

        if [ "''${ENABLE_CONFORMANCE_TEST:-false}" = "true" ] && [ "''${CONFORMANCE_TEST_SUITE:-ltp}" = "xfstests" ]; then
          if [ ! -e "$BUILD_DIR/xfstests_test.img" ]; then
            truncate -s "''${XFSTESTS_DISK_SIZE:-12G}" "$BUILD_DIR/xfstests_test.img"
            mkfs.ext2 -F "$BUILD_DIR/xfstests_test.img" >/dev/null
          fi

          if [ ! -e "$BUILD_DIR/xfstests_scratch.img" ]; then
            truncate -s "''${XFSTESTS_DISK_SIZE:-12G}" "$BUILD_DIR/xfstests_scratch.img"
            mkfs.ext2 -F "$BUILD_DIR/xfstests_scratch.img" >/dev/null
          fi
        fi
      '';
    in {
      _module.args.pkgs = pkgs;

      formatter = pkgs.nixfmt-classic;

      packages = {
        inherit cargoOsdk;
        default = cargoOsdk;
        initramfs-x86_64 = (initramfsPackagesFor "x86_64").initramfs-image;
        initramfs-riscv64 = (initramfsPackagesFor "riscv64").initramfs-image;
      };

      devShells.default = pkgs.mkShell {
        name = "asterinas-dev";
        packages = hostTools;
        shellHook = ''
          export NIX_PATH="nixpkgs=${inputs.nixpkgs}"
          export OSDK_TARGET_ARCH="''${TARGET_ARCH:-x86_64}"
          export OSDK_LOCAL_DEV_ROOT="''${OSDK_LOCAL_DEV_ROOT:-$PWD}"
          export VDSO_LIBRARY_DIR="''${VDSO_LIBRARY_DIR:-${inputs.linux-vdso}}"
          export OVMF_CODE="''${OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF.fd}"
          export OVMF_VARS="''${OVMF_VARS:-${pkgs.OVMF.fd}/FV/OVMF_VARS.fd}"
          export MICROVM_OVMF="''${MICROVM_OVMF:-$OVMF_CODE}"
          echo "Asterinas dev shell loaded."
          echo "  Rust: $(rustc --version)"
          echo "  cargo-osdk: $(cargo osdk --version)"
        '';
      };

      checks = {
        flake-format = pkgs.runCommand "asterinas-flake-format" {
          nativeBuildInputs = [ pkgs.nixfmt-classic ];
        } ''
          nixfmt --check ${../flake.nix} ${./flake-module.nix}
          touch $out
        '';
      };

      apps = let
        apps = {
          kernel = mkApp "asterinas-kernel"
            "Build the Asterinas kernel with cargo-osdk." ''
              ${appPrelude}
              ${configureAutoTest}
              ${ensureInitramfs}
              ${kvmFlag}
              cd "$ASTERINAS_DIR/kernel"
              cargo osdk build ${buildArgs} "''${EXTRA_OSDK_ARGS[@]}"
            '';

          "run-kernel" = mkApp "asterinas-run-kernel"
            "Build and run the Asterinas kernel in QEMU." ''
              ${appPrelude}
              ${configureAutoTest}
              ${ensureInitramfs}
              ${kvmFlag}
              cd "$ASTERINAS_DIR/kernel"
              cargo osdk run ${buildArgs} "''${EXTRA_OSDK_ARGS[@]}"
            '';

          iso =
            mkApp "asterinas-iso" "Build the Asterinas NixOS installer ISO." ''
              ${appPrelude}
              ${ensureInitramfs}
              cd "$ASTERINAS_DIR/kernel"
              KVM_ARG=""
              cargo osdk build \
                --release \
                --boot-method="grub-rescue-iso" \
                --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue" \
                --grub-boot-protocol="linux" \
                --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}" \
                --kcmd-args="console=''${CONSOLE:-hvc0}" \
                --initramfs="$OSDK_INITRAMFS_PATH"
              cd "$ASTERINAS_DIR"
              NIX_SYSTEM="$(target_nix_system "''${TARGET_ARCH:-x86_64}")"
              mkdir -p target/nixos
              nix-build distro/iso_image \
                --argstr target_platform "$NIX_SYSTEM" \
                --arg autoInstall "''${AUTO_INSTALL:-true}" \
                --argstr config-file-name "''${CONFIG_FILE_NAME:-configuration.nix}" \
                --argstr extra-substituters "''${RELEASE_SUBSTITUTER:-} ''${DEV_SUBSTITUTER:-}" \
                --argstr extra-trusted-public-keys "''${RELEASE_TRUSTED_PUBLIC_KEY:-} ''${DEV_TRUSTED_PUBLIC_KEY:-}" \
                --argstr version "$(cat VERSION)" \
                --out-link target/nixos/iso_image
            '';

          "run-iso" = mkApp "asterinas-run-iso"
            "Run the Asterinas NixOS installer ISO in QEMU." ''
              ${appPrelude}
              export OVMF="''${OVMF:-on}"
              export ENABLE_KVM="''${ENABLE_KVM:-1}"
              cd "$ASTERINAS_DIR"
              ./tools/nixos/run.sh iso
            '';

          "install-nixos" = mkApp "asterinas-install-nixos"
            "Install Asterinas NixOS into a local disk image." ''
              ${appPrelude}
              ${ensureInitramfs}
              cd "$ASTERINAS_DIR/kernel"
              cargo osdk build \
                --release \
                --boot-method="grub-rescue-iso" \
                --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue" \
                --grub-boot-protocol="linux" \
                --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}" \
                --kcmd-args="console=''${CONSOLE:-hvc0}" \
                --initramfs="$OSDK_INITRAMFS_PATH"
              cd "$ASTERINAS_DIR"
              NIX_SYSTEM="$(target_nix_system "''${TARGET_ARCH:-x86_64}")"
              pushd distro >/dev/null
              nix-build aster_nixos_installer/default.nix \
                --argstr target_platform "$NIX_SYSTEM" \
                --argstr disable-systemd "''${NIXOS_DISABLE_SYSTEMD:-false}" \
                --argstr stage-2-hook "''${NIXOS_STAGE_2_INIT:-/bin/sh -l}" \
                --argstr log-level "''${LOG_LEVEL:-error}" \
                --argstr console "''${CONSOLE:-hvc0}" \
                --argstr extra-substituters "''${RELEASE_SUBSTITUTER:-} ''${DEV_SUBSTITUTER:-}" \
                --argstr extra-trusted-public-keys "''${RELEASE_TRUSTED_PUBLIC_KEY:-} ''${DEV_TRUSTED_PUBLIC_KEY:-}"
              popd >/dev/null
              mkdir -p target/nixos
              DISK_IMAGE="target/nixos/asterinas.img"
              DISK_SIZE_MB="''${NIXOS_DISK_SIZE_IN_MB:-8192}"
              CONFIG_PATH="distro/etc_nixos/''${CONFIG_FILE_NAME:-configuration.nix}"
              if [ ! -e "$DISK_IMAGE" ]; then
                fallocate -l "$DISK_SIZE_MB"M "$DISK_IMAGE"
              fi
              DISK="$(losetup -fP --show "$DISK_IMAGE")"
              trap 'losetup -d "$DISK" 2>/dev/null || true' EXIT INT TERM ERR
              ./distro/result/bin/aster-nixos-install --config "$CONFIG_PATH" --disk "$DISK"
            '';

          "run-nixos" = mkApp "asterinas-run-nixos"
            "Run an Asterinas NixOS disk image in QEMU." ''
              ${appPrelude}
              export OVMF="''${OVMF:-on}"
              export ENABLE_KVM="''${ENABLE_KVM:-1}"
              cd "$ASTERINAS_DIR"
              ./tools/nixos/run.sh nixos
            '';

          test = mkApp "asterinas-test"
            "Run user-mode Rust tests for non-default workspace packages." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              NON_DEFAULT="$(./tools/print_workspace_members.sh --non-default-ones --package-names 2>/dev/null || true)"
              TEST_PKGS="$(printf '%s\n' "$NON_DEFAULT" | tr ' ' '\n' | grep -v '^linux-bzimage-setup$' || true)"
              if [ -n "$TEST_PKGS" ]; then
                PKG_ARGS="$(printf '%s\n' "$TEST_PKGS" | sed 's/^/-p /' | tr '\n' ' ')"
                cargo test $PKG_ARGS
              fi
            '';

          ktest = mkApp "asterinas-ktest"
            "Run kernel-mode unit tests through cargo-osdk." ''
              ${appPrelude}
              ${ensureInitramfs}
              ${kvmFlag}
              cd "$ASTERINAS_DIR"
              CONSOLE="''${CONSOLE:-ttyS0}"
              cargo osdk test \
                --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}" \
                --kcmd-args="console=$CONSOLE" \
                --boot-method="''${BOOT_METHOD:-grub-rescue-iso}" \
                --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue" \
                --grub-boot-protocol="''${BOOT_PROTOCOL:-multiboot2}" \
                --initramfs="$OSDK_INITRAMFS_PATH" \
                "$KVM_ARG"
            '';
        };
      in apps // {
        run_kernel = apps."run-kernel";
        run_iso = apps."run-iso";
        nixos = apps."install-nixos";
        run_nixos = apps."run-nixos";
      };
    };
}
