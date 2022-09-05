//! Implementation of the parser.
//! This is a separate type to distinguish the public API (of the type @This())
//! from the internal API (what this type provides). This type may only be
//! accessed from code in the module @This().zig and its children.

const std     = @import("std");
const builtin = @import("builtin");

const ContentLevel = @import("ContentLevel.zig");
const Globals      = @import("../Globals.zig");
const Lexer        = @import("Lexer.zig");
const nyarna       = @import("../../nyarna.zig");
const ModuleEntry  = @import("../Globals.zig").ModuleEntry;
const Parser       = @import("../Parser.zig");
const Resolver     = @import("../Interpreter/Resolver.zig");
const syntaxes     = @import("syntaxes.zig");
const unicode      = @import("../unicode.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const Loader      = nyarna.Loader;
const model       = nyarna.model;

const last = @import("../helpers.zig").last;

/// States of the parser.
const State = enum {
  /// skips over any space it finds, then transitions to default.
  start,
  /// same as start, but does not transition to default if list_end is
  /// encountered.
  possible_start,
  /// similar to possible_start, but for the primary block that doesn't exist
  /// if block_name_sep is encountered.
  possible_primary,
  /// reading content of a block or list argument. Allows inner blocks,
  /// swallowing and paragraph separators besides inner nodes that get pushed
  /// to the current level. Will ditch trailing space. Lexer will not produce
  /// structures that are not allowed (i.e. swallowing or blocks start inside
  /// list argument, or consecutive parseps).
  default,
  /// Used to merge literals space, ws_break and escape together.
  textual,
  /// used after closed list. checks for blocks start; if none is encountered,
  /// transitions to command.
  after_flow_list,
  /// checks if a new paragraph starts or if the block ends instead.
  after_paragraph_sep,
  /// used after any command. The current level's .command field will be
  /// .unknown and hold the occurred command in .subject.
  /// When encountering command continuation (e.g. opening list or blocks),
  /// set the .level.command's kind appropriately and open a new level.
  /// When encountering content, will push .level.command.unknown into .level
  /// and transition to .default. Handles error cases like .subject being
  /// prefix notation for a function but not being followed by a call.
  command,
  /// State after entering a block name. Skips space and ends previous block,
  /// then transitions to either block_name or skip_block_name.
  block_name_start,
  /// same as block_name_start, but doesn't end previous block level since this
  /// is the first named block without a primary block.
  first_block_name_start,
  /// read a valid block name, looks for finishing ':'
  block_name,
  /// as block_name, but for block names at top level
  skip_block_name,
  /// Looks for block config, then starts block content.
  after_block_name,
  /// This state expects a .call_id and then transitions to .after_id
  before_id,
  /// emits an error if anything but space occurs before ',' or ')'
  after_id,
  /// expects the call id, transitions to .expect_end_command_end
  end_command,
  /// expects ')', transitions to .command
  expect_end_command_end,
  /// same as expect_end_command_end, but transitions to .default
  expect_end_command_end_stop,
  /// after '::', expects identifier
  access,
  /// after ':=', expects '(' or ':'
  assign,
  /// This state passes lexer tokens to the special syntax processor.
  special,
  /// used when whitespace is encountered within special syntax
  special_after_space,
  /// after a ':' that may be followed by a block header
  block_header_start,
  /// after a '<' or ',' in block config
  block_config_start,
  block_config_csym,
  block_config_syntax,
  block_config_map,
  block_config_map_arg,
  block_config_off,
  block_config_empty,
  block_config_try_recover,
  /// after a finished block config item, expecting ',' or '>'
  block_config_after_item,
  /// look for ':', else transition to after_block_header
  after_block_config,
  /// after a '|', look for symbol or '|'
  block_capture_start,
  /// after block capture symbol, look for ',' or '|'
  block_capture,
  /// after a swallow depth number, look for '>'
  block_swallow_depth,
};

const ns_mapping_failed    = 1 << 15;
const ns_mapping_succeeded = (1 << 15) + 1;
const ns_mapping_no_from   = ns_mapping_succeeded;

/// stack of current levels. must have at least size of 1, with the first
/// level being the current source's root.
levels: std.ArrayListUnmanaged(ContentLevel),
/// stack of currently active namespace mapping statuses.
/// namespace mappings create a new namespace, disable a namespace, or map a
/// namespace from one character to another.
/// if a namespace is disabled, its index is pushed onto the stack.
/// other operations push either ns_mapping_failed or ns_mapping_succeeded.
ns_mapping_stack: std.ArrayListUnmanaged(u16),

lexer    : Lexer,
state    : State,
/// used for reporting errors that span multiple tokens. Set at the start of
/// the erroneous content.
stored_cursor: ?model.Cursor = null,
/// stores the given identifier for a block name.
block_name: union(enum) {
  simple: struct {
    name: []const u8,
    pos : model.Position,
  },
  node: *model.Node,
  none,
} = .none,
/// collects textual content in textual state
text: struct {
  content           : std.ArrayListUnmanaged(u8) = .{},
  non_space_len     : usize = 0,
  non_space_line_len: usize = 0,
  non_space_end     : model.Cursor = undefined,
  start             : model.Cursor,
},
/// memorizes whitespace in special syntax
special: struct {
  newlines  : u21,
  nl_pos    : model.Position,
  whitespace: []const u8,
  ws_pos    : model.Position,
},
/// information about the currently processed block header
block_header: struct {
  context: union(enum) {
    /// when processing the header of a primary block
    primary: struct {
      /// true if any kind of block header has been seen.
      guaranteed: bool,
    },
    /// when processing a header in syntax (after '{…}')
    push_to_syntax: *model.Value.BlockHeader,
    /// when processing the header of a named block
    named,
    /// block header at an illegal block name at root level
    ignored,
  },
  /// currently parsed block config.
  config: ?*model.BlockConfig,
  config_parser: struct {
    into    : *model.BlockConfig,
    map_list: std.ArrayListUnmanaged(model.BlockConfig.Map),
    map_from: u21,
  },
  /// capture variables
  captures: std.ArrayListUnmanaged(model.Value.Ast.VarDef),
} = undefined,

pub fn allocator(self: *@This()) std.mem.Allocator {
  return self.intpr().allocator();
}

pub fn intpr(self: *@This()) *Interpreter {
  return self.lexer.intpr;
}

pub fn logger(self: *@This()) *errors.Handler {
  return self.intpr().ctx.logger;
}

pub fn loader(self: *@This()) *Loader {
  return self.intpr().loader;
}

pub fn source(self: *@This()) *const model.Source {
  return self.lexer.walker.source;
}

fn pushLevel(self: *@This(), fullast: bool) !void {
  if (self.levels.items.len > 0) {
    std.debug.assert(self.curLevel().command.info != .unknown);
  }
  try self.levels.append(self.allocator(), ContentLevel{
    .start     = self.lexer.recent_end,
    .command   = undefined,
    .fullast   = fullast,
    .sym_start = self.intpr().symbols.items.len,
    .capture   = &.{},
  });
}

fn leaveLevel(self: *@This()) !void {
  var lvl = self.curLevel();
  const parent = &self.levels.items[self.levels.items.len - 2];
  const lvl_node = try lvl.finalize(self);
  try parent.command.pushArg(lvl_node);
  _ = self.levels.pop();
}

pub fn curLevel(self: *@This()) *ContentLevel {
  return last(self.levels.items);
}

pub fn procRootStart(self: *@This(), implicit_fullast: bool) !void {
  try self.pushLevel(implicit_fullast);
  self.state = .start;
}

fn procStart(self: *@This(), cur: model.TokenAt) !bool {
  if (cur.isIn(.{.space, .indent, .ws_break, .comment})) return true;
  self.state =
    if (self.curLevel().syntax_proc != null) .special else .default;
  return false;
}

fn procPossibleStart(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space, .comment => return true,
    .list_end => return try self.endList(),
    else => {
      try self.pushLevel(self.curLevel().fullast);
      self.state = .default;
      return false;
    },
  }
}

