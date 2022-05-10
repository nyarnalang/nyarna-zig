//! parses block configuration inside `:<…>`.
//! aborts on first syntax error so that syntax errors such as missing `>`
//! do not lead to large parts of the input being parsed as block config.

const std = @import("std");

const errors = @import("../errors.zig");
const model  = @import("../model.zig");
const Impl   = @import("Impl.zig");

const BlockConfig = @This();

into: *model.BlockConfig,
map_list: std.ArrayList(model.BlockConfig.Map),
parser: *Impl,
cur_item_start: model.Cursor,

pub fn init(
  into     : *model.BlockConfig,
  allocator: std.mem.Allocator,
  parser   : *Impl,
) @This() {
  return .{
    .into           = into,
    .map_list       = std.ArrayList(model.BlockConfig.Map).init(allocator),
    .parser         = parser,
    .cur_item_start = undefined,
  };
}

const ConfigItemKind = enum {
  csym, empty, fullast, map, off,syntax, unknown,
};

inline fn getItemKind(self: *BlockConfig, first: bool) ?ConfigItemKind {
  while (true) {
    self.parser.advance();
    if (self.parser.cur != .space) break;
  }
  switch (self.parser.cur) {
    .diamond_close, .end_source => {
      if (!first) {
        self.parser.logger().ExpectedXGotY(
          self.parser.lexer.walker.posFrom(self.parser.cur_start),
          &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
          .{.token = self.parser.cur});
      }
      return null;
    },
    else => {}
  }
  std.debug.assert(self.parser.cur == .identifier);
  self.cur_item_start = self.parser.cur_start;
  const name = self.parser.lexer.walker.contentFrom(
    self.parser.cur_start.byte_offset);
  return switch (std.hash.Adler32.hash(name)) {
    std.hash.Adler32.hash("csym") => .csym,
    std.hash.Adler32.hash("syntax") => .syntax,
    std.hash.Adler32.hash("map") => .map,
    std.hash.Adler32.hash("off") => .off,
    std.hash.Adler32.hash("fullast") => .fullast,
    std.hash.Adler32.hash("") => .empty,
    else => blk: {
      self.parser.logger().UnknownConfigDirective(
        self.parser.lexer.walker.posFrom(self.cur_item_start));
      break :blk .unknown;
    },
  };
}

inline fn procCsym(self: *BlockConfig) !bool {
  if (self.parser.cur == .ns_sym) {
    try self.map_list.append(.{
      .pos = self.parser.lexer.walker.posFrom(self.cur_item_start),
      .from = 0, .to = self.parser.lexer.code_point});
    return true;
  } else {
    self.parser.logger().ExpectedXGotY(
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
      &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
      .{.token = self.parser.cur});
    return false;
  }
}

inline fn procSyntax(self: *BlockConfig) bool {
  if (self.parser.cur == .literal) {
    const syntax_name =
      self.parser.lexer.walker.contentFrom(self.parser.cur_start.byte_offset);
    switch (std.hash.Adler32.hash(syntax_name)) {
      std.hash.Adler32.hash("locations") => {
        self.into.syntax = .{
          .pos = model.Position.intrinsic(),
          .index = 0,
        };
      },
      std.hash.Adler32.hash("definitions") => {
        self.into.syntax = .{
          .pos = model.Position.intrinsic(),
          .index = 1,
        };
      },
      else =>
        self.parser.logger().UnknownSyntax(
          self.parser.lexer.walker.posFrom(self.parser.cur_start),
          syntax_name),
    }
    return true;
  } else {
    self.parser.logger().ExpectedXGotY(
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
      &[_]errors.WrongItemError.ItemDescr{.{.token = .literal}},
      .{.token = self.parser.cur});
    return false;
  }
}

inline fn procMap(self: *BlockConfig) !bool {
  var failed = false;
  if (self.parser.cur == .ns_sym) {
    const from = self.parser.lexer.code_point;
    failed = while (self.parser.getNext()) {
      if (self.parser.cur != .space) break self.parser.cur != .ns_sym;
    } else true;
    if (!failed) {
      try self.map_list.append(.{
        .pos = self.parser.lexer.walker.posFrom(self.cur_item_start),
        .from = from, .to = self.parser.lexer.code_point,
      });
    }
  } else failed = true;
  if (failed) {
    self.parser.logger().ExpectedXGotY(
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
      &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
      .{.token = self.parser.cur});
  }
  return !failed;
}

