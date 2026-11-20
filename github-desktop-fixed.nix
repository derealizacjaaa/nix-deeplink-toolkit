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
{ lib, callPackage, github-desktop, electron_43 ? null, electron ? null }:

let
  toolkit = callPackage ./deeplink-toolkit.nix { };

  # Must track the electron major that nixpkgs builds github-desktop against.
  # Bumped 41 -> 43 on 2026-11-20: nixpkgs had already moved github-desktop
  # 3.5.8 onto electron 43, so pinning 41 here was running app resources built
  # for 43 under a 41 runtime — the exact ABI mismatch the assert below exists
  # to catch, just inverted. Electron 41 is also EOL (marked insecure in
  # nixpkgs since ~2026-11-16), and this pin was the only thing dragging it in.
  expectedMajor = "43";
  electronPkg = if electron_43 != null then electron_43 else electron;
in
assert lib.assertMsg (electronPkg != null)
  "github-desktop-fixed: no electron package found (need the major github-desktop was built with, currently ${expectedMajor})";
assert lib.assertMsg (lib.versions.major electronPkg.version == expectedMajor)
  "github-desktop-fixed: electron ${electronPkg.version} != major ${expectedMajor} that github-desktop ${github-desktop.version} was built against — native modules (keytar.node etc.) are ABI-sensitive, pin the matching electron";

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
