# dnsutils

The DNS client tools from [ISC BIND 9](https://www.isc.org/bind/) — what Debian
ships as `bind9-dnsutils`: **dig**, **host**, **nslookup**, **delv** and
**nsupdate**. A single self-contained binary, built natively for Linux and
macOS.

[![CI](https://github.com/unpins/dnsutils/actions/workflows/dnsutils.yml/badge.svg)](https://github.com/unpins/dnsutils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install dnsutils`.

## Usage

Run any of the five tools through [unpin](https://github.com/unpins/unpin):

```bash
unpin dnsutils --unpin-program=dig example.com AAAA
unpin dnsutils --unpin-program=host example.com
unpin dnsutils --unpin-program=nslookup example.com
unpin dnsutils --unpin-program=delv example.com     # like dig, but validates DNSSEC
unpin dnsutils --unpin-program=nsupdate -k key.file # dynamic DNS updates
```

A bare `unpin dnsutils` lists the programs it holds.

To install them onto your PATH:

```bash
unpin install dnsutils
```

`unpin install dnsutils` creates `dig`, `host`, `nslookup`, `delv` and
`nsupdate`; once they are on your PATH you can call them by name — `dig
example.com`. `unpin info dnsutils` lists every command.

## Build locally

```bash
nix build github:unpins/dnsutils
./result/bin/dnsutils --unpin-program=dig -v
```

Or run directly:

```bash
nix run github:unpins/dnsutils -- --unpin-program=dig example.com
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/dnsutils/releases) page has standalone binaries for manual download.

## Build notes

- **Platforms:** Linux and macOS. Linux folds a fully-static (musl,
  `-all-static`) binary; macOS has no static libc, so the darwin build links
  BIND's libraries and every dependency from their `.a` archives while leaving
  `libSystem` dynamic (the catalog's macOS policy) — `otool -L` shows only
  `libSystem`.
- **One binary, five tools:** dig, host and nslookup share BIND's `dighost`
  resolver core; delv and nsupdate are standalone. The unpin-llvm engine compiles
  each with LTO, captures its link into a per-program bitcode module, and the
  standalone self-folds the five into one binary — so `bin/dnsutils` is the real
  binary and `dig`/`host`/`nslookup`/`delv`/`nsupdate` are `argv[0]` aliases. Same
  fold on Linux and macOS (earlier macOS used a hand-rolled cpp-rename recipe,
  retired once the engine self-fold worked on Darwin).
- **Force-static:** BIND's `configure` refuses to static-link (it disables
  `dlopen()`, which `named`'s plugins/dyndb/dnstap need). The client tools use
  none of that, so we neuter the guard and drop the parts that genuinely can't
  static-link (krb5/GSSAPI, dnstap) plus jemalloc (a `named`-server allocator
  whose only-C++ symbols would otherwise drag in libstdc++) — the build is pure C.
- **BIND's library constructor:** libisc sets up its digest table, mutexes,
  arenas and TLS from a constructor in a source file nothing references by name,
  so nothing pulled that file into the binary and the setup never ran — every
  hash came back unsupported, which broke `delv` and TSIG. The build forces that
  file in and runs its RCU registration exactly once across the folded copies.
  Needed on every platform.
- **macOS specifics:** pinning BIND's `gen` build-cc, and GNU `libiconv` for
  libunistring's `iconv` references. aarch64-darwin is built and verified on CI
  (the local cross helper can't run BIND's build-time `gen`).
- **`OPENSSLDIR` = `/etc/ssl`:** libcrypto is retargeted off `/nix/store` to the
  conventional system path (same as the [`openssl`](https://github.com/unpins/openssl)
  package), so `dig +tls` consults the host trust store and the binary carries no
  store references.
- **Interactive line-editing:** nslookup and nsupdate get history and arrow-key
  editing at their interactive prompts via BSD libedit (`--with-readline=libedit`
  — lighter than GNU readline and keeps the binary off the GPL). libedit needs
  ncurses for terminfo; we hand it the embedded-fallback ncurses
  (`--disable-database`, ~35 common terminals compiled in), so the binary needs
  no external terminfo files and carries no `/nix/store` reference.
- **Man pages:** all five embedded in the binary, read with
  `unpin man dnsutils dig` (likewise `host`, `nslookup`, `delv`, `nsupdate`).
