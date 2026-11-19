# dnsutils

The DNS client programs from [ISC BIND 9](https://www.isc.org/bind/): **dig**,
**host**, **nslookup**, **delv**, **nsupdate** and **mdig**. A single
self-contained binary, built natively for Linux and macOS.

[![CI](https://github.com/unpins/dnsutils/actions/workflows/dnsutils.yml/badge.svg)](https://github.com/unpins/dnsutils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install dnsutils`.

## Usage

Run any of the programs through [unpin](https://github.com/unpins/unpin):

```bash
unpin dnsutils --unpin-program=dig example.com AAAA
unpin dnsutils --unpin-program=host example.com
unpin dnsutils --unpin-program=nslookup example.com
unpin dnsutils --unpin-program=delv example.com     # like dig, but validates DNSSEC
unpin dnsutils --unpin-program=nsupdate -k key.file # dynamic DNS updates
unpin dnsutils --unpin-program=mdig @9.9.9.9 example.com example.org  # many queries, one connection
```

A bare `unpin dnsutils` lists the programs it holds.

To install them onto your PATH:

```bash
unpin install dnsutils
```

`unpin install dnsutils` creates `dig`, `host`, `nslookup`, `delv`, `nsupdate`
and `mdig`; once they are on your PATH you can call them by name — `dig
example.com`. `unpin info dnsutils` lists every command.

## Man pages

All six are embedded in the binary:

```bash
unpin man dnsutils dig      # likewise host, nslookup, delv, nsupdate, mdig
```

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

- **Platforms:** Linux and macOS. BIND dropped Windows after 9.16.
- **Not included:** `dnstap-read` (it reads logs written by the `named`
  server). On macOS, GSS-TSIG (`nsupdate -g`) is also missing, because Kerberos
  doesn't link statically there.
- **`OPENSSLDIR` = `/etc/ssl`:** `dig +tls` uses the host's trust store, as the
  [`openssl`](https://github.com/unpins/openssl) package does.
- **Line editing:** `nslookup` and `nsupdate` have history and arrow keys at
  their prompts (BSD libedit). They use the system terminfo, with ~35 common
  terminals built in as a fallback.
