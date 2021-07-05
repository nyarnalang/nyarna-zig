const std = @import("std");
const tml = @import("tml.zig");
const lex = @import("lex.zig");
const data = @import("data.zig");

const TestError = error {
  no_match
};

pub fn lexTest(f: *tml.File) !void {
  var input = f.items.get("input").?;
  try input.content.appendSlice(f.alloc(), "\x04\x04\x04\x04");
  const expected_data = f.items.get("tokens").?;
  var expected_content = std.mem.split(expected_data.content.items, "\n");
  var src = lex.Source{
    .content = input.content.items,
    .offsets = .{
      .line = input.line_offset, .column = 0,
    },
    .name = "input",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };
  var ctx = lex.LexerContext{
    .command_characters = .{},
    .allocator = std.testing.allocator,
  };
  defer ctx.command_characters.deinit(ctx.allocator);
  try ctx.command_characters.put(std.testing.allocator, '\\', 0);
  var l = try lex.Lexer.init(&ctx, &src);
  var startpos = l.recent_end;
  defer l.deinit();
  var t = try l.next();
  while(true) : (t = try l.next()) {
    const actual = try if (@enumToInt(t) >= @enumToInt(lex.Token.skipping_call_id))
      std.fmt.allocPrint(std.testing.allocator, "{}:{}[{}] skipping_call_id({})",
          .{startpos.at_line, startpos.before_column, startpos.byte_offset, @enumToInt(t) - @enumToInt(lex.Token.skipping_call_id) + 1})
    else
      std.fmt.allocPrint(std.testing.allocator, "{}:{}[{}] {s}",
          .{startpos.at_line, startpos.before_column, startpos.byte_offset, @tagName(t)});
    defer std.testing.allocator.free(actual);
    const expected = expected_content.next() orelse {
      std.log.err("got more tokens than expected, first unexpected token: {s}", .{actual});
      return TestError.no_match;
    };
    try std.testing.expectEqualStrings(expected, actual);
    if (t == .end_source) break;
    startpos = l.recent_end;
  }
  while (expected_content.next()) |unmatched| {
    if (unmatched.len > 0) {
      std.log.err("got fewer tokens than expected, first missing token: {s}", .{unmatched});
      return TestError.no_match;
    }
  }
}