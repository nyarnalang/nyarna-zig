//! Implementation of the parser.
//! This is a separate type to distinguish the public API (of the type @This())
//! from the internal API (what this type provides). This type may only be
//! accessed from code in the module @This().zig and its children.

const std     = @import("std");
const builtin = @import("builtin");

const BlockConfig  = @import("BlockConfig.zig");
const ContentLevel = @import("ContentLevel.zig");
const Globals      = @import("../Globals.zig");
const Lexer        = @import("Lexer.zig");
const nyarna       = @import("../../nyarna.zig");
const ModuleEntry  = @import("../Globals.zig").ModuleEntry;
const Parser       = @import("../Parser.zig");
const PipeCapture  = @import("PipeCapture.zig");
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
  after_list,
  /// used after any command. The current level's .command field will be
  /// .unknown and hold the occurred command in .subject.
  /// When encountering command continuation (e.g. opening list or blocks),
  /// set the .level.command's kind appropriately and open a new level.
  /// When encountering content, will push .level.command.unknown into .level
  /// and transition to .default. Handles error cases like .subject being
  /// prefix notation for a function but not being followed by a call.
  command,
  /// This state checks whether a primary block exists after a blocks start.
  /// A primary block exists when any of the following is true:
  /// a block config exists, any non-space content appears before the
  /// occurrence of a block name, or an \end() command directly closes the
  /// blocks.
  after_blocks_start,
  /// This state reads in a block name, possibly a block configuration, and
  /// then pushes a level to read the block content.
  block_name,
  /// This state expects a .call_id and then transitions to .after_id
  before_id,
  /// emits an error if anything but space occurs before ',' or ')'
  after_id,
  /// This state passes lexer tokens to the special syntax processor.
  special,
};

const ns_mapping_failed = 1 << 15;
const ns_mapping_succeeded = (1 << 15) + 1;
const ns_mapping_no_from = ns_mapping_succeeded;

/// stack of current levels. must have at least size of 1, with the first
/// level being the current source's root.
levels: std.ArrayListUnmanaged(ContentLevel),
/// currently parsed block config. Filled in the .config state.
config: ?*model.BlockConfig,
/// stack of currently active namespace mapping statuses.
/// namespace mappings create a new namespace, disable a namespace, or map a
/// namespace from one character to another.
/// if a namespace is disabled, its index is pushed onto the stack.
/// other operations push either ns_mapping_failed or ns_mapping_succeeded.
ns_mapping_stack: std.ArrayListUnmanaged(u16),

lexer    : Lexer,
state    : State,
cur      : model.Token,
cur_start: model.Cursor,

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

