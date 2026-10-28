{
  # The development shell: the pinned compiler, the system libraries gpui
  # builds and dlopens against, and the tools the rig, the supply-chain
  # job and the packaging checks call. It builds nothing itself — Strop is
  # still `cargo build`, so a Nix user and a rustup user compile the same
  # tree with the same compiler. Linux only: the macOS and Windows builds
  # are CI's (docs/releasing.md), and nothing here would help them.
  description = "Strop development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib;
          rustBin = rust-overlay.lib.mkRustBin { } pkgs;

          # rust-toolchain.toml stays the one place the version lives (CI and
          # rustup read it too); the shell only adds what an editor wants on
          # top of the components it names. The minimal profile leaves
          # rustfmt out on purpose: the tree is hand-formatted (AGENTS.md),
          # and a formatter on PATH is one format-on-save away from
          # reflowing it.
          pin = (lib.importTOML ./rust-toolchain.toml).toolchain;
          rustToolchain = rustBin.fromRustupToolchain (
            pin
            // {
              profile = "minimal";
              components = (pin.components or [ ]) ++ [
                "rust-src"
                "rust-analyzer"
              ];
            }
          );

          # The attribution check diffs cargo-about's output byte-for-byte
          # against assets/third-party-licenses.txt, so it must be the exact
          # version ci.yml installs (0.9.1), not whatever nixpkgs carries.
          # Bump the two together.
          cargo-about = pkgs.cargo-about.overrideAttrs (
            final: old: {
              version = "0.9.1";
              src = pkgs.fetchFromGitHub {
                owner = "EmbarkStudios";
                repo = "cargo-about";
                tag = final.version;
                hash = "sha256-mZyfECnlpYom/XI445DOeUAthqK3HKC+QkkK+5gf0/E=";
              };
              cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
                inherit (final) src;
                name = "${final.pname}-${final.version}";
                hash = "sha256-//t3ASNljC4rosk5oOmcJy8PZKRYjlQ0euzzAmfiSPQ=";
              };
            }
          );

          # gpui dlopens these at run time rather than linking them, so being
          # in buildInputs is not enough for `cargo run` or the tests: the
          # loader has to find them on LD_LIBRARY_PATH.
          runtimeLibs = with pkgs; [
            vulkan-loader
            libGL
            wayland
            libxkbcommon
            libx11
            libxcursor
            libxi
            libxrandr
            libxcb
          ];
        in
        {
          default = pkgs.mkShell {
            name = "strop";

            nativeBuildInputs = with pkgs; [
              rustToolchain
              pkg-config
            ];

            # The Zed Linux build requirements, as ci.yml's apt list.
            buildInputs =
              runtimeLibs
              ++ (with pkgs; [
                alsa-lib
                fontconfig
                freetype
                libgbm
                libxext
                openssl
                zlib
              ]);

            packages = with pkgs; [
              # Supply chain — ci.yml's `deny` job.
              cargo-deny
              cargo-about
              # The visual rig: headless sway, screenshots, pixel diffs
              # (scripts/wrun.sh, wshot.sh, rig-check.sh).
              sway
              grim
              imagemagick
              jq
              # Packaging checks — ci.yml's `packaging` job.
              appstream
              desktop-file-utils
              (python3.withPackages (ps: [ ps.pyyaml ]))
              # Release signing (script/release-sign.sh).
              minisign
            ];

            LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;

            # `nix develop` replaces the variables the shell's own build
            # sets and passes every other one through from the calling
            # environment. A buildFHSEnv's /etc/profile (the Claude
            # desktop app runs inside one) exports
            # NIX_CFLAGS_LINK="-L/usr/lib -L/usr/lib32", which this shell
            # never sets, so the cc wrapper would hand that to every link:
            # libc and libm resolve from the FHS glibc instead of the
            # wrapper's, the binary takes symbol versions its own loader
            # lacks, and it fails at start-up once the two glibcs part.
            # Owning the variable, empty, keeps the link inside the shell.
            NIX_CFLAGS_LINK = "";
          };
        }
      );
    };
}
