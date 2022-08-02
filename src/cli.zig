const std = @import("std");

const clap = @import("clap");

const generated = @import("generated.zig");
const nyarna    = @import("nyarna.zig");

pub fn main() !void {
  var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  defer arena.deinit();

  const params = comptime [_]clap.Param(clap.Help){
    clap.parseParam("-h, --help     Display this help and exit.") catch unreachable,
    clap.parseParam("-v, --version  Output version information and exit.") catch unreachable,
    clap.parseParam("<file>         The file to be interpreted. '-' for stdin.") catch unreachable,
    clap.parseParam("<arg>...       Nyarna arguments for interpreting <file>.") catch unreachable,
  };

  var iter = try clap.args.OsIterator.init(arena.allocator());
  defer iter.deinit();
  var diag = clap.Diagnostic{};
  var parser = clap.StreamingClap(clap.Help, clap.args.OsIterator){
    .params     = &params,
    .iter       = &iter,
    .diagnostic = &diag,
  };

  var main_path: ?[]const u8 = null;

  while (parser.next() catch |err| {
    diag.report(std.io.getStdErr().writer(), err) catch unreachable;
    std.os.exit(1);
  }) |arg| {
    if (arg.param == &params[0]) {
      try std.io.getStdOut().writer().writeAll(
        \\nyarna [<option>...] <file> [<arg>...]
        \\Reference Nyarna interpreter.
        \\
      ++ "\n");
      const hr = clap.help(std.io.getStdOut().writer(), &params);
      try std.io.getStdOut().writer().writeAll(
        \\
        \\<arg>... can contain argument names like `--<name>`, which make the
        \\following argument value a named argument. Restrictions on positional
        \\after named arguments apply just like in Nyarna code.

        \\Argument values are parsed as Nyarna code with the types in
        \\the Schema of <file> implicitly imported.
      ++ "\n");
      return hr;
    } else if (arg.param == &params[1]) {
      try std.io.getStdOut().writer().writeAll(
        \\ nyarna-zig, reference Nyarna implementation
        \\ Version:
      ++ generated.version ++ "\n");
      return;
    } else if (arg.param == &params[2]) {
      main_path = try std.fs.realpathAlloc(arena.allocator(), arg.value.?);
      parser.state = .rest_are_positional;
    } else if (arg.param == &params[3]) {
      std.debug.panic("command line arguments not implemented", .{});
    } else unreachable;
  }

  const stdlib_path =
    std.os.getenv("NYARNA_STDLIB_PATH") orelse generated.stdlib_path;
  var stdlib_resolver = nyarna.Loader.FileSystemResolver.init(stdlib_path);

  var terminal = nyarna.errors.Terminal.init(std.io.getStdErr());
  var proc = try nyarna.Processor.init(
    std.heap.page_allocator, nyarna.default_stack_size, &terminal.reporter,
    &stdlib_resolver.api);
  defer proc.deinit();

  var fs_resolver =
    nyarna.Loader.FileSystemResolver.init(std.fs.path.basename(main_path.?));

  _ = fs_resolver;

  var loader = try proc.startLoading(&fs_resolver.api, main_path.?);
  if (try loader.finalize()) |container| {
    defer container.destroy();
    if (try container.process()) {
      for (container.documents.items) |output| {
        var file: ?std.fs.File = null;
        defer if (file) |f| f.close();
        var writer = if (std.mem.eql(u8, output.name.content, "")) (
          std.io.getStdOut().writer()
        ) else blk: {
          const f = try std.fs.openFileAbsolute(main_path.?, .{.write = true});
          file = f;
          break :blk f.writer();
        };
        switch (output.body.data) {
          .text => |*txt| try writer.writeAll(txt.content),
          else => {
            std.debug.panic("unsupported non-text output: {s}",
              .{@tagName(output.body.data)});
          },
        }
      }
    } else std.os.exit(1);
  } else std.os.exit(1);
}