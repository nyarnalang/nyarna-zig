const std = @import("std");
const tml = @import("tml");

const TestSet = struct {
  file: std.fs.File,
  tml_item: []const u8,
  func_name: []const u8,
  err_func_name: []const u8,
};

fn genTests(dir: *std.fs.Dir, sets: []TestSet) !void {
  var i = dir.iterate();

  for (sets) |set| {
    try set.file.writeAll(
      \\const std = @import("std");
      \\const testing = @import("testing");
      \\
      \\
    );
  }

  const disabled_tests = [_][]const u8{
    "auto-paragraphs.tml", // missing: intrinsic funcs
    "doc-param.tml", // missing: document parameters
    "integer-fragment.tml", // missing: intrinsic funcs, module kinds
    "ns-symbol-errors.tml", // TODO: ::len on Raw
    "flag-errors.tml", // TODO: integer functions
    "invalid-comptime-call-in-declare.tml", // TODO: can user define comptime fn
  };

  files: while (try i.next()) |entry| {
    if (entry.kind != .File) continue;
    for (disabled_tests) |name| {
      if (std.mem.eql(u8, name, entry.name)) {
        std.debug.print("[DISABLED] {s}\n", .{name});
        continue :files;
      }
    }
    var file = try dir.openFile(entry.name, .{});
    defer file.close();
    var content = try tml.File.loadFile(dir, entry.name, &file);
    defer content.deinit();
    for (sets) |*set| {
      if (content.items.get(set.tml_item) != null) {
        try set.file.writeAll("test \"");
        try set.file.writeAll(content.name);
        try set.file.writeAll(\\" {
          \\  var resolver = try testing.TestDataResolver.init("test/data/
        );
        try set.file.writeAll(entry.name);
        try set.file.writeAll(\\");
          \\  defer resolver.deinit();
          \\  try testing.
        );
        try set.file.writeAll(set.func_name);
        try set.file.writeAll(\\(&resolver);
          \\}
          \\
        );
      }
      if (content.params.errors.get(set.tml_item) != null) {
        try std.fmt.format(set.file.writer(), "test \"{s}\"", .{content.name});
        try set.file.writeAll(\\ {
          \\  var resolver = try testing.TestDataResolver.init("test/data/
        );
        try set.file.writeAll(entry.name);
        try set.file.writeAll(\\");
          \\  defer resolver.deinit();
          \\  try testing.
        );
        try set.file.writeAll(set.err_func_name);
        try set.file.writeAll(\\(&resolver);
          \\}
          \\
        );
      }
    }
  }
}

pub fn main() !void {
  var datadir = try std.fs.cwd().openDir(
    "data", .{.access_sub_paths = true, .iterate = true, .no_follow = true});
  defer datadir.close();
  var sets = [_]TestSet{
    .{
      .file = undefined,
      .tml_item = "tokens",
      .func_name = "lexTest",
      .err_func_name = "lexErrorTest",
    },
    .{
      .file = undefined,
      .tml_item = "rawast",
      .func_name = "parseTest",
      .err_func_name = "parseErrorTest",
    },
    .{
      .file = undefined,
      .tml_item = "expr",
      .func_name = "interpretTest",
      .err_func_name = "interpretErrorTest",
    },
  };
  sets[0].file = try std.fs.cwd().createFile("lex_test.zig", .{});
  defer sets[0].file.close();
  sets[1].file = try std.fs.cwd().createFile("parse_test.zig", .{});
  defer sets[1].file.close();
  sets[2].file = try std.fs.cwd().createFile("interpret_test.zig", .{});
  defer sets[2].file.close();
  try genTests(&datadir, &sets);
}