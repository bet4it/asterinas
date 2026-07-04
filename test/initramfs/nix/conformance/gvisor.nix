{ buildFHSEnv, cacert, clang, fetchFromGitHub, fetchurl, git, jdk11_headless
, lib, libffi, libpcap, libseccomp, openssl, pkg-config, pkgsCross, python3
, stdenv, unzip, zip, zlib }:

let
  gccInternalVersion = lib.concatStringsSep "."
    (lib.take 3 (lib.splitVersion stdenv.cc.cc.version));
  gccPackageVersion = stdenv.cc.cc.version;
  nixSystemIncludeDirs = [
    "${stdenv.cc.libc.dev}/include"
    "${stdenv.cc.cc}/include/c++/${gccPackageVersion}"
    "${stdenv.cc.cc}/include/c++/${gccPackageVersion}/${stdenv.hostPlatform.config}"
    "${stdenv.cc.cc}/include/c++/${gccPackageVersion}/backward"
    "${stdenv.cc.cc}/lib/gcc/${stdenv.hostPlatform.config}/${gccInternalVersion}/include"
    "${stdenv.cc.cc}/lib/gcc/${stdenv.hostPlatform.config}/${gccInternalVersion}/include-fixed"
  ];

  bazelBinary = stdenv.mkDerivation {
    pname = "bazel";
    version = "8.3.1";

    src = fetchurl {
      url =
        "https://releases.bazel.build/8.3.1/release/bazel-8.3.1-linux-x86_64";
      hash = "sha256-FyR+ioQkX1nTvGM9DP4KhAmSp3YKEa8aMAEtA9oxYEw=";
    };

    dontUnpack = true;
    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"
      install -Dm755 "$src" "$out/bin/bazel"

      runHook postInstall
    '';
  };

  bazel_8_3_1 = buildFHSEnv {
    pname = "bazel";
    version = "8.3.1";
    targetPkgs = _: [
      bazelBinary
      pkgsCross.aarch64-multiplatform.stdenv.cc
      stdenv.cc
      zlib
    ];
    extraBuildCommands = ''
      for tool in ar cpp g++ gcc ld; do
        if [ -e "$out/usr/bin/$tool" ]; then
          ln -s "$tool" "$out/usr/bin/x86_64-linux-gnu-$tool"
        fi
        if [ -e "$out/usr/bin/aarch64-unknown-linux-gnu-$tool" ]; then
          ln -s "aarch64-unknown-linux-gnu-$tool" "$out/usr/bin/aarch64-linux-gnu-$tool"
        fi
      done
    '';
    runScript = "bazel";
  };

  gvisorArchive = stdenv.mkDerivation {
    pname = "gvisor-syscall-test-bins-archive";
    version = "20260622.0";

    src = fetchFromGitHub {
      owner = "google";
      repo = "gvisor";
      rev = "release-20260622.0";
      hash = "sha256-VjKn1ACNhiNsPgXEvekf54ZcsPL3Xq5Rn21rSGVTfC0=";
    };

    postPatch = ''
      python3 - <<'PY'
      from pathlib import Path

      path = Path("tools/bazeldefs/extensions/coral_crosstool.bzl")
      text = path.read_text()
      needle = (
          "        patches = [\n"
          "            \"//tools:crosstool-arm-dirs.patch\",\n"
          "            \"//tools:remove_windows_deps.patch\",\n"
          "        ],\n"
      )
      patch_cmds = (
          "        patch_cmds = [\"\"\"python3 - <<'INNER'\n"
          "from pathlib import Path\n"
          "\n"
          "configure = Path(\"configure.bzl\")\n"
          "text = configure.read_text()\n"
          "text = text.replace(\n"
          "    '    gcc_version = repository_ctx.execute',\n"
          "    '    nix_builtin_include_dirs = repository_ctx.os.environ.get(\"NIX_BAZEL_BUILTIN_INCLUDE_DIRS\", \"\")\\\\n'\n"
          "    '    nix_builtin_include_dirs = \", \".join([\\\\n'\n"
          "    '        repr(include_dir)\\\\n'\n"
          "    '        for include_dir in nix_builtin_include_dirs.split(\":\")\\\\n'\n"
          "    '        if include_dir\\\\n'\n"
          "    '    ])\\\\n\\\\n'\n"
          "    '    gcc_version = repository_ctx.execute',\n"
          ")\n"
          "text = text.replace(\n"
          "    '            \"%{additional_system_include_directories}%\": additional_include_dirs,',\n"
          "    '            \"%{additional_system_include_directories}%\": additional_include_dirs,\\\\n'\n"
          "    '            \"%{nix_builtin_include_directories}%\": nix_builtin_include_dirs,',\n"
          ")\n"
          "text = text.replace(\n"
          "    '        \"BCM2708_TOOLCHAIN_ROOT\",\\\\n',\n"
          "    '        \"BCM2708_TOOLCHAIN_ROOT\",\\\\n'\n"
          "    '        \"NIX_BAZEL_BUILTIN_INCLUDE_DIRS\",\\\\n',\n"
          ")\n"
          "configure.write_text(text)\n"
          "\n"
          "config = Path(\"cc_toolchain_config.bzl.tpl\")\n"
          "text = config.read_text()\n"
          "text = text.replace(\n"
          "    'ADDITIONAL_SYSTEM_INCLUDE_DIRECTORIES = [%{additional_system_include_directories}%]',\n"
          "    'ADDITIONAL_SYSTEM_INCLUDE_DIRECTORIES = [%{additional_system_include_directories}%]\\\\n'\n"
          "    'NIX_BUILTIN_INCLUDE_DIRECTORIES = [%{nix_builtin_include_directories}%]',\n"
          ")\n"
          "text = text.replace(\n"
          "    '                ADDITIONAL_SYSTEM_INCLUDE_DIRECTORIES +\\\\n'\n"
          "    '                CXX_BUILTIN_INCLUDE_DIRECTORIES[ctx.attr.cpu]\\\\n',\n"
          "    '                ADDITIONAL_SYSTEM_INCLUDE_DIRECTORIES +\\\\n'\n"
          "    '                CXX_BUILTIN_INCLUDE_DIRECTORIES[ctx.attr.cpu] +\\\\n'\n"
          "    '                NIX_BUILTIN_INCLUDE_DIRECTORIES\\\\n',\n"
          ")\n"
          "config.write_text(text)\n"
          "INNER\n"
          "\"\"\"],\n"
      )
      if needle not in text:
          raise SystemExit("failed to find coral crosstool patches block")
      path.write_text(text.replace(needle, needle + patch_cmds))
      PY
    '';

    nativeBuildInputs = [
      bazel_8_3_1
      cacert
      clang
      git
      jdk11_headless
      libffi
      libpcap
      libseccomp
      openssl
      pkg-config
      python3
      unzip
      zip
    ];

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR"
      export BAZELISK_HOME="$TMPDIR/bazelisk"
      export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      export NIX_BAZEL_BUILTIN_INCLUDE_DIRS="${
        lib.concatStringsSep ":" nixSystemIncludeDirs
      }"

      bazel build \
        --repo_env=GOPROXY='https://proxy.golang.org|https://goproxy.io|https://goproxy.cn|direct' \
        --test_tag_filters=native \
        //test/syscalls/linux/...

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner \
        -cf - -C bazel-bin/test/syscalls/linux . | gzip -n > "$out"

      runHook postInstall
    '';

    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    outputHash = "sha256-IxTjKhJh2FrsqqtiAyAc/hSP2WxhyhjNSAt8IRVfikA=";
  };
in stdenv.mkDerivation {
  pname = "gvisor-syscall-test-bins";
  inherit (gvisorArchive) version;

  src = gvisorArchive;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    tar -xzf "$src" -C "$out"

    runHook postInstall
  '';
}
