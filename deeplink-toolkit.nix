# Generic helpers for browser-auth deep-link (x-scheme-handler) bugs on NixOS.
#
# Two failure classes keep recurring with Electron apps from nixpkgs:
#  1. The package wraps electron with makeBinaryWrapper but passes shell
#     expressions like '${NIXOS_OZONE_WL:+...}' via --add-flags. A binary
#     wrapper cannot expand these, so the literal string becomes an argv
#     entry that corrupts/swallows the OAuth callback URL.
#     (Seen in: claude-desktop repackage 2026-07-12, nixpkgs github-desktop.)
#  2. The app itself lacks Linux code to pull the URL out of argv
#     (needs a per-app patch via the patchApp hook below).
#
# Usage from configuration.nix:
#   (pkgs.callPackage ./deeplink-toolkit.nix { }).doctor        # diagnostics CLI
#   see github-desktop-fixed.nix for fixElectronLauncher usage
{ lib, stdenv, runCommand, symlinkJoin, writeShellScriptBin }:

rec {
  # Replace a package's broken binary-wrapper launcher with a shell launcher
  # that expands Wayland/ozone flags at runtime and passes "$@" (the deep-link
  # URL) through untouched. Reuses the original package's share/ (desktop
  # files, icons), so existing x-scheme-handler registrations keep working.
  fixElectronLauncher =
    { pkg               # the broken package (used for share/ and version)
    , mainProgram       # launcher name, must match the .desktop Exec=
    , electron ? null   # MUST match the electron major the app was built for
    , appPath ? null    # e.g. "${pkg}/share/foo/resources/app"
    , exePath ? null    # alternative: app bundles its own electron binary
                        # (env-only wrapping of that binary stays in the pkg;
                        # only argv-sensitive flags belong out here)
    , patchApp ? null   # optional shell snippet; $app = writable copy of appPath
    , extraFlags ? [ ]
    }:
    assert lib.assertMsg (exePath != null || (electron != null && appPath != null))
      "fixElectronLauncher: pass either exePath or electron+appPath";
    assert lib.assertMsg (exePath == null || patchApp == null)
      "fixElectronLauncher: patchApp requires the electron+appPath form (asar-bundled apps must patch in their own derivation)";
    let
      # Symlink the app dir file-by-file so patchApp only copies what it edits.
      patchedApp =
        if patchApp == null then appPath
        else runCommand "${mainProgram}-app-patched" { } ''
          mkdir -p $out
          for f in ${appPath}/* ${appPath}/.[!.]*; do
            [ -e "$f" ] && ln -s "$f" $out/ || true
          done
          app=$out
          ${patchApp}
        '';

      execCmd =
        if exePath != null
        then exePath
        else "${electron}/bin/electron ${patchedApp}";

      launcher = writeShellScriptBin mainProgram ''
        exec -a "$0" ${execCmd} \
          ''${NIXOS_OZONE_WL:+''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}} \
          ${lib.escapeShellArgs extraFlags} "$@"
      '';

      shareOnly = runCommand "${mainProgram}-share" { } ''
        mkdir -p $out
        ln -s ${pkg}/share $out/share
      '';
    in
    symlinkJoin {
      name = "${mainProgram}-deeplink-fixed-${pkg.version or "unknown"}";
      paths = [ launcher shareOnly ];
      passthru = { inherit patchedApp; original = pkg; };
      meta = (pkg.meta or { }) // { inherit mainProgram; };
    };

  # deeplink-doctor <scheme> — checks the whole inbound chain:
  # registration -> .desktop file -> Exec %u -> launcher binary sanity.
  doctor = writeShellScriptBin "deeplink-doctor" ''
    set -u
    scheme="''${1:-}"
    if [ -z "$scheme" ]; then
      echo "usage: deeplink-doctor <scheme>   e.g.: deeplink-doctor x-github-desktop-dev-auth"
      exit 2
    fi
    scheme="''${scheme#x-scheme-handler/}"; scheme="''${scheme%%:*}"
    mt="x-scheme-handler/$scheme"
    rc=0

    echo "== $mt =="
    def="$(xdg-mime query default "$mt" 2>/dev/null || true)"
    if [ -z "$def" ]; then
      echo "FAIL: no default handler registered (browser will silently drop the redirect)"
      echo "      fix: xdg-mime default <app>.desktop $mt"
      exit 1
    fi
    echo "default handler: $def"

    f=""
    IFS=: read -ra dirs <<< "''${XDG_DATA_HOME:-$HOME/.local/share}:''${XDG_DATA_DIRS:-/usr/share}"
    for d in "''${dirs[@]}"; do
      [ -e "$d/applications/$def" ] && { f="$d/applications/$def"; break; }
    done
    if [ -z "$f" ]; then
      echo "FAIL: $def not found in XDG_DATA_DIRS — stale registration?"
      exit 1
    fi
    echo "desktop file: $f"
    grep -E '^(Exec|MimeType)=' "$f" | sed 's/^/  /'

    if ! grep -q '%[uU]' "$f"; then
      echo "WARN: Exec= has no %u/%U — the URL is never passed to the app"
      rc=1
    fi
    if ! grep -E '^MimeType=' "$f" | grep -q "$mt"; then
      echo "note: $mt not in this file's MimeType= (registered via mimeapps.list only)"
    fi

    bin="$(grep -m1 '^Exec=' "$f" | sed 's/^Exec=//; s/^"//; s/[" ].*//')"
    path_bin="$(command -v "$bin" 2>/dev/null || true)"
    if [ -z "$path_bin" ]; then
      echo "FAIL: Exec binary '$bin' not on PATH"
      exit 1
    fi
    real="$(readlink -f "$path_bin")"
    echo "launcher: $path_bin -> $real"

    pat='$'; pat="$pat{"
    if [ "$(head -c 4 "$real" | tail -c 3)" = "ELF" ] && grep -aqF "$pat" "$real"; then
      echo "WARN: launcher is a BINARY wrapper embedding an unexpanded shell expression:"
      tr -c '[:print:]' '\n' < "$real" | grep -F "$pat" | sort -u | head -3 | sed 's/^/    /'
      echo "      this is passed as a literal argv entry and can swallow the deep-link URL"
      echo "      (rewrap with makeShellWrapper or fixElectronLauncher from deeplink-toolkit.nix)"
      rc=1
    fi

    [ $rc -eq 0 ] && echo "OK: chain looks sane. Test with: xdg-open \"$scheme://test\" (then check the app's logs)"
    exit $rc
  '';
}
