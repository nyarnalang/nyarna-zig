const std = @import("std");

const clap = @import("clap");

const generated = @import("generated.zig");
const nyarna    = @import("nyarna.zig");

const Input = union(enum) {
  file: struct {
    fs_res : nyarna.Loader.FileSystemResolver,
    name   : []const u8,
  },
  stdin: nyarna.Loader.SingleResolver,

  fn fromName(input: []const u8, alloc: std.mem.Allocator) !Input {
    if (std.mem.eql(u8, input, "-")) {
      var list = std.ArrayList(u8).init(alloc);
      try std.io.getStdIn().reader().readAllArrayList(&list, 65535);
      try list.appendSlice("\x04\x04\x04\x04");
      return Input{
        .stdin = nyarna.Loader.SingleResolver.init(list.items),
      };
    } else {
      const dirname = std.fs.path.dirname(input).?;
      // strip ".ny" from file name
      const filename = std.fs.path.basename(input);
      return Input{.file = .{
        .fs_res = nyarna.Loader.FileSystemResolver.init(dirname),
        .name   = filename[0..filename.len - 3],
      }};
    }
  }

  fn name(self: @This()) []const u8 {
    return switch (self) {
      .stdin => "",
      .file  => |f| f.name,
    };
  }

  fn resolver(self: *@This()) *nyarna.Loader.Resolver {
    return switch (self.*) {
      .stdin => |*s| &s.api,
      .file  => |*f| &f.fs_res.api,
    };
  }
};

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

  const stdlib_path =
    std.os.getenv("NYARNA_STDLIB_PATH") orelse generated.stdlib_path;
  var stdlib_resolver = nyarna.Loader.FileSystemResolver.init(stdlib_path);
  var terminal = nyarna.errors.Terminal.init(std.io.getStdErr());

  var proc = try nyarna.Processor.init(
    std.heap.page_allocator, nyarna.default_stack_size, &terminal.reporter,
    &stdlib_resolver.api);
  defer proc.deinit();

  var loader: *nyarna.Loader.Main = blk: {
    var cur_loader: ?*nyarna.Loader.Main = null;
    var cur_name: ?[]const u8 = null;
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
          \\<arg>... must be an alternating list of `--<name> <value>`.
          \\Unnamed values are not allowed.
          \\
          \\Argument values are parsed as Nyarna code with the types in
          \\the Schema of <file> implicitly imported.
        ++ "\n");
        return hr;
      } else if (arg.param == &params[1]) {
        try std.io.getStdOut().writer().print(
          \\ nyarna-zig, reference Nyarna implementation
          \\ Version: {s}
          \\ Stdlib : {s}
        ++ "\n", .{generated.version, generated.stdlib_path});
        return;
      } else if (arg.param == &params[2] and cur_loader == null) {
        const main_path = if (std.mem.eql(u8, arg.value.?, "-")) "-" else (
          std.fs.realpathAlloc(arena.allocator(), arg.value.?)
        ) catch |err| {
          const writer = std.io.getStdErr().writer();
          switch (err) {
            error.FileNotFound => try writer.print(
              "unknown file: {s}\n", .{arg.value.?}),
            error.AccessDenied => try writer.print(
              "cannot access file: {s}\n", .{arg.value.?}),
            error.FileTooBig => try writer.print(
              "file too big: {s}\n", .{arg.value.?}),
            error.IsDir => try writer.print(
              "given path is a directory: {s}\n", .{arg.value.?}),
            else => return err,
          }
          std.os.exit(1);
        };
        var input = try Input.fromName(main_path, arena.allocator());
        cur_loader = try proc.startLoading(input.resolver(), input.name());
        parser.state = .rest_are_positional;
      } else {
        if (cur_name) |name| {
          try cur_loader.?.pushArg(name, arg.value.?);
          cur_name = null;
        } else {
          const content = arg.value.?;
          if (content.len < 3 or !std.mem.eql(u8, "--", content[0..2])) {
            const writer = std.io.getStdErr().writer();
            try writer.print(
              \\invalid param name: '{s}' (must start with '--' and have non-empty name)
            ++ "\n", .{content});
            std.os.exit(1);
          }
          cur_name = content[2..];
        }
      }
    }
    break :blk cur_loader orelse {
      var input = try Input.fromName("-", arena.allocator());
      break :blk try proc.startLoading(input.resolver(), input.name());
    };
  };

  if (try loader.finalize()) |container| {
    defer container.destroy();
    if (try container.process()) {
      for (container.documents.items) |output| {
        var file: ?std.fs.File = null;
        defer if (file) |f| f.close();
        var writer = if (std.mem.eql(u8, output.name.content, "")) (
          std.io.getStdOut().writer()
        ) else blk: {
          const f = try std.fs.cwd().openFile(
            output.name.content, .{.write = true});
          file = f;
          break :blk f.writer();
        };
        switch (output.body.data) {
          .text => |*txt| {
            try writer.writeAll(txt.content);
            // unix requirement: all text files are to end with a line break.
            try writer.writeByte('\n');
          },
          else => {
            std.debug.panic("unsupported non-text output: {s}",
              .{@tagName(output.body.data)});
          },
        }
      }
    } else std.os.exit(1);
  } else std.os.exit(1);
}