fn procEndSource(self: *@This(), cur: model.TokenAt) !void {
  while (self.levels.items.len > 1) {
    try self.leaveLevel();
    const parent = self.curLevel();
    if (parent.command.swallow_depth == null) {
      const spos = parent.command.mapper().subject_pos;
      if (self.lexer.paren_depth > 0) {
        self.logger().MissingClosingParenthesis(
          self.lexer.walker.posFrom(cur.start));
      } else {
        const name =
          if (spos.end.byte_offset - spos.start.byte_offset > 0)
            self.lexer.walker.contentIn(spos) else "<unnamed>";
        self.logger().MissingEndCommand(
          name, parent.command.mapper().subject_pos,
          self.lexer.walker.posFrom(cur.start));
      }
    }
    try parent.command.shift(
      self.intpr(), self.source(), cur.start, parent.fullast);
    try parent.append(self.intpr(), parent.command.info.unknown);
  }
}

fn procSymref(self: *@This(), cur: model.TokenAt) !void {
  self.curLevel().command = .{
    .start = cur.start,
    .info = .{
      .unknown = try self.intpr().resolveSymbol(
        self.lexer.walker.posFrom(cur.start),
        self.lexer.ns,
        std.unicode.utf8CodepointSequenceLength(
          self.lexer.code_point) catch unreachable,
        self.lexer.recent_id
      ),
    },
    .cur_cursor = undefined,
  };
  self.state = .command;
}

fn procParagraphEnd(self: *@This()) void {
  self.state = .after_paragraph_sep;
  self.curLevel().dangling = .{.parsep = self.lexer.newline_count};
}

fn procAfterParagraphSep(self: *@This(), cur: model.TokenAt) void {
  if (cur.isIn(.{.block_end_open, .end_source})) {
    self.curLevel().dangling = .none;
  }
  self.state = .default;
}

fn finishSwallowing(self: *@This(), at: model.Cursor) !void {
  var parent = &self.levels.items[self.levels.items.len - 2];
  while (parent.command.swallow_depth != null) {
    // end level that is swallowed
    try self.leaveLevel();
    // finalize swallowing command
    try parent.command.shift(
      self.intpr(), self.source(), at, parent.fullast);
    try parent.append(self.intpr(), parent.command.info.unknown);

    parent = &self.levels.items[self.levels.items.len - 2];
  }
}

fn procBlockNameStartColon(self: *@This(), cur: model.TokenAt) !void {
  try self.finishSwallowing(cur.start);
  self.state = .block_name_start;
}

fn procBlockNameStart(self: *@This(), cur: model.TokenAt) !void {
  if (cur.token == .space) return;
  if (self.levels.items.len == 1) {
    self.stored_cursor = cur.start;
    self.state = .skip_block_name;
  } else {
    try self.leaveLevel();
    switch (cur.token) {
      .identifier => {
        self.block_name = .{.simple = .{
          .name = self.lexer.walker.contentFrom(cur.start.byte_offset),
          .pos  = self.lexer.walker.posFrom(cur.start),
        }};
        self.stored_cursor = null;
      },
      else => {
        self.block_name = .none;
        self.stored_cursor = cur.start;
      },
    }
    self.state = .block_name;
  }
}

fn procFirstBlockNameStart(self: *@This(), cur: model.TokenAt) !void {
  switch (cur.token) {
    .space => return,
    .identifier => {
      self.block_name = .{.simple = .{
        .name = self.lexer.walker.contentFrom(cur.start.byte_offset),
        .pos  = self.lexer.walker.posFrom(cur.start),
      }};
      self.stored_cursor = null;
    },
    else => {
      self.block_name = .none;
      self.stored_cursor = cur.start;
    },
  }
  self.state = .block_name;
}

fn enterBlockNameExpr(self: *@This(), valid: bool, start: model.Cursor) !void {
  try self.pushLevel(self.curLevel().fullast);
  const lvl = self.curLevel();
  lvl.start = start;
  lvl.semantics = if (valid) .block_name else .discarded_block_name;
  // we create a command with a void target, then an assignment mapper on it.
  // This is okay because we won't finalize the assignment and extract the
  // pushed node instead. The assignment mapper is used because it handles
  // multiple values just like we want it here, with error messages.
  lvl.command = .{
    .start      = start,
    .info       = .{
      .unknown =
        try self.intpr().node_gen.@"void"(self.source().at(start)),
    },
    .cur_cursor = undefined,
  };
  lvl.command.startAssignment(self.intpr());
  self.state = .possible_start;
}

fn procBlockNameExprStart(self: *@This(), cur: model.TokenAt) !void {
  try self.finishSwallowing(cur.start);

  const valid = if (self.levels.items.len > 1) blk: {
    try self.leaveLevel();
    break :blk true;
  } else false;
  try self.enterBlockNameExpr(valid, self.lexer.recent_end);
}

fn procEndCommandToken(self: *@This(), cur: model.TokenAt) !void {
  try self.finishSwallowing(cur.start);

  self.state = .end_command;
}

fn procEndCommand(self: *@This(), cur: model.TokenAt) !void {
  switch (cur.token) {
    .space => {},
    .call_id => self.state = .expect_end_command_end,
    .wrong_call_id => {
      const cmd_start =
        self.levels.items[self.levels.items.len - 2].command.start;
      self.logger().WrongCallId(
        self.lexer.walker.posFrom(cur.start),
        self.lexer.recent_expected_id, self.lexer.recent_id,
        self.source().at(cmd_start));
      self.state = .expect_end_command_end;
    },
    .no_block_call_id => {
      self.logger().NoBlockToEnd(self.lexer.walker.posFrom(cur.start));
      self.state = .expect_end_command_end_stop;
    },
    else => {
      std.debug.assert(@enumToInt(cur.token) >=
        @enumToInt(model.Token.skipping_call_id));
      const cmd_start =
        self.levels.items[self.levels.items.len - 2].command.start;
      self.logger().SkippingCallId(
        self.lexer.walker.posFrom(cur.start),
        self.lexer.recent_expected_id, self.lexer.recent_id,
        self.source().at(cmd_start));
      const num_skipped = model.Token.numSkippedEnds(cur.token);
      var i: u32 = 0; while (i < num_skipped) : (i += 1) {
        try self.leaveLevel();
        const lvl = self.curLevel();
        try lvl.command.shift(
          self.intpr(), self.source(), cur.start, lvl.fullast);
        try lvl.append(self.intpr(), lvl.command.info.unknown);
      }
      self.state = .expect_end_command_end;
    },
  }
}

