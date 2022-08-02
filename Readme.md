# Reference Nyarna Implementation

This is the reference [Nyarna][3] implementation, written in Zig.

## Development

[Nix Flakes][1] are used as build system.
Refer to the linked documentation for instructions on enabling Nix Flakes.
Released source tarballs contain all generated files so that you can compile the source without Nix (useful for OSes without Nix support, e.g. Windows).

`nix build .#nyarna_cli` builds the command-line executable.

`nix develop` starts a bash session where you can do:

 * `eval "$configurePhase"` to generate source files
 * `eval "$buildPhase"` to compile (requires generated sources)
 * `eval "$checkPhase"` to run the tests.

This should be easier but is currently blocked by [this Nix issue][2].
Typical development workflow is to do `eval "$configurePhase"` which gives you a `build.zig` and then use that.

### Debugging

After configuring, you can generate the tests and can also debug them:

 * `zig build outputTest -Demit_bin=true` will give you an executable `outputTest`
 * use `-Dtest-filter="Schema extension"` to run only a specific test.
 * use `lldb -- ./outputTest $(which zig)` to debug a test executable (lldb is not available by default).

The `configurePhase` also generates a `.vscode` folder usable with [Visual Studio Code][4]. It requires `lldb` available on your PATH.
With this, you can debug the test binaries in VSCode – you need to have generated them before as described above.

## License

[MIT](/License.md)

 [1]: https://nixos.wiki/wiki/Flakes
 [2]: https://github.com/NixOS/nix/issues/6202
 [3]: https://nyarna.org
 [4]: https://code.visualstudio.com