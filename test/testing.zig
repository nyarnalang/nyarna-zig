const std = @import("std");
const nyarna = @import("nyarna");
const data = nyarna.data;
const tml = @import("tml.zig");
const errors = nyarna.errors;

const TestError = error {
  no_match
};

pub fn lexTest(f: *tml.File) !void {
  var input = f.items.get("input").?;
  try input.content.appendSlice(f.alloc(), "\x04\x04\x04\x04");
  const expected_data = f.items.get("tokens").?;
  var expected_content = std.mem.split(u8, expected_data.content.items, "\n");
  var src_meta = data.Source.Descriptor{
    .name = "input",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = data.Source{
    .meta = &src_meta,
    .content = input.content.items,
    .offsets = .{
      .line = input.line_offset, .column = 0,
    },
    .locator_ctx = ".doc.",
  };
  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit();
  var ml = try nyarna.ModuleLoader.create(&ctx, &src, &.{});
  defer ml.destroy();
  var lexer = try ml.initLexer();
  defer lexer.deinit();
  var startpos = lexer.recent_end;
  var t = try lexer.next();
  while(true) : (t = try lexer.next()) {
    const actual =
      try if (@enumToInt(t) >= @enumToInt(data.Token.skipping_call_id))
        std.fmt.allocPrint(
          std.testing.allocator, "{}:{}[{}] skipping_call_id({})", .{
            startpos.at_line, startpos.before_column, startpos.byte_offset,
            @enumToInt(t) - @enumToInt(data.Token.skipping_call_id) + 1
          })
      else
        std.fmt.allocPrint(std.testing.allocator, "{}:{}[{}] {s}", .{
            startpos.at_line, startpos.before_column, startpos.byte_offset,
            @tagName(t)
          });
    defer std.testing.allocator.free(actual);
    const expected = expected_content.next() orelse {
      std.log.err("got more tokens than expected, first unexpected token: {s}",
        .{actual});
      return TestError.no_match;
    };
    try std.testing.expectEqualStrings(expected, actual);
    if (t == .end_source) break;
    startpos = lexer.recent_end;
  }
  while (expected_content.next()) |unmatched| {
    if (unmatched.len > 0) {
      std.log.err("got fewer tokens than expected, first missing token: {s}",
        .{unmatched});
      return TestError.no_match;
    }
  }
}

fn formatTypeName(t: data.Type, comptime _: []const u8,
                  _: std.fmt.FormatOptions, writer: anytype) !void {
  switch (t) {
    .intrinsic => |i| try writer.writeAll(@tagName(i)),
    .structural => |_| unreachable,
    .instantiated => |i|
      try writer.writeAll(if (i.name) |sym| sym.name else "<anon>"),
  }
}

const HeaderWithContext = struct {
  header: *const data.Value.BlockHeader,
  context: *nyarna.Context,
};

fn formatBlockHeader(hc: HeaderWithContext, comptime _: []const u8,
                     _: std.fmt.FormatOptions, writer: anytype) !void {
  if (hc.header.config) |config| {
    try writer.writeAll(":<");
    var first = true;
    for (config.map) |*item| {
      if (item.to == 0) {
        if (first) first = false else try writer.writeAll(", ");
        const ec = nyarna.EncodedCharacter.init(item.from);
        try writer.print("off {s}", .{ec.repr()});
      }
    }
    for (config.map) |*item| {
      if (item.from == 0) {
        if (first) first = false else try writer.writeAll(", ");
        const ec = nyarna.EncodedCharacter.init(item.to);
        try writer.print("csym {s}", .{ec.repr()});
      }
    }
    for (config.map) |*item| {
      if (item.from != 0 and item.to != 0) {
        if (first) first = false else try writer.writeAll(", ");
        const fc = nyarna.EncodedCharacter.init(item.from);
        const tc = nyarna.EncodedCharacter.init(item.to);
        try writer.print("map {s} {s}", .{fc.repr(), tc.repr()});
      }
    }
    if (config.full_ast) |_| {
      if (first) first = false else try writer.writeAll(", ");
      try writer.writeAll("fullast");
    }
    if (config.syntax) |def| {
      if (first) first = false else try writer.writeAll(", ");
      // TODO: user-define syntaxes
      try writer.print("syntax {s}", .{switch (def.index) {
        0 => @as([]const u8, "locations"), 1 => "definitions",
        else => unreachable
      }});
    }
    try writer.writeByte('>');
  }
  if (hc.header.swallow_depth) |swallow_depth| {
    try if (swallow_depth > 0) writer.print(":{}>", .{swallow_depth})
        else writer.writeAll(":>");
  } else if (hc.header.config == null) try writer.writeAll("null");
}

fn AstEmitter(Handler: anytype) type {
  return struct {
    const Self = @This();

    const Popper = struct {
      e: *Self,
      name: []const u8,

      fn pop(self: Popper) !void {
        self.e.depth -= 1;
        try self.e.emitLine("-{s}", .{self.name});
      }
    };

    handler: Handler,
    depth: usize,
    context: *nyarna.Context,

    fn emitLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
      var buffer: [1024]u8 = undefined;
      var i: usize = 0; while (i < self.depth*2) : (i += 1) buffer[i] = ' ';
      const str = try std.fmt.bufPrint(buffer[i..], fmt, args);
      try self.handler.handle(buffer[0..i+str.len]);
    }

    fn push(self: *Self, comptime name: []const u8) !Popper {
      try self.emitLine("+{s}", .{name});
      self.depth += 1;
      return Popper{.e = self, .name = name};
    }

    fn pushWithKey(self: *Self, comptime name: []const u8,
                   comptime key: []const u8, value: ?[]const u8) !Popper {
      if (name.len == 0) try self.emitLine("+{s} " ++ value.?) else
      if (value) |v| try self.emitLine("+{s} " ++ key ++ "=\"{s}\"", .{name, v})
      else try self.emitLine("+{s} " ++ key, .{name});
      self.depth += 1;
      return Popper{.e = self, .name = name};
    }

    pub fn process(self: *Self, n: *data.Node) anyerror!void {
      switch (n.data) {
        .access => |a| {
          const access = try self.push("ACCESS");
          {
            const target = try self.push("SUBJECT");
            try self.process(a.subject);
            try target.pop();
          }
          try self.emitLine("=ID \"{s}\"", .{a.id});
          try access.pop();
        },
        .assignment => |a| {
          const ass = try self.push("ASS");
          {
            const target = try self.push("TARGET");
            try switch (a.target) {
              .unresolved => |u| self.process(u),
              .resolved => unreachable, // TODO
            };
            try target.pop();
          }
          {
            const repl = try self.push("REPL");
            try self.process(a.replacement);
            try repl.pop();
          }
          try ass.pop();
        },
        .literal => |a| {
          try self.emitLine("=LIT {s} \"{}\"",
            .{@tagName(a.kind), std.zig.fmtEscapes(a.content)});
        },
        .concatenation => |c| {
          for (c.content) |item| try self.process(item);
        },
        .paragraphs => |p| {
          for (p.items) |i| {
            const para = try self.push("PARA");
            try self.process(i.content);
            try para.pop();
          }
        },
        .unresolved_symref => |u|
          try self.emitLine("=SYMREF [{}]{s}", .{u.ns, u.name}),
        .resolved_symref => |res|
          try self.emitLine("=SYMREF {s}.{s}",
            .{res.defined_at.source.name, res.name}),
        .unresolved_call => |uc| {
          const ucall = try self.push("UCALL");
          {
            const t = try self.push("TARGET");
            try self.process(uc.target);
            try t.pop();
          }
          for (uc.proto_args) |a| {
            const parg = try switch (a.kind) {
              .position => self.pushWithKey("PROTO", "pos", null),
              .named => |named| self.pushWithKey("PROTO", "name", named),
              .direct => |direct| self.pushWithKey("PROTO", "direct", direct),
              .primary => self.pushWithKey("PROTO", "primary", null),
            };
            try self.process(a.content);
            try parg.pop();
          }
          try ucall.pop();
        },
        .resolved_call => |rc| {
          const rcall = try self.push("RCALL");
          {
            const t = try self.push("TARGET");
            try self.processExpr(rc.target);
            try t.pop();
          }
          for (rc.args) |a| {
            const arg = try self.push("ARG");
            try self.process(a);
            try arg.pop();
          }
          try rcall.pop();
        },
        .expression => |e| try self.processExpr(e),
        .poisonNode => try self.emitLine("=POISON", .{}),
        .voidNode => try self.emitLine("=VOID", .{}),
      }
    }

    pub fn processExpr(self: *Self, e: *data.Expression) anyerror!void {
      switch (e.data) {
        .call => |call| {
          const c = try self.push("CALL");
          const t = try self.push("TARGET");
          try self.processExpr(call.target);
          try t.pop();
          for (call.exprs) |expr| {
            const a = try self.push("ARG");
            try self.processExpr(expr);
            try a.pop();
          }
          try c.pop();
        },
        .assignment => |_| {
          unreachable;
        },
        .access => |_| {
          unreachable;
        },
        .literal => |l| {
          try self.processValue(&l.value);
        },
        .var_retrieval => |_| {
          unreachable;
        },
        .poison => try self.emitLine("=POISON", .{}),
        .void => try self.emitLine("=VOID", .{}),
      }
    }

    fn processType(self: *Self, t: data.Type) !void {
      switch (t) {
        .intrinsic => |i| try self.emitLine("=TYPE {s}", .{@tagName(i)}),
        .structural => unreachable,
        .instantiated => |i| {
          if (i.name) |sym| try self.emitLine("=TYPE {s} \"{s}\"",
            .{@tagName(i.data), sym.name})
          else {
            const tc = try self.pushWithKey("TYPE", "", @tagName(i.data));
            switch (i.data) {
              .textual => |_| unreachable,
              .numeric => |_| unreachable,
              .float => |_| unreachable,
              .tenum => |en| {
                for (en.values.entries.items(.key)) |*key| {
                  try self.emitLine("=ITEM {s}", .{key});
                }
              },
              .record => |_| unreachable,
            }
            try tc.pop();
          }
        },
      }
    }

    fn processValue(self: *Self, v: *const data.Value) !void {
      switch (v.data) {
        .text => |txt| {
          const t = std.fmt.Formatter(formatTypeName){.data = txt.t};
          try self.emitLine("=TEXT {} \"{}\"",
            .{t, std.zig.fmtEscapes(txt.value)});
        },
        .number => |_| {
          unreachable;
        },
        .float => |_| {
          unreachable;
        },
        .enumval => |ev| {
          const t = std.fmt.Formatter(formatTypeName){.data = ev.t.typedef()};
          try self.emitLine("=ENUM {} \"{s}\"",
            .{t, ev.t.values.entries.items(.key)[ev.index]});
        },
        .record => |_| {
          unreachable;
        },
        .concat => |_| {
          unreachable;
        },
        .list => |_| {
          unreachable;
        },
        .map => |_| {
          unreachable;
        },
        .location => |_| {
          unreachable;
        },
        .definition => |_| {
          unreachable;
        },
        .ast => |_| {
          unreachable;
        },
        .typeval => |tv| try self.processType(tv.t),
        .funcref => |_| unreachable,
        .poison => try self.emitLine("=POISON", .{}),
        .void => try self.emitLine("=VOID", .{}),
        .block_header => |*h| {
          const hf = std.fmt.Formatter(formatBlockHeader){
            .data = .{.header = h, .context = self.context}
          };
          try self.emitLine("=HEADER {}", .{hf});
        },
      }
    }
  };
}