fn procExpectEndCommandEnd(self: *@This(), cur: model.TokenAt) !bool {
  const ret = switch (cur.token) {
    .space => return true,
    .list_end => true,
    else => blk: {
      self.logger().MissingClosingParenthesis(self.source().at(cur.start));
      break :blk false;
    },
  };
  try self.leaveLevel();
  self.state = .command;
  try self.curLevel().command.shift(
    self.intpr(), self.source(), self.lexer.recent_end, self.curLevel().fullast
  );
  return ret;
}

fn procExpectEndCommandEndStop(self: *@This(), cur: model.TokenAt) bool {
  switch (cur.token) {
    .space => return true,
    .list_end => {
      self.state = .default;
      return true;
    },
    else => {
      self.logger().MissingClosingParenthesis(self.source().at(cur.start));
      self.state = .default;
      return false;
    },
  }
}

fn procTextual(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => try self.text.content.appendSlice(
      self.allocator(), self.lexer.walker.contentFrom(cur.start.byte_offset)),
    .literal => {
      try self.text.content.appendSlice(self.allocator(),
          self.lexer.walker.contentFrom(cur.start.byte_offset));
      self.text.non_space_len = self.text.content.items.len;
      self.text.non_space_line_len = self.text.non_space_len;
      self.text.non_space_end = self.lexer.recent_end;
    },
    .ws_break => {
      // dump whitespace before newline
      self.text.content.shrinkRetainingCapacity(
        self.text.non_space_line_len);
      try self.text.content.append(self.allocator(), '\n');
      self.text.non_space_line_len = self.text.content.items.len;
    },
    .escape => {
      try self.text.content.appendSlice(
        self.allocator(), self.lexer.recent_id);
      self.text.non_space_len = self.text.content.items.len;
      self.text.non_space_line_len = self.text.non_space_len;
      self.text.non_space_end = self.lexer.recent_end;
    },
    .indent => {},
    .comment => {
      // dump whitespace before comment
      self.text.content.shrinkRetainingCapacity(self.text.non_space_line_len);
    },
    else => {
      const lvl = self.curLevel();
      const pos = switch (cur.token) {
        .block_end_open, .block_name_sep, .comma, .name_sep, .list_start,
        .list_end, .list_end_missing_colon, .end_source => blk: {
          self.text.content.shrinkAndFree(
            self.allocator(), self.text.non_space_len);
          break :blk self.source().between(
            self.text.start, self.text.non_space_end);
        },
        else => self.lexer.walker.posFrom(self.text.start),
      };
      if (self.text.content.items.len > 0) {
        if (cur.token == .name_sep) {
          const parent = &self.levels.items[self.levels.items.len - 2];
          if (
            lvl.nodes.items.len > 0 or
            parent.command.cur_cursor != .not_pushed
          ) {
            self.logger().IllegalNameSep(self.lexer.walker.posFrom(cur.start));
          } else {
            try parent.command.pushName(
              pos, self.text.content.items,
              self.lexer.walker.before.byte_offset - cur.start.byte_offset
                == 2, .flow);
            self.state = .start;
          }
          return true;
        } else {
          const node = (try self.intpr().node_gen.literal(pos,
            if (self.text.non_space_len > 0) .text else .space,
            self.text.content.items
          )).node();
          // dangling space will be postponed for the case of a following,
          // swallowing command that ends the current level.
          if (self.text.non_space_len > 0) try lvl.append(self.intpr(), node)
          else {
            switch (lvl.dangling) {
              .space  => unreachable,
              .parsep => |num_lines| try lvl.pushParagraph(self.intpr(), num_lines),
              .none   => {},
            }
            lvl.dangling = .{.space = node};
          }
          self.state = .default;
        }
      } else self.state = .default; // happens with space at block/arg end
      return false;
    },
  }
  return true;
}

fn procCommand(self: *@This(), cur: model.TokenAt) !bool {
  var lvl = self.curLevel();
  while (true) switch (lvl.command.info.unknown.data) {
    .import => |*import| {
      // ensure that the imported module has been parsed at least up until its
      // options declaration.
      const me = &self.intpr().ctx.data.known_modules.values()[
        import.module_index];
      switch (me.*) {
        .require_options => |ml| if (ml.state == .initial) {
          return Parser.UnwindReason.referred_module_unavailable;
        },
        .require_module => {
          // if another module set require_module already, it had taken
          // priority over the current module and therefore would have
          // already been loaded.
          unreachable;
        },
        .parsed, .pushed_param => unreachable,
        .loaded => |module| {
          // if the import is not called, generate an implicit call
          if (!cur.isIn(.{.list_start, .blocks_sep})) {
            if (module.root != null) {
              lvl.command.info.unknown = (
                try self.intpr().node_gen.uCall(import.node().pos, .{
                  .target = import.node(),
                  .proto_args = &.{},
                  .first_block_arg = 0,
                })
              ).node();
            } else {
              try self.intpr().importModuleSyms(module, import.ns_index);
              lvl.command.info.unknown.data = .void;
              break;
            }
          } else break;
        }
      }
    },
    .root_def => {
      if (self.loader().hasEncounteredOptions()) {
        return Parser.UnwindReason.encountered_options;
      } else break;
    },
    .unresolved_call => |*uc| switch (uc.target.data) {
      .import => |*import| {
        const me = &self.intpr().ctx.data.known_modules.values()[
          import.module_index];
        switch (me.*) {
          .require_options => |ml| {
            me.* = .{.require_module = ml};
            return Parser.UnwindReason.referred_module_unavailable;
          },
          .parsed, .require_module, .pushed_param => unreachable,
          .loaded => |module| {
            if (module.root) |root| {
              uc.target.data = .{
                .expression = try self.intpr().ctx.createValueExpr((
                  try self.intpr().ctx.values.funcRef(uc.node().pos, root)
                ).value())
              };
            } else {
              self.logger().CannotCallLibraryImport(uc.node().pos);
              uc.target.data = .poison;
            }
          }
        }
      },
      else => break,
    },
    else => break,
  };
  switch (cur.token) {
    .access => {
      self.state = .access;
      return true;
    },
    .assign => {
      self.state = .assign;
      return true;
    },
    .list_start, .blocks_sep => {
      const target = lvl.command.info.unknown;
      switch (target.data) {
        .import => |*import| {
          try lvl.command.startImportCall(self.intpr(), import);
        },
        else => {
          const ctx = try Resolver.CallContext.fromChain(
            self.intpr(), target, try Resolver.init(
              self.intpr(), .{.kind = .intermediate}).resolveChain(target));
          switch (ctx) {
            .known => |call_context| {
              try lvl.command.startResolvedCall(self.intpr(),
                call_context.target, call_context.ns,
                call_context.signature);
              if (call_context.first_arg) |prefix| {
                try lvl.command.pushArg(prefix);
              }
            },
            .unknown => try lvl.command.startUnresolvedCall(self.intpr()),
            .poison => {
              target.data = .poison;
              try lvl.command.startUnresolvedCall(self.intpr());
            }
          }
        },
      }
      if (cur.token == .list_start) {
        self.state = .possible_start;
      } else self.startBlockHeader(.{.primary = .{.guaranteed = false}});
      return true;
    },
    .closer => {
      try lvl.append(self.intpr(), lvl.command.info.unknown);
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
      return true;
    },
    else => {
      try lvl.append(self.intpr(), lvl.command.info.unknown);
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
      return false;
    },
  }
}

