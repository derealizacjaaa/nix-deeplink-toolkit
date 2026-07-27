# nixpkgs github-desktop with working browser (OAuth) sign-in.
#
# Two bugs stacked (diagnosed 2026-07-13):
#  1. bin/github-desktop is a binary wrapper passing '${NIXOS_OZONE_WL:+...}'
#     as a literal argv entry — fixed by fixElectronLauncher.
#  2. main.js has no Linux code path to consume the OAuth callback URL from
#     argv: upstream gates it on __WIN32__, so it is dead-code-eliminated from
#     the Linux bundle, and Electron's open-url event is macOS-only. The
#     second-instance handler drops the URL on the floor. Fixed by patching
#     handleCommandLineArguments (minified: Rt) to spot an x-github-* URL in
#     argv and feed it to the app's own open-url listener via app.emit.
#
# Note: this build uses GitHub's public dev OAuth client, so the callback
# scheme is x-github-desktop-dev-auth:// (already in mimeapps.list).
{ lib, callPackage, github-desktop, electron_41 ? null, electron ? null }:

let
  toolkit = callPackage ./deeplink-toolkit.nix { };
  electronPkg = if electron_41 != null then electron_41 else electron;
in
assert lib.assertMsg (electronPkg != null)
  "github-desktop-fixed: no electron package found (need the major github-desktop was built with, currently 41)";
assert lib.assertMsg (lib.versions.major electronPkg.version == "41")
  "github-desktop-fixed: electron ${electronPkg.version} != major 41 that github-desktop ${github-desktop.version} was built against — native modules (keytar.node etc.) are ABI-sensitive, pin the matching electron";

toolkit.fixElectronLauncher {
  pkg = github-desktop;
  electron = electronPkg;
  appPath = "${github-desktop}/share/github-desktop/resources/app";
  mainProgram = "github-desktop";

  # Minified names (Rt, yt, r) change between releases; --replace-fail makes
  # the build fail loudly on update so the anchor gets refreshed instead of
  # silently shipping a broken login again.
  patchApp = ''
    rm $out/main.js
    cp ${github-desktop}/share/github-desktop/resources/app/main.js $out/main.js
    substituteInPlace $out/main.js --replace-fail \
      'async function Rt(e){const t=yt()(e,{boolean:["protocol-launcher"]});' \
      'async function Rt(e){const _pu=e.find((a)=>"string"==typeof a&&a.startsWith("x-github-")&&a.includes("://"));_pu&&r.app.emit("open-url",{preventDefault(){}},_pu);const t=yt()(e,{boolean:["protocol-launcher"]});'
  '';
}
