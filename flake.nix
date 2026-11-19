{
  description = "BIND 9 DNS client tools (dig, host, nslookup, delv, nsupdate, mdig) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # The DNS client programs from ISC BIND 9: dig, host, nslookup, delv,
  # nsupdate and mdig. The unpin-llvm engine captures each program's link and
  # the standalone folds them into one `dnsutils`, on Linux and darwin alike.
  #
  # bind's configure refuses a static build (patches/allow-static-link.patch);
  # the client programs use none of the dlopen machinery the guard protects
  # (named's dyndb/plugins/dnstap). Only lib/ and the client bin dirs are built.
  # aarch64-darwin can't be checked by the local cross helper (bind's `gen`
  # must run on the build host); its source of truth is CI macos-14.
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

      # BIND dropped Windows after 9.16, so there is no windows target.
      engine = "unpin-llvm";
      multicall = {
        # krb5 bakes its own store path into the library as install-time
        # defaults (a second krb5.conf after /etc/krb5.conf, the plugin dir,
        # the locale dir); a static binary loads no plugins and ships no
        # catalogs, so they are dead.
        removeReferences = [ "krb5-" ];
        programs = [
          { name = "dig"; }
          { name = "host"; }
          { name = "nslookup"; }
          { name = "delv"; }
          { name = "nsupdate"; }
          { name = "mdig"; }
        ];
      };

      build = pkgs:
        let
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          # openssl (OPENSSLDIR=/etc/ssl, so dig +tls uses the host trust store)
          # and ncurses (FHS terminfo dir + ~35 built-in fallbacks) come already
          # retargeted from nix-lib's native-overlay; libedit gives nslookup and
          # nsupdate line editing without GNU readline's GPL.
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
          # bind takes GSSAPI's link flags from `krb5-config --libs gssapi`,
          # which omits what a static libkrb5 needs (libkrb5support, and
          # libkeyutils for the kernel keyring cache).
          krb5Config = pkgs.buildPackages.writeShellScript "krb5-config" ''
            out=$(${pkgsS.libkrb5.dev}/bin/krb5-config "$@") || exit
            case " $* " in *" --libs "*) out="$out -lkrb5support -lkeyutils" ;; esac
            echo "$out"
          '';
          bindStatic = (pkgsS.bind.override ({
            libxml2 = null;
            # GSS-TSIG (`nsupdate -g`) needs krb5, and on darwin `krb5-static`
            # fails to link (undefined CCAPI symbols in its macOS cache
            # backend, `cc_api_macos.o`).
            enableGSSAPI = !isDarwin;
            # dnstap is force-disabled below (`--disable-dnstap`), so its two deps
            # — fstrm and protobuf-c — are dead build inputs. bind lists them
            # unconditionally, but on darwin `protobuf-c-static` doesn't even
            # build (its `protoc-gen-c` link drops the CoreFoundation framework
            # abseil/cctz's `local_time_zone()` needs). Drop both inputs: fixes
            # darwin and trims an unused chunk of the closure on every platform.
            fstrm = null;
            protobufc = null;
            # jemalloc is an allocator for the long-running `named`; the client
            # programs run for milliseconds. It also pulls -lstdc++, which the
            # engine (libc++) lacks, and its strerror_r probe fails on darwin.
            jemalloc = null;
          })).overrideAttrs (old: ({
            # libedit isn't a bind.override parameter; pkg-config finds it and
            # `--with-readline=libedit` wires it in.
            buildInputs = (old.buildInputs or [ ]) ++ [ pkgsS.libedit pkgsS.ncurses ]
              ++ pkgs.lib.optional (!isDarwin) pkgsS.keyutils;
            # patches/allow-static-link.patch: bind's configure refuses a
            # static build. patches/isc-initialize-fold.patch: libisc's
            # constructor must reach every program in the fold, once.
            patches = (old.patches or [ ]) ++ [
              ./patches/allow-static-link.patch
              ./patches/isc-initialize-fold.patch
            ];
            # dnstap (fstrm/protobuf-c) has no upstream toggle and its static link
            # is fragile; the dnsutils client tools don't use it. Force it off.
            configureFlags =
              (map
                (f: if pkgs.lib.hasPrefix "--with-gssapi=" f then "--with-gssapi=${krb5Config}" else f)
                (builtins.filter
                  (f: f != "--enable-dnstap")
                  (old.configureFlags or [ ])))
              ++ [
                "--disable-dnstap"
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
              ;
          }
          # Build and install only the client programs and their man pages,
          # never named and the server tools (C++, programs we don't ship).
          //
          {
            outputs = [ "out" ];
            meta = (old.meta or { }) // { outputsToInstall = [ "out" ]; };
            buildPhase = ''
              runHook preBuild
              make bind.keys.h
              # libns bakes -DNAMED_PLUGINDIR=$(pkglibdir) into hooks.c and delv
              # links libns: point it at a system path so no store path is kept.
              make -C lib -j$NIX_BUILD_CORES pkglibdir=/usr/lib/bind
              make -C bin/dig -j$NIX_BUILD_CORES dig host nslookup
              make -C bin/delv -j$NIX_BUILD_CORES delv
              make -C bin/nsupdate -j$NIX_BUILD_CORES nsupdate
              make -C bin/tools -j$NIX_BUILD_CORES mdig
              # nsupdate.1 names $(sysconfdir)/named.conf, otherwise a store path.
              make -C doc/man -j$NIX_BUILD_CORES sysconfdir=/etc dig.1 host.1 nslookup.1 delv.1 nsupdate.1 mdig.1
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/share/man/man1"
              for t in bin/dig/dig bin/dig/host bin/dig/nslookup \
                       bin/delv/delv bin/nsupdate/nsupdate bin/tools/mdig; do
                install -m755 "$t" "$out/bin/$(basename "$t")"
              done
              for m in dig host nslookup delv nsupdate mdig; do
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
            # Our installPhase already puts every program in $out/bin.
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