fn procAccess(self: *@This(), cur: model.TokenAt) !bool {
  const start = cur.start;
  const lvl = self.curLevel();
  if (cur.token == .identifier) {
    const name_node = try self.intpr().node_gen.literal(
      self.lexer.walker.posFrom(start), .text, self.lexer.recent_id);
    const access_node = try self.intpr().node_gen.uAccess(
      self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start),
      lvl.command.info.unknown,
      name_node.node(),
      self.lexer.ns,
    );
    lvl.command.info.unknown = access_node.node();
    self.state = .command;
    return true;
  } else {
    self.logger().MissingSymbolName(self.source().at(cur.start));
    lvl.command.info.unknown = try self.intpr().node_gen.poison(
      self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start));
    self.state = .default;
    return false;
  }
}

fn procAssign(self: *@This(), cur: model.TokenAt) !bool {
  const start = cur.start;
  const lvl = self.curLevel();
  switch (cur.token) {
    .list_start => {
      lvl.command.startAssignment(self.intpr());
      try self.pushLevel(self.curLevel().fullast);
      self.state = .start;
    },
    .blocks_sep => {
      lvl.command.startAssignment(self.intpr());
      self.startBlockHeader(.{.primary = .{.guaranteed = false}});
    },
    .closer => {
      self.logger().AssignmentWithoutExpression(
        self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start));
      self.state = .default;
      return true;
    },
    else => {
      const pos = model.Position{
        .source = self.source().meta,
        .start = lvl.command.info.unknown.pos.start,
        .end = start,
      };
      self.logger().AssignmentWithoutExpression(pos);
      self.state = .default;
      return false;
    }
  }
  return true;
}

fn endList(self: *@This()) !bool {
  const lvl = self.curLevel();
  switch (lvl.semantics) {
    .default => self.state = .after_flow_list,
    .discarded_block_name => {
      self.logger().BlockNameAtTopLevel(self.lexer.walker.posFrom(lvl.start));
      _ = self.levels.pop();
      self.startBlockHeader(.ignored);
    },
    .block_name => {
      self.block_name = .{.node = (
        lvl.command.info.assignment.pushed
      ) orelse (
        try self.intpr().node_gen.@"void"(self.source().at(lvl.command.start))
      )};
      _ = self.levels.pop();
      self.state = .after_block_name;
      return false;
    },
  }
  return true;
}

fn procAfterBlockName(self: *@This(), cur: model.TokenAt) !void {
  const parent = self.curLevel();
  switch (self.block_name) {
    .simple => |data| {
      try parent.command.pushName(data.pos, data.name, false,
        if (cur.token == .diamond_open) .block_with_config else .block_no_config
      );
    },
    .node => |node| {
      try parent.command.pushNameExpr(node, cur.token == .diamond_open);
    },
    .none => {
      self.logger().MissingBlockName(self.source().at(cur.start));
      parent.command.cur_cursor = .failed;
    },
  }
  self.startBlockHeader(.named);
}

fn startBlockHeader(self: *@This(), context: anytype) void {
  self.state = .block_header_start;
  self.block_header = .{
    .context       = context,
    .config        = null,
    .config_parser = undefined,
    .captures      = .{},
  };
}

fn procAfterFlowList(self: *@This(), cur: model.TokenAt) !bool {
  if (cur.token == .blocks_sep) {
    // call continues
    self.startBlockHeader(.{.primary = .{.guaranteed = false}});
    return true;
  } else {
    const lvl = self.curLevel();
    if (lvl.command.checkAutoSwallow()) |swallow_depth| {
      self.lexer.implicitSwallowOccurred();
      try self.pushLevel(if (
        lvl.command.choseAstNodeParam()
      ) false else lvl.fullast);
      if (lvl.implicitBlockConfig()) |config| {
        try self.applyBlockConfig(self.source().at(cur.start), config);
      }
      lvl.command.swallow_depth = swallow_depth;
      try self.closeSwallowing(swallow_depth);
      self.state = .start;
      return false;
    } else {
      try lvl.command.shift(
        self.intpr(), self.source(), cur.start, lvl.fullast);
      self.state = .command;
      return false;
    }
  }
}

fn procSkipSpace(self: *@This(), cur: model.TokenAt) !bool {
  if (cur.isIn(.{.space, .indent, .ws_break, .comment})) return true;
  self.state =
    if (self.curLevel().syntax_proc != null) .special else .default;
  return false;
}

fn procPossiblePrimary(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space, .indent => return true,
    .block_name_sep, .list_start => {
      const lvl = self.levels.pop();
      if (lvl.block_config) |c| try self.revertBlockConfig(c.*);
      if (cur.token == .block_name_sep) {
        self.state = .first_block_name_start;
      } else {
        try self.enterBlockNameExpr(true, self.lexer.recent_end);
      }
      return true;
    },
    else => {
      const parent = &self.levels.items[self.levels.items.len - 2];
      try parent.command.pushPrimary(self.source().at(cur.start), false);
      self.state = .start;
      return false;
    },
  }
}

fn procBlockName(self: *@This(), cur: model.TokenAt) bool {
  switch (cur.token) {
    .space => return true,
    .block_name_sep => {},
    .missing_block_name_sep => {
      self.logger().MissingBlockNameEnd(self.source().at(cur.start));
    },
    else => {
      if (self.stored_cursor == null) self.stored_cursor = cur.start;
      return true;
    },
  }
  if (self.stored_cursor) |start| {
    self.logger().IllegalContentInBlockName(self.lexer.walker.posFrom(start));
  }
  self.state = .after_block_name;
  return false;
}

fn procSkipBlockName(self: *@This(), cur: model.TokenAt) void {
  if (cur.token == .space) return;
  self.logger().BlockNameAtTopLevel(
    self.lexer.walker.posFrom(self.stored_cursor.?));
  switch (cur.token) {
    else => unreachable,
    .block_name_sep => self.startBlockHeader(.ignored),
    .missing_block_name_sep => {
      self.logger().MissingBlockNameEnd(self.source().at(cur.start));
      self.state = .default;
    },
  }
}

fn procBeforeId(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space, .comment => return true,
    .call_id        => {
      self.state = .after_id;
      return true;
    },
    else => {
      self.logger().MissingId(self.lexer.walker.posFrom(cur.start).before());
      self.state = .after_id;
      return false;
    },
  }
}

fn procAfterId(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space, .comment => return true,
    .comma           => {
      self.state = .start;
      _ = self.levels.pop();
      try self.pushLevel(self.curLevel().fullast);
      return true;
    },
    .list_end => {
      _ = self.levels.pop();
      return try self.endList();
    },
    .list_end_missing_colon => {
      self.logger().MissingColon(self.source().at(cur.start));
      _ = self.levels.pop();
      return try self.endList();
    },
    .end_source => {
      self.state = .default;
      return false;
    },
    else => {
      self.logger().IllegalContentAfterId(
        self.lexer.walker.posFrom(cur.start));
      const parent = &self.levels.items[self.levels.items.len - 2];
      parent.command.cur_cursor = .failed;
      self.state = .default;
      return false;
    },
  }
}

