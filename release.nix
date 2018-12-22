{ nixpkgs ? <nixpkgs>
, systems ? [ "x86_64-linux" "i686-linux" ]
}:

let
  lib = import "${nixpkgs}/lib";

  # This is with all the *required* dependencies only.
  withSystem = fun: system: let
    pkgs = import nixpkgs { inherit system; };
    attrs = fun pkgs;
  in pkgs.stdenv.mkDerivation (attrs // rec {
    inherit (import ./. { inherit pkgs; }) name version src;

    mesonFlags = [ "-Dtest-timeout=3600" ] ++ attrs.mesonFlags or [];

    nativeBuildInputs = [ pkgs.meson pkgs.ninja pkgs.pkgconfig ]
                     ++ attrs.nativeBuildInputs or [];
    buildInputs = [ pkgs.libyamlcpp ] ++ attrs.buildInputs or [];

    doCheck = attrs.doCheck or true;

    doInstallCheck = attrs.doInstallCheck or true;
    installCheckPhase = attrs.installCheckPhase or ''
      found=0
      for man in "$out/share/man/man1"/ip2unix.1*; do
        test -s "$man" && found=1
      done
      expected=${if attrs.requireManpage or true then "1" else "0"}
      if [ $found -ne $expected ]; then
        echo "ASSERTION: Manpage found($found) != expected($expected)" >&2
        exit 1
      fi
    '';
  });

  # Bare minimum dependencies plus pytest for integration tests.
  withSystemAndTests = fun: system: let
    funWithTests = pkgs: let
      funAttrs = fun pkgs;
    in funAttrs // {
      nativeBuildInputs = [
        pkgs.python3Packages.pytest pkgs.python3Packages.pytest-timeout
      ] ++ funAttrs.nativeBuildInputs or [];
      postConfigure = ''
        grep -qF 'Program pytest found: YES' meson-logs/meson-log.txt
        ${funAttrs.postConfigure or ""}
      '';
    };
  in withSystem funWithTests system;

  # All the dependencies including optional ones.
  withSystemFull = fun: system: let
    funFull = pkgs: let
      funAttrs = fun pkgs;
    in funAttrs // {
      nativeBuildInputs = [
        pkgs.asciidoc pkgs.libxslt.bin pkgs.docbook_xml_dtd_45 pkgs.docbook_xsl
        pkgs.libxml2.bin pkgs.docbook5 pkgs.systemd
      ] ++ funAttrs.nativeBuildInputs or [];
      postConfigure = ''
        grep -qF 'Program systemd-socket-activate found: YES' \
          meson-logs/meson-log.txt
        ${funAttrs.postConfigure or ""}
      '';
    };
  in withSystemAndTests funFull system;

  forEachSystem = fun: lib.genAttrs systems (withSystem fun);
  testForEachSystem = fun: lib.genAttrs systems (withSystemAndTests fun);
  fullForEachSystem = fun : lib.genAttrs systems (withSystemFull fun);

  mkManpageJobs = attrsFun: {
    no-manpage = testForEachSystem (pkgs: (attrsFun pkgs) // {
      requireManpage = false;
    });

    asciidoc.with-validation = testForEachSystem (pkgs: (attrsFun pkgs) // {
      nativeBuildInputs = [
        pkgs.libxslt.bin pkgs.docbook_xml_dtd_45 pkgs.docbook_xsl
        pkgs.libxml2.bin pkgs.docbook5

        # We want to pass the -v argument to a2x so that if we get a validation
        # error it's actually shown in the build log. The reason we don't do
        # this by default is because it would cause unnecessary build output
        # when built on other systems.
        (pkgs.runCommand "a2x-wrapped" {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          a2x = "${pkgs.asciidoc}/bin/a2x";
        } ''
          mkdir -p "$out/bin"
          makeWrapper "$a2x" "$out/bin/a2x" --add-flags -v
          ln -s ${lib.escapeShellArg pkgs.asciidoc}/bin/asciidoc "$out/bin"
        '')
      ] ++ (attrsFun pkgs).nativeBuildInputs or [];
      postConfigure = ''
        grep -qF 'Program xmllint found: YES' meson-logs/meson-log.txt
        ${(attrsFun pkgs).postConfigure or ""}
      '';
    });

    asciidoc.without-validation = testForEachSystem (pkgs: (attrsFun pkgs) // {
      nativeBuildInputs = [
        pkgs.asciidoc pkgs.libxslt.bin pkgs.docbook_xml_dtd_45 pkgs.docbook_xsl
      ] ++ (attrsFun pkgs).nativeBuildInputs or [];
      postConfigure = ''
        grep -qF 'Program a2x found: YES' meson-logs/meson-log.txt
        ${(attrsFun pkgs).postConfigure or ""}
      '';
    });

    asciidoctor = testForEachSystem (pkgs: (attrsFun pkgs) // {
      nativeBuildInputs = [ pkgs.asciidoctor ]
                       ++ (attrsFun pkgs).nativeBuildInputs or [];
      postConfigure = ''
        grep -qF 'Program asciidoctor found: YES' meson-logs/meson-log.txt
        ${(attrsFun pkgs).postConfigure or ""}
      '';
    });
  };

  tests.configurations = {
    minimal.no-tests = forEachSystem (lib.const { requireManpage = false; });
    minimal.tested = testForEachSystem (lib.const { requireManpage = false; });

    systemd = mkManpageJobs (pkgs: {
      nativeBuildInputs = [ pkgs.systemd ];
      postConfigure = ''
        grep -qF 'Program systemd-socket-activate found: YES' \
          meson-logs/meson-log.txt
      '';
    });
    no-systemd = mkManpageJobs (lib.const {
      mesonFlags = [ "-Dsystemd-support=false" ];
    });

    # This is to make sure AsciiDoc is picked over Asciidoctor when generating
    # the manpage.
    default-asciidoc = forEachSystem (pkgs: {
      requireManpage = true;
      nativeBuildInputs = [
        pkgs.libxslt.bin pkgs.docbook_xml_dtd_45 pkgs.docbook_xsl
        pkgs.libxml2.bin pkgs.docbook5 pkgs.asciidoc
        (pkgs.writeScriptBin "asciidoctor" "#!${pkgs.stdenv.shell}\nexit 1")
      ];
    });
  };

  tests.full = fullForEachSystem (lib.const {});

  tests.repeat100 = fullForEachSystem (pkgs: {
    checkPhase = ''
      meson test --print-errorlogs --repeat=100
    '';
  });

  coverage = fullForEachSystem (pkgs: {
    nativeBuildInputs = [ pkgs.lcov ];

    mesonFlags = [ "-Db_coverage=true" ];

    installPhase = ''
      ninja coverage-html 2>&1 | tee metrics.log >&2

      mkdir -p "$out/nix-support"
      sed -n -e '/^Overall coverage rate:$/,/^[^ ]/ {
        s/^ \+lines\.*: \([0-9.]\+\)%.*/lineCoverage \1 %/p
        s/^ \+functions\.*: \([0-9.]\+\)%.*/functionCoverage \1 %/p
      }' metrics.log > "$out/nix-support/hydra-metrics"

      if $(wc -l < "$out/nix-support/hydra-metrics") -ne 2; then
        echo "Failed to get coverage statistics." >&2
        exit 1
      fi

      mv meson-logs/coveragereport "$out/coverage"
      echo "report coverage $out/coverage" \
        > "$out/nix-support/hydra-build-products"
    '';

    doInstallCheck = false;
  });

  jobs = {
    inherit tests coverage;
  };

in jobs // {
  badge = import nix/badge.nix {
    pkgs = import nixpkgs {};
    constituents = lib.collect lib.isDerivation jobs;
    purgeUrl = "https://camo.githubusercontent.com/"
             + "db651432b76ed2a8e41ced794713cce2acdfed27/"
             + "68747470733a2f2f68656164636f756e7465722e6f72672f68796472612f6a"
             + "6f622f697032756e69782f6d61737465722f62616467652f6c61746573742d"
             + "66696e69736865642f646f776e6c6f61642f312f7374617475732e737667";
  };
}
