{
  inputs = {
    zicross.url = "github:flyx/Zicross";
    nixpkgs.follows = "zicross/nixpkgs";
    utils.url = "github:numtide/flake-utils";
    filter.url = "github:numtide/nix-filter";
  };
  outputs = { self, zicross, utils, filter, nixpkgs }:
    with utils.lib;
    eachSystem allSystems (system:
      let
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
        version = if release then
          version_base
        else
          "${version_base}-${self.shortRev or self.lastModifiedDate}";

        # hash of the dependencies in build.zig.zon (zig-clap).
        # set to "" and build to get the new hash after changing them.
        zigDepsHash = "sha256-DxNZw68RIExGcWFmL6Q/ks67dSQQSdKo5P4U9sPZfZg=";

        buildNyarna = { pname, src, ... }@args:
          pkgs.buildZig ({
            inherit version zigDepsHash;
            zigBuildFlags = [ "-Dversion=${version}" ];
            # the stdlib path is compiled into the CLI if it is absolute.
            # otherwise, the CLI searches the stdlib relative to its own
            # executable (this is the case for Windows packages).
            postConfigure = ''
              if [[ "$targetSharePath" = /* ]]; then
                zigFlags+=("-Dstdlib_path=$targetSharePath/lib")
              fi
            '';
          } // args);

        nyarna_cli = buildNyarna {
          pname = "nyarna";
          src = filter.lib.filter {
            root = ./.;
            exclude = [ ./flake.nix ./flake.lock ./src/nyarna.js ];
          };
          doCheck = true;
        };

        nyarna_wasm = (buildNyarna {
          pname = "nyarna-wasm";
          src = filter.lib.filter {
            root = ./.;
            exclude = [ ./flake.nix ./flake.lock ];
          };
          zigBuildFlags = [ "-Dversion=${version}" "wasm" ];
          doCheck = false;
        }).overrideAttrs (_: {
          installPhase = ''
            runHook preInstall
            mkdir -p $out/www
            cp zig-out/lib/wasm.wasm $out/www/nyarna.wasm
            cp src/nyarna.js $out/www/nyarna.js
            runHook postInstall
          '';
        });

        devShell = pkgs.mkShell {
          packages = [ pkgs.zig ];
          vscode_launch_json = builtins.toJSON {
            version = "0.2.0";
            configurations = builtins.map (kind: {
              name = "(lldb) ${kind}Test";
              type = "cppdbg";
              request = "launch";
              program = "\${workspaceFolder}/zig-out/bin/${kind}Test";
              args = [ ];
              cwd = "\${workspaceFolder}";
              externalConsole = false;
              MIMode = "lldb";
              environment = [{
                name = "NYARNA_STDLIB_PATH";
                value = "\${workspaceFolder}/lib";
              }];
            }) [ "lex" "parse" "interpret" "load" "output" ];
          };
          # test executables for debugging are created with
          # `zig build -Demit_bin=true`.
          shellHook = ''
            mkdir -p .vscode
            printenv vscode_launch_json >.vscode/launch.json
          '';
        };
      in {
        packages = rec {
          cli = nyarna_cli;
          cli_win64 = pkgs.packageForWindows nyarna_cli {
            targetSystem = "x86_64-windows";
          };
          wasm = nyarna_wasm;
          default = cli;
        };
        devShells.default = devShell;
      });
}
