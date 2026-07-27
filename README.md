# nix-deeplink-toolkit

Fixes for `x-scheme-handler` (deep-link) breakage in Electron apps on NixOS —
the bug class where **browser-based OAuth sign-in silently does nothing**.

Ships:

| Output | What it is |
| --- | --- |
| `lib.<system>.fixElectronLauncher` | Rewraps a package so the deep-link URL survives to `argv` |
| `packages.<system>.deeplink-doctor` | CLI that diagnoses the whole inbound URL chain |
| `packages.<system>.claude-desktop` | Claude Desktop (Chat, Cowork, Claude Code) repackaged from the official `.deb` |
| `packages.<system>.github-desktop-fixed` | nixpkgs `github-desktop` with working OAuth sign-in |

## The bug

You click "Sign in with browser", authenticate, the browser redirects to
`x-github-desktop-dev-auth://…` or `claude://…` — and the app just sits there.
Two distinct causes, which stack:

**1. The launcher is a binary wrapper holding an unexpanded shell expression.**
Several nixpkgs Electron packages wrap with `makeBinaryWrapper` but pass flags
like `${NIXOS_OZONE_WL:+--ozone-platform-hint=auto}` via `--add-flags`. A
*binary* wrapper cannot expand shell syntax, so that literal string is handed to
the app as a real `argv` entry. Apps that treat the first non-flag argument as
their deep-link URL then parse garbage — and drop the real callback.

**2. The app has no Linux code path for the URL at all.**
`github-desktop` gates its handler on `__WIN32__`, so it's dead-code-eliminated
from the Linux bundle, and Electron's `open-url` event is macOS-only. The
callback reaches the second-instance handler and is discarded.

`fixElectronLauncher` fixes (1) generically. (2) needs a per-app patch — see the
`patchApp` hook and [`github-desktop-fixed.nix`](github-desktop-fixed.nix) for a
worked example.

## Diagnosing

```console
$ nix run github:derealizacjaaa/nix-deeplink-toolkit#deeplink-doctor -- x-github-desktop-dev-auth
== x-scheme-handler/x-github-desktop-dev-auth ==
default handler: github-desktop.desktop
desktop file: /run/current-system/sw/share/applications/github-desktop.desktop
  Exec=github-desktop %u
launcher: /run/current-system/sw/bin/github-desktop -> /nix/store/…
WARN: launcher is a BINARY wrapper embedding an unexpanded shell expression:
    ${NIXOS_OZONE_WL:+--ozone-platform-hint=auto …}
      this is passed as a literal argv entry and can swallow the deep-link URL
```

It checks the chain end to end: scheme registration → `.desktop` file → `Exec=`
has `%u` → launcher binary sanity.

## Usage

Add the input:

```nix
inputs.deeplink-toolkit.url = "github:derealizacjaaa/nix-deeplink-toolkit";
inputs.deeplink-toolkit.inputs.nixpkgs.follows = "nixpkgs";
```

### Install a fixed package

```nix
environment.systemPackages = [
  inputs.deeplink-toolkit.packages.${pkgs.system}.claude-desktop
  inputs.deeplink-toolkit.packages.${pkgs.system}.github-desktop-fixed
  inputs.deeplink-toolkit.packages.${pkgs.system}.deeplink-doctor
];
```

Or via the overlay:

```nix
nixpkgs.overlays = [ inputs.deeplink-toolkit.overlays.default ];
environment.systemPackages = [ pkgs.claude-desktop ];
```

### Fix your own Electron package

```nix
inputs.deeplink-toolkit.lib.${pkgs.system}.fixElectronLauncher {
  pkg = pkgs.some-electron-app;      # reused for share/ (.desktop, icons)
  mainProgram = "some-electron-app"; # must match the .desktop Exec=
  electron = pkgs.electron_41;       # MUST match the major it was built for
  appPath = "${pkgs.some-electron-app}/share/some-electron-app/resources/app";
}
```

Pass either `electron` + `appPath`, or `exePath` if the app bundles its own
Electron binary. Env-only wrapping (`wrapGAppsHook`, `PATH` prefixes) should
stay in the app's own derivation — env args can't corrupt `argv`, so that split
is safe. Anything argv-visible belongs in the launcher, where it's expanded at
runtime.

`electron` is asserted against the major the app was built with: native modules
(`keytar.node` and friends) are ABI-sensitive and mismatches fail at runtime,
not build time.

## Claude Desktop notes

Repackaged from the official Debian package. This flake does **not**
redistribute the binary — it fetches from `downloads.claude.ai` at build time.
The app is unfree; the flake sets `allowUnfree` for its own nixpkgs instance.

What the `.deb` assumes, and how the derivation adapts it:

- FHS-linked dynamic binaries → `autoPatchelfHook`
- UEFI firmware at `/usr/share/OVMF/` → `app.asar` patched to `${OVMF.fd}/FV`
- `qemu-system-x86_64` on `PATH` → in-place wrapper prefixes `qemu_kvm`
- `virtiofsd` from apt → the bundled binary is patchelf'd, and the probe (which
  otherwise falls back to the bundle on Ubuntu 22 only) is pointed at it
- AppArmor userns profile → unnecessary, NixOS allows unprivileged userns
- setuid `chrome-sandbox` → dropped; Chromium uses the userns sandbox

Cowork's VM features need KVM. The `asar` patches use `--replace-fail`, so an
upstream change breaks the build loudly instead of silently shipping a broken
app.

### Updating

Pick a new version + hash from the
[stable Packages index](https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages),
then bump `version` and `hash` in [`claude-desktop.nix`](claude-desktop.nix).

The same applies to `github-desktop-fixed.nix`: its patch anchors on minified
identifiers (`Rt`, `yt`, `r`) that change between releases. `--replace-fail`
turns that into a build error so the anchor gets refreshed.

## License

The Nix expressions here are MIT. The packaged applications keep their own
licenses — Claude Desktop is unfree, see [Anthropic's terms](https://claude.ai).
