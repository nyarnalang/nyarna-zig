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

  const params = comptime clap.parseParamsComptime(
    \\-h, --help           Display this help and exit.
    \\-v, --version        Print version information and exit.
    \\-o, --output <DIR>   Write output documents to <DIR>. default: cwd
    \\--ast                Print AST of file to stdout, then exit.
    \\<FILE>               The file to be interpreted. default: '-' for stdin.
    \\<ARG>...             Nyarna arguments for interpreting <FILE>.
  ++ "");

  var iter = try std.process.ArgIterator.initWithAllocator(arena.allocator());
  defer iter.deinit();
  _ = iter.next();

  var diag = clap.Diagnostic{};
  var parser = clap.streaming.Clap(clap.Help, std.process.ArgIterator){
    .params     = &params,
    .iter       = &iter,
    .diagnostic = &diag,
  };

  const stdlib_path = std.process.getEnvVarOwned(
    arena.allocator(), "NYARNA_STDLIB_PATH"
  ) catch |err| switch (err) {
    error.EnvironmentVariableNotFound => generated.stdlib_path,
    else => return err,
  };
  var stdlib_resolver = nyarna.Loader.FileSystemResolver.init(stdlib_path);
  var terminal = nyarna.errors.Terminal(std.fs.File.Writer, true).init(
    std.io.getStdErr().writer());

  var proc = try nyarna.Processor.init(
    std.heap.page_allocator, nyarna.default_stack_size, &terminal.reporter,
    &stdlib_resolver.api);
  defer proc.deinit();

  var target_dir: ?std.fs.Dir = null;
  defer if (target_dir) |*dir| dir.close();

  var print_ast = false;

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
        const hr =
          clap.help(std.io.getStdOut().writer(), clap.Help, &params, .{});
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
      } else if (arg.param == &params[2]) {
        if (target_dir != null) {
          std.io.getStdErr().writer().print(
            "only one --output directory allowed\n", .{}) catch unreachable;
            std.os.exit(1);
        }
        const dir_opts = std.fs.Dir.OpenDirOptions{
          .access_sub_paths = false, .no_follow = false,
        };
        target_dir = (
          if (std.fs.path.isAbsolute(arg.value.?)) (
            std.fs.openDirAbsolute(arg.value.?, dir_opts)
          ) else std.fs.cwd().openDir(arg.value.?, dir_opts)
        ) catch |err| {
          std.io.getStdErr().writer().print(
            "cannot access output directory '{s}':\n  {s}\n",
            .{arg.value.?, @errorName(err)}) catch unreachable;
          std.os.exit(1);
        };
      } else if (arg.param == &params[3]) {
        print_ast = true;
      } else if (arg.param == &params[4] and cur_loader == null) {
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

  if (print_ast) {
    defer loader.destroy();
    const ml = try loader.finishMainAst();
    defer ml.destroy();
    const node = try ml.finalizeNode();
    try std.io.getStdOut().writer().print(
      "{}\n", .{node.formatter(loader.loader.data)});
  } else if (try loader.finalize()) |container| {
    defer container.destroy();
    if (try container.process()) {
      const base_dir = target_dir orelse std.fs.cwd();
      for (container.documents.items) |output| {
        if (
          if (output.schema) |schema| schema.backend != null else false
        ) continue;
        var file: ?std.fs.File = null;
        defer if (file) |f| f.close();
        var writer = if (std.mem.eql(u8, output.name.content, "")) (
          std.io.getStdOut().writer()
        ) else blk: {
          if (std.fs.path.dirname(output.name.content)) |dir_path| {
            base_dir.makePath(dir_path) catch |err| {
              std.io.getStdErr().writer().print(
                "unable to create output path: '{s}'\n  {s}\n",
                .{output.name.content, @errorName(err)}) catch unreachable;
              std.os.exit(1);
            };
          }
          const f = base_dir.createFile(
            output.name.content, .{.truncate = true}
          ) catch |err| {
            std.io.getStdErr().writer().print(
              "unable to create output file: '{s}'\n  {s}\n",
              .{output.name.content, @errorName(err)}) catch unreachable;
            std.os.exit(1);
          };
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