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
      pkgsAttr = "bind";
      smoke = [ "--unpin-program=dig" "-v" ];
      smokePattern = "DiG 9\\.";

      # Build via the unpin-llvm engine + emit a bitcode multicall module. On
      # Linux the engine compiles the force-static bind (guard neutered;
      # gssapi/dnstap/libxml2 dropped; libedit+embedded-ncurses for line editing)
      # to bitcode, letting make link dig/host/nslookup/delv/nsupdate as the five
      # separate binaries upstream builds by default — the engine captures each
      # link sidecar and the standalone self-folds them into one `dnsutils`
      # binary. darwin/windows keep the cpp-rename fold in ./multicall.nix (which
      # needs the throwaway-link-avoiding `.o`-only buildPhase; that build is
      # incompatible with the engine's per-program link capture, so the engine
      # path uses bind's normal build+install instead). Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "dig"; }
          { name = "host"; }
          { name = "nslookup"; }
          { name = "delv"; }
          { name = "nsupdate"; }
        ];
        defaultProgram = "dig";
      };

      build = pkgs:
        let
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          # openssl is retargeted (OPENSSLDIR/ENGINESDIR/MODULESDIR off /nix/store
          # to /etc/ssl, so static libcrypto bakes no store paths and dig's TLS
          # consults the host trust store) by nix-lib's native-overlay/openssl.nix —
          # the same lib.retargetOpenssl recipe the standalone `openssl` package
          # uses — so pkgs.pkgsStatic.openssl is already that one shared, deduped
          # copy: no per-package override here (same arrangement as ncurses below).
          # libxml2 is only for named's XML statistics channel — the client tools
          # don't use it — so it's dropped below to shed its /etc/xml/catalog ref.
          # Line-editing for nslookup/nsupdate's interactive prompts. bind detects
          # it via pkg-config; `--with-readline=libedit` (below) makes it the BSD
          # libedit (lighter than GNU readline and avoids pulling GPL into the
          # binary). libedit uses the *terminfo* API (setupterm/tigetstr), which
          # pulls ncurses' DB-reader object. native-overlay/ncurses.nix bakes the
          # FHS default-dir pin (so the binary stays 0-ref with the database on,
          # same as htop) + the ~35 compiled-in fallbacks into every engine
          # ncurses, linux + darwin, so pkgsStatic.ncurses is already that one
          # shared, deduped copy — no per-package override.
          embeddedNcurses = pkgs.pkgsStatic.ncurses;
          libeditStatic = pkgs.pkgsStatic.libedit.override { ncurses = embeddedNcurses; };
          bindStatic = (pkgs.pkgsStatic.bind.override ({
            openssl = pkgs.pkgsStatic.openssl;
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
          } // pkgs.lib.optionalAttrs isLinux {
            # Engine (Linux) path: jemalloc's static lib pulls `-lstdc++` (its
            # C++ bits) via jemalloc.pc, and the engine toolchain ships libc++
            # (not GNU libstdc++) — so bind's tool links fail with "unable to
            # find library -lstdc++". The fold path (darwin/windows) relinks by
            # hand and absorbs it; the engine link goes through bind's own
            # libtool line, so drop jemalloc here and let the five short-lived
            # client tools use the default musl allocator (no C++ dep → pure C).
            jemalloc = null;
          })).overrideAttrs (old: ({
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
              ++ pkgs.lib.optionals isDarwin [ "--enable-static=yes" "--enable-shared=no" ]
              # Engine (Linux) path: bind's normal build+install links the five
              # client tools as separate static binaries (musl pkgsStatic), and
              # the engine captures each link. The catalog's filterEnableStatic
              # strip only fires on darwin, so on Linux the pkgsStatic-injected
              # --enable-static/--disable-shared already stand — no opt-back-in
              # needed. We DON'T build named/the server tools (they'd add applets
              # we don't ship); the bin/ subset is selected by the program list.
              ;
          }
          # The fold-only build/install (`.o`-only buildPhase, single `out`
          # output) is for the darwin/windows cpp-rename path. The engine (Linux)
          # path uses bind's NORMAL build+install so make links the five client
          # tools as separate binaries for the engine to capture — so skip these
          # overrides on Linux.
          // pkgs.lib.optionalAttrs (!isLinux) {
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
          }
          # Engine (Linux) path: build + LINK only the five client tools (lib/ +
          # the three client bin dirs), never named/the server tools — named
          # links C++ (`-lstdc++`, unavailable unprefixed under the engine) and
          # would add applets we don't ship. Unlike the fold path we DO let make
          # link each tool: that real link is what the engine captures per
          # program for the bitcode self-fold. Install just the five binaries +
          # their man pages into the single `out`.
          // pkgs.lib.optionalAttrs isLinux {
            outputs = [ "out" ];
            meta = (old.meta or { }) // { outputsToInstall = [ "out" ]; };
            buildPhase = ''
              runHook preBuild
              make bind.keys.h
              # pkglibdir retarget: same 0-ref rationale as the fold path — libns
              # bakes -DNAMED_PLUGINDIR=$(pkglibdir) into hooks.c (delv links
              # libns), so point it at a conventional system path, not $out.
              make -C lib -j$NIX_BUILD_CORES pkglibdir=/usr/lib/bind
              make -C bin/dig -j$NIX_BUILD_CORES dig host nslookup
              make -C bin/delv -j$NIX_BUILD_CORES delv
              make -C bin/nsupdate -j$NIX_BUILD_CORES nsupdate
              make -C doc/man -j$NIX_BUILD_CORES dig.1 host.1 nslookup.1 delv.1 nsupdate.1
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/share/man/man1"
              for t in bin/dig/dig bin/dig/host bin/dig/nslookup \
                       bin/delv/delv bin/nsupdate/nsupdate; do
                install -m755 "$t" "$out/bin/$(basename "$t")"
              done
              for m in dig host nslookup delv nsupdate; do
                install -m644 "doc/man/$m.1" "$out/share/man/man1/$m.1"
              done
              runHook postInstall
            '';
            dontPatchELF = true;
            separateDebugInfo = false;
          }));
        in
        if isLinux
        then bindStatic
        else import ./multicall.nix { inherit lib; } { inherit pkgs; basePkg = bindStatic; };
    };
}
