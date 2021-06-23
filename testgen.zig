const std = @import("std");
const tml = @import("tml.zig");

pub fn main() !void {
  var datadir = try std.fs.cwd().openDir("testdata",
      .{.access_sub_paths = true, .iterate = true, .no_follow = true});
  defer datadir.close();
  var i = datadir.iterate();

  var lextest = try std.fs.cwd().createFile("lex_test.zig", .{});
  defer lextest.close();
  _ = try lextest.write(
    \\const std = @import("std");
    \\const tml = @import("tml.zig");
    \\const testing = @import("testing.zig");
    \\
    \\
  );

  while (try i.next()) |entry| {
    if (entry.kind != .File) continue;
    var file = try datadir.openFile(entry.name, .{});
    defer file.close();
    const content = try tml.File.loadFile(&datadir, entry.name, &file);
    if (content.items.get("tokens")) |tokens| {
      _ = try lextest.write("test \"");
      _ = try lextest.write(content.name);
      _ = try lextest.write(\\" {
        \\  var data = try tml.File.loadPath("testdata/
      );
      _ = try lextest.write(entry.name);
      _ = try lextest.write(\\");
        \\  defer data.deinit();
        \\  try testing.lexTest(&data);
        \\}
        \\
      );
    }
  }
}