fn procSpecial(self: *@This(), cur: model.TokenAt) !bool {
  const proc = self.curLevel().syntax_proc.?;
  const result = try switch (cur.token) {
    .comment => return true,
    .indent => syntaxes.SpecialSyntax.Processor.Action.none,
    .space, .parsep => {
      self.enterSpecialWhitespace();
      return false;
    },
    .ws_break =>
      proc.push(proc, self.lexer.walker.posFrom(cur.start), .{.newlines = 1}),
    .escape =>
      proc.push(proc, self.lexer.walker.posFrom(cur.start),
        .{.escaped = self.lexer.recent_id}),
    .identifier =>
      proc.push(proc, self.lexer.walker.posFrom(cur.start),
        .{.literal = self.lexer.recent_id}),
    .special =>
      proc.push(proc, self.lexer.walker.posFrom(cur.start),
        .{.special_char = self.lexer.code_point}),
    .end_source, .block_name_sep, .list_start, .block_end_open => {
      const res =
        try proc.push(proc, self.source().at(cur.start), .{.newlines = 1});
      std.debug.assert(res == .none);
      self.state = .default;
      return false;
    },
    .symref => {
      self.state = .default;
      return false;
    },
    else => std.debug.panic("{}: unexpected token in special: {s}\n",
      .{self.source().at(cur.start).formatter(), @tagName(cur.token)}),
  };
  switch (result) {
    .none => {},
    .read_block_header => {
      const value = try self.intpr().ctx.global().create(model.Value);
      value.origin.start = cur.start;
      value.data = .{.block_header = .{}};
      const bh = &value.data.block_header;
      self.startBlockHeader(.{.push_to_syntax = bh});
      self.lexer.readBlockHeader();
    }
  }
  return true;
}

fn enterSpecialWhitespace(self: *@This()) void {
  self.state = .special_after_space;
  self.special = .{
    .newlines   = 0,
    .nl_pos     = undefined,
    .whitespace = &.{},
    .ws_pos     = undefined,
  };
}

fn procSpecialAfterSpace(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .comment => {
      self.special.whitespace = &.{};
      if (self.special.newlines == 0) {
        self.special.newlines = 1;
      }
      return true;
    },
    .space => {
      std.debug.assert(self.special.whitespace.len == 0);
      self.special.whitespace =
        self.lexer.walker.contentFrom(cur.start.byte_offset);
      self.special.ws_pos = self.lexer.walker.posFrom(cur.start);
      return true;
    },
    .ws_break, .parsep => {
      self.special.whitespace = &.{};
      self.special.newlines =
        if (cur.token == .ws_break) 1 else self.lexer.newline_count;
      self.special.nl_pos = self.lexer.walker.posFrom(cur.start);
      return true;
    },
    .end_source, .block_name_sep, .list_start, .block_end_open => {
      if (self.special.newlines == 0) {
        self.special.newlines = 1;
        self.special.nl_pos = self.source().at(cur.start);
      }
      const proc = self.curLevel().syntax_proc.?;
      const res = try proc.push(proc, self.special.nl_pos,
        .{.newlines = self.special.newlines});
      std.debug.assert(res == .none);
      self.state = .special;
      return false;
    },
    else => {
      const proc = self.curLevel().syntax_proc.?;
      if (self.special.newlines > 0) {
        const res = try proc.push(proc, self.special.nl_pos,
          .{.newlines = self.special.newlines});
        std.debug.assert(res == .none);
      }
      if (self.special.whitespace.len > 0) {
        const res = try proc.push(proc, self.special.ws_pos,
          .{.space = self.special.whitespace});
        std.debug.assert(res == .none);
      }
      self.state = .special;
      return false;
    }
  }
}

pub fn push(
  self: *@This(),
  cur: model.TokenAt,
) Parser.Error!bool {
  while (true) {
    const prev_state = self.state;
    switch (self.state) {
    .start            => if (try self.procStart(cur))           return false,
    .possible_start   => if (try self.procPossibleStart(cur))   return false,
    .possible_primary => if (try self.procPossiblePrimary(cur)) return false,
    .default        => switch (cur.token) {
      .comment => return false,
      .space, .escape, .literal, .ws_break => {
        self.state = .textual;
        self.text = .{.start = cur.start};
      },
      .end_source => {
        try self.procEndSource(cur);
        return true;
      },
      .indent           => return false,
      .symref           => {
        try self.procSymref(cur);
        return false;
      },
      .comma => {
        try self.leaveLevel();
        try self.pushLevel(self.curLevel().fullast);
        self.state = .start;
        return false;
      },
      .list_end => {
        try self.leaveLevel();
        if (try self.endList()) return false;
      },
      .list_end_missing_colon => {
        try self.leaveLevel();
        self.logger().MissingColon(self.source().at(cur.start));
        if (try self.endList()) return false;
      },
      .parsep           => {
        self.procParagraphEnd();
        return false;
      },
      .block_name_sep   => {
        try self.procBlockNameStartColon(cur);
        return false;
      },
      .list_start       => {
        try self.procBlockNameExprStart(cur);
        return false;
      },
      .block_end_open   => {
        try self.procEndCommandToken(cur);
        return false;
      },
      .name_sep         => {
        self.logger().IllegalNameSep(self.lexer.walker.posFrom(cur.start));
        return false;
      },
      .id_set           => {
        self.state = .before_id;
        return false;
      },
      else => std.debug.panic(
        "unexpected token in default: {s} at {}\n",
        .{@tagName(cur.token), cur.start.formatter()}),
    },
    .textual            => if (try self.procTextual(cur)) return false,
    .command            => if (try self.procCommand(cur)) return false,
    .after_flow_list    => if (try self.procAfterFlowList(cur)) return false,
    .after_block_name   => {
      try self.procAfterBlockName(cur);
      return false;
    },
    .after_paragraph_sep => self.procAfterParagraphSep(cur),
    .block_name_start   => {
      try self.procBlockNameStart(cur);
      return false;
    },
    .first_block_name_start => {
      try self.procFirstBlockNameStart(cur);
      return false;
    },
    .block_name         => if (self.procBlockName(cur)) return false,
    .skip_block_name    => {
      self.procSkipBlockName(cur);
      return false;
    },
    .before_id          => if (try self.procBeforeId(cur)) return false,
    .after_id           => if (try self.procAfterId(cur)) return false,
    .end_command        => {
      try self.procEndCommand(cur);
      return false;
    },
    .expect_end_command_end => {
      if (try self.procExpectEndCommandEnd(cur)) return false;
    },
    .expect_end_command_end_stop => {
      if (self.procExpectEndCommandEndStop(cur)) return false;
    },
    .access => if (try self.procAccess(cur)) return false,
    .assign => if (try self.procAssign(cur)) return false,
    .special            => if (try self.procSpecial(cur)) return false,
    .special_after_space=> if (try self.procSpecialAfterSpace(cur))return false,
    .block_header_start => if (try self.procBlockHeaderStart(cur)) return false,
    .block_config_start => if (try self.procBlockConfigStart(cur)) return false,
    .block_config_csym  => if (try self.procBlockConfigCsym(cur))  return false,
    .block_config_syntax=> if (try self.procBlockConfigSyntax(cur))return false,
    .block_config_map   => if (try self.procBlockConfigMap(cur))   return false,
    .block_config_map_arg =>
      if (try self.procBlockConfigMapArg(cur)) return false,
    .block_config_off   => if (try self.procBlockConfigOff(cur))   return false,
    .block_config_empty => if (try self.procBlockConfigEmpty(cur)) return false,
    .block_config_try_recover => {
      if (try self.procBlockConfigTryRecover(cur)) return false;
    },
    .block_config_after_item =>
      if (try self.procBlockConfigAfterItem(cur)) return false,
    .after_block_config => if (try self.procAfterBlockConfig(cur)) return false,
    .block_capture_start=> if (try self.procBlockCaptureStart(cur))return false,
    .block_capture      => if (try self.procBlockCapture(cur))     return false,
    .block_swallow_depth=> if (try self.procBlockSwallowDepth(cur))return false,
    }
    if (self.state == prev_state) {
      std.debug.panic("pushing {s} in state {s} didn't change state or consume",
        .{@tagName(cur.token), @tagName(prev_state)});
    }
  }
}

