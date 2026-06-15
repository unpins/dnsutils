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

Run any of the five tools through [unpin](https://github.com/unpins/unpin) — the
name after `dnsutils` selects the applet:

```bash
unpin dnsutils dig example.com AAAA
unpin dnsutils host example.com
unpin dnsutils nslookup example.com
unpin dnsutils delv example.com          # like dig, but validates DNSSEC
unpin dnsutils nsupdate -k key.file      # dynamic DNS updates
```

To install them onto your PATH:

```bash
unpin install dnsutils
```

`unpin install dnsutils` creates `dig`, `host`, `nslookup`, `delv` and
`nsupdate`. `unpin info dnsutils` lists every command.

## Build locally

```bash
nix build github:unpins/dnsutils
./result/bin/dig -v
```

Or run directly:

```bash
nix run github:unpins/dnsutils -- dig example.com
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
  resolver core; delv and nsupdate are standalone. They're folded into one binary
  with the cpp-rename multicall recipe (each tool recompiled into its own private
  symbol namespace, then linked together), so `bin/dnsutils` is the real binary
  and `dig`/`host`/`nslookup`/`delv`/`nsupdate` are `argv[0]` aliases.
- **Force-static:** BIND's `configure` refuses to static-link (it disables
  `dlopen()`, which `named`'s plugins/dyndb/dnstap need). The client tools use
  none of that, so we neuter the guard and drop the parts that genuinely can't
  static-link (krb5/GSSAPI, dnstap).
- **macOS specifics:** the darwin link folds the C++ runtime statically
  (`libc++.a`/`libc++abi.a` — pulled in by jemalloc's `operator new`/`delete`)
  since the allow-list forbids `libc++.1.dylib`, appends GNU `libiconv.a` for
  libunistring's `iconv` references, and force-includes BIND's library
  constructor (`isc__initialize`) so its mutex/memory/RCU setup runs — glibc
  tolerates the missing constructor, macOS does not.
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
