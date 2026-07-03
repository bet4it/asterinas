{
  description = "Asterinas OS kernel development environment";

  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/c0bebd16e69e631ac6e52d6eb439daba28ac50cd";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    linux-vdso = {
      url = "github:asterinas/linux_vdso/7489835";
      flake = false;
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      imports = [ ./nix/flake-module.nix ];
    };
}
