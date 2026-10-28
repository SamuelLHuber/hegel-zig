{ pkgs, lib, ... }:

let
  libhegelVersion = "0.48.0";
  # Same artifacts and SHA-256s as build.zig.
  libhegelArtifacts = {
    x86_64-linux = {
      name = "libhegel-linux-amd64.a";
      sha256 = "9123fd093e9994e0fb5b5151e5429b27991180a962352024e5dd588c1ec48dbd";
    };
    aarch64-linux = {
      name = "libhegel-linux-arm64.a";
      sha256 = "622a2fce27cea68ea22a742a9b4a1361032d0e725f40773f4725422c0f55a56b";
    };
    aarch64-darwin = {
      name = "libhegel-darwin-arm64.a";
      sha256 = "c8d3478e5eb4e21f5a14770b42842922c2a14d58736782448236748dc3a497e4";
    };
  };
  artifact = libhegelArtifacts.${pkgs.stdenv.hostPlatform.system} or null;
  libhegel =
    if artifact == null then
      null
    else
      pkgs.fetchurl {
        url = "https://github.com/hegeldev/hegel/releases/download/libhegel/${libhegelVersion}/${artifact.name}";
        inherit (artifact) sha256;
      };
  # Linux uses nixpkgs' Zig, which links against and runs on the Nix store's
  # glibc. On macOS, nixpkgs' zig_0_17 dies with SIGBUS compiling the tests, so
  # it is the official ziglang.org build: the same tarball and SHA-256 as
  # .github/scripts/install-zig.sh.
  zigVersion = "0.17.0";
  zigMacos = {
    triple = "aarch64-macos";
    sha256 = "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a";
  };
  zig =
    if pkgs.stdenv.hostPlatform.system == "aarch64-darwin" then
      pkgs.stdenvNoCC.mkDerivation {
        pname = "zig";
        version = zigVersion;
        src = pkgs.fetchurl {
          url = "https://ziglang.org/download/${zigVersion}/zig-${zigMacos.triple}-${zigVersion}.tar.xz";
          inherit (zigMacos) sha256;
        };
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          mkdir -p $out/bin $out/share/zig
          cp -r . $out/share/zig
          ln -s $out/share/zig/zig $out/bin/zig
        '';
      }
    else
      pkgs.zig_0_17;
  # nixpkgs' Apple SDK leaves libiconv to its own package.
  buildFlags =
    lib.optionalString (libhegel != null) "-Dlibhegel=${libhegel}"
    + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin " --search-prefix ${pkgs.libiconv}";
in
{
  # On macOS, Zig finds the SDK through `xcode-select` and `xcrun`; xcbuild
  # provides both, resolving to devenv's pinned `apple.sdk`.
  packages = [ zig ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.xcbuild ];

  env.HEGEL_ZIG_LIBHEGEL = lib.optionalString (libhegel != null) "${libhegel}";

  scripts = {
    hz-test.exec = ''zig build test ${buildFlags} --summary all "$@"'';
    hz-examples.exec = ''zig build examples ${buildFlags} --summary all "$@"'';
    hz-check.exec = ''
      set -euo pipefail
      zig fmt --check .
      for mode in Debug ReleaseSafe; do
        hz-test -Doptimize="$mode"
        hz-examples -Doptimize="$mode"
      done
    '';
  };

  # Zig skips SDK detection when NIX_CFLAGS_COMPILE or NIX_LDFLAGS is set;
  # without them it finds the pinned Apple SDK through xcrun.
  enterShell = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS
  '' + ''
    echo "hegel-zig: zig $(zig version), libhegel ${libhegelVersion} (''${HEGEL_ZIG_LIBHEGEL:-fetched by build.zig})"
    echo "  hz-test, hz-examples, hz-check (what CI runs)"
  '';

  enterTest = ''
    set -euo pipefail
    test "$(zig version)" = "${zigVersion}"
    grep -q ${zigMacos.sha256} .github/scripts/install-zig.sh
    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "xcode-select --print-path && xcrun --sdk macosx --show-sdk-path"}
    grep -q 'libhegel_version = "${libhegelVersion}"' build.zig
    ${lib.concatMapStrings (a: "grep -q ${a.sha256} build.zig\n") (lib.attrValues libhegelArtifacts)}
    hz-check
  '';
}
