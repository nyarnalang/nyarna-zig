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
    handler_gen = {
      name = "handler_gen";
      file = "build/gen_errorhandler.zig";
      description = "generates error handler functions";
      target = { };
    };
    test_gen = {
      name = "test_gen";
      file = "build/gen_tests.zig";
      description = "generates unit tests from test/data";
      target = { };
      dependencies = [ zigPkgs.tml ];
    };
    testList = builtins.map (kind: {
      name = "${kind}Test";
      description = "Run ${kind} tests";
      file = "test/${kind}_test.zig";
      dependencies = [ zigPkgs.nyarna zigPkgs.testing ];
      generators   = [ handler_gen test_gen ];
    }) ["lex" "parse" "interpret" "load" "output"];
    buildNyarna = {
      pname, src, genTests ? false, ...
    }@args: pkgs.buildZig (args // {
      inherit version src;
      postConfigure = ''
        cat <<EOF >src/generated.zig
        pub const version = "${version}";
        pub const stdlib_path = "$targetSharePath/lib";
        EOF
      '';
    });

    cliExecutable = {
      name         = "nyarna";
      description  = "Nyarna CLI interpreter";
      file         = "src/cli.zig";
      dependencies = [ zigPkgs.clap ];
      generators   = [ handler_gen ];
      install      = true;
    };
    wasmLibrary = {
      name         = "wasm";
      description  = "Nyarna WASM library";
      file         = "src/wasm.zig";
      target       = {
        cpu_arch = "wasm32";
        os_tag = "freestanding";
      };
      install = true;
      generators = [ handler_gen ];
    };

    nyarna_cli = buildNyarna {
      pname = "nyarna";
      src = filter.lib.filter {
        root = ./.;
        exclude = [ ./flake.nix ./flake.lock ./src/wasm.zig ./src/nyarna.js ];
      };
      genTests = true;
      zigExecutables = [ handler_gen test_gen cliExecutable ];
      zigTests = testList;
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
        exclude = [ ./flake.nix ./flake.lock ./build/gen_tests.zig ./src/cli.zig ./test ];
      };
      zigExecutables = [ handler_gen ];
      zigLibraries = [ wasmLibrary ];
    }).overrideAttrs (_: {
      checkPhase = "";
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
      zigExecutables = [ handler_gen test_gen cliExecutable ];
      zigLibraries = [ wasmLibrary ];
      zigTests = testList;
      vscode_launch_json = builtins.toJSON {
        version = "0.2.0";
        configurations = builtins.map(test: {
          name = "(lldb) ${test.name}";
          type = "cppdbg";
          request = "launch";
          program = ''''${workspaceFolder}/${test.name}'';
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
      cli_win64 = pkgs.packageForWindows nyarna_cli {
        targetSystem = "x86_64-windows";
      };
      wasm = nyarna_wasm;
    };
    defaultPackage = nyarna_cli;
    inherit devShell;
  });
}