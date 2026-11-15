# Reference Nyarna Implementation

This is the reference [Nyarna][3] implementation, written in Zig.

## Building

Nyarna requires Zig 0.17.1.
It uses a standard `build.zig`, so with Zig installed, you can do

    zig build

to get the CLI in `zig-out/bin` and the standard library in `zig-out/share/lib`.
The CLI searches the standard library at `../share/lib` relative to its executable.
You can give a different path at compile time with `-Dstdlib_path=<path>`
or at runtime with the environment variable `NYARNA_STDLIB_PATH`.

Alternatively, [Nix Flakes][1] can be used, which pin the versions of Zig and third-party libraries.
You can install Nix on most Linux distributions and macOS.
With Nix installed and Flakes enabled, you can simply do

    nix build github:nyarnalang/nyarna-zig#cli

to get the CLI in `result`.

## Windows

You can cross-compile to Windows on a Nix host (e.g. WSL) by doing

    nix build github:nyarnalang/nyarna-zig#cli_win64

which generates a zip file you can extract.
After that, you can open a terminal and execute `bin/nyarna.exe` from the extraction directory.

## Development

Assumes being in checked-out repository.

`nix build .#cli` builds the command-line executable.

`nix build .#wasm` builds the WASM library with JavaScript interface used for the tour on the website.

`nix develop` starts a shell with the right Zig version, where you can do:

 * `zig build` to build the CLI.
 * `zig build wasm` to build the WASM library into `zig-out/lib`.
 * `zig build test` to run all tests.
   `zig build lexTest` (or `parseTest`, `interpretTest`, `loadTest`, `outputTest`) runs only one kind of test.

The build generates `src/nyarna/errors/Handler.zig` and `test/*_test.zig`, which are not checked in.

### Debugging

 * `zig build test -Demit_bin=true` will additionally install executables for all tests into `zig-out/bin`.
 * use `-Dtest-filter="Schema extension"` to run only a specific test.
 * use `lldb -- zig-out/bin/outputTest` to debug a test executable (needs lldb on your system).
   Run it from the repository root since the tests load `lib` and `test/data` from there.

`nix develop` also generates a `.vscode` folder usable with [Visual Studio Code][4] that contains debug configurations.
You will need to have configured LLDB in your editor.
There is a configuration available for each test executable – you need to have generated the executable manually as described above.
The tests are not generated automatically by the debug configurations so that you can generate and use filtered executables.

## License

[MIT](/License.md)

 [1]: https://nixos.wiki/wiki/Flakes
 [3]: https://nyarna.org
 [4]: https://code.visualstudio.com