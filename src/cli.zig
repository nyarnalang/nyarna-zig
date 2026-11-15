const std = @import("std");

const clap = @import("clap");

const generated = @import("generated");
const nyarna    = @import("nyarna.zig");

const Input = union(enum) {
  file: struct {
    fs_res : nyarna.Loader.FileSystemResolver,
    name   : []const u8,
  },
  stdin: nyarna.Loader.SingleResolver,

  fn fromName(
    io   : std.Io,
    input: []const u8,
    alloc: std.mem.Allocator,
  ) !Input {
    if (std.mem.eql(u8, input, "-")) {
      var list: std.ArrayList(u8) = .empty;
      var reader = std.Io.File.stdin().readerStreaming(io, &.{});
      try reader.interface.appendRemaining(alloc, &list, .limited(65535));
      try list.appendSlice(alloc, "\x04\x04\x04\x04");
      return Input{
        .stdin = nyarna.Loader.SingleResolver.init(list.items),
      };
    } else {
      const dirname = std.fs.path.dirname(input).?;
      // strip ".ny" from file name
      const filename = std.fs.path.basename(input);
      return Input{.file = .{
        .fs_res = nyarna.Loader.FileSystemResolver.init(io, dirname),
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

/// the stdlib is searched at ../share/lib relative to the executable unless
/// a path has been given at compile time.
fn defaultStdlibPath(
  io   : std.Io,
  alloc: std.mem.Allocator,
) ![]const u8 {
  if (generated.stdlib_path) |path| return path;
  const exe_dir = try std.process.executableDirPathAlloc(io, alloc);
  return try std.fs.path.resolve(alloc, &.{exe_dir, "..", "share", "lib"});
}

pub fn main(init: std.process.Init) !void {
  const io    = init.io;
  const arena = init.arena;

  var stdout_buffer: [4096]u8 = undefined;
  var stdout_impl = std.Io.File.stdout().writer(io, &stdout_buffer);
  const stdout    = &stdout_impl.interface;
  var stderr_impl = std.Io.File.stderr().writerStreaming(io, &.{});
  const stderr    = &stderr_impl.interface;

  const params = comptime clap.parseParamsComptime(
    \\-h, --help           Display this help and exit.
    \\-v, --version        Print version information and exit.
    \\-o, --output <DIR>   Write output documents to <DIR>. default: cwd
    \\--ast                Print AST of file to stdout, then exit.
    \\<FILE>               The file to be interpreted. default: '-' for stdin.
    \\<ARG>...             Nyarna arguments for interpreting <FILE>.
  ++ "");

  var iter = try init.minimal.args.iterateAllocator(arena.allocator());
  defer iter.deinit();
  _ = iter.next();

  var diag = clap.Diagnostic{};
  var parser = clap.streaming.Clap(clap.Help, std.process.Args.Iterator){
    .params     = &params,
    .iter       = &iter,
    .diagnostic = &diag,
  };

  const stdlib_path = init.environ_map.get("NYARNA_STDLIB_PATH") orelse
    try defaultStdlibPath(io, arena.allocator());
  var stdlib_resolver = nyarna.Loader.FileSystemResolver.init(io, stdlib_path);
  var terminal = nyarna.errors.Terminal(*std.Io.Writer, true).init(stderr);

  var proc = try nyarna.Processor.init(
    std.heap.page_allocator, nyarna.default_stack_size, &terminal.reporter,
    &stdlib_resolver.api);
  defer proc.deinit();

  var target_dir: ?std.Io.Dir = null;
  defer if (target_dir) |dir| dir.close(io);

  var print_ast = false;

  var loader: *nyarna.Loader.Main = blk: {
    var cur_loader: ?*nyarna.Loader.Main = null;
    var cur_name: ?[]const u8 = null;
    while (parser.next() catch |err| {
      diag.report(stderr, err) catch unreachable;
      std.process.exit(1);
    }) |arg| {
      if (arg.param == &params[0]) {
        try stdout.writeAll(
          \\nyarna [<option>...] <file> [<arg>...]
          \\Reference Nyarna interpreter.
          \\
        ++ "\n");
        try clap.help(stdout, clap.Help, &params, .{});
        try stdout.writeAll(
          \\
          \\<arg>... must be an alternating list of `--<name> <value>`.
          \\Unnamed values are not allowed.
          \\
          \\Argument values are parsed as Nyarna code with the types in
          \\the Schema of <file> implicitly imported.
        ++ "\n");
        return stdout.flush();
      } else if (arg.param == &params[1]) {
        try stdout.print(
          \\ nyarna-zig, reference Nyarna implementation
          \\ Version: {s}
          \\ Stdlib : {s}
        ++ "\n", .{generated.version, stdlib_path});
        return stdout.flush();
      } else if (arg.param == &params[2]) {
        if (target_dir != null) {
          stderr.print(
            "only one --output directory allowed\n", .{}) catch unreachable;
            std.process.exit(1);
        }
        const dir_opts = std.Io.Dir.OpenOptions{
          .access_sub_paths = true, .follow_symlinks = true,
        };
        target_dir = (
          if (std.fs.path.isAbsolute(arg.value.?)) (
            std.Io.Dir.openDirAbsolute(io, arg.value.?, dir_opts)
          ) else std.Io.Dir.cwd().openDir(io, arg.value.?, dir_opts)
        ) catch |err| {
          stderr.print(
            "cannot access output directory '{s}':\n  {s}\n",
            .{arg.value.?, @errorName(err)}) catch unreachable;
          std.process.exit(1);
        };
      } else if (arg.param == &params[3]) {
        print_ast = true;
      } else if (arg.param == &params[4] and cur_loader == null) {
        const main_path = if (std.mem.eql(u8, arg.value.?, "-")) "-" else (
          std.Io.Dir.cwd().realPathFileAlloc(io, arg.value.?, arena.allocator())
        ) catch |err| {
          const writer = stderr;
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
          std.process.exit(1);
        };
        var input = try Input.fromName(io, main_path, arena.allocator());
        cur_loader = if (print_ast) load: {
          const loader =
            try proc.initMainModule(input.resolver(), input.name(), .out);
          try loader.loader.data.work();
          break :load loader;
        } else try proc.startLoading(input.resolver(), input.name());
        parser.state = .rest_are_positional;
      } else {
        if (cur_name) |name| {
          try cur_loader.?.pushArg(name, arg.value.?);
          cur_name = null;
        } else {
          const content = arg.value.?;
          if (content.len < 3 or !std.mem.eql(u8, "--", content[0..2])) {
            const writer = stderr;
            try writer.print(
              \\invalid param name: '{s}' (must start with '--' and have non-empty name)
            ++ "\n", .{content});
            std.process.exit(1);
          }
          cur_name = content[2..];
        }
      }
    }
    break :blk cur_loader orelse {
      var input = try Input.fromName(io, "-", arena.allocator());
      break :blk try proc.startLoading(input.resolver(), input.name());
    };
  };

  if (print_ast) {
    defer loader.destroy();
    const ml = try loader.finishMainAst();
    defer ml.destroy();
    const node = try ml.finalizeNode();
    try stdout.print("{f}\n", .{node.formatter(loader.loader.data)});
    try stdout.flush();
  } else if (try loader.finalize()) |container| {
    defer container.destroy();
    if (try container.process()) {
      const base_dir = target_dir orelse std.Io.Dir.cwd();
      for (container.documents.items) |output| {
        if (
          if (output.schema) |schema| schema.backend != null else false
        ) continue;
        var file: ?std.Io.File = null;
        defer if (file) |f| f.close(io);
        var file_buffer: [4096]u8 = undefined;
        var file_writer: std.Io.File.Writer = undefined;
        const writer = if (std.mem.eql(u8, output.name.content, "")) (
          stdout
        ) else blk: {
          if (std.fs.path.dirname(output.name.content)) |dir_path| {
            base_dir.createDirPath(io, dir_path) catch |err| {
              stderr.print(
                "unable to create output path: '{s}'\n  {s}\n",
                .{output.name.content, @errorName(err)}) catch unreachable;
              std.process.exit(1);
            };
          }
          const f = base_dir.createFile(
            io, output.name.content, .{.truncate = true}
          ) catch |err| {
            stderr.print(
              "unable to create output file: '{s}'\n  {s}\n",
              .{output.name.content, @errorName(err)}) catch unreachable;
            std.process.exit(1);
          };
          file = f;
          file_writer = f.writer(io, &file_buffer);
          break :blk &file_writer.interface;
        };
        switch (output.body.data) {
          .text => |*txt| {
            try writer.writeAll(txt.content);
            // unix requirement: all text files are to end with a line break.
            try writer.writeByte('\n');
            try writer.flush();
          },
          else => {
            std.debug.panic("unsupported non-text output: {s}",
              .{@tagName(output.body.data)});
          },
        }
      }
    } else std.process.exit(1);
  } else std.process.exit(1);
}