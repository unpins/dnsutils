# Changelog

## [Unreleased]

- **`delv` works, and so does TSIG.** libisc sets up its digest table, mutex
  attributes, arenas and TLS from a constructor in a source file nothing
  references by name; nothing pulled that file into the binary, so the
  constructor never ran and every hash the tools asked for came back
  unsupported. `delv` hashes while building its resolver view, so it failed
  every query with `;; resolution failed: not implemented` — without a packet
  ever leaving the host. TSIG needs HMAC, so `dig -y` and `nsupdate -k` (the
  documented way to authenticate a dynamic update) refused their keys with
  "algorithm is unsupported". Plain `dig`, `host` and `nslookup` lookups were
  unaffected. The same omission aborted macOS outright and had been fixed there
  only; the fix now applies on every platform.
- The README's examples used a form the binary does not accept. Selecting a
  tool is `--unpin-program=dig`, and a bare `dnsutils` lists the five and
  exits.
