{
  inputs = {
    zicross.url = github:flyx/Zicross;
    utils.url   = github:numtide/flake-utils;
    filter.url  = github:numtide/nix-filter;
    nixpkgs.url = github:NixOS/nixpkgs/nixos-22.05;
  };
  outputs = {self, zicross, utils, filter, nixpkgs}:
      with utils.lib; eachSystem allSystems (system: let
    # edit these when releasing
    version_base = "0.1.0";
    release = false;

    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        (zicross.lib.zigOverlayFor {
          version = "2022-08-16";
          master = true;
          patchArmHeader = false;
        })
        zicross.overlays.debian
        zicross.overlays.windows
      ];
    };
    zig-clap = pkgs.fetchFromGitHub {
      owner = "Hejsil";
      repo  = "zig-clap";
      rev   = "1c09e0dc31918dd716b1032ad3e1d1c080cbbff1";
      sha256 = "5fUOIWsIS9G9TET0YfZH51SQVQUHp2DJfglmSERxql4=";
    };
    zigPkgs = rec {
      clap = {
        name = "clap";
        src  = zig-clap;
        main = "clap.zig";
        dependencies = [ ];
      };
      nyarna = {
        name = "nyarna";
        main = "src/nyarna.zig";
        dependencies = [ ];
      };
      testing = {
        name = "testing";
        main = "test/testing.zig";
        dependencies = [ nyarna ];
      };
      tml = {
        name = "tml";
        main = "test/tml.zig";
      };
    };
    version = if release then version_base else "${version_base}-${self.shortRev or self.lastModifiedDate}";
    testList = ["lex" "parse" "interpret" "load" "output"];
    generators = pkgs.buildZig {
      pname = "nyarna-codegen";
      inherit version;
      src = filter.lib.filter {
        root = ./.;
        include = [
          (filter.lib.inDirectory ./build)
          ./src/nyarna/errors/ids.zig
          ./src/nyarna/model/lexing.zig
          (filter.lib.inDirectory ./test)
        ];
      };

      zigExecutables = [ {
        name = "handler_gen";
        file = "build/gen_errorhandler.zig";
      } {
        name = "test_gen";
        file = "build/gen_tests.zig";
        dependencies = [ zigPkgs.tml ];
      } ];
    };
    buildNyarna = {
      pname, src, genTests ? false, ...
    }@args: pkgs.buildZig (args // {
      inherit version src;
      zigTests = builtins.map (kind: {
        name = "${kind}Test";
        description = "Run ${kind} tests";
        file = "test/${kind}_test.zig";
        dependencies = [ zigPkgs.nyarna zigPkgs.testing ];
      }) testList;
      postConfigure = ''
        cat <<EOF >src/generated.zig
        pub const version = "${version}";
        pub const stdlib_path = "$targetSharePath/lib";
        EOF
        echo "generating error handler…"
        ${generators}/bin/handler_gen
        ${if genTests then ''
        echo "generating tests…"
        ${generators}/bin/test_gen
        '' else ""}
      '';
    });

    cliExecutable = {
      name         = "nyarna";
      description  = "Nyarna CLI interpreter";
      file         = "src/cli.zig";
      dependencies = [ zigPkgs.clap ];
    };
    wasmLibrary = {
      name         = "wasm";
      description  = "Nyarna WASM library";
      file         = "src/wasm.zig";
    };

    nyarna_cli = buildNyarna {
      pname = "nyarna";
      src = filter.lib.filter {
        root = ./.;
        exclude = [ ./flake.nix ./flake.lock ./build ./src/wasm.zig ./src/nyarna.js ];
      };
      genTests = true;
      zigExecutables = [ cliExecutable ];
      preInstall = ''
        mkdir -p $out/share
        cp -r lib $out/share/
      '';
    };

    nyarna_wasm = (buildNyarna {
      pname = "nyarna-wasm";
      inherit version;
      src = filter.lib.filter {
        root = ./.;
        exclude = [ ./flake.nix ./flake.lock ./build ./src/cli.zig ./test ];
      };

      zigLibraries = [ wasmLibrary ];
      ZIG_TARGET = "wasm32-freestanding";
    }).overrideAttrs (_: {
      installPhase = ''
        mkdir -p $out/www
        cp zig-out/lib/wasm.wasm $out/www/nyarna.wasm
        cp src/nyarna.js $out/www/nyarna.js
      '';
    });

    devShell = buildNyarna {
      pname = "nyarna-devenv";
      inherit version;
      genTests = true;
      src = filter.lib.filter {
        root = ./.;
        exclude = [ ./flake.nix ./flake.lock ];
      };
      zigExecutables = [ cliExecutable ];
      zigLibraries = [ wasmLibrary ];
      vscode_launch_json = builtins.toJSON {
        version = "0.2.0";
        configurations = builtins.map(name: {
          name = "(lldb) ${name}Test";
          type = "cppdbg";
          request = "launch";
          program = ''''${workspaceFolder}/${name}Test'';
          args = [ "${pkgs.zig}/bin/zig" ];
          cwd = ''''${workspaceFolder}'';
          externalConsole = false;
          MIMode = "lldb";
          environment = [
            {
              name  = "NYARNA_STDLIB_PATH";
              value = ''''${workspaceFolder}/lib'';
            }
          ];
        }) testList;
      };
      preConfigure = ''
        mkdir -p .vscode
        printenv vscode_launch_json >.vscode/launch.json
      '';
      installPhase = ''
        echo "dev env doesn't support install, use `zig build`."
        exit 1
      '';
    };
  in {
    packages = {
      cli  = nyarna_cli;
      wasm = nyarna_wasm;
    };
    defaultPackage = nyarna_cli;
    inherit devShell;
  });
}