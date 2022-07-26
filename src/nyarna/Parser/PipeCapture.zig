const std = @import("std");

const nyarna       = @import("../../nyarna.zig");
const Impl         = @import("Impl.zig");
const ContentLevel = @import("ContentLevel.zig");

const model  = nyarna.model;
const errors = nyarna.errors;

const Self = @This();

parser: *Impl,
items : std.ArrayList(model.Value.Ast.VarDef),
lvl   : *ContentLevel,

pub fn init(parser: *Impl, lvl: *ContentLevel) Self {
  return .{
    .parser = parser,
    .items  = std.ArrayList(model.Value.Ast.VarDef).init(parser.allocator()),
    .lvl    = lvl,
  };
}

fn push(self: *Self, ns: u15, name: []const u8, pos: model.Position) !void {
  try self.items.append(.{
    .ns = ns, .name = name, .pos = pos,
  });
}

pub fn parse(self: *Self) !void {
  std.debug.assert(self.parser.cur == .pipe);
  self.parser.advance();
  var expect_param = true;
  while (true) {
    switch (self.parser.cur) {
      .comma => {
        if (expect_param) {
          self.parser.logger().MissingToken(
            self.parser.source().at(self.parser.cur_start),
            &.{.{.token = model.Token.symref}}, .{.token = .comma});
        } else expect_param = true;
      },
      .pipe => {
        self.parser.advance();
        break;
      },
      .space => {},
      .symref => {
        if (!expect_param) {
          self.parser.logger().MissingToken(
            self.parser.source().at(self.parser.cur_start),
            &.{.{.token = model.Token.comma}}, .{.token = .symref});
        } else expect_param = false;
        try self.push(
          self.parser.lexer.ns, self.parser.lexer.recent_id,
          self.parser.lexer.walker.posFrom(self.parser.cur_start));
      },
      else => {
        self.parser.logger().MissingToken(
          self.parser.source().at(self.parser.cur_start),
          &.{.{.token = model.Token.pipe}}, .{.token = self.parser.cur});
        self.parser.lexer.abortCaptureList();
        break;
      },
    }
    self.parser.advance();
  }
  self.lvl.capture = self.items.items;
}