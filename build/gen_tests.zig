const std = @import("std");
const tml = @import("tml");

const TestSet = struct {
  file: std.fs.File,
  tml_item: []const u8,
  funcname: []const u8
};

fn genTests(dir: *std.fs.Dir, sets: []TestSet) !void {
  var i = dir.iterate();

  for (sets) |set| {
    _ = try set.file.write(
      \\const std = @import("std");
      \\const tml = @import("tml.zig");
      \\const testing = @import("testing");
      \\
      \\
    );
  }

  const disabled_tests = [_][]const u8{
    "auto-paragraphs.tml", // missing: intrinsic funcs
    "delayed-method-resolution.tml", // missing: intrinsic funcs
    "doc-param.tml", // missing: document parameters
    "simple-swallow.tml", // missing: if expression
    "indirect-recursion.tml", // missing: declare
    "integer-fragment.tml", // missing: intrinsic funcs, module kinds
    "simple-variables.tml", // missing: variable decls
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
      if (content.items.get(set.tml_item)) |_| {
        _ = try set.file.write("test \"");
        _ = try set.file.write(content.name);
        _ = try set.file.write(\\" {
          \\  var data = try tml.File.loadPath("test/data/
        );
        _ = try set.file.write(entry.name);
        _ = try set.file.write(\\");
          \\  defer data.deinit();
          \\  try testing.
        );
        _ = try set.file.write(set.funcname);
        _ = try set.file.write("(&data);\n" ++
          \\}
          \\
        );
      }
    }
  }
}

pub fn main() !void {
  var datadir = try std.fs.cwd().openDir("data",
      .{.access_sub_paths = true, .iterate = true, .no_follow = true});
  defer datadir.close();
  var sets = [_]TestSet{
    .{
      .file = undefined,
      .tml_item = "tokens",
      .funcname = "lexTest",
    },
    .{
      .file = undefined,
      .tml_item = "rawast",
      .funcname = "parseTest",
    },
    .{
      .file = undefined,
      .tml_item = "expr",
      .funcname = "interpretTest",
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