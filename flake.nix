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
        zicross.overlays.zig
        zicross.overlays.debian
        zicross.overlays.windows
      ];
    };
    zig-clap = pkgs.fetchFromGitHub {
      owner = "Hejsil";
      repo  = "zig-clap";
      rev   = "511b357b9fd6480f46cf2a52b1d168471d1ec015";
      sha256 = "28RH8i4hWzx2nqseIUZ+Qy+juhZx4Ix+bAlzZu6ZHtk=";
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
    src = filter.lib.filter {
      root = ./.;
      exclude = [ ./flake.nix ./flake.lock ];
    };
    testList = ["lex" "parse" "interpret" "load" "output"];
    generators = pkgs.buildZig {
      pname = "nyarna-codegen";
      inherit version src;
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
      pname, ...
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
        echo "generating tests…"
        ${generators}/bin/test_gen
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
      zigExecutables = [ cliExecutable ];
      preInstall = ''
        mkdir -p $out/share
        cp -r lib $out/share/
      '';
    };

    nyarna_wasm = (buildNyarna {
      pname = "nyarna-wasm";
      inherit version src;
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
      inherit version src;
      zigExecutables = [ cliExecutable ];
      zigLibraries = [ wasmLibrary ];
      vscode_launch_json = builtins.toJSON {
        version = "0.2.0";
        configurations = builtins.map(name: {
          name = "(lldb) ${name}Test";
          type = "lldb";
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