pub fn parseFile(
  self: *@This(),
  path: []const u8,
  locator: model.Locator,
  context: *Interpreter,
) !*model.Node {
  const file = try std.fs.cwd().openFile(path, .{});
  defer file.close();
  const file_contents = try std.fs.cwd().readFileAlloc(
    self.allocator(), path, (try file.stat()).size + 4);
  std.mem.copy(
    u8, file_contents[(file_contents.len - 4)..], "\x04\x04\x04\x04");
  return self.parseSource(&model.Source{
      .content = file_contents,
      .offsets = .{.line = 0, .column = 0},
      .name = path,
      .locator = locator,
      .locator_ctx = locator.parent()
    }, context);
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

/// retrieves the next valid token from the lexer.
/// emits errors for any invalid token along the way.
pub fn advance(self: *@This()) void {
  while (true) {
    self.cur_start = self.lexer.recent_end;
    (switch (self.lexer.next() catch blk: {
      const start = self.cur_start;
      const next = while (true) {
        break self.lexer.next() catch continue;
      } else unreachable;
      self.logger().InvalidUtf8Encoding(self.lexer.walker.posFrom(start));
      break :blk next;
    }) {
      // the following errors are not handled here since they indicate
      // structure:
      //   missing_block_name_sep (ends block name)
      //   wrong_call_id, skipping_call_id (end a call)
      //
      .illegal_code_point => errors.Handler.IllegalCodePoint,
      .illegal_opening_parenthesis =>
        errors.Handler.IllegalOpeningParenthesis,
      .illegal_blocks_start_in_args =>
        errors.Handler.IllegalBlocksStartInArgs,
      .illegal_command_char => errors.Handler.IllegalCommandChar,
      .illegal_characters => errors.Handler.IllegalCharacters,
      .mixed_indentation => errors.Handler.MixedIndentation,
      .illegal_indentation => errors.Handler.IllegalIndentation,
      .illegal_content_at_header => errors.Handler.IllegalContentAtHeader,
      .invalid_end_command => errors.Handler.InvalidEndCommand,
      .comment => continue,
      else => |t| {
        self.cur = t;
        break;
      }
    })(self.logger(), self.lexer.walker.posFrom(self.cur_start));
  }
}

/// retrieves the next token from the lexer. true iff that token is valid.
/// if false is returned, self.cur is to be considered undefined.
pub fn getNext(self: *@This()) bool {
  self.cur_start = self.lexer.recent_end;
  (switch (self.lexer.next() catch {
    self.logger().InvalidUtf8Encoding(
      self.lexer.walker.posFrom(self.cur_start));
    return false;
  }) {
    .missing_block_name_sep => errors.Handler.MissingBlockNameEnd,
    .illegal_code_point => errors.Handler.IllegalCodePoint,
    .illegal_opening_parenthesis => errors.Handler.IllegalOpeningParenthesis,
    .illegal_blocks_start_in_args => errors.Handler.IllegalBlocksStartInArgs,
    .illegal_command_char => errors.Handler.IllegalCommandChar,
    .illegal_characters => errors.Handler.IllegalCharacters,
    .mixed_indentation => errors.Handler.MixedIndentation,
    .illegal_indentation => errors.Handler.IllegalIndentation,
    .illegal_content_at_header => errors.Handler.IllegalContentAtHeader,
    .invalid_end_command => errors.Handler.InvalidEndCommand,
    .no_block_call_id => unreachable,
    .wrong_call_id => unreachable,
    .skipping_call_id => unreachable,
    else => |t| {
      if (@enumToInt(t) > @enumToInt(model.Token.skipping_call_id))
        unreachable;
      self.cur = t;
      return true;
    }
  })(self.logger(), self.lexer.walker.posFrom(self.cur_start));
  return false;
}

fn leaveLevel(self: *@This()) !void {
  var lvl = self.curLevel();
  const parent = &self.levels.items[self.levels.items.len - 2];
  const lvl_node = try lvl.finalize(self);
  try parent.command.pushArg(lvl_node);
  _ = self.levels.pop();
}

fn curLevel(self: *@This()) *ContentLevel {
  return last(self.levels.items);
}

fn procStart(self: *@This(), implicit_fullast: bool) !void {
  while (self.cur == .space or self.cur == .indent) self.advance();
  // this state is used for initial top-level and for list arguments.
  // list arguments do not change block configuration and so will always
  // inherit parent's fullast. the top-level will not be fullast unless
  // instructed by the caller.
  try self.pushLevel(
    if (self.levels.items.len == 0) implicit_fullast
    else self.curLevel().fullast);
  self.state = .default;
}

fn procPossibleStart(self: *@This()) !void {
  while (self.cur == .space) self.advance();
  if (self.cur == .list_end) {
    self.state = .after_list;
  } else {
    try self.pushLevel(self.curLevel().fullast);
    self.state = .default;
  }
}

fn procEndSource(self: *@This()) !void {
  while (self.levels.items.len > 1) {
    try self.leaveLevel();
    const parent = self.curLevel();
    if (parent.command.swallow_depth == null) {
      const spos = parent.command.mapper.subject_pos;
      if (self.lexer.paren_depth > 0) {
        self.logger().MissingClosingParenthesis(
          self.lexer.walker.posFrom(self.cur_start));
      } else {
        const name =
          if (spos.end.byte_offset - spos.start.byte_offset > 0)
            self.lexer.walker.contentIn(spos) else "<unnamed>";
        self.logger().MissingEndCommand(
          name, parent.command.mapper.subject_pos,
          self.lexer.walker.posFrom(self.cur_start));
      }
    }
    try parent.command.shift(
      self.intpr(), self.source(), self.cur_start, parent.fullast);
    try parent.append(self.intpr(), parent.command.info.unknown);
  }
}

fn procSymref(self: *@This()) !void {
  self.curLevel().command = .{
    .start = self.cur_start,
    .info = .{
      .unknown = try self.intpr().resolveSymbol(
        self.lexer.walker.posFrom(self.cur_start),
        self.lexer.ns,
        std.unicode.utf8CodepointSequenceLength(
          self.lexer.code_point) catch unreachable,
        self.lexer.recent_id
      ),
    },
    .mapper = undefined,
    .cur_cursor = undefined,
  };
  self.state = .command;
  self.advance();
}

fn procLeaveArg(self: *@This()) !void {
  try self.leaveLevel();
  if (self.cur == .comma) {
    self.advance();
    self.state = .start;
  } else self.state = .after_list;
}

fn procParagraphEnd(self: *@This()) !void {
  const newline_count = self.lexer.newline_count;
  self.advance();
  if (self.cur != .block_end_open and self.cur != .end_source) {
    self.curLevel().dangling = .{.parsep = newline_count};
  }
}

/// skip over possible block configuration, including swallow spec.
/// used for top-level block names that do not correspond to a call.
fn skipOverBlockConfig(self: *@This()) !void {
  self.advance();
  var colon_start: ?model.Position = null;
  var buffer: model.BlockConfig = undefined;
  const check_pipe = if (self.cur == .diamond_open) blk: {
    try BlockConfig.init(
      &buffer, self.allocator(), self).parse();
    if (self.cur == .blocks_sep) {
      colon_start = self.lexer.walker.posFrom(self.cur_start);
      self.advance();
      break :blk true;
    } else break :blk false;
  } else true;
  const check_swallow = if (check_pipe) if (self.cur == .pipe) blk: {
    try PipeCapture.init(self, self.curLevel()).parse();
    if (self.cur == .blocks_sep) {
      colon_start = self.lexer.walker.posFrom(self.cur_start);
      self.advance();
      break :blk true;
    } else break :blk false;
  } else true else false;
  if (check_swallow) _ = self.checkSwallow(colon_start);
}

fn procBlockNameStart(self: *@This()) !void {
  if (self.levels.items.len == 1) {
    const start = self.cur_start;
    while (true) {
      self.advance();
      if (
        self.cur == .block_name_sep or
        self.cur == .missing_block_name_sep
      ) break;
    }
    if (self.cur == .block_name_sep) {
      try self.skipOverBlockConfig();
    } else self.advance();
    self.logger().BlockNameAtTopLevel(self.lexer.walker.posFrom(start));
  } else {
    try self.leaveLevel();
    self.state = .block_name;
  }
}

fn enterBlockNameExpr(self: *@This(), valid: bool) !void {
  const start = self.cur_start;
  while (self.cur == .space) self.advance();
  try self.pushLevel(self.curLevel().fullast);
  const lvl = self.curLevel();
  lvl.start = start;
  lvl.semantics = if (valid) .block_name else .discarded_block_name;
  // we create a command with a void target, then an assignment mapper on it.
  // This is okay because we won't finalize the assignment and extract the
  // pushed node instead. The assignment mapper is used because it handles
  // multiple values just like we want it here, with error messages.
  lvl.command = .{
    .start      = self.cur_start,
    .info       = .{
      .unknown =
        try self.intpr().node_gen.@"void"(self.source().at(start)),
    },
    .mapper     = undefined,
    .cur_cursor = undefined,
  };
  lvl.command.startAssignment(self.intpr());
  self.state = .possible_start;
  self.advance();
}

fn procBlockNameExprStart(self: *@This()) !void {
  const valid = if (self.levels.items.len > 1) blk: {
    try self.leaveLevel();
    break :blk true;
  } else false;
  try self.enterBlockNameExpr(valid);
}

fn procEndCommand(self: *@This()) !void {
  self.advance();
  const do_shift = switch (self.cur) {
    .call_id => blk: {
      try self.leaveLevel();
      break :blk true;
    },
    .wrong_call_id => blk: {
      const cmd_start =
        self.levels.items[self.levels.items.len - 2].command.start;
      self.logger().WrongCallId(
        self.lexer.walker.posFrom(self.cur_start),
        self.lexer.recent_expected_id, self.lexer.recent_id,
        self.source().at(cmd_start));
      try self.leaveLevel();
      break :blk true;
    },
    .no_block_call_id => blk: {
      self.logger().NoBlockToEnd(self.lexer.walker.posFrom(self.cur_start));
      break :blk false;
    },
    else => blk: {
      std.debug.assert(@enumToInt(self.cur) >=
        @enumToInt(model.Token.skipping_call_id));
      const cmd_start =
        self.levels.items[self.levels.items.len - 2].command.start;
      self.logger().SkippingCallId(
        self.lexer.walker.posFrom(self.cur_start),
        self.lexer.recent_expected_id, self.lexer.recent_id,
        self.source().at(cmd_start));
      const num_skipped = model.Token.numSkippedEnds(self.cur);
      var i: u32 = 0; while (i < num_skipped) : (i += 1) {
        try self.leaveLevel();
        const lvl = self.curLevel();
        try lvl.command.shift(
          self.intpr(), self.source(), self.cur_start, lvl.fullast);
        try lvl.append(self.intpr(), lvl.command.info.unknown);
      }
      try self.leaveLevel();
      break :blk true;
    },
  };
  self.advance();
  if (self.cur == .list_end) {
    self.advance();
  } else {
    self.logger().MissingClosingParenthesis(self.source().at(self.cur_start));
  }
  if (do_shift) {
    self.state = .command;
    try self.curLevel().command.shift(
      self.intpr(), self.source(), self.cur_start, self.curLevel().fullast);
  }
}

fn procIllegalNameSep(self: *@This()) void {
  self.logger().IllegalNameSep(self.lexer.walker.posFrom(self.cur_start));
  self.advance();
}

fn procIdSet(self: *@This()) void {
  self.state = .before_id;
  self.advance();
}

fn procTextual(self: *@This()) !void {
  var content: std.ArrayListUnmanaged(u8) = .{};
  var non_space_len: usize = 0;
  var non_space_line_len: usize = 0;
  var non_space_end: model.Cursor = undefined;
  const textual_start = self.cur_start;
  while (true) {
    switch (self.cur) {
      .space =>
        try content.appendSlice(self.allocator(),
            self.lexer.walker.contentFrom(self.cur_start.byte_offset)),
      .literal => {
        try content.appendSlice(self.allocator(),
            self.lexer.walker.contentFrom(self.cur_start.byte_offset));
        non_space_len = content.items.len;
        non_space_line_len = non_space_len;
        non_space_end = self.lexer.recent_end;
      },
      .ws_break => {
        // dump whitespace before newline
        content.shrinkRetainingCapacity(non_space_line_len);
        try content.append(self.allocator(), '\n');
        non_space_line_len = content.items.len;
      },
      .escape => {
        try content.appendSlice(self.allocator(), self.lexer.recent_id);
        non_space_len = content.items.len;
        non_space_line_len = non_space_len;
        non_space_end = self.lexer.recent_end;
      },
      .indent => {},
      .comment => {
        // dump whitespace before comment
        content.shrinkRetainingCapacity(non_space_line_len);
      },
      else => break
    }
    if (!self.getNext()) {
      self.advance();
      break;
    }
  }
  const lvl = self.curLevel();
  const pos = switch (self.cur) {
    .block_end_open, .block_name_sep, .comma, .name_sep, .list_start, .list_end,
    .list_end_missing_colon, .end_source => blk: {
      content.shrinkAndFree(self.allocator(), non_space_len);
      break :blk self.source().between(textual_start, non_space_end);
    },
    else => self.lexer.walker.posFrom(textual_start),
  };
  if (content.items.len > 0) {
    if (self.cur == .name_sep) {
      const parent = &self.levels.items[self.levels.items.len - 2];
      if (
        lvl.nodes.items.len > 0 or
        parent.command.cur_cursor != .not_pushed
      ) {
        self.logger().IllegalNameSep(
          self.lexer.walker.posFrom(self.cur_start));
        self.advance();
      } else {
        try parent.command.pushName(
          pos, content.items,
          self.lexer.walker.before.byte_offset - self.cur_start.byte_offset
            == 2, .flow);
        while (true) {
          self.advance();
          if (self.cur != .space) break;
        }
      }
    } else {
      const node = (try self.intpr().node_gen.literal(pos, .{
        .kind = if (non_space_len > 0) .text else .space,
        .content = content.items
      })).node();
      // dangling space will be postponed for the case of a following,
      // swallowing command that ends the current level.
      if (non_space_len > 0) try lvl.append(self.intpr(), node)
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
}

fn procCommand(self: *@This()) !void {
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
        .pushed_param => unreachable,
        .loaded => |module| {
          // if the import is not called, generate an implicit call
          if (self.cur != .list_start and self.cur != .blocks_sep) {
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
          .require_module, .pushed_param => unreachable,
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
  switch (self.cur) {
    .access => {
      const start = self.lexer.recent_end;
      self.advance();
      lvl.command.info.unknown = if (self.cur == .identifier) blk: {
        const access_node = try self.intpr().node_gen.uAccess(
          self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start),
          .{
            .subject = lvl.command.info.unknown,
            .id = self.lexer.recent_id,
            .id_pos = self.lexer.walker.posFrom(start),
            .ns = self.lexer.ns,
          }
        );
        self.advance();
        break :blk access_node.node();
      } else blk: {
        self.logger().MissingSymbolName(self.source().at(self.cur_start));
        break :blk try self.intpr().node_gen.poison(
          self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start));
      };
    },
    .assign => {
      const start = self.lexer.recent_end;
      self.advance();
      switch (self.cur) {
        .list_start => self.state = .start,
        .blocks_sep => self.state = .after_blocks_start,
        .closer => {
          self.logger().AssignmentWithoutExpression(
            self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start));
          self.state = .default;
          self.advance();
          return;
        },
        else => {
          const pos = model.Position{
            .source = self.source().meta,
            .start = lvl.command.info.unknown.pos.start,
            .end = start,
          };
          self.logger().AssignmentWithoutExpression(pos);
          self.state = .default;
          return;
        }
      }
      lvl.command.startAssignment(self.intpr());
      self.advance();
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
      self.state =
        if (self.cur == .list_start) .possible_start else .after_blocks_start;
      self.advance();
    },
    .closer => {
      try lvl.append(self.intpr(), lvl.command.info.unknown);
      self.advance();
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
    },
    else => {
      try lvl.append(self.intpr(), lvl.command.info.unknown);
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
    }
  }
}

fn procAfterList(self: *@This()) !void {
  const end = self.lexer.recent_end;
  const lvl = self.curLevel();
  switch (lvl.semantics) {
    .default => {
      self.advance();
      if (self.cur == .blocks_sep) {
        // call continues
        self.state = .after_blocks_start;
        self.advance();
      } else {
        if (lvl.command.checkAutoSwallow()) |swallow_depth| {
          self.lexer.implicitSwallowOccurred();
          try self.pushLevel(if (
            lvl.command.choseAstNodeParam()
          ) false else lvl.fullast);
          if (lvl.implicitBlockConfig()) |config| {
            try self.applyBlockConfig(self.source().at(end), config);
          }
          lvl.command.swallow_depth = swallow_depth;
          try self.closeSwallowing(swallow_depth);
          while (
            self.cur == .space or self.cur == .indent or self.cur == .ws_break
          ) self.advance();
          self.state = .default;
        } else {
          try lvl.command.shift(self.intpr(), self.source(), end, lvl.fullast);
          self.state = .command;
        }
      }
      return;
    },
    .discarded_block_name => {
      if (self.cur == .list_end) {
        try self.skipOverBlockConfig();
      } else {
        self.logger().MissingColon(self.source().at(end));
      }
      self.logger().BlockNameAtTopLevel(self.lexer.walker.posFrom(lvl.start));
      _ = self.levels.pop();
      self.state = if (
        self.curLevel().syntax_proc != null
      ) .special else .default;
    },
    .block_name => {
      const node = (
        lvl.command.info.assignment.pushed
      ) orelse (
        try self.intpr().node_gen.@"void"(self.source().at(lvl.command.start))
      );
      _ = self.levels.pop();
      const parent = self.curLevel();
      self.advance();
      try parent.command.pushNameExpr(node, self.cur == .diamond_open);
      try self.pushLevel(
        if (parent.command.choseAstNodeParam()) false else parent.fullast);
      if (!(try self.processBlockHeader(null))) {
        if (parent.implicitBlockConfig()) |c| {
          try self.applyBlockConfig(self.source().at(self.cur_start), c);
        }
      }
      while (
        self.cur == .space or self.cur == .indent or self.cur == .ws_break
      ) self.advance();
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
    }
  }
}

fn procAfterBlocksStart(self: *@This()) !void {
  var pb_exists = PrimaryBlockExists.unknown;
  if (try self.processBlockHeader(&pb_exists)) {
    self.state =
      if (self.curLevel().syntax_proc != null) .special else .default;
  } else {
    while (self.cur == .space or self.cur == .indent) self.advance();
    if (self.cur == .block_name_sep or self.cur == .list_start) {
      switch (pb_exists) {
        .unknown => {},
        .maybe => {
          const lvl = self.levels.pop();
          if (lvl.block_config) |c| try self.revertBlockConfig(c.*);
        },
        .yes => try self.leaveLevel(),
      }
      if (self.cur == .list_start) {
        try self.enterBlockNameExpr(true);
      } else {
        self.state = .block_name;
      }
    } else {
      if (pb_exists == .unknown) {
        const lvl = self.curLevel();
        // neither explicit nor implicit block config. fullast is thus
        // inherited except when an AstNode parameter has been chosen.
        try self.pushLevel(
          if (lvl.command.choseAstNodeParam()) false else lvl.fullast);
      }
      self.state =
        if (self.curLevel().syntax_proc != null) .special else .default;
    }
  }
}

fn procBlockName(self: *@This()) !void {
  while (true) {
    self.advance();
    if (self.cur != .space) break;
  }
  const parent = self.curLevel();
  if (self.cur == .identifier) {
    const name = self.lexer.walker.contentFrom(self.cur_start.byte_offset);
    const name_pos = self.lexer.walker.posFrom(self.cur_start);
    var recover = false;
    while (true) {
      self.advance();
      if (
        self.cur == .block_name_sep or
        self.cur == .missing_block_name_sep
      ) break;
      if (self.cur != .space and !recover) {
        self.logger().ExpectedXGotY(
          self.lexer.walker.posFrom(self.cur_start),
          &[_]errors.WrongItemError.ItemDescr{
            .{.token = .block_name_sep}
          }, .{.token = self.cur});
        recover = true;
      }
    }
    if (self.cur == .missing_block_name_sep) {
      self.logger().MissingBlockNameEnd(self.source().at(self.cur_start));
    }
    try parent.command.pushName(name_pos, name, false,
      if (self.cur == .diamond_open) .block_with_config else .block_no_config
    );
  } else {
    self.logger().ExpectedXGotY(self.source().at(self.cur_start),
      &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
      .{.token = self.cur});
    while (
      self.cur != .block_name_sep and self.cur != .missing_block_name_sep
    ) self.advance();
    parent.command.cur_cursor = .failed;
  }
  self.advance();
  // initialize level with fullast according to chosen param type.
  // may be overridden by block config in following processBlockHeader.
  try self.pushLevel(
    if (parent.command.choseAstNodeParam()) false else parent.fullast);
  if (!(try self.processBlockHeader(null))) {
    if (parent.implicitBlockConfig()) |c| {
      try self.applyBlockConfig(self.source().at(self.cur_start), c);
    }
  }
  while (
    self.cur == .space or self.cur == .indent or self.cur == .ws_break
  ) self.advance();
  self.state = if (
    self.curLevel().syntax_proc != null
  ) .special else .default;
}

fn procBeforeId(self: *@This()) !void {
  while (self.cur == .space) self.advance();
  if (self.cur == .call_id) {
    self.advance();
  } else {
    self.logger().MissingId(
      self.lexer.walker.posFrom(self.cur_start).before());
  }
  self.state = .after_id;
}

fn procAfterId(self: *@This()) !void {
  while (self.cur == .space) self.advance();
  switch (self.cur) {
    .comma => {
      self.state = .start;
      self.advance();
      _ = self.levels.pop();
    },
    .list_end, .list_end_missing_colon => {
      self.state = .after_list;
      _ = self.levels.pop();
    },
    .end_source => self.state = .default,
    else => {
      self.logger().IllegalContentAfterId(
        self.lexer.walker.posFrom(self.cur_start));
      const parent = &self.levels.items[self.levels.items.len - 2];
      parent.command.cur_cursor = .failed;
      self.state = .default;
    }
  }
}

fn procSpecial(self: *@This()) !void {
  const proc = self.curLevel().syntax_proc.?;
  const result = try switch (self.cur) {
    .indent => syntaxes.SpecialSyntax.Processor.Action.none,
    .space =>
      proc.push(proc, self.lexer.walker.posFrom(self.cur_start), .{
        .space = self.lexer.walker.contentFrom(self.cur_start.byte_offset)
      }),
    .escape =>
      proc.push(proc, self.lexer.walker.posFrom(self.cur_start),
        .{.escaped = self.lexer.recent_id}),
    .identifier =>
      proc.push(proc, self.lexer.walker.posFrom(self.cur_start),
        .{.literal = self.lexer.recent_id}),
    .special =>
      proc.push(proc, self.lexer.walker.posFrom(self.cur_start),
        .{.special_char = self.lexer.code_point}),
    .ws_break, .parsep => {
      const num_breaks: u16 =
        if (self.cur == .ws_break) 1 else self.lexer.newline_count;
      const pos = self.lexer.walker.posFrom(self.cur_start);
      while (true) {
        self.advance();
        if (self.cur != .indent) break;
      }
      switch (self.cur) {
        .end_source, .block_name_sep, .list_start, .block_end_open => {
          self.state = .default;
          return;
        },
        else => {
          const res = try proc.push(proc, pos, .{.newlines = num_breaks});
          std.debug.assert(res == .none);
          return;
        },
      }
    },
    .end_source, .symref, .block_name_sep, .list_start, .block_end_open => {
      self.state = .default;
      return;
    },
    else => std.debug.panic("unexpected token in special: {s}\n",
        .{@tagName(self.cur)}),
  };
  switch (result) {
    .none => self.advance(),
    .read_block_header => {
      const start = self.cur_start;
      self.lexer.readBlockHeader();
      const value = try self.intpr().ctx.global().create(model.Value);
      value.data = .{.block_header = .{}};
      const bh = &value.data.block_header;

      self.advance();
      const check_pipe: ?model.Position =
        if (self.cur == .diamond_open) blk: {
          bh.config = @as(model.BlockConfig, undefined);
          try BlockConfig.init(
            &bh.config.?, self.intpr().ctx.global(), self).parse();
          if (self.cur == .blocks_sep) {
            defer self.advance();
            break :blk self.lexer.walker.posFrom(self.cur_start);
          } else break :blk null;
        } else self.source().between(start, self.cur_start);
      const check_swallow = if (check_pipe) |pos| if (self.cur == .pipe) blk: {
        try PipeCapture.init(self, self.curLevel()).parse();
        if (self.cur == .blocks_sep) {
          defer self.advance();
          break :blk self.lexer.walker.posFrom(self.cur_start);
        } else break :blk null;
      } else pos else null;
      if (check_swallow) |colon_pos| {
        bh.swallow_depth = self.checkSwallow(colon_pos);
      }

      value.origin = self.source().between(start, self.cur_start);
      _ = try proc.push(proc, value.origin, .{.block_header = bh});
    }
  }
}

pub fn doParse(
  self            : *@This(),
  implicit_fullast: bool,
) Parser.Error!*model.Node {
  while (true) {
    switch (self.state) {
      .start          => try self.procStart(implicit_fullast),
      .possible_start => try self.procPossibleStart(),
      .default        => switch (self.cur) {
        .space, .escape, .literal, .ws_break => self.state = .textual,
        .end_source => {
          try self.procEndSource();
          return self.levels.items[0].finalize(self);
        },
        .indent           => self.advance(),
        .symref           => try self.procSymref(),
        .list_end, .comma, .list_end_missing_colon => try self.procLeaveArg(),
        .parsep           => try self.procParagraphEnd(),
        .block_name_sep   => try self.procBlockNameStart(),
        .list_start       => try self.procBlockNameExprStart(),
        .block_end_open   => try self.procEndCommand(),
        .name_sep         => self.procIllegalNameSep(),
        .id_set           => self.procIdSet(),
        else => std.debug.panic(
          "unexpected token in default: {s} at {}\n",
          .{@tagName(self.cur), self.cur_start.formatter()}),
      },
      .textual            => try self.procTextual(),
      .command            => try self.procCommand(),
      .after_list         => try self.procAfterList(),
      .after_blocks_start => try self.procAfterBlocksStart(),
      .block_name         => try self.procBlockName(),
      .before_id          => try self.procBeforeId(),
      .after_id           => try self.procAfterId(),
      .special            => try self.procSpecial(),
    }
  }
}

/// out-value used for processBlockHeader after the initial ':'.
const PrimaryBlockExists = enum {unknown, maybe, yes};

/// processes the content after a `:` that either started blocks or ended a
/// block name.
/// pb_exists shall be non-null iff the ':' starts block parameters (i.e. we
/// are not after a block name). its initial value shall be .unknown.
/// the out value of pb_exists indicates the following:
///   .unknown =>
///     no level has been pushed since neither explicit nor implicit block
///     configuration has been encountered. the current level's primary param
///     has been entered to check for implicit block config.
///   .maybe =>
///     level has been pushed and command entered its primary param, but
///     existence of primary block is not known. This happens if a call target
///     does have a primary parameter that supplies an implicit block config.
///     This block config must be activated before reading the block content,
///     since it may change the lexer's behavior. If there is, in fact, no
///     primary block, the pushed level is to be discarded.
///   .yes =>
///     level has been pushed and command entered its primary param due to
///     explicit block config.
///
/// this func's return value must be interpreted depending on pb_exists:
/// if pb_exists is null, returns true iff explicit block config has been
/// encountered. if pb_exists is non-null, returns true iff swallowing has
/// occurred.
fn processBlockHeader(self: *@This(), pb_exists: ?*PrimaryBlockExists) !bool {
  // on named blocks, the new level has already been pushed
  const parent = &self.levels.items[
    self.levels.items.len - if (pb_exists == null) @as(usize, 2) else 1];
  // position of the colon *after* a block header, for additional swallow
  var colon_start: ?model.Position = null;
  const check_pipe = if (self.cur == .diamond_open) blk: {
    const config = try self.allocator().create(model.BlockConfig);
    try BlockConfig.init(config, self.allocator(), self).parse();
    const pos = self.source().at(self.cur_start);
    if (pb_exists) |ind| {
      try parent.command.pushPrimary(pos, true);
      try self.pushLevel(
        if (parent.command.choseAstNodeParam()) false else parent.fullast);
      ind.* = .yes;
    }
    try self.applyBlockConfig(pos, config);
    if (self.cur == .blocks_sep) {
      colon_start = self.lexer.walker.posFrom(self.cur_start);
      self.advance();
      break :blk true;
    } else break :blk false;
  } else true;
  const check_swallow = if (check_pipe) if (self.cur == .pipe) blk: {
    if (pb_exists) |ind| if (ind.* == .unknown) {
      try parent.command.pushPrimary(self.source().at(self.cur_start), true);
      try self.pushLevel(
        if (parent.command.choseAstNodeParam()) false else parent.fullast);
      ind.* = .yes;
    };
    try PipeCapture.init(self, self.curLevel()).parse();
    if (self.cur == .blocks_sep) {
      colon_start = self.lexer.walker.posFrom(self.cur_start);
      self.advance();
      break :blk true;
    } else break :blk false;
  } else true else false;
  if (check_swallow) {
    if (self.checkSwallow(colon_start)) |swallow_depth| {
      if (pb_exists) |ind| {
        if (ind.* == .unknown) {
          try parent.command.pushPrimary(
            self.source().at(self.cur_start), false);
          try self.pushLevel(if (
            parent.command.choseAstNodeParam()
          ) false else parent.fullast);
          if (parent.implicitBlockConfig()) |c| {
            try self.applyBlockConfig(
              self.source().at(self.cur_start), c);
          }
        }
        ind.* = .yes;
      }
      parent.command.swallow_depth = swallow_depth;
      try self.closeSwallowing(swallow_depth);

      while (
        self.cur == .space or self.cur == .indent or self.cur == .ws_break
      ) self.advance();
      return if (pb_exists == null) (
        self.curLevel().block_config != null
      ) else true;
    } else if (pb_exists) |ind| {
      if (ind.* == .unknown) {
        try parent.command.pushPrimary(self.source().at(self.cur_start), false);
        if (parent.implicitBlockConfig()) |c| {
          ind.* = .maybe;
          try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                              else parent.fullast);
          try self.applyBlockConfig(self.source().at(self.cur_start), c);
        }
      }
    }
  }
  return if (pb_exists == null) self.curLevel().block_config != null else false;
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
    tl.command.mapper = switch (tl.command.info) {
      .assignment      => |*as| &as.mapper,
      .import_call     => |*ic| &ic.mapper,
      .resolved_call   => |*sm| &sm.mapper,
      .unknown         => unreachable,
      .unresolved_call => |*uc| &uc.mapper,
    };
    tl.dangling = dangling;

    // finally, shift the new level on top of the target_level
    self.levels.items[target_level + 1] = last(self.levels.items).*;
    const ll = &self.levels.items[target_level + 1];
    ll.command.mapper = switch (ll.command.info) {
      .assignment      => |*as| &as.mapper,
      .import_call     => |*ic| &ic.mapper,
      .resolved_call   => |*sm| &sm.mapper,
      .unknown         => unreachable,
      .unresolved_call => |*uc| &uc.mapper,
    };
    try self.levels.resize(self.allocator(), target_level + 2);
  }
}

/// if colon_pos is given, assumes that swallowing *must* occur and issues an
/// error using the colon_pos if non occurs.
fn checkSwallow(self: *@This(), colon_pos: ?model.Position) ?u21 {
  switch (self.cur) {
    .swallow_depth => {
      const swallow_depth = self.lexer.code_point;
      const start = self.cur_start;
      self.advance();
      if (self.cur == .diamond_close) {
        self.advance();
      } else {
        self.logger().SwallowDepthWithoutDiamondClose(
          self.source().between(start, self.cur_start));
        return null;
      }
      return swallow_depth;
    },
    .diamond_close => {
      self.advance();
      return 0;
    },
    else => {
      if (colon_pos) |pos| self.logger().IllegalColon(pos);
      return null;
    }
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