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
        cachix
        clang-tools
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
        mdbook
        mdbook-mermaid
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
        export NIX_RUN_DIR="''${NIX_RUN_DIR:-$ASTERINAS_DIR/.nix-run}"
        export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$NIX_RUN_DIR/cargo-target}"
        export INITRAMFS_BUILD_DIR="''${INITRAMFS_BUILD_DIR:-$NIX_RUN_DIR/initramfs}"
        export NIXOS_DIR="''${NIXOS_DIR:-$NIX_RUN_DIR/nixos}"
        export OVMF_CODE="''${OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF.fd}"
        export OVMF_VARS="''${OVMF_VARS:-$NIX_RUN_DIR/OVMF_VARS.fd}"
        export MICROVM_OVMF="''${MICROVM_OVMF:-$OVMF_CODE}"

        if [ ! -e "$OVMF_VARS" ]; then
          mkdir -p "$(dirname "$OVMF_VARS")"
          cp "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd" "$OVMF_VARS"
          chmod u+w "$OVMF_VARS"
        fi

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

      configureOsdkArgs = ''
        OSDK_COMMON_ARGS=()
        OSDK_BUILD_ARGS=(
          --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}"
          --kcmd-args="console=''${CONSOLE:-hvc0}"
        )
        OSDK_TEST_ARGS=(
          --kcmd-args="ostd.log_level=''${LOG_LEVEL:-error}"
          --kcmd-args="console=''${CONSOLE:-ttyS0}"
        )

        TARGET="''${TARGET_ARCH:-x86_64}"
        BOOT_METHOD_VALUE="''${BOOT_METHOD:-grub-rescue-iso}"
        BOOT_PROTOCOL_VALUE="''${BOOT_PROTOCOL:-multiboot2}"
        SCHEME_VALUE="''${SCHEME:-}"

        if [ "''${RELEASE_LTO:-0}" = "1" ]; then
          OSDK_COMMON_ARGS+=(--profile release-lto)
          export OSTD_TASK_STACK_SIZE_IN_PAGES="''${OSTD_TASK_STACK_SIZE_IN_PAGES:-8}"
        elif [ "''${RELEASE:-0}" = "1" ]; then
          OSDK_COMMON_ARGS+=(--release)
          if [ "$TARGET" = "riscv64" ]; then
            export OSTD_TASK_STACK_SIZE_IN_PAGES="''${OSTD_TASK_STACK_SIZE_IN_PAGES:-16}"
          else
            export OSTD_TASK_STACK_SIZE_IN_PAGES="''${OSTD_TASK_STACK_SIZE_IN_PAGES:-8}"
          fi
        else
          export OSTD_TASK_STACK_SIZE_IN_PAGES="''${OSTD_TASK_STACK_SIZE_IN_PAGES:-64}"
        fi

        if [ "''${BENCHMARK:-none}" != "none" ]; then
          OSDK_BUILD_ARGS+=(--init-args="/benchmark/common/bench_runner.sh ''${BENCHMARK} asterinas")
        fi

        if [ "''${INTEL_TDX:-0}" = "1" ]; then
          BOOT_PROTOCOL_VALUE="linux-efi-handover64"
          OSDK_COMMON_ARGS+=(--scheme tdx)
        else
          if [ "$BOOT_PROTOCOL_VALUE" = "multiboot" ]; then
            BOOT_METHOD_VALUE="qemu-direct"
          fi
          if [ "$SCHEME_VALUE" = "microvm" ]; then
            BOOT_METHOD_VALUE="qemu-direct"
          fi

          if [ -z "$SCHEME_VALUE" ]; then
            case "$TARGET" in
              riscv64) SCHEME_VALUE="riscv" ;;
              loongarch64) SCHEME_VALUE="loongarch" ;;
            esac
          fi

          if [ -n "$SCHEME_VALUE" ]; then
            OSDK_COMMON_ARGS+=(--scheme "$SCHEME_VALUE")
          else
            OSDK_COMMON_ARGS+=(--boot-method="$BOOT_METHOD_VALUE")
          fi
        fi

        if [ "''${COVERAGE:-0}" = "1" ]; then
          OSDK_COMMON_ARGS+=(--coverage)
        fi
        if [ -n "''${FEATURES:-}" ]; then
          OSDK_COMMON_ARGS+=(--features="''${FEATURES}")
        fi
        if [ "''${NO_DEFAULT_FEATURES:-0}" = "1" ]; then
          OSDK_COMMON_ARGS+=(--no-default-features)
        fi

        case "$BOOT_PROTOCOL_VALUE" in
          linux-efi-handover64)
            OSDK_COMMON_ARGS+=(
              --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue"
              --grub-boot-protocol="linux"
            )
            ;;
          linux-efi-pe64)
            OSDK_COMMON_ARGS+=(--grub-boot-protocol="linux")
            ;;
          linux-legacy32)
            OSDK_COMMON_ARGS+=(
              --linux-x86-legacy-boot
              --grub-boot-protocol="linux"
              --strip-elf
            )
            ;;
          *)
            OSDK_COMMON_ARGS+=(--grub-boot-protocol="$BOOT_PROTOCOL_VALUE")
            ;;
        esac

        if [ "''${ENABLE_KVM:-1}" = "1" ] && [ "$TARGET" = "x86_64" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
          OSDK_COMMON_ARGS+=(--qemu-args="-accel kvm")
        fi

        OSDK_COMMON_ARGS+=(
          --grub-mkrescue="${pkgs.grub2}/bin/grub-mkrescue"
          --initramfs="''${OSDK_INITRAMFS_PATH:-$INITRAMFS_BUILD_DIR/initramfs.cpio.gz}"
        )

        OSDK_BUILD_ARGS+=("''${OSDK_COMMON_ARGS[@]}")
        OSDK_TEST_ARGS+=("''${OSDK_COMMON_ARGS[@]}")
      '';

      workspaceLintCheck = ''
        WORKSPACE_MEMBER_DIRS="$("$ASTERINAS_DIR/tools/print_workspace_members.sh")"
        for member_dir in $WORKSPACE_MEMBER_DIRS; do
          if [ "$(tail -2 "$member_dir/Cargo.toml")" != "[lints]
        workspace = true" ]; then
            echo "Error: Workspace lints in $member_dir are not enabled." >&2
            exit 1
          fi
        done
      '';

      checkCAndNixFormatting = ''
        find "$ASTERINAS_DIR/test/initramfs/src/regression" \
          -type f \( -name "*.c" -o -name "*.h" \) \
          -print0 | xargs -0 clang-format --dry-run --Werror
        nixfmt --check "$ASTERINAS_DIR/test/initramfs/nix"
        nixfmt --check "$ASTERINAS_DIR/distro"
      '';

      formatCAndNix = ''
        find "$ASTERINAS_DIR/test/initramfs/src/regression" \
          -type f \( -name "*.c" -o -name "*.h" \) \
          -print0 | xargs -0 clang-format -i
        nixfmt "$ASTERINAS_DIR/test/initramfs/nix"
        nixfmt "$ASTERINAS_DIR/distro"
      '';

      prepareNixosConfig = ''
        prepare_nixos_config() {
          local base_config="$ASTERINAS_DIR/distro/etc_nixos/''${CONFIG_FILE_NAME:-configuration.nix}"

          if [ -z "''${NIXOS_TEST_SUITE:-}" ]; then
            export NIXOS_CONFIG_PATH="$base_config"
            return
          fi

          local test_dir="$ASTERINAS_DIR/test/nixos/tests/$NIXOS_TEST_SUITE"
          local extra_config="$test_dir/extra_config.nix"
          local test_config="$NIXOS_DIR/etc_nixos/$NIXOS_TEST_SUITE-configuration.nix"

          if [ ! -d "$test_dir" ]; then
            echo "Error: NixOS test suite '$NIXOS_TEST_SUITE' does not exist." >&2
            exit 1
          fi

          mkdir -p "$(dirname "$test_config")"
          if [ -f "$extra_config" ]; then
            "$ASTERINAS_DIR/test/nixos/common/merge_nixos_config.sh" \
              "$base_config" \
              "$extra_config" \
              "$test_config"
          else
            cp "$base_config" "$test_config"
          fi

          export NIXOS_CONFIG_PATH="$test_config"
        }
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
          export NIX_RUN_DIR="''${NIX_RUN_DIR:-$PWD/.nix-run}"
          export OVMF_CODE="''${OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF.fd}"
          export OVMF_VARS="''${OVMF_VARS:-$NIX_RUN_DIR/OVMF_VARS.fd}"
          export MICROVM_OVMF="''${MICROVM_OVMF:-$OVMF_CODE}"
          if [ ! -e "$OVMF_VARS" ]; then
            mkdir -p "$(dirname "$OVMF_VARS")"
            cp "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd" "$OVMF_VARS"
            chmod u+w "$OVMF_VARS"
          fi
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
              ${configureOsdkArgs}
              cd "$ASTERINAS_DIR/kernel"
              cargo osdk build "''${OSDK_BUILD_ARGS[@]}" "''${EXTRA_OSDK_ARGS[@]}"
            '';

          "run-kernel" = mkApp "asterinas-run-kernel"
            "Build and run the Asterinas kernel in QEMU." ''
              ${appPrelude}
              ${configureAutoTest}
              ${ensureInitramfs}
              ${configureOsdkArgs}
              cd "$ASTERINAS_DIR/kernel"
              cargo osdk run "''${OSDK_BUILD_ARGS[@]}" "''${EXTRA_OSDK_ARGS[@]}"
            '';

          iso =
            mkApp "asterinas-iso" "Build the Asterinas NixOS installer ISO." ''
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
              ${prepareNixosConfig}
              prepare_nixos_config
              NIX_SYSTEM="$(target_nix_system "''${TARGET_ARCH:-x86_64}")"
              mkdir -p "$NIXOS_DIR"
              nix-build distro/iso_image \
                --argstr target_platform "$NIX_SYSTEM" \
                --arg autoInstall "''${AUTO_INSTALL:-true}" \
                --argstr config-file-name "''${CONFIG_FILE_NAME:-configuration.nix}" \
                --argstr config-path "$NIXOS_CONFIG_PATH" \
                --argstr extra-substituters "''${RELEASE_SUBSTITUTER:-} ''${DEV_SUBSTITUTER:-}" \
                --argstr extra-trusted-public-keys "''${RELEASE_TRUSTED_PUBLIC_KEY:-} ''${DEV_TRUSTED_PUBLIC_KEY:-}" \
                --argstr version "$(cat VERSION)" \
                --out-link "$NIXOS_DIR/iso_image"
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
              ${prepareNixosConfig}
              prepare_nixos_config
              NIX_SYSTEM="$(target_nix_system "''${TARGET_ARCH:-x86_64}")"
              mkdir -p "$NIXOS_DIR"
              nix-build distro/aster_nixos_installer/default.nix \
                --argstr target_platform "$NIX_SYSTEM" \
                --argstr disable-systemd "''${NIXOS_DISABLE_SYSTEMD:-false}" \
                --argstr stage-2-hook "''${NIXOS_STAGE_2_INIT:-/bin/sh -l}" \
                --argstr log-level "''${LOG_LEVEL:-error}" \
                --argstr console "''${CONSOLE:-hvc0}" \
                --argstr config-path "$NIXOS_CONFIG_PATH" \
                --argstr extra-substituters "''${RELEASE_SUBSTITUTER:-} ''${DEV_SUBSTITUTER:-}" \
                --argstr extra-trusted-public-keys "''${RELEASE_TRUSTED_PUBLIC_KEY:-} ''${DEV_TRUSTED_PUBLIC_KEY:-}" \
                --out-link "$NIXOS_DIR/aster-nixos-installer"
              DISK_IMAGE="$NIXOS_DIR/asterinas.img"
              DISK_SIZE_MB="''${NIXOS_DISK_SIZE_IN_MB:-8192}"
              if [ ! -e "$DISK_IMAGE" ]; then
                fallocate -l "$DISK_SIZE_MB"M "$DISK_IMAGE"
              fi
              DISK="$(losetup -fP --show "$DISK_IMAGE")"
              trap 'losetup -d "$DISK" 2>/dev/null || true' EXIT INT TERM ERR
              "$NIXOS_DIR/aster-nixos-installer/bin/aster-nixos-install" --config "$NIXOS_CONFIG_PATH" --disk "$DISK"
            '';

          "run-nixos" = mkApp "asterinas-run-nixos"
            "Run an Asterinas NixOS disk image in QEMU." ''
              ${appPrelude}
              export OVMF="''${OVMF:-on}"
              export ENABLE_KVM="''${ENABLE_KVM:-1}"
              cd "$ASTERINAS_DIR"
              if [ -n "''${NIXOS_TEST_SUITE:-}" ]; then
                TEST_DIR="$ASTERINAS_DIR/test/nixos/tests/$NIXOS_TEST_SUITE"
                if [ ! -d "$TEST_DIR" ]; then
                  echo "Error: NixOS test suite '$NIXOS_TEST_SUITE' does not exist." >&2
                  exit 1
                fi
                TEST_CASE_ARGS=()
                if [ -n "''${NIXOS_TEST_CASE:-}" ]; then
                  TEST_CASE_ARGS+=(--test "$NIXOS_TEST_CASE")
                fi
                QEMU_CMD="bash $ASTERINAS_DIR/tools/nixos/run.sh nixos"
                (
                  cd "$TEST_DIR"
                  cargo run -- --qemu-cmd "$QEMU_CMD" "''${TEST_CASE_ARGS[@]}"
                )
              else
                ./tools/nixos/run.sh nixos
              fi
            '';

          test = mkApp "asterinas-test"
            "Run user-mode Rust tests for non-default workspace packages." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              NON_DEFAULT="$(./tools/print_workspace_members.sh --non-default-ones --package-names 2>/dev/null || true)"
              TEST_PKGS="$(printf '%s\n' "$NON_DEFAULT" | tr ' ' '\n' | grep -v '^linux-bzimage-setup$' || true)"
              if [ -n "$TEST_PKGS" ]; then
                PKG_ARGS=()
                while IFS= read -r package; do
                  PKG_ARGS+=(-p "$package")
                done <<< "$TEST_PKGS"
                cargo test "''${PKG_ARGS[@]}"
              fi
            '';

          check = mkApp "asterinas-check"
            "Run the development checks previously covered by make check." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              ./tools/format_all.sh --check
              ${workspaceLintCheck}
              ./tools/clippy_check.sh workspace
              ${checkCAndNixFormatting}
              (
                cd "$ASTERINAS_DIR/test/nixos"
                cargo fmt --check
                cargo clippy -- -D warnings
              )
              typos "$ASTERINAS_DIR"
            '';

          format = mkApp "asterinas-format"
            "Format Rust, C, and Nix files used by the workspace." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              ./tools/format_all.sh
              ${formatCAndNix}
              (
                cd "$ASTERINAS_DIR/test/nixos"
                cargo fmt
                nixfmt .
              )
            '';

          docs = mkApp "asterinas-docs"
            "Build Rust documentation for the workspace." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              DEFAULT_PACKAGES="$("$ASTERINAS_DIR/tools/print_workspace_members.sh" --default-ones --package-names)"
              DEFAULT_DOC_PACKAGES="$(printf '%s\n' "$DEFAULT_PACKAGES" | tr ' ' '\n' | grep -v '^aster-kernel$' || true)"
              NON_DEFAULT_PACKAGES="$("$ASTERINAS_DIR/tools/print_workspace_members.sh" --non-default-ones --package-names)"
              NON_DEFAULT_DOC_PACKAGES="$(printf '%s\n' "$NON_DEFAULT_PACKAGES" | tr ' ' '\n' | grep -v '^linux-bzimage-setup$' || true)"

              if [ -n "$DEFAULT_DOC_PACKAGES" ]; then
                DEFAULT_DOC_ARGS=()
                while IFS= read -r package; do
                  DEFAULT_DOC_ARGS+=(-p "$package")
                done <<< "$DEFAULT_DOC_PACKAGES"
                RUSTDOCFLAGS="-Dwarnings" cargo osdk doc "''${DEFAULT_DOC_ARGS[@]}" --no-deps
              fi

              if [ -n "$NON_DEFAULT_DOC_PACKAGES" ]; then
                NON_DEFAULT_DOC_ARGS=()
                while IFS= read -r package; do
                  NON_DEFAULT_DOC_ARGS+=(-p "$package")
                done <<< "$NON_DEFAULT_DOC_PACKAGES"
                RUSTDOCFLAGS="-Dwarnings" cargo doc "''${NON_DEFAULT_DOC_ARGS[@]}" --no-deps
              fi

              RUSTDOCFLAGS="-Dwarnings --document-private-items -Arustdoc::private_intra_doc_links" \
                cargo osdk doc -p aster-kernel --no-deps

              if [ "''${TARGET_ARCH:-x86_64}" = "x86_64" ]; then
                (
                  cd "$ASTERINAS_DIR/ostd/libs/linux-bzimage/setup"
                  RUSTDOCFLAGS="-Dwarnings" cargo osdk doc --no-deps
                )
              fi
            '';

          book = mkApp "asterinas-book"
            "Build the Asterinas mdBook documentation." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR/book"
              if [ ! -e mermaid.min.js ] || [ ! -e mermaid-init.js ]; then
                mdbook-mermaid install .
              fi
              mdbook build
            '';

          "check-osdk" = mkApp "asterinas-check-osdk"
            "Run clippy for the cargo-osdk crate." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              ./tools/clippy_check.sh osdk
            '';

          "test-osdk" = mkApp "asterinas-test-osdk"
            "Build and test the cargo-osdk crate." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR/osdk"
              OSDK_LOCAL_DEV=1 cargo build
              OSDK_LOCAL_DEV=1 cargo test -- --test-threads=1
            '';

          "validate-scml" = mkApp "asterinas-validate-scml"
            "Validate SCML files with sctrace." ''
              ${appPrelude}
              cd "$ASTERINAS_DIR"
              mapfile -t ASTER_SCML < <(find ./book/src/kernel/linux-compatibility/ -name "*.scml")
              ./tools/sctrace.sh "''${ASTER_SCML[@]}" -- echo "Asterinas"
            '';

          ktest = mkApp "asterinas-ktest"
            "Run kernel-mode unit tests through cargo-osdk." ''
              ${appPrelude}
              ${ensureInitramfs}
              ${configureOsdkArgs}
              cd "$ASTERINAS_DIR"
              cargo osdk test "''${OSDK_TEST_ARGS[@]}"
            '';
        };
      in apps // {
        run_kernel = apps."run-kernel";
        run_iso = apps."run-iso";
        nixos = apps."install-nixos";
        run_nixos = apps."run-nixos";
        check_osdk = apps."check-osdk";
        test_osdk = apps."test-osdk";
        validate_scml = apps."validate-scml";
      };
    };
}