fn procBlockHeaderStart(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .diamond_open => {
      self.block_header.config_parser = .{
        .into     = switch (self.block_header.context) {
          .push_to_syntax => |bh| blk: {
            if (bh.config == null) {
              bh.config = @as(model.BlockConfig, undefined);
              break :blk &bh.config.?;
            } else break :blk try self.allocator().create(model.BlockConfig);
          },
          else => try self.allocator().create(model.BlockConfig),
        },
        .map_list = .{},
        .map_from = undefined,
      };
      self.block_header.config_parser.into.* = .{};
      self.state = .block_config_start;
      switch (self.block_header.context) {
        .primary => |*p| p.guaranteed = true,
        else     => {},
      }
      return true;
    },
    .pipe => {
      self.state = .block_capture_start;
      switch (self.block_header.context) {
        .primary => |*p| p.guaranteed = true,
        else     => {},
      }
      return true;
    },
    .swallow_depth => {
      switch (self.block_header.context) {
        .primary => |*p| p.guaranteed = true,
        else     => {}
      }
      self.state = .block_swallow_depth;
      self.stored_cursor = cur.start;
      return true;
    },
    .diamond_close => {
      switch (self.block_header.context) {
        .primary => |*p| p.guaranteed = true,
        else     => {},
      }
      try self.finishBlockHeader(self.lexer.recent_end, 0);
      return true;
    },
    else => {
      try self.finishBlockHeader(cur.start, null);
      return false;
    }
  }
}

fn procBlockConfigStart(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .diamond_close => {
      self.finalizeBlockConfig(self.lexer.walker.before);
      self.state = .after_block_config;
      return true;
    },
    .end_source => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .identifier}}, .{.token = .diamond_close}
      );
      self.finalizeBlockConfig(cur.start);
      self.state = .after_block_config;
      return false;
    },
    .identifier => {
      const name = self.lexer.walker.contentFrom(cur.start.byte_offset);
      self.state = switch (std.hash.Adler32.hash(name)) {
        std.hash.Adler32.hash("csym")    => .block_config_csym,
        std.hash.Adler32.hash("syntax")  => .block_config_syntax,
        std.hash.Adler32.hash("map")     => .block_config_map,
        std.hash.Adler32.hash("off")     => .block_config_off,
        std.hash.Adler32.hash("fullast") => blk: {
          self.block_header.config_parser.into.full_ast =
            self.lexer.walker.posFrom(cur.start);
          break :blk .block_config_after_item;
        },
        std.hash.Adler32.hash("")        => .block_config_empty,
        else => blk: {
          self.logger().UnknownConfigDirective(
            self.lexer.walker.posFrom(cur.start));
          break :blk .block_config_try_recover;
        },
      };
      self.stored_cursor = cur.start;
      return true;
    },
    else => unreachable,
  }
}

fn abortBlockHeader(self: *@This(), cur: model.TokenAt) !void {
  self.lexer.abortBlockHeader(cur.token == .ws_break);
  self.finalizeBlockConfig(cur.start);
  try self.finishBlockHeader(cur.start, null);
}

fn finalizeBlockConfig(self: *@This(), at: model.Cursor) void {
  self.block_header.config_parser.into.map =
    self.block_header.config_parser.map_list.items;
  if (self.block_header.config != null) {
    self.logger().MultipleBlockConfigs(self.source().at(at));
  } else {
    self.block_header.config = self.block_header.config_parser.into;
  }
}

fn procBlockConfigCsym(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .ns_char => {
      try self.block_header.config_parser.map_list.append(
        self.intpr().ctx.global(), .{
          .pos = self.lexer.walker.posFrom(self.stored_cursor.?),
          .from = 0, .to = self.lexer.code_point});
      self.state = .block_config_after_item;
      return true;
    },
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .ns_char}}, .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    }
  }
}

fn procBlockConfigSyntax(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .literal => {
      const syntax_name = self.lexer.walker.contentFrom(cur.start.byte_offset);
      switch (std.hash.Adler32.hash(syntax_name)) {
        std.hash.Adler32.hash("locations") => {
          self.block_header.config_parser.into.syntax = .{
            .pos = model.Position.intrinsic(),
            .index = 0,
          };
        },
        std.hash.Adler32.hash("definitions") => {
          self.block_header.config_parser.into.syntax = .{
            .pos = model.Position.intrinsic(),
            .index = 1,
          };
        },
        else => self.logger().UnknownSyntax(
          self.lexer.walker.posFrom(cur.start), syntax_name),
      }
      self.state = .block_config_after_item;
      return true;
    },
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .literal}}, .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    },
  }
}

fn procBlockConfigMap(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .ns_char => {
      self.block_header.config_parser.map_from = self.lexer.code_point;
      self.state = .block_config_map_arg;
      return true;
    },
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .ns_char}}, .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    },
  }
}

fn procBlockConfigMapArg(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .ns_char => {
      try self.block_header.config_parser.map_list.append(
        self.intpr().ctx.global(), .{
          .pos  = self.lexer.walker.posFrom(self.stored_cursor.?),
          .from = self.block_header.config_parser.map_from,
          .to   = self.lexer.code_point,
        });
      self.state = .block_config_after_item;
      return true;
    },
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .ns_char}}, .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    },
  }
}

fn procBlockConfigOff(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space   => return true,
    .comment => {
      self.block_header.config_parser.into.off_comment =
        self.lexer.walker.posFrom(self.stored_cursor.?);
      self.state = .block_config_after_item;
      return true;
    },
    .block_name_sep => {
      self.block_header.config_parser.into.off_colon =
        self.lexer.walker.posFrom(self.stored_cursor.?);
      self.state = .block_config_after_item;
      return true;
    },
    .ns_char => {
      try self.block_header.config_parser.map_list.append(
        self.intpr().ctx.global(), .{
          .pos  = self.lexer.walker.posFrom(self.stored_cursor.?),
          .from = self.lexer.code_point, .to = 0,
        });
      self.state = .block_config_after_item;
      return true;
    },
    else => {
      self.block_header.config_parser.into.off_comment =
        self.source().between(self.stored_cursor.?, cur.start);
      self.block_header.config_parser.into.off_colon =
        self.source().between(self.stored_cursor.?, cur.start);
      try self.block_header.config_parser.map_list.append(
        self.intpr().ctx.global(), .{
          .pos = self.source().between(self.stored_cursor.?, cur.start),
          .from = 0, .to = 0,
        });
      self.state = .block_config_after_item;
      return false;
    },
  }
}

fn procBlockConfigEmpty(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .identifier}}, .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    },
  }
}

