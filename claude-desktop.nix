# Claude Desktop (with Cowork) for NixOS, repackaged from the official
# Debian package published at https://downloads.claude.ai/claude-desktop/apt/stable
#
# What the Debian package assumes and how this derivation fixes it:
#  - dynamic binaries linked against FHS paths        -> autoPatchelfHook
#  - UEFI firmware at /usr/share/OVMF/OVMF_CODE*.fd   -> app.asar patched to ${OVMF.fd}/FV
#    (the app derives the VARS template by replacing "OVMF_CODE" -> "OVMF_VARS"
#     in the chosen path, which also holds for the nixpkgs OVMF layout)
#  - qemu-system-x86_64 available on PATH             -> in-place wrapper prefixes qemu_kvm
#  - virtiofsd from apt (bundled fallback: Ubuntu 22   -> app.asar patched to use the
#    only, so NixOS would fail the Cowork VM check)       bundled, patchelf'd virtiofsd
#  - cowork-linux-helper                               -> statically linked, works as-is
#  - AppArmor userns profile from postinst             -> unnecessary, NixOS allows
#    unprivileged user namespaces by default
#
# The launcher (bin/claude-desktop) comes from deeplink-toolkit.nix: the app
# treats the first non-flag argument as its claude:// deep-link URL, so the
# launcher must never leak unexpanded flag expressions into argv (the original
# makeBinaryWrapper-based wrapper did exactly that and silently broke browser
# login). Env-only wrapping (gapps vars, qemu PATH) is applied in place on the
# real binary below — env args cannot corrupt argv, so that split is safe.
#
# Update procedure: pick a new version + SHA256 from
#   https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages
{ lib
, stdenv
, callPackage
, fetchurl
, dpkg
, autoPatchelfHook
, makeShellWrapper
, wrapGAppsHook3
, asar
, alsa-lib
, at-spi2-atk
, at-spi2-core
, atk
, cairo
, cups
, dbus
, expat
, fontconfig
, freetype
, gdk-pixbuf
, glib
, gtk3
, libdrm
, libgbm
, libGL
, libglvnd
, libnotify
, libpulseaudio
, libsecret
, libuuid
, libxkbcommon
, mesa
, nspr
, nss
, pango
, pipewire
, systemd
, vulkan-loader
, wayland
, xorg
, libseccomp
, libcap_ng
, qemu_kvm
, OVMF
}:

let
  toolkit = callPackage ./deeplink-toolkit.nix { };

  unwrapped = stdenv.mkDerivation rec {
    pname = "claude-desktop-unwrapped";
    version = "1.19367.0";

    src = fetchurl {
      url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
      hash = "sha256-dvVwcwwRhZJOJCPF+IonvsF8HnrbBV7NCUAaDpOpKZs=";
    };

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
      makeShellWrapper
      wrapGAppsHook3
      asar
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      fontconfig
      freetype
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libgbm
      libGL
      libnotify
      libpulseaudio
      libsecret
      libuuid
      libxkbcommon
      mesa
      nspr
      nss
      pango
      stdenv.cc.cc
      libseccomp # virtiofsd
      libcap_ng  # virtiofsd
    ];

    # The bundled ANGLE libEGL.so dlopens the native libEGL.so.1 at runtime;
    # dlopen from a library only searches that library's own RUNPATH, so the GL
    # stack has to be appended to every patched ELF. /run/opengl-driver/lib
    # brings in the actual hardware drivers on NixOS.
    appendRunpaths = [
      "/run/opengl-driver/lib"
      (lib.makeLibraryPath [ libglvnd vulkan-loader libgbm wayland libxkbcommon ])
    ];

    runtimeDependencies = map lib.getLib [
      systemd
      libpulseaudio
      libGL
      pipewire
      vulkan-loader
      wayland
      xorg.libX11
      xorg.libxcb
    ];

    dontConfigure = true;
    dontBuild = true;
    # gappsWrapperArgs are applied by hand in postFixup so they land as an
    # env-only in-place wrapper on the real binary
    dontWrapGApps = true;

    # Cowork's VM code probes a fixed list of Debian firmware paths; point it at
    # the nix store instead. --replace-fail makes version bumps fail loudly here
    # if upstream ever changes that list.
    postPatch = ''
      asar extract usr/lib/claude-desktop/resources/app.asar asar-unpacked
      chunk=$(grep -rl 'OVMF_CODE_4M' asar-unpacked/.vite/build)
      substituteInPlace "$chunk" --replace-fail \
        '["/usr/share/OVMF/OVMF_CODE_4M.fd","/usr/share/OVMF/OVMF_CODE.fd"]' \
        '["${OVMF.fd}/FV/OVMF_CODE.fd"]'
      # The virtiofsd probe checks apt paths and falls back to the bundled
      # (patchelf'd) binary only on Ubuntu 22; point it straight at the bundle.
      substituteInPlace "$chunk" --replace-fail \
        '["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"]' \
        '["${placeholder "out"}/lib/claude-desktop/resources/virtiofsd"]'
      rm -rf usr/lib/claude-desktop/resources/app.asar.unpacked
      asar pack asar-unpacked usr/lib/claude-desktop/resources/app.asar --unpack '*.node'
      rm -rf asar-unpacked
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r usr/lib $out/lib
      cp -r usr/share $out/share
      rm -rf $out/share/lintian

      # dpkg installs chrome-sandbox setuid; the store cannot, and NixOS does
      # not need it (Chromium uses the user-namespace sandbox)
      chmod 0755 $out/lib/claude-desktop/chrome-sandbox

      runHook postInstall
    '';

    # Env-only wrapper, applied in place (wrapProgramShell renames the binary
    # to .claude-desktop-wrapped next to it, so Electron still finds its
    # resources/ dir). No --add-flags here — anything argv-visible belongs in
    # the toolkit launcher, where it is expanded at runtime.
    postFixup = ''
      wrapProgramShell $out/lib/claude-desktop/claude-desktop \
        "''${gappsWrapperArgs[@]}" \
        --prefix PATH : ${lib.makeBinPath [ qemu_kvm ]}
    '';

    meta = with lib; {
      description = "Claude desktop app (Chat, Cowork, Claude Code) repackaged from the official Debian package";
      homepage = "https://claude.ai";
      downloadPage = "https://code.claude.com/docs/en/desktop-linux";
      license = licenses.unfree;
      sourceProvenance = with sourceTypes; [ binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "claude-desktop";
    };
  };
in
toolkit.fixElectronLauncher {
  pkg = unwrapped;
  exePath = "${unwrapped}/lib/claude-desktop/claude-desktop";
  mainProgram = "claude-desktop";
}
