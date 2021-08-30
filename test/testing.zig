const std = @import("std");
const data = @import("data");
const tml = @import("tml.zig");
const lex = @import("lex");
const parse = @import("parse");
const errors = @import("errors");
const Source = @import("source").Source;
const Context = @import("interpret").Context;

const TestError = error {
  no_match
};

pub fn lexTest(f: *tml.File) !void {
  var input = f.items.get("input").?;
  try input.content.appendSlice(f.alloc(), "\x04\x04\x04\x04");
  const expected_data = f.items.get("tokens").?;
  var expected_content = std.mem.split(expected_data.content.items, "\n");
  var src = Source{
    .content = input.content.items,
    .offsets = .{
      .line = input.line_offset, .column = 0,
    },
    .name = "input",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };
  var r = errors.CmdLineReporter.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var l = try lex.Lexer.init(&ctx, &src);
  var startpos = l.recent_end;
  defer l.deinit();
  var t = try l.next();
  while(true) : (t = try l.next()) {
    const actual = try if (@enumToInt(t) >= @enumToInt(data.Token.skipping_call_id))
      std.fmt.allocPrint(std.testing.allocator, "{}:{}[{}] skipping_call_id({})",
          .{startpos.at_line, startpos.before_column, startpos.byte_offset,
            @enumToInt(t) - @enumToInt(data.Token.skipping_call_id) + 1})
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

fn AstEmitter(Handler: anytype) type {
  return struct {
    const Self = @This();

    const Popper = struct {
      e: *Self,
      name: []const u8,

      fn pop(self: Popper) void {
        self.e.depth -= 1;
        self.e.emitLine("-{s}", .{self.name}) catch unreachable;
      }
    };

    handler: Handler,
    depth: usize,

    fn emitLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
      var buffer: [1024]u8 = undefined;
      var i: usize = 0; while (i < self.depth*2) : (i += 1) buffer[i] = ' ';
      const str = try std.fmt.bufPrint(buffer[i*2..], fmt, args);
      try self.handler.handle(buffer[0..i*2+str.len]);
    }

    fn push(self: *Self, comptime name: []const u8) !Popper {
      try self.emitLine("+{s}", .{name});
      self.depth += 1;
      return Popper{.e = self, .name = name};
    }

    fn pushWithKey(self: *Self, comptime name: []const u8, comptime key: []const u8, value: ?[]const u8) !Popper {
      try if (value) |v| self.emitLine("+{s} " ++ key ++ "=\"{s}\"", .{name, v})
      else self.emitLine("+{s} " ++ key, .{name});
      self.depth += 1;
      return Popper{.e = self, .name = name};
    }

    pub fn process(self: *Self, n: *data.Node) anyerror!void {
      switch (n.data) {
        .access => |a| {
          const access = try self.push("ACCESS"); defer access.pop();
          {
            const target = try self.push("SUBJECT"); defer target.pop();
            try self.process(a.subject);
          }
          try self.emitLine("=ID \"{s}\"", .{a.id});
        },
        .assignment => |a| {
          const ass = try self.push("ASS"); defer ass.pop();
          {
            const target = try self.push("TARGET"); defer target.pop();
            try switch (a.target) {
              .unresolved => |u| self.process(u),
              .resolved => unreachable, // TODO
            };
          }
          {
            const repl = try self.push("REPL"); defer repl.pop();
            try self.process(a.replacement);
          }
        },
        .literal => |a| {
          try self.emitLine("=LIT {s} \"{}\"", .{if (a.kind == .text) @as([]const u8, "TEXT") else "SPACE", std.zig.fmtEscapes(a.content)});
        },
        .concatenation => |c| {
          for (c.content) |item| try self.process(item);
        },
        .paragraphs => |p| {
          for (p.items) |i| {
            const para = try self.push("PARA"); defer para.pop();
            try self.process(i.content);
          }
        },
        .symref => |r| {
          switch (r) {
            .resolved => |res| try self.emitLine("=SYMREF {s}.{s}", .{res.defined_at.module.name, res.name}),
            .unresolved => |u| try self.emitLine("=SYMREF [{}]{s}", .{u.ns, u.name}),
          }
        },
        .unresolved_call => |uc| {
          const ucall = try self.push("UCALL"); defer ucall.pop();
          {
            const t = try self.push("TARGET"); defer t.pop();
            try self.process(uc.target);
          }
          for (uc.params) |p| {
            const para = try switch (p.kind) {
              .position => self.pushWithKey("PARAM", "pos", null),
              .named => |named| self.pushWithKey("PARAM", "name", named),
              .direct => |direct| self.pushWithKey("PARAM", "direct", direct),
              .primary => self.pushWithKey("PARAM", "primary", null),
            }; defer para.pop();
            try self.process(p.content);
          }
        },
        .resolved_call => unreachable,
        .voidNode => try self.emitLine("=VOID", .{}),
      }
    }
  };
}

pub fn parseTest(f: *tml.File) !void {
  var input = f.items.get("input").?;
  try input.content.appendSlice(f.alloc(), "\x04\x04\x04\x04");
  const expected_data = f.items.get("ast").?;
  var checker = struct {
    expected_iter: std.mem.SplitIterator,
    fn handle(self: *@This(), line: []const u8) !void {
      const expected = self.expected_iter.next() orelse {
        std.log.err("got more output than expected, first unexpected line:\n  {s}", .{line});
        return TestError.no_match;
      };
      try std.testing.expectEqualStrings(expected, line);
    }
  }{.expected_iter = std.mem.split(expected_data.content.items, "\n")};

  var src = Source{
    .content = input.content.items,
    .offsets = .{
      .line = input.line_offset, .column = 0,
    },
    .name = "input",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };
  var r = errors.CmdLineReporter.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var p = parse.Parser.init();
  var res = try p.parseSource(&src, &ctx);
  var emitter = AstEmitter(@TypeOf(&checker)){
    .depth = 0,
    .handler = &checker,
  };
  try emitter.process(res);
  if (checker.expected_iter.next()) |line| {
    std.log.err("got less output than expected, first line missing:\n  {s}", .{line});
    return TestError.no_match;
  }
}