fn procBlockConfigTryRecover(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => {},
    .comma => self.state = .block_config_start,
    .diamond_close => {
      self.finalizeBlockConfig(self.lexer.walker.before);
      self.state = .after_block_config;
    },
    else => {
      if (cur.token != .ws_break) {
        self.logger().ExpectedXGotY(
          self.lexer.walker.posFrom(cur.start),
          &.{.{.token = .comma}, .{.token = .diamond_close}},
          .{.token = cur.token});
      }
      try self.abortBlockHeader(cur);
      return cur.token != .end_source;
    }
  }
  return true;
}

fn procBlockConfigAfterItem(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .comma => {
      self.state = .block_config_start;
      return true;
    },
    .diamond_close => {
      self.finalizeBlockConfig(self.lexer.walker.before);
      self.state = .after_block_config;
      return true;
    },
    else => {
      self.logger().ExpectedXGotY(
        self.lexer.walker.posFrom(cur.start),
        &.{.{.token = .diamond_close}, .{.token = .comma}},
        .{.token = cur.token});
      self.state = .block_config_try_recover;
      return switch (cur.token) {
        .end_source, .ws_break => false,
        else => true,
      };
    },
  }
}

fn procAfterBlockConfig(self: *@This(), cur: model.TokenAt) !bool {
  if (cur.token == .blocks_sep) {
    self.state = .block_header_start;
    return true;
  }
  try self.finishBlockHeader(cur.start, null);
  return false;
}

fn procBlockCaptureStart(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .pipe => {
      self.state = .after_block_config;
      return true;
    },
    .symref => {
      try self.block_header.captures.append(self.allocator(), .{
        .ns = self.lexer.ns,
        // this will become a variable name, which must be global
        .name = try self.intpr().ctx.global().dupe(u8, self.lexer.recent_id),
        .pos  = self.lexer.walker.posFrom(cur.start),
      });
      self.state = .block_capture;
      return true;
    },
    .comma => {
      self.logger().MissingToken(
        self.source().at(cur.start),
        &.{.{.token = .symref}}, .{.token = .comma});
      return true;
    },
    else => {
      self.logger().MissingToken(
        self.source().at(cur.start),
        &.{.{.token = model.Token.pipe}}, .{.token = cur.token});
      self.lexer.abortCaptureList();
      try self.finishBlockHeader(cur.start, null);
      return true;
    },
  }
}

fn procBlockCapture(self: *@This(), cur: model.TokenAt) !bool {
  switch (cur.token) {
    .space => return true,
    .comma => {
      self.state = .block_capture_start;
      return true;
    },
    else   => {
      self.state = .block_capture_start;
      return false;
    }
  }
}

fn procBlockSwallowDepth(self: *@This(), cur: model.TokenAt) !bool {
  if (cur.token == .diamond_close) {
    try self.finishBlockHeader(self.lexer.recent_end, self.lexer.code_point);
    return true;
  } else {
    self.logger().MissingToken(
      self.source().at(cur.start),
      &.{.{.token = .diamond_close}}, .{.token = cur.token});
    try self.finishBlockHeader(cur.start, null);
    return false;
  }
}

fn finishBlockHeader(
  self         : *@This(),
  start        : model.Cursor,
  swallow_depth: ?u21,
) !void {
  const parent = self.curLevel();
  switch (self.block_header.context) {
    .primary => |p| {
      if (p.guaranteed) {
        try parent.command.pushPrimary(
          self.source().at(start), self.block_header.config != null);
      } else {
        const cfg = parent.command.mapper().spyPrimary();
        try self.pushLevel(if (cfg.ast_node) false else parent.fullast);
        if (cfg.config) |c| {
          try self.applyBlockConfig(self.source().at(start), c);
        }
        self.state = .possible_primary;
        return;
      }
    },
    .named => {},
    .push_to_syntax => |bh| {
      const proc = self.curLevel().syntax_proc.?;
      if (self.block_header.config) |res_cfg| {
        std.debug.assert(res_cfg == &bh.config.?);
      } else bh.config = null;
      const pos = self.source().between(bh.value().origin.start, start);
      bh.value().origin = pos;
      bh.swallow_depth = swallow_depth;
      _ = try proc.push(proc, pos, .{.block_header = bh});
      self.state = .special;
      return;
    },
    .ignored => {
      self.state = .default;
      return;
    },
  }
  // initialize level with fullast according to chosen param type.
  // may be overridden by block config.
  try self.pushLevel(
    if (parent.command.choseAstNodeParam()) false else parent.fullast);
  if (self.block_header.config) |c| {
    try self.applyBlockConfig(self.source().at(start), c);
  } else if (parent.implicitBlockConfig()) |c| {
    try self.applyBlockConfig(self.source().at(start), c);
  }
  self.curLevel().capture = self.block_header.captures.items;
  self.state = .start;

  if (swallow_depth) |depth| {
    parent.command.swallow_depth = swallow_depth;
    try self.closeSwallowing(depth);
  }
}

/// Close other swallowing levels when swallowing is encountered. `target_depth`
/// is to be the depth at which the new swallowing occurs. The level that will
/// contain the newly swallowed content must have been pushed prior to calling
/// this function.
///
/// Closes all commands that have a swallow depth equal or greater than
/// `target_depth`, excluding 0. To do this, we first determine the actual
/// level in which the current command is to be placed in (we'll skip the
/// innermost level which must have been pushed to contain the swallowed).
fn closeSwallowing(self: *@This(), target_depth: usize) !void {
  if (target_depth == 0) return;
  // calculate the level into which the current command should be pushed.
  var target_level: usize = self.levels.items.len - 2;
  const parent = &self.levels.items[target_level];
  // the level we're currently checking. Since we may need to look
  // beyond levels with swallow depth 0, we need to keep this in a variable
  // separate from `target_level`.
  var cur_depth: usize = target_level;
  while (cur_depth > 0) : (cur_depth = cur_depth - 1) {
    if (self.levels.items[cur_depth - 1].command.swallow_depth) |level_depth| {
      if (level_depth != 0) {
        if (level_depth < target_depth) break;
        target_level = cur_depth - 1;
      }
      // if level_depth is 0, we don't set target_level but still look
      // if it has parents that have a depth greater 0 and are ended by
      // the current swallow.
    } else break;
  }
  if (target_level < self.levels.items.len - 2) {
    // one or more levels need closing. calculate the end of the most
    // recent node, which will be the end cursor for all levels that
    // will now be closed. this cursor is not necesserily the start of
    // the current swallowing command, since whitespace before that
    // command is dumped.
    const end_cursor = if (parent.nodes.items.len == 0) (
      if (parent.seq.items.len == 0) (
        parent.start
      ) else last(parent.seq.items).content.pos.end
    ) else last(parent.nodes.items).*.pos.end;

    // dangling space of the current level will be transferred to the
    // target level.
    const dangling = self.levels.items[self.levels.items.len - 2].dangling;
    self.levels.items[self.levels.items.len - 2].dangling = .none;

    var i = self.levels.items.len - 2;
    while (i > target_level) : (i -= 1) {
      const cur_parent = &self.levels.items[i - 1];
      try cur_parent.command.pushArg(
        try self.levels.items[i].finalize(self));
      self.lexer.swallowEndOccurred();
      try cur_parent.command.shift(
        self.intpr(), self.source(), end_cursor, cur_parent.fullast);
      try cur_parent.append(
        self.intpr(), cur_parent.command.info.unknown);
    }
    // target_level's command has now been closed. therefore it is safe
    // to assign it to the previous parent's command
    // (which has not been touched).
    const tl = &self.levels.items[target_level];
    tl.command = parent.command;
    tl.dangling = dangling;

    // finally, shift the new level on top of the target_level
    self.levels.items[target_level + 1] = last(self.levels.items).*;
    try self.levels.resize(self.allocator(), target_level + 2);
  }
}

