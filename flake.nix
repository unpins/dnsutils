{
  description = "bind9-dnsutils (dig + host + nslookup + delv + nsupdate) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # The DNS client tools from ISC BIND 9 — what Debian ships as bind9-dnsutils:
  # dig, host, nslookup, delv and nsupdate. We fold them into one multicall
  # binary (see multicall.nix); bin/dnsutils is the real ELF and each tool name
  # is an argv[0] alias symlink.
  #
  # Force-static base build: `pkgsStatic.bind` refuses to configure — bind's
  # configure aborts with "Static linking is not supported as it disables
  # dlopen() and certain security features". The dnsutils tools use none of the
  # dlopen-loaded machinery (that's named's dyndb/plugins/dnstap), so the guard
  # is overly broad for our subset. We neuter it, drop the bits that genuinely
  # can't static-link (krb5/gssapi, dnstap), and build only lib/ + the three
  # client bin dirs with a libtool `-all-static` link. Without that explicit
  # flag the executables come out dynamic even though the bind libs are static;
  # the guard bypass only makes the libraries static.
  #
  # macOS reuses the same force-static base and cpp-rename multicall fold; only
  # the *degree* of static differs. Linux folds everything (musl, libtool
  # `-all-static`); darwin has no static libc, so it links bind's libraries (and
  # every dep) from their `.a` archives but leaves libSystem dynamic — the
  # catalog's darwin policy. The platform forks are small and live inline:
  #   * the rename harvest strips Mach-O's leading-underscore so the cpp `#define`
  #     names match the source spelling (multicall.nix Phase A);
  #   * the final link (multicall.nix Phase C) swaps `-all-static`/`--export-dynamic`
  #     /`-lstdc++` for an archive-only ld64 link that folds libc++ statically
  #     (jemalloc pulls it; libc++.1.dylib is off the allow-list), appends GNU
  #     libiconv.a for libunistring, and force-includes bind's `isc__initialize`
  #     constructor (glibc tolerates its absence, macOS aborts on the zeroed
  #     mutex attr);
  #   * gssapi/dnstap deps that don't even build static on darwin are dropped at
  #     the `override` (below).
  # See docs/platforms/darwin.md.
  outputs = { self, unpins-lib }:
    let lib = unpins-lib.lib;
    in
    lib.mkStandaloneFlake {
      inherit self;
      name = "dnsutils";
      binName = "dnsutils";
      smoke = [ "--unpin-program=dig" "-v" ];
      smokePattern = "DiG 9\\.";
      build = pkgs:
        let
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          # Retarget openssl's OPENSSLDIR/ENGINESDIR/MODULESDIR off /nix/store to
          # the conventional /etc/ssl (same fix, and rationale, as the `openssl`
          # package): kills the store-path strings the static libcrypto bakes in,
          # and makes dig's TLS consult the host trust store. libxml2 is only for
          # named's XML statistics channel — the client tools don't use it — so
          # drop it to shed its /etc/xml/catalog reference.
          opensslRetargeted = pkgs.pkgsStatic.openssl.overrideAttrs (o: {
            buildFlags = (o.buildFlags or [ ]) ++ [
              "OPENSSLDIR=/etc/ssl"
              "ENGINESDIR=/etc/ssl/engines-3"
              "MODULESDIR=/etc/ssl/ossl-modules"
            ];
          });
          # Line-editing for nslookup/nsupdate's interactive prompts. bind detects
          # it via pkg-config; `--with-readline=libedit` (below) makes it the BSD
          # libedit (lighter than GNU readline and avoids pulling GPL into the
          # binary). libedit needs ncurses for terminfo, whose static build bakes
          # an absolute /nix/store terminfo path — so feed it the embedded-fallback
          # ncurses to stay 0-ref.
          #
          # `…Only` (not plain `embedFallbackTerminfo`) is required here: libedit
          # uses the *terminfo* API (setupterm/tigetstr), which pulls ncurses' DB
          # reader object — and with database lookup still enabled that object
          # carries the `$out/share/terminfo` store-path string (telnet escapes it
          # only because it uses the termcap API, which doesn't pull that object).
          # `…Only` adds `--disable-database`, so ncurses uses only the ~35
          # compiled-in fallback terminals (xterm/256color/vt100/tmux/screen/
          # alacritty/kitty/… — every real terminal) and bakes no path. Same
          # variant psmisc and the Windows targets use.
          embeddedNcurses = lib.embedFallbackTerminfoOnly pkgs.pkgsStatic.ncurses;
          libeditStatic = pkgs.pkgsStatic.libedit.override { ncurses = embeddedNcurses; };
          bindStatic = (pkgs.pkgsStatic.bind.override {
            openssl = opensslRetargeted;
            libxml2 = null;
            # GSS-TSIG (gssapi/krb5) can't static-link into bind — the catalog
            # has always dropped it for dnsutils. `enableGSSAPI = false` removes
            # both the `--with-gssapi` flag and the krb5 *build input*: keeping it
            # as an input (the old manual flag-filter did) is fatal on darwin,
            # where `krb5-static` itself fails to link (undefined CCAPI symbols in
            # its macOS cache backend, `cc_api_macos.o`). One feature, dropped on
            # every platform for the same reason — noted in the README.
            enableGSSAPI = false;
            # dnstap is force-disabled below (`--disable-dnstap`), so its two deps
            # — fstrm and protobuf-c — are dead build inputs. bind lists them
            # unconditionally, but on darwin `protobuf-c-static` doesn't even
            # build (its `protoc-gen-c` link drops the CoreFoundation framework
            # abseil/cctz's `local_time_zone()` needs). Drop both inputs: fixes
            # darwin and trims an unused chunk of the closure on every platform.
            fstrm = null;
            protobufc = null;
          }).overrideAttrs (old: {
            # libedit isn't a bind.override parameter, so add it (with the
            # embedded-terminfo ncurses) as a build input; pkg-config then finds
            # libedit.pc and `--with-readline=libedit` wires it into nslookup/
            # nsupdate.
            buildInputs = (old.buildInputs or [ ]) ++ [ libeditStatic embeddedNcurses ];
            postPatch = (old.postPatch or "") + ''
              substituteInPlace configure \
                --replace-fail 'as_fn_error $? "Static linking is not supported as it disables dlopen() and certain security features (e.g. RELRO, ASLR)"' ': '
            '';
            # dnstap (fstrm/protobuf-c) has no upstream toggle and its static link
            # is fragile; the dnsutils client tools don't use it. Force it off.
            configureFlags =
              (builtins.filter
                (f: f != "--enable-dnstap")
                (old.configureFlags or [ ]))
              ++ [
                "--disable-dnstap"
                # Restore nslookup/nsupdate interactive line-editing (history,
                # arrow keys) with BSD libedit (embedded-terminfo ncurses, so
                # still 0-ref — see the `let` above).
                "--with-readline=libedit"
              ]
              # mkStandaloneFlake's filterEnableStaticOnDarwin strips the literal
              # `--enable-static`/`--disable-shared` that pkgsStatic injects (a
              # blanket guard for configures that misread the flag as a `-static`
              # link request and then fail the libSystem probe). bind uses libtool,
              # where the flag keeps its standard "build the .a archive" meaning,
              # and the multicall fold *needs* static-only archives — so opt back
              # in with the equivalent spellings the filter doesn't match.
              ++ pkgs.lib.optionals isDarwin [ "--enable-static=yes" "--enable-shared=no" ];
            # Build only what the five client tools need. `bind.keys.h` is a
            # top-level perl-generated BUILT_SOURCE — it must exist before the
            # bin dirs compile (delv.c includes it) — then lib/, then *only the
            # object files* of each client tool.
            #
            # We deliberately stop at the .o targets and never let make link the
            # standalone tool executables: those binaries are throwaway (multicall
            # relinks from these objects in Phase C), and on darwin their link
            # trips an iconv ordering trap — bind's libtool reorders `-lunistring`
            # after the cc-wrapper's appended `-liconv`, so ld64's single pass
            # can't resolve libunistring.a's `_libiconv_open`. Building objects
            # only sidesteps the throwaway link on every platform; the one link we
            # keep (Phase C) lists the libraries in the order ld64 needs.
            buildPhase = ''
              runHook preBuild
              make bind.keys.h
              # libns bakes `-DNAMED_PLUGINDIR="$(pkglibdir)"` (= $out/lib/bind,
              # the autoconf default) into hooks.c; delv links libns, so that
              # store path would ride along as a (self-)reference even though the
              # client tools never load a plugin (only named's `plugin`
              # statement reaches hooks.c). Override pkglibdir to the conventional
              # system location at compile time so the binary is genuinely
              # 0-ref — same rationale as the OPENSSLDIR retarget above.
              make -C lib -j$NIX_BUILD_CORES pkglibdir=/usr/lib/bind
              make -C bin/dig -j$NIX_BUILD_CORES dig.o dighost.o host.o nslookup-nslookup.o
              make -C bin/delv -j$NIX_BUILD_CORES delv.o
              make -C bin/nsupdate -j$NIX_BUILD_CORES nsupdate.o
              # Man pages: bind ships pre-generated docutils templates
              # (doc/man/*.1in) that the `.1in.1` rule turns into real .1 with a
              # pure-sed placeholder substitution (no sphinx). Build the five we
              # ship so the multicall install can embed them.
              make -C doc/man -j$NIX_BUILD_CORES dig.1 host.1 nslookup.1 delv.1 nsupdate.1
              runHook postBuild
            '';
            # bind is a 6-output derivation (out/lib/dev/man/dnsutils/host); the
            # multicall installPhase only produces `out`.
            outputs = [ "out" ];
            meta = (old.meta or { }) // { outputsToInstall = [ "out" ]; };
            dontPatchELF = true;
            separateDebugInfo = false;
          });
        in
        import ./multicall.nix { inherit lib; } { inherit pkgs; basePkg = bindStatic; };
    };
}