pub fn parseTest(f: *tml.File) !void {
  var input = f.items.get("input").?;
  try input.content.appendSlice(f.alloc(), "\x04\x04\x04\x04");
  const expected_data = f.items.get("rawast").?;
  var checker = struct {
    expected_iter: std.mem.TokenIterator(u8),
    line: usize,
    full_output: std.ArrayListUnmanaged(u8),
    failed: bool,
    fn handle(self: *@This(), line: []const u8) !void {
      defer {
        self.line += 1;
        self.full_output.appendSlice(std.testing.allocator, line)
          catch unreachable;
        self.full_output.append(std.testing.allocator, '\n') catch unreachable;
      }
      const expected = self.expected_iter.next() orelse {
        if (!self.failed) {
          std.log.err(
            "got more output than expected, first unexpected line:\n  {s}",
            .{line});
          self.failed = true;
        }
        return;
      };
      if (!self.failed) {
        if (!std.mem.eql(u8, expected, line)) {
          std.log.err(
            \\Wrong output at line {}:
            \\==== expected content ====
            \\{s}
            \\
            \\===== actual content =====
            \\{s}
            \\
            \\
          , .{self.line, expected, line});
          self.failed = true;
        }
      }
    }
  }{.expected_iter = std.mem.tokenize(u8, expected_data.content.items, "\n"),
    .line = expected_data.line_offset + 1,
    .full_output = .{}, .failed = false};
  defer checker.full_output.deinit(std.testing.allocator);

  var src_meta = data.Source.Descriptor{
    .name = "input",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = data.Source{
    .meta = &src_meta,
    .content = input.content.items,
    .offsets = .{
      .line = input.line_offset, .column = 0,
    },
    .locator_ctx = ".doc.",
  };
  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.init(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.deinit();
  var ml = try nyarna.ModuleLoader.create(&ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  var emitter = AstEmitter(@TypeOf(&checker)){
    .depth = 0,
    .handler = &checker,
    .context = &ctx,
  };
  try emitter.process(res);
  if (checker.expected_iter.next()) |line| {
    if (!checker.failed) {
      std.log.err("got less output than expected, line {} missing:\n{s}\n",
        .{checker.line, line});
      checker.failed = true;
    }
  }
  if (checker.failed) {
    std.log.err(
      \\==== Full output ====
      \\{s}
      \\
      \\
      , .{checker.full_output.items});
    return TestError.no_match;
  }
  try std.testing.expectEqual(@as(usize, 0), ml.logger.count);
}