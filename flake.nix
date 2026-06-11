{
  description = "Odysseus — Racket port (CLIs + server). Reproducible toolchain for NixOS/Nix.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # nixpkgs `racket` is the FULL distribution: web-server, db, rackunit, net,
      # json are all bundled — so no `raco pkg install` is needed. Our local
      # packages under racket/pkgs are made resolvable via PLTCOLLECTS instead of
      # `raco pkg install --link` (pure, no mutable user package scope).
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      entrypoints = [
        "odysseus-logs" "odysseus-preset" "odysseus-signature"
        "odysseus-notes" "odysseus-sessions" "odysseus-tasks"
        "odysseus-research" "odysseus-mcp" "odysseus-calendar"
        "odysseus-agent"
      ];

      # Single source of truth for what gets byte-compiled. Derived from
      # `entrypoints` so the CLI list can't drift from the build list; the
      # remaining requires (domain/*, server/*) are pulled in transitively by
      # `raco make`.
      makeList = builtins.concatStringsSep " " (
        [ "config.rkt" ]
        ++ (builtins.map (e: "cli/${e}.rkt") entrypoints)
        ++ [ "server/main.rkt" "server/proxy.rkt" "test/run-tests.rkt" "test/seed-db.rkt" ]
      );

      mkOdysseus = pkgs: pkgs.stdenv.mkDerivation {
        pname = "odysseus-racket";
        version = "0.1.0";
        src = ./racket;

        nativeBuildInputs = [ pkgs.racket pkgs.makeWrapper ];

        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR
          export PLTCOLLECTS="$PWD/pkgs:"
          raco make ${makeList}
          runHook postBuild
        '';

        # Run our portable suite as part of the build (hermetic: no network).
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          export HOME=$TMPDIR
          export PLTCOLLECTS="$PWD/pkgs:"
          racket test/run-tests.rkt
          runHook postCheck
        '';

        # Install the source+bytecode and wrap `racket` per entrypoint. We use
        # wrappers (not `raco exe`) — bulletproof on Nix's read-only store, and
        # the kits resolve via PLTCOLLECTS pointed at the installed copy.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/odysseus $out/bin
          cp -r . $out/share/odysseus
          for t in ${builtins.toString entrypoints}; do
            makeWrapper ${pkgs.racket}/bin/racket $out/bin/$t \
              --add-flags "$out/share/odysseus/cli/$t.rkt" \
              --set PLTCOLLECTS "$out/share/odysseus/pkgs:"
          done
          makeWrapper ${pkgs.racket}/bin/racket $out/bin/odysseus-server \
            --add-flags "$out/share/odysseus/server/main.rkt" \
            --set PLTCOLLECTS "$out/share/odysseus/pkgs:"
          makeWrapper ${pkgs.racket}/bin/racket $out/bin/odysseus-proxy \
            --add-flags "$out/share/odysseus/server/proxy.rkt" \
            --set PLTCOLLECTS "$out/share/odysseus/pkgs:"
          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Odysseus Racket port — CLIs and web server";
          platforms = systems;
          license = licenses.mit;
          mainProgram = "odysseus-logs";
        };
      };
    in
    {
      # ---- packages: `nix build` / `nix profile install` ---------------------
      packages = forAll (pkgs:
        let odysseus = mkOdysseus pkgs; in
        {
          inherit odysseus;
          default = odysseus;
        }
        # OCI image for container-capable hosts (k8s, a Genio on Docker).
        # dockerTools is Linux-only, so guard by platform.
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          container = pkgs.dockerTools.streamLayeredImage {
            name = "odysseus";
            tag = "0.1.0";
            contents = [ odysseus pkgs.cacert ];
            config = {
              Entrypoint = [ "${odysseus}/bin/odysseus-agent" ];
              Env = [ "ODYSSEUS_DATA_DIR=/data" ];
            };
          };
        });

      # ---- checks: `nix flake check` builds the package (runs the test suite) -
      checks = forAll (pkgs: {
        odysseus = self.packages.${pkgs.stdenv.hostPlatform.system}.odysseus;
      });

      # ---- NixOS module: declarative deploy (agent CLIs + optional server) ----
      # On a NixOS box or a Genio running NixOS:
      #   imports = [ odysseus.nixosModules.odysseus ];
      #   services.odysseus.enable = true;          # CLIs on PATH
      #   services.odysseus.server.enable = true;   # + systemd web server
      #   services.odysseus.ollama.enable = true;   # + local LLM, model preloaded
      nixosModules.odysseus = { config, lib, pkgs, ... }:
        let cfg = config.services.odysseus;
            pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.odysseus;
        in {
          options.services.odysseus = {
            enable = lib.mkEnableOption "Odysseus agent CLIs on PATH";
            package = lib.mkOption {
              type = lib.types.package; default = pkg;
              description = "The odysseus package to install.";
            };
            server.enable = lib.mkEnableOption "the Odysseus web server (systemd)";
            server.port = lib.mkOption { type = lib.types.port; default = 8099; };
            ollama.enable = lib.mkEnableOption "a local ollama for the agent";
            ollama.models = lib.mkOption {
              type = lib.types.listOf lib.types.str; default = [ "qwen2.5:7b" ];
              description = "Models to preload (see PERFORMANCE.md for sizing).";
            };
          };
          config = lib.mkIf cfg.enable (lib.mkMerge [
            { environment.systemPackages = [ cfg.package ]; }
            (lib.mkIf cfg.server.enable {
              systemd.services.odysseus-server = {
                description = "Odysseus web server";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  ExecStart = "${cfg.package}/bin/odysseus-server --port ${toString cfg.server.port}";
                  DynamicUser = true;
                  StateDirectory = "odysseus";
                  Environment = "ODYSSEUS_DATA_DIR=/var/lib/odysseus";
                  Restart = "on-failure";
                };
              };
            })
            (lib.mkIf cfg.ollama.enable {
              # ollama is in nixpkgs — no setup script needed on Nix hosts.
              services.ollama = { enable = true; loadModels = cfg.ollama.models; };
            })
          ]);
        };

      # ---- apps: `nix run .#odysseus-logs -- list` ---------------------------
      apps = forAll (pkgs:
        let p = self.packages.${pkgs.stdenv.hostPlatform.system}.odysseus;
            mk = name: { type = "app"; program = "${p}/bin/${name}"; };
        in {
          odysseus-logs = mk "odysseus-logs";
          odysseus-preset = mk "odysseus-preset";
          odysseus-signature = mk "odysseus-signature";
          odysseus-notes = mk "odysseus-notes";
          odysseus-sessions = mk "odysseus-sessions";
          odysseus-tasks = mk "odysseus-tasks";
          odysseus-research = mk "odysseus-research";
          odysseus-mcp = mk "odysseus-mcp";
          odysseus-calendar = mk "odysseus-calendar";
          odysseus-agent = mk "odysseus-agent";
          odysseus-server = mk "odysseus-server";
          odysseus-proxy = mk "odysseus-proxy";
          default = mk "odysseus-logs";
        });

      # ---- dev shell: `nix develop` -----------------------------------------
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.racket pkgs.git pkgs.curl pkgs.sqlite pkgs.python3 ];
          shellHook = ''
            # Make racket/pkgs/* resolvable as collections (cli-kit, db-kit, web-kit)
            # without `raco pkg install`. Assumes you `nix develop` from the repo root.
            export PLTCOLLECTS="$PWD/racket/pkgs:''${PLTCOLLECTS:-}"
            echo "Odysseus (Racket) dev shell · $(racket --version)"
            echo "  build : (cd racket && raco make config.rkt cli/odysseus-logs.rkt cli/odysseus-preset.rkt cli/odysseus-signature.rkt server/main.rkt test/run-tests.rkt)"
            echo "  test  : (cd racket && racket test/run-tests.rkt)   # expect 23 success(es)"
            echo "  run   : (cd racket && racket cli/odysseus-logs.rkt --version)"
            echo "  (kits resolve via PLTCOLLECTS — no raco pkg install needed)"
          '';
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt-rfc-style);
    };
}
