# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

Initial extraction.

### Added

- `packages.<system>.bitcoind` — Bitcoin Core with the regtest network given
  mainnet's identity, and `overlays.default` exposing it as
  `pkgs.bitcoind-virtual-mainnet`.
- `checks.identity` — starts the node and asserts genesis, address format, and
  that mining ten blocks yields height ten.
- `checks.<system>.formatting` and a `formatter` output, over Nix only — the
  patch is excluded, since reformatting it would move its hunk offsets.
- `devShells.default` with `treefmt`, installing a pre-commit hook (formatting)
  and a pre-push hook (formatting, plus `nix flake check` under `FULL=1`).
- GitHub Actions CI: a fast formatting job, and `nix flake check` on every push
  and pull request.

### Notes

Extracted from an atomic-swap test rig, where it existed to make a shipped
mainnet-only binary usable against a local chain. Two things were changed on the
way out:

- The patch header called it "the three hunks" and then explained a fourth, and
  one paragraph appeared twice. Corrected.
- The DANGER section pointed at a script in the originating repository. It now
  points at this flake's own check, which demonstrates the required flags.

The mining assertion is deliberately an assertion about *height* rather than
about the RPC succeeding: without the `pow.cpp` hunk, `generatetoaddress`
returns fewer blocks than requested without erroring, so a check that only
tested the exit status would pass on a broken build.
