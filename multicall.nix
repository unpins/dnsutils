# bind9-dnsutils ships five DNS client tools — dig, host, nslookup (which all
# build from bin/dig and share the dighost.o resolver core), plus delv and
# nsupdate. To honour the unpins one-pkg-one-bin rule we post-link them into a
# single multicall ELF (bin/dnsutils + an argv[0] alias symlink per tool).
#
# This is the cpp-rename fold (same idea as lib.cppRenameMulticall / bc): each
# program is recompiled with a per-program `-include <p>.rename.h` that renames
# `main`→<p>_main and namespaces every other defined global behind `<p>__`, so
# the five object graphs can't collide. dig/host/nslookup each carry their OWN
# renamed copy of dighost.o — it holds the shared resolver STATE (current_lookup,
# the dighost_* callback POINTERS, …) as its own definitions and dispatches via
# runtime pointers, so a private per-program copy is both correct and the
# simplest thing that links. delv and nsupdate are standalone (own main only).
#
# We drive the recipe by hand rather than through lib.cppRenameMulticall because
# bind links with libtool and needs an explicit `-all-static` (the libtool
# fully-static link) over a union of five static .la archives spanning three
# bin/ subdirs — easier to write that final link out than to thread it through
# the generic $(LINK)/$(LIBS) machinery. The force-static base build itself
# (neutering bind's "static linking is not supported" guard, etc.) lives in
# flake.nix and reaches us as `basePkg`.
{ lib }:
{ pkgs                  # build-host pkgs (writeText/withAliases)
, basePkg               # the force-static bind derivation (custom buildPhase)
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # program → object set (paths relative to the build top). dig/host/nslookup
  # live in bin/dig and each pull dighost.o; delv/nsupdate stand alone. All five
  # names are already valid C identifiers, so the dispatcher's <name>_main and
  # our `#define main <name>_main` line up with no sanitising needed.
  programs = {
    dig = [ "bin/dig/dig.o" "bin/dig/dighost.o" ];
    host = [ "bin/dig/host.o" "bin/dig/dighost.o" ];
    nslookup = [ "bin/dig/nslookup-nslookup.o" "bin/dig/dighost.o" ];
    delv = [ "bin/delv/delv.o" ];
    nsupdate = [ "bin/nsupdate/nsupdate.o" ];
  };
  progNames = builtins.attrNames programs;

  # Phase A: discover defined globals per program (canonical names, BEFORE any
  # recompile) and emit its rename header.
  renameHeader = prog: ''
    {
      echo "/* dnsutils multicall rename header: ${prog} */"
      echo "#define main ${prog}_main"
      # bind builds with -Werror=missing-prototypes; the renamed main needs one.
      echo "int ${prog}_main(int, char **);"
      $NM --defined-only -g ${pkgs.lib.concatStringsSep " " programs.${prog}} 2>/dev/null \
        | awk -v p="${prog}" -v u=${if isDarwin then "1" else "0"} '
            $2 ~ /^[TBDRWVCS]$/ {
              sym = $3
              # Mach-O prefixes every C symbol with a leading underscore at the
              # ABI level (so nm shows `_main`, `_dighost_…`), but the rename
              # header is `#include`d into the *source*, where the identifiers
              # have no such prefix. Strip one leading `_` on darwin so the
              # `#define`d names match the source spelling (ELF nm already shows
              # the bare name).
              if (u == "1") sub(/^_/, "", sym)
              if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                print "#define " sym " " p "__" sym
            }'
    } > multicall/${prog}.rename.h
  '';

  # Phase B: rm the program's objects, recompile them with the rename header
  # `-include`d (reusing automake's exact per-target flags via `make`), then copy
  # the freshly-renamed .o into multicall/obj_<p>/ before the next program's
  # rebuild can clobber a shared source path (bin/dig/dighost.o).
  rebuild = prog: ''
    rm -f ${pkgs.lib.concatStringsSep " " programs.${prog}}
    ${pkgs.lib.concatMapStringsSep "\n    "
        (obj: ''make -C ${builtins.dirOf obj} -j$NIX_BUILD_CORES ${baseNameOf obj} NIX_CFLAGS_COMPILE="$_orig_NIX_CFLAGS_COMPILE -include $PWD/multicall/${prog}.rename.h"'')
        programs.${prog}}
    mkdir -p multicall/obj_${prog}
    ${pkgs.lib.concatMapStringsSep "\n    "
        (obj: ''cp "${obj}" "multicall/obj_${prog}/$(echo '${obj}' | tr / _)"'')
        programs.${prog}}
  '';

  multicall = basePkg.overrideAttrs (old: {
    pname = "dnsutils-multi";
    doCheck = false;

    # bind's stock postInstall splits the binaries into its `host`/`dnsutils`
    # multi-outputs (moveToOutput) and seds a config script — both bogus once we
    # collapse to a single `out` and ship our own binary. Drop it.
    postInstall = "";

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p multicall
      _orig_NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}

      # Phase A: discovery
      ${pkgs.lib.concatMapStringsSep "\n" renameHeader progNames}
      # Phase B: recompile + isolate
      ${pkgs.lib.concatMapStringsSep "\n" rebuild progNames}

      # Dispatcher: basename(argv[0]) → <prog>_main (or --unpin-program=<prog>).
      printf '${pkgs.lib.concatMapStringsSep "\\n" (p: "${p}\t${p}") progNames}\n' > multicall/applets.list
    ${lib.multicallTableDispatcherC { name = "dnsutils"; defaultApplet = null; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Phase C: one libtool link folding all five renamed graphs plus the union
      # of the libraries any of the five tools needs (delv pulls libns; the rest
      # is common). nslookup/nsupdate call libedit's readline-compat API
      # (`readline`/`add_history`), so the link adds `-ledit -lncurses` (the
      # embedded-terminfo ncurses; libedit.pc's `Libs.private`) at the tail —
      # after the objects that reference them, libedit before its ncurses backend.
      # The bind libs + every dep (jemalloc/idn2/unistring/urcu/openssl/libuv/…)
      # come from pkgsStatic, so all are `.a`; only libSystem stays dynamic.
      #
      # Linux: `-all-static` (fully static musl) + `--export-dynamic` + the static
      # `-lstdc++`. darwin: no `-all-static` (no static libc) and no GNU
      # `--export-dynamic` (ld64 spells it `-export_dynamic`, and the dlopen-only
      # paths that wanted it are disabled anyway). The C++ runtime (jemalloc's
      # `operator new`/`delete` overrides pull it in) must be folded static — the
      # darwin allow-list rejects /usr/lib/libc++.1.dylib. We can't use plain
      # `-nostdlib++` here: libtool injects an explicit `-lstdc++` from a `.la`
      # deplib, and `-nostdlib++` strips the cc-wrapper's libc++ `-L`, so that
      # token then fails to resolve. Instead use the search-path shim (the ffmpeg
      # recipe): a TMPDIR `-L` exposing libc++.a under libc++/libstdc++/libc++abi
      # names, with `-search_paths_first` so ld64 takes the `.a` over the dylib.
      # It's a light C++ user (no iostream), so no unexported-symbols dance.
      ${pkgs.lib.optionalString isDarwin ''
        mkdir -p "$TMPDIR/cxx-static"
        ln -sf ${pkgs.pkgsStatic.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
        ln -sf ${pkgs.pkgsStatic.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
        ln -sf ${pkgs.pkgsStatic.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
        export NIX_LDFLAGS="-search_paths_first -L$TMPDIR/cxx-static $NIX_LDFLAGS"
      ''}
      #
      # iconv: idn2 → libunistring.a's striconveh.o references the GNU-prefixed
      # `_libiconv`/`_libiconv_open`/`_libiconv_close`. withDarwinIconv's bare
      # `-liconv` resolves to Apple's stub libiconv-113 (no `.a`, no `_libiconv*`
      # — those are `_iconv*` in libSystem), so it can't satisfy them. Append the
      # GNU `libiconvReal` archive dead-last (after `-lunistring`); ld64 is
      # single-pass, and libtool reorders `-lunistring` past anything we could put
      # in NIX_LDFLAGS, so a full archive path at the very end is the order-safe
      # spot. Same fix the xvnc/fish darwin builds use.
      #
      # `-u isc__initialize`: bind's per-library init (mutex attr, mem arenas,
      # TLS, hashing, `rcu_register_thread`, …) runs from `isc__initialize`, an
      # `__attribute__((constructor))` in lib/isc/lib.o. Nothing references that
      # object by symbol, so the static linker never pulls it and the constructor
      # never runs. glibc tolerates the resulting zeroed `pthread_mutexattr_t`
      # (linux silently limps), but macOS rejects it — the first `isc_mutex_init`
      # aborts with `pthread_mutex_init(): Invalid argument (22)`. Force the object
      # in on both platforms (the Mach-O symbol carries the leading `_`); ld then
      # pulls lib.o and the constructor is registered to run at startup.
      ${
        if isDarwin then ''
          ./libtool --silent --tag=CC --mode=link $CC \
            -Wl,-u,_isc__initialize \
            -o multicall/dnsutils \
            multicall/dispatcher.o multicall/obj_*/*.o \
            -ljemalloc -pthread \
            lib/isc/libisc.la lib/dns/libdns.la lib/ns/libns.la lib/isccfg/libisccfg.la \
            -lidn2 -lunistring -lpthread \
            -lurcu-common -lurcu -lurcu-common -lurcu-cds \
            -ledit -lncurses \
            -lc++ -lc++abi \
            ${pkgs.pkgsStatic.libiconvReal}/lib/libiconv.a
        '' else ''
          ./libtool --silent --tag=CC --mode=link $CC -Wl,--export-dynamic -all-static \
            -Wl,-u,isc__initialize \
            -o multicall/dnsutils \
            multicall/dispatcher.o multicall/obj_*/*.o \
            -ljemalloc -lstdc++ -pthread \
            lib/isc/libisc.la lib/dns/libdns.la lib/ns/libns.la lib/isccfg/libisccfg.la \
            -lidn2 -lunistring -lpthread \
            -lurcu-common -lurcu -lurcu-common -lurcu-cds \
            -ledit -lncurses
        ''
      }
    '';

    # Replace upstream install entirely — it would relink the standalone tools,
    # which now fail (main renamed). We ship the one multicall + man pages.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/man/man1"
      install -m755 multicall/dnsutils "$out/bin/dnsutils"
      ${pkgs.lib.concatMapStringsSep "\n      "
          (p: ''ln -s dnsutils "$out/bin/${p}"'')
          (pkgs.lib.filter (p: p != "dnsutils") progNames)}
      for m in dig host nslookup delv nsupdate; do
        f=$(find . -name "$m.1" -print -quit 2>/dev/null || true)
        if [ -n "$f" ]; then install -m644 "$f" "$out/share/man/man1/$m.1"; fi
      done
      runHook postInstall
    '';

    # Don't inherit bind's postFixup either — it seds the dev/.pc config that no
    # longer exists. Just drop the propagated-input metadata (leaf artifact).
    postFixup = ''
      rm -rf "$out/nix-support"
    '';
  });
in
lib.withAliases pkgs
  { primary = "dnsutils"; aliasesFromSymlinksIn = "bin"; }
  multicall
