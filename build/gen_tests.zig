const std = @import("std");
const tml = @import("tml");

const TestSet = struct {
  file         : std.Io.File,
  impl         : std.Io.File.Writer,
  buffer       : [4096]u8,
  tml_item     : []const u8,
  func_name    : []const u8,
  err_func_name: []const u8,

  fn open(
    self: *TestSet,
    io  : std.Io,
    dir : std.Io.Dir,
    name: []const u8,
  ) !void {
    self.file = try dir.createFile(io, name, .{});
    self.impl = self.file.writer(io, &self.buffer);
  }

  fn close(self: *TestSet, io: std.Io) !void {
    try self.impl.interface.flush();
    self.file.close(io);
  }
};

fn genTests(io: std.Io, dir: std.Io.Dir, sets: []TestSet) !void {
  var i = dir.iterate();

  for (sets) |*set| {
    try set.impl.interface.writeAll(
      \\const std = @import("std");
      \\const testing = @import("testing");
      \\
      \\
    );
  }

  const disabled_tests = [_][]const u8{
    "invalid-comptime-call-in-declare.tml", // TODO: can user define comptime fn
  };

  files: while (try i.next(io)) |entry| {
    if (entry.kind != .file) continue;
    for (disabled_tests) |name| {
      if (std.mem.eql(u8, name, entry.name)) {
        std.debug.print("[DISABLED] {s}\n", .{name});
        continue :files;
      }
    }
    var content = try tml.File.loadFile(
      std.heap.page_allocator, io, dir, entry.name);
    defer content.deinit();
    for (sets) |*set| {
      const is_output = std.mem.eql(u8, "output", set.tml_item);
      if (
        (is_output and content.params.output.count() > 0) or
        content.items.get(set.tml_item) != null
      ) {
        try set.impl.interface.writeAll("test \"");
        try set.impl.interface.writeAll(content.name);
        try set.impl.interface.writeAll(\\" {
          \\  var resolver = try testing.TestDataResolver.init("test/data/
        );
        try set.impl.interface.writeAll(entry.name);
        try set.impl.interface.writeAll(\\");
          \\  defer resolver.deinit();
          \\  try testing.
        );
        try set.impl.interface.writeAll(set.func_name);
        try set.impl.interface.writeAll(\\(&resolver);
          \\}
          \\
        );
      }
      if (content.params.errors.get(set.tml_item) != null) {
        try set.impl.interface.print("test \"{s}\"", .{content.name});
        try set.impl.interface.writeAll(\\ {
          \\  var resolver = try testing.TestDataResolver.init("test/data/
        );
        try set.impl.interface.writeAll(entry.name);
        try set.impl.interface.writeAll(\\");
          \\  defer resolver.deinit();
          \\  try testing.
        );
        try set.impl.interface.writeAll(set.err_func_name);
        try set.impl.interface.writeAll(\\(&resolver);
          \\}
          \\
        );
      }
    }
  }
}

pub fn main(init: std.process.Init) !void {
  const io   = init.io;
  const args = try init.minimal.args.toSlice(init.arena.allocator());
  if (args.len != 3) {
    std.debug.print("usage: {s} <data dir> <output dir>\n", .{args[0]});
    std.process.exit(1);
  }
  var datadir = try std.Io.Dir.cwd().openDir(
    io, args[1], .{.iterate = true, .follow_symlinks = false});
  defer datadir.close(io);
  var outdir = try std.Io.Dir.cwd().openDir(io, args[2], .{});
  defer outdir.close(io);
  var sets = [_]TestSet{
    .{
      .file          = undefined,
      .impl          = undefined,
      .buffer        = undefined,
      .tml_item      = "tokens",
      .func_name     = "lexTest",
      .err_func_name = "lexErrorTest",
    },
    .{
      .file          = undefined,
      .impl          = undefined,
      .buffer        = undefined,
      .tml_item      = "rawast",
      .func_name     = "parseTest",
      .err_func_name = "parseErrorTest",
    },
    .{
      .file          = undefined,
      .impl          = undefined,
      .buffer        = undefined,
      .tml_item      = "expr",
      .func_name     = "interpretTest",
      .err_func_name = "interpretErrorTest",
    },
    .{
      .file          = undefined,
      .impl          = undefined,
      .buffer        = undefined,
      .tml_item      = "document",
      .func_name     = "loadTest",
      .err_func_name = "loadErrorTest",
    },
    .{
      .file          = undefined,
      .impl          = undefined,
      .buffer        = undefined,
      .tml_item      = "output",
      .func_name     = "outputTest",
      .err_func_name = "outputErrorTest",
    },
  };
  try sets[0].open(io, outdir, "lex_test.zig");
  try sets[1].open(io, outdir, "parse_test.zig");
  try sets[2].open(io, outdir, "interpret_test.zig");
  try sets[3].open(io, outdir, "load_test.zig");
  try sets[4].open(io, outdir, "output_test.zig");
  try genTests(io, datadir, &sets);
  for (&sets) |*set| try set.close(io);
}
