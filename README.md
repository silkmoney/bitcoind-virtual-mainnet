# bitcoind-virtual-mainnet

A `bitcoind` whose **regtest chain carries mainnet's identity** — genesis hash,
address prefixes, p2p magic and difficulty handling — so you can test software
that refuses to run anywhere but mainnet, on a chain you control.

```nix
{
  inputs.virtual-mainnet.url = "github:silkmoney/bitcoind-virtual-mainnet";

  # then either the package…
  #   virtual-mainnet.packages.${system}.bitcoind
  # …or the overlay, which adds `bitcoind-virtual-mainnet` to pkgs:
  #   nixpkgs.overlays = [ virtual-mainnet.overlays.default ];
}
```

## 🚨 Read this before running it

This node answers with **mainnet's genesis hash** and speaks **mainnet's p2p
magic**. It is therefore *wire-compatible with the real Bitcoin network*. Left
to its own devices it will dial real peers and begin syncing the real chain onto
what is supposed to be your private one.

**Always disable outbound networking:**

```sh
bitcoind -regtest -connect=0 -dnsseed=0 -listen=0 -bind=127.0.0.1:<port>
```

Two further consequences worth stating plainly:

- It emits real **`bc1…` mainnet addresses**. They are indistinguishable from
  addresses on the real network, because in every format sense they *are*
  mainnet addresses. Anything you generate here — addresses, WIF keys, xpubs —
  is live mainnet key material that you have just written into a test fixture.
- Wallet software cannot tell this chain from mainnet by identity. Never point
  a wallet file at both.

This is a **test harness**. Do not expose it to the internet, and do not reuse
keys between it and the real network.

## Why this exists

Regtest is the obvious way to get a chain you control, and [custom
signets](https://bitcoincore.academy/testnets.html) are the obvious way to get a
shared one. Neither helps when the software under test *insists on mainnet* —
because both have their own genesis, and that is exactly what gets checked.

The failure that motivated this was an Electrum-backed wallet refusing to
initialise:

```
Failed to create new wallet: cannot find agreement block with server
```

That is checkpoint reconciliation. The client walks its local chain back looking
for a block the server also has, and a fresh wallet's only checkpoint is the
genesis block of its configured network. A mainnet-configured client looks for
`000000000019d668…`; a stock regtest chain answers `0f9188f13cb7b2c7…`; there is
no agreement at any height. It is not an explicit network check, but it is a
genesis check in effect — and no amount of chain length fixes it.

Telling the client it is on regtest was not available: its network selector
reached only Mainnet or Testnet, and config validation rejected the mismatch
outright. Mainnet was also the configuration we *wanted* under test, since it
carries the real timeouts and confirmation policies rather than regtest's
substitutes.

So: give regtest mainnet's identity instead.

## What the patch changes

Four hunks. `patches/regtest-mainnet-identity.patch` carries the full reasoning;
this is the summary.

| Hunk | Why |
|---|---|
| **genesis** | So checkpoint reconciliation finds its agreement block. The load-bearing one; the rest are consequences. |
| **address prefixes** | `bech32_hrp` `bcrt` → `bc`, base58 to mainnet, so every tool in the rig speaks the same addresses and nothing has to translate. |
| **p2p magic** | electrs derives *both* its starting genesis and its p2p magic from `--network`, and only signet's magic is configurable. With mainnet genesis on the chain, electrs must run as `--network bitcoin` — so bitcoind must speak mainnet magic too, or electrs dies with `missing prev_blockhash`. |
| **`pow.cpp`** | Not optional. See below. |

### The `pow.cpp` hunk, and why a naive test would miss it

Mainnet's genesis carries difficulty-1 proof of work, and `nBits` is inherited:
`GetNextWorkRequired` returns `pindexLast->nBits` between retargets.

`fPowAllowMinDifficultyBlocks` rescues only the *first* block. Block 1's
timestamp is ~17 years after genesis's 2009, far more than
`nPowTargetSpacing * 2`, so the min-difficulty rule returns
`nProofOfWorkLimit`. But block 2 is mined milliseconds after block 1, fails that
same test, takes the else branch, walks back past block 1 to genesis, and
inherits `0x1d00ffff`. Every block after the first then costs ~2³² hashes.

**This fails almost silently.** `generatetoaddress` exhausts its default
`maxtries` and returns *fewer blocks than asked* without erroring. A caller that
does not check the resulting height sees success and a one-block chain.

So the hunk returns the proof-of-work limit outright when `fPowNoRetargeting` is
set. Only regtest sets it, so no other network is affected — and
`checks.identity` asserts the height after mining, not merely that the RPC
returned.

The merkle root assert is deliberately left alone: every network shares the same
genesis coinbase transaction, so mainnet's merkle root already equals regtest's.

## Verifying it

```sh
nix flake check
```

`checks.identity` starts the node and asserts all three claims: genesis is
`000000000019d668…`, a fresh address is `bc1…`, and mining ten blocks yields
height ten.

It builds Bitcoin Core from source with the patch applied, so budget tens of
minutes the first time. CI runs the same thing on every push.

## Development

```sh
nix develop
```

The shell brings in `treefmt` and installs two git hooks:

- **pre-commit** — `treefmt --fail-on-change`. It reformats in place, so the fix
  is `git add` and commit again. Only Nix is formatted; the patch is left alone,
  because its hunk offsets are load-bearing.
- **pre-push** — the same formatting gate. `FULL=1 git push` additionally runs
  `nix flake check`, which is the full bitcoind build and therefore not in the
  default path.

`nix fmt` formats without the hook.

## Platforms

`x86_64-linux` and `aarch64-linux`. Built and verified on **aarch64-linux**;
x86_64 is expected to work and has not been run here. Darwin is deliberately not
offered rather than offered untested.

## Version compatibility

The patch edits `src/kernel/chainparams.cpp` and `src/pow.cpp` as source, so it
rots whenever upstream touches those files — and `chainparams.cpp` is touched
fairly often.

It was written against **Bitcoin Core 31.0**, and has been built and checked
against **31.0 and 31.1** — 31.1 from this flake's own `nixpkgs` pin, and 31.0
from a consumer that overrides `nixpkgs` with its own (which is the normal way
to use this: you want the patch on the same Core the rest of your build uses).

Two minor versions is not a compatibility guarantee, but it does mean the hunks
are not knife-edge against one particular release. If your `nixpkgs` moves ahead
and the patch stops applying, that is expected maintenance rather than a
surprise: the hunks are small and the constants are stable, so rebasing is
usually mechanical. Pin `nixpkgs` if you need this not to move under you.

This project does **not** track Bitcoin Core releases automatically. Issues and
PRs for newer versions are welcome.

## License

MIT OR Apache-2.0.
