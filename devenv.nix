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
  libhegelFlag = lib.optionalString (libhegel != null) "-Dlibhegel=${libhegel}";
in
{
  # On macOS, Zig finds the SDK through `xcode-select` and `xcrun`; xcbuild
  # provides both, resolving to devenv's pinned `apple.sdk`.
  packages = [ pkgs.zig_0_17 ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.xcbuild ];

  env.HEGEL_ZIG_LIBHEGEL = lib.optionalString (libhegel != null) "${libhegel}";

  scripts = {
    hz-test.exec = ''zig build test ${libhegelFlag} --summary all "$@"'';
    hz-examples.exec = ''zig build examples ${libhegelFlag} --summary all "$@"'';
    hz-check.exec = ''
      set -euo pipefail
      zig fmt --check .
      for mode in Debug ReleaseSafe; do
        hz-test -Doptimize="$mode"
        hz-examples -Doptimize="$mode"
      done
    '';
  };

  # Zig skips SDK detection when NIX_CFLAGS_COMPILE is set, so frameworks
  # (CoreFoundation, Security) have to be passed the Nix way.
  enterShell = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -iframework $(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks"
  '' + ''
    echo "hegel-zig: zig $(zig version), libhegel ${libhegelVersion} (''${HEGEL_ZIG_LIBHEGEL:-fetched by build.zig})"
    echo "  hz-test, hz-examples, hz-check (what CI runs)"
  '';

  enterTest = ''
    set -euo pipefail
    test "$(zig version)" = "0.17.0"
    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "xcode-select --print-path && xcrun --sdk macosx --show-sdk-path"}
    grep -q 'libhegel_version = "${libhegelVersion}"' build.zig
    ${lib.concatMapStrings (a: "grep -q ${a.sha256} build.zig\n") (lib.attrValues libhegelArtifacts)}
    hz-check
  '';
}
