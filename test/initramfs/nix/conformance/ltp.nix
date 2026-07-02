{ stdenv, fetchFromGitHub, hostPlatform, pkgsBuildBuild, python3, }:
stdenv.mkDerivation rec {
  pname = "ltp";
  version = "20260529";
  src = fetchFromGitHub {
    owner = "linux-test-project";
    repo = "ltp";
    rev = "${version}";
    hash = "sha256-h4cIK0sDbyGiGwvba3jkJ+W28oNzvQAfGu1RbGAFljA=";
  };
  kirkSrc = fetchFromGitHub {
    owner = "linux-test-project";
    repo = "kirk";
    rev = "7d4234c4305ab8b7b4ec27e911798b5e7f65ef88";
    hash = "sha256-W/6sxdqNACs0yI+g8BLYFdqPzJXA1VHYbUN/YL7kuJE=";
  };

  # Clear `CFLAGS` and `DEBUG_CFLAGS` to prevent `-g` from being automatically added.
  CFLAGS = "";
  DEBUG_CFLAGS = "";
  dontPatchShebangs = true;
  enableParallelBuilding = true;
  nativeBuildInputs = with pkgsBuildBuild; [
    automake
    autoconf
    libtool
    gnum4
    makeWrapper
    pkg-config
  ];
  configurePhase = ''
    runHook preConfigure

    make autotools
    ./configure --host ${hostPlatform.system} --prefix=$out

    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild

    make -C testcases/kernel
    make -C testcases/lib
    make -C runtest

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    make -C testcases/kernel install
    make -C testcases/lib install
    make -C runtest install

    cp -r ${kirkSrc}/libkirk $out/libkirk
    install -m 00755 ${kirkSrc}/kirk $out/kirk
    substituteInPlace $out/kirk \
      --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'
    install -m 00444 $src/VERSION $out/Version
    install -m 00755 $src/ver_linux $out/ver_linux
    install -m 00755 $src/IDcheck.sh $out/IDcheck.sh

    runHook postInstall
  '';
}
