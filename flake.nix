{
  description = "bitcoind whose regtest chain carries mainnet's identity, for testing software that refuses to run anywhere but mainnet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      # Linux only. The patch itself is platform-neutral, but this is a test
      # harness for CI and dev rigs, and claiming a platform nobody has run it
      # on is worse than not offering it: a `nix flake check` that skips a
      # declared system reports success without having tried.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Nix is the only language here — the patch is not something a formatter
      # should touch, since its hunk offsets are load-bearing.
      treefmtFor =
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        };

      # Mainnet's genesis, which is the whole point: software that checkpoints
      # against it will now agree with this chain.
      mainnetGenesis = "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";

      # The patch is four hunks against src/kernel/chainparams.cpp and
      # src/pow.cpp. Read patches/regtest-mainnet-identity.patch — its header is
      # the design document, including why the pow.cpp hunk is not optional.
      #
      # doCheck is off because upstream's own suite asserts regtest's original
      # genesis hash, which is precisely what this changes.
      patchFor =
        pkgs:
        pkgs.bitcoind.overrideAttrs (old: {
          pname = "bitcoind-virtual-mainnet";
          patches = (old.patches or [ ]) ++ [ ./patches/regtest-mainnet-identity.patch ];
          doCheck = false;
        });
    in
    {
      overlays.default = final: prev: { bitcoind-virtual-mainnet = patchFor prev; };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bitcoind = patchFor pkgs;
        in
        {
          inherit bitcoind;
          default = bitcoind;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bitcoind = patchFor pkgs;
        in
        {
          # Everything this build claims, asserted against a running node.
          #
          # The mining assertion is the one that matters. Mainnet's genesis
          # carries difficulty-1 nBits, and without the pow.cpp hunk block 2
          # inherits it: `generatetoaddress` then exhausts maxtries and returns
          # FEWER blocks than asked WITHOUT erroring. A caller that does not
          # check the height sees success and a one-block chain — so a test that
          # only ran the RPC and checked its exit status would pass on a broken
          # build. Assert the height.
          identity = pkgs.runCommand "virtual-mainnet-identity" { nativeBuildInputs = [ bitcoind ]; } ''
            set -euo pipefail
            export HOME=$TMPDIR
            datadir=$TMPDIR/d
            mkdir -p "$datadir"

            # -connect=0 -listen=0 -dnsseed=0: this node speaks mainnet magic and
            # answers with mainnet's genesis, so it is wire-compatible with real
            # Bitcoin. Left alone it would dial real peers. The sandbox has no
            # network, but the flags are the habit to copy, not an accident of
            # the environment.
            bitcoind -regtest -datadir="$datadir" -connect=0 -listen=0 -dnsseed=0 \
              -daemon -rpcuser=u -rpcpassword=p -rpcport=18443
            cli() { bitcoin-cli -regtest -datadir="$datadir" -rpcuser=u -rpcpassword=p -rpcport=18443 "$@"; }

            for _ in $(seq 1 60); do cli getblockcount >/dev/null 2>&1 && break; sleep 1; done

            echo "--- genesis must be mainnet's"
            genesis=$(cli getblockhash 0)
            [ "$genesis" = "${mainnetGenesis}" ] || {
              echo "genesis is $genesis, expected ${mainnetGenesis}" >&2; exit 1; }

            echo "--- addresses must be mainnet-formatted"
            addr=$(cli -named createwallet wallet_name=w >/dev/null && cli -rpcwallet=w getnewaddress)
            case "$addr" in
              bc1*) ;;
              *) echo "address is $addr, expected a bc1... mainnet address" >&2; exit 1 ;;
            esac

            echo "--- mining must not stall on inherited difficulty"
            cli -rpcwallet=w generatetoaddress 10 "$addr" >/dev/null
            height=$(cli getblockcount)
            [ "$height" = "10" ] || {
              echo "height is $height, expected 10 — the pow.cpp hunk is not working" >&2
              echo "(generatetoaddress returns short WITHOUT erroring when block 2" >&2
              echo " inherits mainnet's difficulty-1 nBits)" >&2
              exit 1; }

            cli stop || true
            touch $out
          '';

          formatting = (treefmtFor system).config.build.check self;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          treefmt = (treefmtFor system).config.build.wrapper;

          # Fails the commit if anything is unformatted. treefmt reformats in
          # place, so the fix is `git add` and commit again.
          preCommitHook = pkgs.writeShellScript "pre-commit" ''
            if ! ${treefmt}/bin/treefmt --fail-on-change --no-cache; then
              echo "✖ pre-commit: files were reformatted — 'git add' them and commit again." >&2
              exit 1
            fi
          '';

          # Formatting always; the build only on request. `nix flake check`
          # compiles Bitcoin Core from source with the patch applied, which is
          # tens of minutes — too slow to put in everyone's push path, and CI
          # runs it on every push anyway.
          prePushHook = pkgs.writeShellScript "pre-push" ''
            set -e
            cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
            echo "▸ pre-push gate — FULL=1 git push runs nix flake check as well"
            ${treefmt}/bin/treefmt --fail-on-change --no-cache
            if [ "''${FULL:-0}" = "1" ]; then
              echo "▸ FULL=1: nix flake check (builds bitcoind — expect tens of minutes)"
              nix flake check
            fi
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              treefmt
              pkgs.git
            ];

            shellHook = ''
              echo "  nix fmt                          format the flake"
              echo "  nix flake check                  build the patched bitcoind and assert its identity"
              echo "  nix build                        just the package"
              echo
              echo "  Running the result — ALWAYS disable outbound networking:"
              echo "    bitcoind -regtest -connect=0 -dnsseed=0 -listen=0"
              echo
              if [ -d .git ]; then
                ln -sf ${preCommitHook} .git/hooks/pre-commit
                ln -sf ${prePushHook} .git/hooks/pre-push
              fi
            '';
          };
        }
      );

      formatter = forAllSystems (system: (treefmtFor system).config.build.wrapper);
    };
}
