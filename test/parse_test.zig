const std = @import("std");
const data = @import("data");
const parse = @import("parse");
const Source = @import("source").Source;
const Context = @import("interpret").Context;

test "parse simple line" {
  var src = Source{
    .content = "Hello, World!\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "helloworld",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };

  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.literal, res.data);
  try std.testing.expectEqualStrings("Hello, World!", res.data.literal.content);
}