const ResultAction = enum {
  none, recover, dont_consume_next,
};

inline fn procOff(self: *BlockConfig) !ResultAction {
  switch (self.parser.cur) {
    .comment => self.into.off_comment =
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
    .block_name_sep => self.into.off_colon =
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
    .ns_sym =>
      try self.map_list.append(.{
        .pos = self.parser.lexer.walker.posFrom(self.cur_item_start),
        .from = self.parser.lexer.code_point, .to = 0,
      }),
    .diamond_close, .comma => {
      self.into.off_comment =
        self.parser.lexer.walker.posFrom(self.cur_item_start);
      self.into.off_colon =
        self.parser.lexer.walker.posFrom(self.cur_item_start);
      try self.map_list.append(.{
        .pos = self.parser.lexer.walker.posFrom(self.cur_item_start),
        .from = 0, .to = 0,
      });
      return .dont_consume_next;
    },
    else => {
      self.parser.logger().ExpectedXGotY(
        self.parser.lexer.walker.posFrom(self.parser.cur_start),
        &[_]errors.WrongItemError.ItemDescr{
          .{.token = .ns_sym}, .{.character = '#'},
          .{.character = ':'},
        }, .{.token = self.parser.cur});
      return .recover;
    }
  }
  return .none;
}

pub fn parse(self: *BlockConfig) !void {
  std.debug.assert(self.parser.cur == .diamond_open);
  self.into.* = .{
    .syntax      = null,
    .off_colon   = null,
    .off_comment = null,
    .full_ast    = null,
    .map         = undefined,
  };
  var first = true;
  var recover = false;
  while (
    switch (self.parser.cur) {
      .diamond_close, .end_source => false,
      else => true,
    }
  ) {
    const kind = self.getItemKind(first) orelse break;
    first = false;
    recover = while (self.parser.getNext()) {
      if (self.parser.cur != .space) break false;
    } else true;
    if (!recover) consume_next: {
      switch (kind) {
        .csym   => if (!(try self.procCsym())) {recover = true;},
        .syntax => if (!self.procSyntax()) {recover = true;},
        .map    => if (!(try self.procMap())) {recover = true;},
        .off    => switch (try self.procOff()) {
          .none => {},
          .recover => recover = true,
          .dont_consume_next => break :consume_next,
        },
        .fullast => {
          self.into.full_ast =
            self.parser.lexer.walker.posFrom(self.parser.cur_start);
          break :consume_next;
        },
        .empty => {
          self.parser.logger().ExpectedXGotY(
            self.parser.lexer.walker.posFrom(self.parser.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
              .{.token = self.parser.cur});
          recover = true;
          break :consume_next;
        },
        .unknown => {
          recover = true;
          break :consume_next;
        },
      }
      while (!self.parser.getNext()) {}
    }
    if (recover) {
      // skip over the error token, which might not be processable in default
      // context.
      self.parser.lexer.abortBlockHeader();
      self.parser.advance();
    } else while (
      switch (self.parser.cur) {
        .comma, .diamond_close, .end_source => false,
        else => true,
      }
    ) : (while (!self.parser.getNext()) {}) {
      if (self.parser.cur != .space) {
        self.parser.logger().ExpectedXGotY(
          self.parser.lexer.walker.posFrom(self.parser.cur_start),
          &[_]errors.WrongItemError.ItemDescr{
            .{.character = ','}, .{.character = '>'}
          }, .{.token = self.parser.cur});
        recover = true;
        break;
      }
    }
    if (recover) break;
  }
  if (self.parser.cur == .diamond_close) {
    self.parser.advance();
  } else if (!recover) {
    self.parser.logger().ExpectedXGotY(
      self.parser.lexer.walker.posFrom(self.parser.cur_start),
      &[_]errors.WrongItemError.ItemDescr{.{.token = .diamond_close}},
      .{.token = self.parser.cur});
  }
  self.into.map = self.map_list.items;
}