fn applyBlockConfig(
  self  : *@This(),
  pos   : model.Position,
  config: *const model.BlockConfig,
) !void {
  var sf = std.heap.stackFallback(128, self.allocator());
  var alloc = sf.get();
  const lvl = self.curLevel();

  if (config.syntax) |s| {
    const syntax = self.intpr().syntax_registry[s.index];
    lvl.syntax_proc = try syntax.init(self.intpr(), self.source());
    self.lexer.enableSpecialSyntax(syntax.comments_include_newline);
  }

  if (config.map.len > 0) {
    var resolved_indexes = try alloc.alloc(u16, config.map.len);
    defer alloc.free(resolved_indexes);
    try self.ns_mapping_stack.ensureUnusedCapacity(
      self.allocator(), config.map.len);
    // resolve all given `from` characters.
    for (config.map) |mapping, i| {
      resolved_indexes[i] =
        if (mapping.from == 0) ns_mapping_no_from
        else if (self.intpr().command_characters.get(mapping.from))
          |from_index| @intCast(u16, from_index)
        else blk: {
          const ec = unicode.EncodedCharacter.init(mapping.from);
          self.logger().IsNotANamespaceCharacter(ec.repr(), pos, mapping.pos);
          break :blk ns_mapping_failed;
        };
    }
    // disable all command characters that need disabling.
    for (config.map) |mapping, i| {
      if (mapping.to == 0) {
        const from_index = resolved_indexes[i];
        if (from_index != ns_mapping_failed) {
          _ = self.intpr().command_characters.remove(mapping.from);
        }
        try self.ns_mapping_stack.append(self.allocator(), from_index);
      }
    }
    // execute all namespace remappings
    for (config.map) |mapping, i| {
      const from_index = resolved_indexes[i];
      if (mapping.to != 0 and from_index != ns_mapping_no_from) {
        try self.ns_mapping_stack.append(self.allocator(), blk: {
          if (from_index == ns_mapping_failed) break :blk ns_mapping_failed;

          if (self.intpr().command_characters.get(mapping.to)) |_| {
            // check if an upcoming remapping will remove this character
            var found = false;
            for (config.map[i+1..]) |upcoming| {
              if (upcoming.from == mapping.to) {
                found = true;
                break;
              }
            }
            if (!found) {
              const ec = unicode.EncodedCharacter.init(mapping.to);
              self.logger().AlreadyANamespaceCharacter(
                ec.repr(), pos, mapping.pos);
              break :blk ns_mapping_failed;
            }
          }
          try self.intpr().command_characters.put(
            self.allocator(), mapping.to, @intCast(u15, from_index));
          // only remove old command character if it has not previously been
          // remapped.
          if (self.intpr().command_characters.get(mapping.from))
              |cur_from_index| {
            if (cur_from_index == from_index) {
              _ = self.intpr().command_characters.remove(mapping.from);
            }
          }
          break :blk ns_mapping_succeeded;
        });
      }
    }
    // establish all new namespaces
    for (config.map) |mapping, i| {
      if (resolved_indexes[i] == ns_mapping_no_from) {
        if (mapping.to == 0) {
          std.mem.swap(std.hash_map.AutoHashMapUnmanaged(u21, u15),
            &self.intpr().command_characters,
            &self.intpr().stored_command_characters);
          try self.ns_mapping_stack.append(
            self.allocator(), ns_mapping_succeeded);
        } else if (self.intpr().command_characters.get(mapping.to)) |_| {
          // this is not an error, but we still record it as 'failed' so
          // that we know when reversing this block config, nothing needs to
          // be done.
          try self.ns_mapping_stack.append(
            self.allocator(), ns_mapping_failed);
        } else {
          try self.intpr().addNamespace(mapping.to);
          try self.ns_mapping_stack.append(
            self.allocator(), ns_mapping_succeeded);
        }
      }
    }
  }

  if (config.off_colon != null) self.lexer.disableColons();
  if (config.off_comment != null) self.lexer.disableComments();
  if (config.full_ast != null) lvl.fullast = true;
  lvl.block_config = config;
}

pub fn revertBlockConfig(self  : *@This(), config: model.BlockConfig) !void {
  // config.syntax does not need to be reversed, this happens automatically by
  // leaving the level.

  if (config.map.len > 0) {
    var sf = std.heap.stackFallback(128, self.allocator());
    var alloc = sf.get();

    // reverse establishment of new namespaces
    var i = config.map.len - 1;
    while (true) : (i = i - 1) {
      const mapping = &config.map[i];
      if (mapping.from == 0) {
        if (self.ns_mapping_stack.pop() == ns_mapping_succeeded) {
          if (mapping.to == 0) {
            std.mem.swap(std.hash_map.AutoHashMapUnmanaged(u21, u15),
              &self.intpr().command_characters,
              &self.intpr().stored_command_characters);
          } else self.intpr().removeNamespace(mapping.to);
        }
      }
      if (i == 0) break;
    }

    // get the indexes of namespaces that have been remapped.
    var ns_indexes = try alloc.alloc(u15, config.map.len);
    defer alloc.free(ns_indexes);
    for (config.map) |mapping, j| {
      if (mapping.from != 0 and mapping.to != 0) {
        // command_characters may not have the .to character in case of
        // failure. we assign undefined here because this will be checked in
        // the next while loop.
        ns_indexes[j] =
          self.intpr().command_characters.get(mapping.to) orelse undefined;
      }
    }

    // reverse namespace remappings
    i = config.map.len - 1;
    while (true) : (i = i - 1) {
      const mapping = &config.map[i];
      if (mapping.from != 0 and mapping.to != 0) {
        if (self.ns_mapping_stack.pop() == ns_mapping_succeeded) {
          const ns_index = ns_indexes[i];
          // only remove command character if it has not already been reset
          // to another namespace.
          if (
            self.intpr().command_characters.get(mapping.to).? == ns_index
          ) {
            _ = self.intpr().command_characters.remove(mapping.to);
          }
          // this cannot fail because command_characters will always be
          // large enough to add another item without requiring allocation.
          self.intpr().command_characters.put(
            self.allocator(), mapping.from, ns_index) catch unreachable;
        }
      }
      if (i == 0) break;
    }

    // re-enable characters that have been disabled.
    i = config.map.len - 1;
    while (true) : (i = i - 1) {
      const mapping = &config.map[i];
      if (mapping.from != 0 and mapping.to == 0) {
        const ns_index = self.ns_mapping_stack.pop();
        if (ns_index != ns_mapping_failed) {
          // like above
          self.intpr().command_characters.put(
            self.allocator(), mapping.from, @intCast(u15, ns_index))
            catch unreachable;
        }
      }
      if (i == 0) break;
    }
  }

  // off_colon, off_comment, and special syntax are reversed automatically by
  // the lexer, except if the level is closed implicitly due to swallowing.
  // in that case, caller must tell lexer swallowEndOccurred.
  // full_ast is automatically reversed by leaving the level.
}