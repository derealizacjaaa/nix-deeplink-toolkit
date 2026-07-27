{
  description = "Deep-link (x-scheme-handler) fixes for Electron apps on NixOS, plus a Claude Desktop repackage";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      # claude-desktop repackages an amd64 .deb; github-desktop is x86_64 in
      # nixpkgs too. The toolkit itself is platform-agnostic but has no
      # standalone consumers, so one system keeps the outputs honest.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Claude Desktop is unfree (it repackages Anthropic's official .deb, it
      # does not redistribute it). Instantiate with allowUnfree so `nix build`
      # against this flake works without the consumer re-declaring it.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # The library. Not a derivation — an attrset of { fixElectronLauncher, doctor }.
      # Consumers: `deeplink-toolkit.lib.${system}.fixElectronLauncher { ... }`
      lib = forAllSystems (system:
        (pkgsFor system).callPackage ./deeplink-toolkit.nix { }
      );

      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in rec {
          default = claude-desktop;

          claude-desktop = pkgs.callPackage ./claude-desktop.nix { };

          github-desktop-fixed = pkgs.callPackage ./github-desktop-fixed.nix { };

          # deeplink-doctor <scheme> — diagnose a broken x-scheme-handler chain
          deeplink-doctor = (pkgs.callPackage ./deeplink-toolkit.nix { }).doctor;
        }
      );

      overlays.default = final: prev: {
        claude-desktop = final.callPackage ./claude-desktop.nix { };
        github-desktop-fixed = final.callPackage ./github-desktop-fixed.nix { };
        deeplink-toolkit = final.callPackage ./deeplink-toolkit.nix { };
      };

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
