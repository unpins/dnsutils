{
  description = "bind9-dnsutils (dig + host + nslookup + delv + nsupdate) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # The DNS client tools from ISC BIND 9 — what Debian ships as bind9-dnsutils:
  # dig, host, nslookup, delv and nsupdate. The unpin-llvm engine compiles each
  # with -flto and captures its link into a per-program bitcode module; the
  # standalone then self-folds the five into one `dnsutils`, where each tool name
  # is an argv[0] alias. Identical mechanism on Linux and darwin — darwin used to
  # hand-fold via a cpp-rename ./multicall.nix, retired now that the engine
  # self-fold works on macOS too (useEngine is forced on for darwin).
  #
  # Force-static base build: `pkgsStatic.bind` refuses to configure — bind's
  # configure aborts with "Static linking is not supported as it disables
  # dlopen() and certain security features". The dnsutils tools use none of the
  # dlopen-loaded machinery (that's named's dyndb/plugins/dnstap), so the guard
  # is overly broad for our subset — we neuter it (postPatch, below) and drop the
  # bits that don't static-link cleanly (dnstap, and jemalloc, whose only-C++ dep
  # would drag in libstdc++). We build only lib/ + the three client bin dirs;
  # named/the server tools would add applets we don't ship.
  #
  # We collapse bind to a single `out` and install the five tools ourselves, so
  # bind's stock multi-output postInstall/postFixup are cleared on BOTH platforms
  # (they'd otherwise moveToOutput into the read-only sandbox `/bin`). macOS then
  # adds two darwin-only fixes, each documented at its site: bind's `gen` build-cc
  # pin (preConfigure) and the two source tweaks that make isc__initialize's
  # constructor run once in the folded binary (shared postPatch). aarch64-darwin
  # can't be checked by the local x86_64 cross helper (bind's `gen` must run on the
  # build host) — its source of truth is CI macos-14.
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

      # Build via the unpin-llvm engine + emit a bitcode multicall module. The
      # engine compiles the force-static bind (guard neutered; gssapi/dnstap/
      # libxml2/jemalloc dropped; libedit+embedded-ncurses for line editing) to
      # bitcode, letting make link dig/host/nslookup/delv/nsupdate as the five
      # separate binaries upstream builds by default — the engine captures each
      # link and the standalone self-folds them into one `dnsutils`. Same on Linux
      # and darwin (dnsutils has no windows target). Pure C — no requires.cxx.
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
          #
          # liburcu (userspace-rcu, pulled by bind) builds a suite of C++ test
          # programs as part of `make all`, and two of them break only on the
          # 32-bit engine targets — never in the STATIC C library bind folds in:
          #   * i686:   test_build_dynlink_cxx (a C++/shared-lib build-interface
          #             probe) miscompares — cds_lfs_empty reports non-empty right
          #             after init when that TU is compiled as C++. The C probe
          #             passes, all 433 functional tests pass, and the whole suite
          #             passes on x86_64, so the RCU logic is sound; only this C++
          #             probe trips. (i686 is a musl cross whose binaries still
          #             run on the x86_64 builder, so nixpkgs keeps doCheck on;
          #             the real crosses never run target tests.)
          #   * armv7l: test_urcu_multiflavor_single_unit_cxx fails to *link* —
          #             the engine's ARM-EHABI libunwind.a has an unresolved
          #             intra-unwinder symbol (unwindOneFrame) when pulled into a
          #             C++ exe. This is a latent engine defect for C++-on-armv7l
          #             at large, but bind is pure C and never hits it.
          # bind links only liburcu's static C library, which these C++ test
          # programs never touch. Restrict SUBDIRS to skip the tests subdir on the
          # two 32-bit arches (build + check + install) — a config bind never
          # ships. Via an overlay because liburcu is a *spliced* buildInput of
          # bind (not a bind.override arg), so overrideAttrs on bind's buildInputs
          # would silently no-op. Gated so every other arch's liburcu — and thus
          # bind — stays byte-identical.
          pkgsS = pkgs.pkgsStatic.extend (final: prev: {
            liburcu =
              if prev.stdenv.hostPlatform.isi686 || prev.stdenv.hostPlatform.isAarch32
              then prev.liburcu.overrideAttrs (o: {
                # Drop the tests+extras subdirs from the *top-level* Makefile only
                # (bind needs neither). A make-var override — SUBDIRS= on the
                # command line or via makeFlagsArray — is wrong here: recursive
                # make propagates it to every sub-make, so the doc/ sub-make would
                # then try to recurse into include/src/doc under doc/. Editing the
                # generated top Makefile keeps each sub-make's own SUBDIRS intact.
                postConfigure = (o.postConfigure or "") + ''
                  substituteInPlace Makefile --replace-fail \
                    'SUBDIRS = include src doc tests extras' \
                    'SUBDIRS = include src doc'
                '';
              })
              else prev.liburcu;
          });
          embeddedNcurses = pkgsS.ncurses;
          libeditStatic = pkgsS.libedit.override { ncurses = embeddedNcurses; };
          bindStatic = (pkgsS.bind.override ({
            openssl = pkgsS.openssl;
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
            # Drop jemalloc on every platform. jemalloc is a performance
            # allocator for the long-running `named` server; the five one-shot
            # client tools we ship (dig/host/nslookup/delv/nsupdate) run for
            # milliseconds and exit, so the default allocator is entirely
            # adequate — no user-facing feature is lost. Dropping it also sheds
            # jemalloc's only-C++ dependency (its `operator new`/`delete`
            # overrides pull `-lstdc++`): the engine toolchain ships libc++ not
            # GNU libstdc++, so on Linux bind's libtool link failed to find
            # `-lstdc++`, and on darwin jemalloc's own configure fails outright
            # under the engine cc (`-Werror` strerror_r probe → "cannot
            # determine return type of strerror_r"). With jemalloc gone the whole
            # build is pure C on both platforms — nothing pulls libc++ into the
            # fold.
            jemalloc = null;
          })).overrideAttrs (old: ({
            # libedit isn't a bind.override parameter, so add it (with the
            # embedded-terminfo ncurses) as a build input; pkg-config then finds
            # libedit.pc and `--with-readline=libedit` wires it into nslookup/
            # nsupdate.
            buildInputs = (old.buildInputs or [ ]) ++ [ libeditStatic embeddedNcurses ];
            # Neutralize bind's static-linking guard (configure aborts "Static
            # linking is not supported …" when enable_static != no unless
            # --enable-developer). The dnsutils client tools use none of the
            # dlopen'd machinery the guard protects, and a static self-contained
            # binary is the whole point, so replace the error with a no-op. Both
            # platforms need this; keep the two darwin-only source fixes in the
            # SAME postPatch (gated below) rather than the isDarwin attrs — a
            # `postPatch` there would shadow, not append to, this one.
            postPatch = (old.postPatch or "") + ''
              substituteInPlace configure \
                --replace-fail 'as_fn_error $? "Static linking is not supported as it disables dlopen() and certain security features (e.g. RELRO, ASLR)"' ': '
            ''
            + pkgs.lib.optionalString isDarwin ''
              # (darwin) Force lib/isc/lib.o — and its isc__initialize constructor
              # — into every tool's engine module. isc__initialize
              # (__attribute__((constructor))) sets up mutex attrs, arenas, TLS,
              # hashing and rcu registration, but nothing references it by symbol,
              # so neither the static linker nor the fold's llvm-link pulls lib.o
              # and it never runs. glibc tolerates the zeroed mutexattr (Linux limps
              # on); macOS aborts at the first isc_mutex_init ("pthread_mutex_init():
              # Invalid argument (22)"). A -u linker flag can't help — the engine
              # builds each module from the captured object list via llvm-link,
              # which ignores -u. So plant a real symbol reference from mem.c
              # (always linked — it owns isc_mem_create, the TU that aborts); `used`
              # shields it from opt -internalize.
              {
                echo 'void isc__initialize(void);'
                echo '__attribute__((used)) static void (*const isc__unpin_force_init)(void) = isc__initialize;'
              } >> lib/isc/mem.c
              # (darwin) Register the main thread with liburcu exactly once. That
              # reference pulls lib.o into all five programs' modules, each of which
              # internalizes isc__initialize, so the fold's LTO keeps five renamed
              # copies — the constructor fires five times at startup. Its body MUST
              # run every time (libisc's globals are internalized per module too, so
              # each program inits its own mutex/arena/TLS copies), but
              # rcu_register_thread() acts on the single shared liburcu depArchive,
              # so calls 2..5 re-register the main thread and trip liburcu's
              # assertion (urcu.c:486). Guard ONLY the rcu (un)register calls on a
              # process-global (the environment, immune to per-module symbol
              # duplication). Verified: bind's own standalone dig, pre-fold, is clean.
              substituteInPlace lib/isc/lib.c \
                --replace-fail 'rcu_register_thread();' \
                  '{ extern char *getenv(const char *); extern int setenv(const char *, const char *, int); if (!getenv("UNPIN_RCU_MAIN")) { setenv("UNPIN_RCU_MAIN", "1", 1); rcu_register_thread(); } }' \
                --replace-fail 'rcu_unregister_thread();' \
                  '{ extern char *getenv(const char *); extern int unsetenv(const char *); if (getenv("UNPIN_RCU_MAIN")) { unsetenv("UNPIN_RCU_MAIN"); rcu_unregister_thread(); } }'
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
          # Engine path (all platforms). Build + LINK only the five client tools
          # (lib/ + the three client bin dirs), never named/the server tools —
          # named links C++ and would add applets we don't ship. make links each
          # tool as a separate static binary and the unpin-llvm engine captures
          # each link into a per-program bitcode module; the standalone then
          # self-folds the five into one `dnsutils`. Identical mechanism on Linux
          # and darwin — darwin used to hand-fold via a cpp-rename ./multicall.nix,
          # retired now that the engine self-fold works on macOS too (useEngine is
          # forced on for darwin). Install just the five binaries + their man
          # pages into the single `out`.
          //
          {
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
            # Clear bind's stock postInstall/postFixup on BOTH platforms. This
            # override collapses bind to a single `out`, so bind's
            # `moveToOutput bin/{host,dig,…} $host` and
            # `remove-references-to -t $out "$dnsutils/bin/delv"` see empty output
            # vars and target the ABSOLUTE `/bin/host` / `/bin/delv`. The nix build
            # sandbox mounts `/bin` read-only (on CI Linux and macOS alike), so the
            # move dies "Permission denied" — CI-Linux caught this even though a
            # local build with a writable sandbox `/bin` let it slip into the void.
            # Our own installPhase already puts all five tools in $out/bin and the
            # engine fold ships the captured modules (not bind's $out), so both
            # hooks are pure dead weight — dropping them leaves $out byte-identical.
            postInstall = "";
            postFixup = "";
          }
          // pkgs.lib.optionalAttrs isDarwin {
            # bind compiles its `gen` build helper with BUILD_CC=$(CC_FOR_BUILD).
            # pkgsStatic makes host≠build, so nixpkgs adds that flag and the
            # stdenv points CC_FOR_BUILD at the *vanilla* darwin `clang`, whose
            # wrapper drives the ELF ld.lld and chokes on the Mach-O compiler-rt
            # ("archive member … neither ET_REL nor LLVM bitcode") — it cannot
            # link an executable, so bind's build-cc conftest fails. Every darwin
            # build that ships is native (build == host: x86_64 on macos-13,
            # arm64 on macos-14), so the host engine cc ($CC — e.g.
            # x86_64-apple-darwin-clang / arm64-apple-darwin-clang, both linking
            # via ld64.lld) is also the build cc and compiles/runs `gen` fine; pin
            # CC_FOR_BUILD to it. ($CC is arch-correct on both runners — hardcoding
            # x86_64 would break the arm64 runner. The local aarch64-darwin *cross*
            # check can't get here: bind's `gen` must run on the x86_64 build host,
            # and the cross build cc is broken, so aarch64-darwin's source of truth
            # is CI macos-14.) Darwin-gated → Linux bind stays byte-identical.
            preConfigure = (old.preConfigure or "") + ''
              export CC_FOR_BUILD=$CC
            '';
          }));
        in
        bindStatic;
    };
}
