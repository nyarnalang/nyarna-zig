const std = @import("std");
const builtin = @import("builtin");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const Interpreter = @import("interpret.zig").Interpreter;

const lex = @import("lex.zig");
const mapper = @import("mapper.zig");
const unicode = @import("unicode.zig");
const syntaxes = @import("syntaxes.zig");
const chains = @import("chains.zig");

const last = @import("../helpers.zig").last;

/// The parser creates AST nodes.
/// Whenever an AST node is created, the parser checks whether it needs to be
/// evaluated immediately, and if so, asks the interpreter to do so, which will
/// yield the replacement for the original node.
pub const Parser = struct {
  /// Contains information about the current command's structure and processes
  /// arguments to that command.
  const Command = struct {
    start: model.Cursor,
    info: union(enum) {
      /// This state means that the command has just been created and awaits
      /// classification via the next lexer token.
      unknown: *model.Node,
      resolved_call: mapper.SignatureMapper,
      unresolved_call: mapper.CollectingMapper,
      assignment: mapper.AssignmentMapper,
    },
    mapper: *mapper.Mapper,
    cur_cursor: union(enum) {
      mapped: mapper.Mapper.Cursor,
      failed,
      not_pushed
    },
    /// if set, this command is currently swallowing at the given depth and will
    /// end implicitly at the encounter of another command that has a lesser or
    /// equal swallow depth – excluding swallow depth 0, which will only end
    /// when a parent scope ends.
    swallow_depth: ?u21 = null,

    fn pushName(c: *Command, pos: model.Position, name: []const u8,
                direct: bool, flag: mapper.Mapper.ProtoArgFlag) void {
      c.cur_cursor = if (c.mapper.map(pos,
          if (direct) .{.direct = name} else .{.named = name}, flag)
      ) |mapped| .{
        .mapped = mapped,
      } else .failed;
    }

    fn pushArg(c: *Command, arg: *model.Node) !void {
      defer c.cur_cursor = .not_pushed;
      const cursor = switch (c.cur_cursor) {
        .mapped => |val| val,
        .failed => return,
        .not_pushed => c.mapper.map(arg.pos, .position, .flow) orelse return,
      };
      try c.mapper.push(cursor, arg);
    }

    fn pushPrimary(c: *Command, pos: model.Position, config: bool) void {
      c.cur_cursor = if (c.mapper.map(pos, .primary,
          if (config) .block_with_config else .block_no_config)) |cursor| .{
            .mapped = cursor,
          } else .failed;
    }

    fn shift(c: *Command, ip: *Interpreter, end: model.Cursor) !void {
      const newNode = try c.mapper.finalize(ip.input.between(c.start, end));
      c.info = .{.unknown = newNode};
    }

    fn startAssignment(c: *Command, ip: *Interpreter) void {
      const subject = c.info.unknown;
      c.info = .{.assignment = mapper.AssignmentMapper.init(subject, ip)};
      c.mapper = &c.info.assignment.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn startResolvedCall(
        c: *Command, ip: *Interpreter, target: *model.Expression,
        ns: u15, sig: *const model.Type.Signature) !void {
      c.info = .{
        .resolved_call =
          try mapper.SignatureMapper.init(ip, target, ns, sig),
      };
      c.mapper = &c.info.resolved_call.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn startUnresolvedCall(c: *Command, ip: *Interpreter) !void {
      const subject = c.info.unknown;
      c.info = .{
        .unresolved_call = mapper.CollectingMapper.init(subject, ip),
      };
      c.mapper = &c.info.unresolved_call.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn choseAstNodeParam(c: *Command) bool {
      return switch (c.cur_cursor) {
        .mapped => |cursor|
          if (c.mapper.paramType(cursor)) |t| t.is(.ast_node) else false,
        else => false,
      };
    }
  };

  /// This is either the root level of the current file,
  /// a block argument or a list argument.
  /// The content level takes care of generating concatenations and paragraphs.
  const ContentLevel = struct {
    /// used for generating void nodes.
    start: model.Cursor,
    /// Changes to command characters that occurred upon entering this level.
    /// For implicit block configs, this links to the block config definition.
    changes: ?[]model.BlockConfig.Map,
    /// the currently open command on this content level. info === unknown if no
    /// command is open or only the subject has been read.
    /// every ContentLevel but the innermost one must have an open command.
    command: Command,
    /// whether this level has fullast semantics.
    fullast: bool,

    nodes: std.ArrayListUnmanaged(*model.Node),
    paragraphs: std.ArrayListUnmanaged(model.Node.Paras.Item),

    block_config: ?*const model.BlockConfig,
    syntax_proc: ?*syntaxes.SpecialSyntax.Processor = null,
    dangling_space: ?*model.Node = null,

    fn append(level: *ContentLevel, ip: *Interpreter, item: *model.Node)
        !void {
      if (level.syntax_proc) |proc| {
        const res = try proc.push(proc, item.pos, .{.node = item});
        std.debug.assert(res == .none);
      } else {
        if (level.dangling_space) |space_node| {
          try level.nodes.append(ip.allocator(), space_node);
          level.dangling_space = null;
        }
        const res = if (level.fullast) item else switch (item.data) {
          .literal, .unresolved_call, .unresolved_symref, .expression,
          .void => item,
          else =>
            if (try ip.tryInterpret(item, .{.kind = .intermediate})) |expr|
              try ip.node_gen.expression(expr) else item,
        };
        try level.nodes.append(ip.allocator(), res);
      }
    }

    fn finalizeParagraph(level: *ContentLevel, ip: *Interpreter) !*model.Node {
      return switch (level.nodes.items.len) {
        0 => ip.node_gen.void(ip.input.at(level.start)),
        1 => level.nodes.items[0],
        else => (try ip.node_gen.concat(
          level.nodes.items[0].pos.span(last(level.nodes.items).*.pos),
          .{.items = level.nodes.items})).node(),
      };
    }

    fn implicitBlockConfig(level: *ContentLevel) ?*model.BlockConfig {
      return switch (level.command.cur_cursor) {
        .mapped => |c| level.command.mapper.config(c),
        else => null,
      };
    }

    fn finalize(level: *ContentLevel, p: *Parser) !*model.Node {
      if (level.block_config) |c| {
        try p.revertBlockConfig(c);
      }
      const alloc = p.allocator();
      if (level.syntax_proc) |proc| {
        return try proc.finish(
          proc, p.intpr().input.between(level.start, p.cur_start));
      } else if (level.paragraphs.items.len == 0) {
        return level.finalizeParagraph(p.intpr());
      } else {
        if (level.nodes.items.len > 0) {
          try level.paragraphs.append(alloc, .{
            .content = try level.finalizeParagraph(p.intpr()),
            .lf_after = 0,
          });
        }
        return (try p.intpr().node_gen.paras(
          level.paragraphs.items[0].content.pos.span(
            last(level.paragraphs.items).content.pos),
          .{.items = level.paragraphs.items})).node();
      }
    }

    fn pushParagraph(level: *ContentLevel, ip: *Interpreter, lf_after: usize)
        !void {
      if (level.nodes.items.len > 0) {
        try level.paragraphs.append(ip.allocator(), .{
          .content = try level.finalizeParagraph(ip),
          .lf_after = lf_after
        });
        level.nodes = .{};
      }
    }
  };

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
  /// buffer for inline block config.
  config_buffer: model.BlockConfig,
  /// stack of currently active namespace mapping statuses.
  /// namespace mappings create a new namespace, disable a namespace, or map a
  /// namespace from one character to another.
  /// if a namespace is disabled, its index is pushed onto the stack.
  /// other operations push either ns_mapping_failed or ns_mapping_succeeded.
  ns_mapping_stack: std.ArrayListUnmanaged(u16),

  lexer: lex.Lexer,
  state: State,
  cur: model.Token,
  cur_start: model.Cursor,

  inline fn allocator(self: *@This()) std.mem.Allocator {
    return self.intpr().allocator();
  }

  inline fn intpr(self: *@This()) *Interpreter {
    return self.lexer.intpr;
  }

  inline fn logger(self: *@This()) *errors.Handler {
    return self.intpr().ctx.logger;
  }

  pub fn init() Parser {
    return Parser{
      .config = null,
      .config_buffer = undefined,
      .levels = .{},
      .ns_mapping_stack = .{},
      .lexer = undefined,
      .state = .start,
      .cur = undefined,
      .cur_start = undefined,
    };
  }

  pub fn parseFile(self: *Parser, path: []const u8, locator: model.Locator,
      context: *Interpreter) !*model.Node {
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

  fn pushLevel(self: *Parser, fullast: bool) !void {
    try self.levels.append(self.allocator(), ContentLevel{
      .start = self.lexer.recent_end,
      .changes = null,
      .command = undefined,
      .nodes = .{},
      .paragraphs = .{},
      .block_config = null,
      .fullast = fullast,
    });
  }

  /// parse context.input. If it returns .referred_source_unavailable, parsing
  /// may be resumed via resumeParse() after the referred source has been
  /// loaded. Other returned errors are not recoverable.
  ///
  /// Errors in the given input are not returned as errors of this function.
  /// Instead, they are handed to the loader's errors.Handler. To check whether
  /// errors have occurred, check for increase of the handler's error_count.
  pub fn parseSource(self: *Parser, context: *Interpreter, fullast: bool)
      !*model.Node {
    self.lexer = try lex.Lexer.init(context);
    self.advance();
    return self.doParse(fullast);
  }

  /// continue parsing. Precondition: Either parseSource() or resumeParse()
  /// have returned with .referred_source_unavailable previously on the given
  /// parser, and have never returned a *model.Node.
  ///
  /// Apart from the precondition, this function has the same semantics as
  /// parseSource(), including that it may return .referred_source_unavailable.
  pub fn resumeParse(self: *Parser) !*model.Node {
    // when resuming, the fullast value is irrelevant since it is only inspected
    // when encountering the first non-space token in the file – which will
    // always be before parsing is interrupted.
    return self.doParse(undefined);
  }

  /// retrieves the next valid token from the lexer.
  /// emits errors for any invalid token along the way.
  inline fn advance(self: *Parser) void {
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
        //
        .illegal_code_point => errors.Handler.IllegalCodePoint,
        .illegal_opening_parenthesis =>
          errors.Handler.IllegalOpeningParenthesis,
        .illegal_blocks_start_in_args =>
          errors.Handler.IllegalBlocksStartInArgs,
        .illegal_command_char => errors.Handler.IllegalCommandChar,
        .mixed_indentation => errors.Handler.MixedIndentation,
        .illegal_indentation => errors.Handler.IllegalIndentation,
        .illegal_content_at_header => errors.Handler.IllegalContentAtHeader,
        .illegal_character_for_id => errors.Handler.IllegalCharacterForId,
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
  inline fn getNext(self: *Parser) bool {
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
      .mixed_indentation => errors.Handler.MixedIndentation,
      .illegal_indentation => errors.Handler.IllegalIndentation,
      .illegal_content_at_header => errors.Handler.IllegalContentAtHeader,
      .illegal_character_for_id => errors.Handler.IllegalCharacterForId,
      .invalid_end_command => unreachable,
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

  fn leaveLevel(self: *Parser) !void {
    var lvl = self.curLevel();
    var parent = &self.levels.items[self.levels.items.len - 2];
    const lvl_node = try lvl.finalize(self);
    try parent.command.pushArg(lvl_node);
    _ = self.levels.pop();
  }

  inline fn curLevel(self: *Parser) *ContentLevel {
    return last(self.levels.items);
  }

  fn doParse(self: *Parser, implicit_fullast: bool) !*model.Node {
    while (true) {
      switch (self.state) {
        .start => {
          while (self.cur == .space or self.cur == .indent) self.advance();
          // this state is used for initial top-level and for list arguments.
          // list arguments do not change block configuration and so will always
          // inherit parent's fullast. the top-level will not be fullast unless
          // instructed by the caller.
          try self.pushLevel(
            if (self.levels.items.len == 0) implicit_fullast
            else self.curLevel().fullast);
          self.state = .default;
        },
        .possible_start => {
          while (self.cur == .space) self.advance();
          if (self.cur == .list_end) {
            self.state = .after_list;
          } else {
            try self.pushLevel(self.curLevel().fullast);
            self.state = .default;
          }
        },
        .default => {
          switch (self.cur) {
            .indent => self.advance(),
            .space, .escape, .literal, .ws_break => self.state = .textual,
            .end_source => {
              while (self.levels.items.len > 1) {
                try self.leaveLevel();
                const parent = self.curLevel();
                try parent.command.shift(self.intpr(), self.cur_start);
                try parent.append(self.intpr(), parent.command.info.unknown);
              }
              return self.levels.items[0].finalize(self);
            },
            .symref => {
              self.curLevel().command = .{
                .start = self.cur_start,
                .info = .{
                  .unknown = try self.intpr().resolveSymbol(
                      self.lexer.walker.posFrom(self.cur_start),
                      self.lexer.ns, self.lexer.recent_id),
                },
                .mapper = undefined,
                .cur_cursor = undefined,
              };
              self.state = .command;
              self.advance();
            },
            .list_end, .comma => {
              try self.leaveLevel();
              if (self.cur == .comma) {
                self.advance();
                self.state = .start;
              } else self.state = .after_list;
            },
            .parsep => {
              const newline_count = self.lexer.newline_count;
              self.advance();
              if (self.cur != .block_end_open and self.cur != .end_source) {
                try self.curLevel().pushParagraph(self.intpr(), newline_count);
              }
            },
            .block_name_sep => {
              try self.leaveLevel();
              self.state = .block_name;
            },
            .block_end_open => {
              self.advance();
              switch (self.cur) {
                .call_id => {},
                .wrong_call_id => {
                  const cmd_start =
                    self.levels.items[self.levels.items.len - 2].command.start;
                  self.logger().WrongCallId(
                    self.lexer.walker.posFrom(self.cur_start),
                    self.lexer.recent_expected_id, self.lexer.recent_id,
                    self.intpr().input.at(cmd_start));
                },
                else => {
                  std.debug.assert(@enumToInt(self.cur) >=
                    @enumToInt(model.Token.skipping_call_id));
                  const cmd_start =
                    self.levels.items[self.levels.items.len - 2].command.start;
                  self.logger().SkippingCallId(
                    self.lexer.walker.posFrom(self.cur_start),
                    self.lexer.recent_expected_id, self.lexer.recent_id,
                    self.intpr().input.at(cmd_start));
                  var i = @as(u32, 0);
                  while (i < model.Token.numSkippedEnds(self.cur)): (i += 1) {
                    try self.leaveLevel();
                  }
                },
              }
              try self.leaveLevel();
              self.advance();
              if (self.cur == .list_end) {
                self.advance();
              } else {
                self.logger().MissingClosingParenthesis(
                  self.intpr().input.at(self.cur_start));
              }
              self.state = .command;
              try self.curLevel().command.shift(
                self.intpr(), self.cur_start);
            },
            else => std.debug.panic(
                "unexpected token in default: {s}\n", .{@tagName(self.cur)}),
          }
        },
        .textual => {
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
            .block_end_open, .block_name_sep, .comma, .name_sep, .list_end,
            .end_source => blk: {
              content.shrinkAndFree(self.allocator(), non_space_len);
              break :blk self.intpr().input.between(
                textual_start, non_space_end);
            },
            else => self.lexer.walker.posFrom(textual_start),
          };
          if (content.items.len > 0) {
            if (self.cur == .name_sep) {
              if (lvl.nodes.items.len > 0) {
                unreachable; // TODO: error: equals not allowed here
              }
              self.levels.items[self.levels.items.len - 2].command.pushName(
                pos, content.items,
                pos.end.byte_offset - pos.start.byte_offset == 2, .flow);
              while (true) {
                self.advance();
                if (self.cur != .space) break;
              }
            } else {
              const node = (try self.intpr().node_gen.literal(pos, .{
                .kind = if (non_space_len > 0) .text else .space,
                .content = content.items
              })).node();
              // dangling space will be postponed for the case of a following,
              // swallowing command that ends the current level.
              if (non_space_len > 0) try lvl.append(self.intpr(), node)
              else lvl.dangling_space = node;
              self.state = .default;
            }
          } else self.state = .default; // happens with space at block/arg end
        },
        .command => {
          var lvl = self.curLevel();
          switch (self.cur) {
            .access => {
              self.advance();
              if (self.cur != .identifier) unreachable; // TODO: recover
              lvl.command.info.unknown = (try self.intpr().node_gen.access(
                self.lexer.walker.posFrom(lvl.command.info.unknown.pos.start),
                .{
                  .subject = lvl.command.info.unknown,
                  .id = self.lexer.recent_id,
                })).node();
              self.advance();
            },
            .assign => {
              self.advance();
              switch (self.cur) {
                .list_start => {
                  self.state = .start;
                },
                .blocks_sep => {
                  self.state = .after_blocks_start;
                },
                else => unreachable // TODO: recover
              }
              lvl.command.startAssignment(self.intpr());
              self.advance();
            },
            .list_start, .blocks_sep => {
              const target = lvl.command.info.unknown;
              const ctx = try chains.CallContext.fromChain(
                self.intpr(), target.pos, try chains.Resolver.init(
                  self.intpr(), .{.kind = .intermediate}).resolve(target));
              switch (ctx) {
                .known => |call_context| {
                  try lvl.command.startResolvedCall(self.intpr(),
                    call_context.target, call_context.ns,
                    call_context.signature);
                  if (call_context.first_arg) |prefix| {
                    try lvl.command.pushArg(prefix);
                  }
                },
                .unknown =>
                  try lvl.command.startUnresolvedCall(self.intpr()),
                .poison => {
                  target.data = .poison;
                  try lvl.command.startUnresolvedCall(self.intpr());
                }
              }
              self.state = if (self.cur == .list_start) .possible_start
                           else .after_blocks_start;
              self.advance();
            },
            .closer => {
              try lvl.append(self.intpr(), lvl.command.info.unknown);
              self.advance();
              self.state = if (self.curLevel().syntax_proc != null) .special
                           else .default;
            },
            else => {
              try lvl.append(self.intpr(), lvl.command.info.unknown);
              self.state = if (self.curLevel().syntax_proc != null) .special
                           else .default;
            }
          }
        },
        .after_list => {
          const end = self.lexer.recent_end;
          self.advance();
          if (self.cur == .blocks_sep) {
            // call continues
            self.state = .after_blocks_start;
            self.advance();
          } else {
            self.state = .command;
            try self.curLevel().command.shift(self.intpr(), end);
          }
        },
        .after_blocks_start => {
          var pb_exists = PrimaryBlockExists.unknown;
          if (try self.processBlockHeader(&pb_exists)) {
            self.state =
              if (self.curLevel().syntax_proc != null) .special else .default;
          } else {
            while (self.cur == .space or self.cur == .indent) self.advance();
            if (self.cur == .block_name_sep) {
              switch (pb_exists) {
                .unknown => {},
                .maybe => {
                  const lvl = self.levels.pop();
                  if (lvl.block_config) |c| try self.revertBlockConfig(c);
                },
                .yes => try self.leaveLevel(),
              }
              self.state = .block_name;
            } else {
              if (pb_exists == .unknown) {
                const lvl = self.curLevel();
                // neither explicit nor implicit block config. fullast is thus
                // inherited except when an AstNode parameter has been chosen.
                try self.pushLevel(if (lvl.command.choseAstNodeParam()) false
                                   else lvl.fullast);
              }
              self.state = if (self.curLevel().syntax_proc != null) .special
                           else .default;
            }
          }
        },
        .block_name => {
          while (true) {
            self.advance();
            if (self.cur != .space) break;
          }
          const parent = self.curLevel();
          if (self.cur == .identifier) {
            const name =
              self.lexer.walker.contentFrom(self.cur_start.byte_offset);
            const name_pos = self.lexer.walker.posFrom(self.cur_start);
            var recover = false;
            while (true) {
              self.advance();
              if (self.cur == .block_name_sep or
                  self.cur == .missing_block_name_sep) break;
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
              self.logger().MissingBlockNameEnd(
                self.intpr().input.at(self.cur_start));
            }
            parent.command.pushName(name_pos, name, false,
              if (self.cur == .diamond_open) .block_with_config
              else .block_no_config);
          } else {
            self.logger().ExpectedXGotY(self.intpr().input.at(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
              .{.token = self.cur});
            while (self.cur != .block_name_sep and
                   self.cur != .missing_block_name_sep) {
              self.advance();
            }
            parent.command.cur_cursor = .failed;
          }
          self.advance();
          // initialize level with fullast according to chosen param type.
          // may be overridden by block config in following processBlockHeader.
          try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                             else parent.fullast);
          if (!(try self.processBlockHeader(null))) {
            while (self.cur == .space or self.cur == .indent) self.advance();
          }
          self.state = if (
            self.curLevel().syntax_proc != null
          ) .special else .default;
        },
        .special => {
          const proc = self.curLevel().syntax_proc.?;
          const result = try switch (self.cur) {
            .indent => syntaxes.SpecialSyntax.Processor.Action.none,
            .space =>
              proc.push(proc, self.lexer.walker.posFrom(self.cur_start), .{
                  .space = self.lexer.walker.contentFrom(
                    self.cur_start.byte_offset)
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
            .ws_break => // TODO: discard if at end of block
              proc.push(proc, self.lexer.walker.posFrom(self.cur_start),
                .{.newlines = 1}),
            .parsep =>
              proc.push(proc, self.lexer.walker.posFrom(self.cur_start),
                .{.newlines = self.lexer.newline_count}),
            .end_source, .symref, .block_name_sep, .block_end_open => {
              self.state = .default;
              continue;
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
              value.data = .{.block_header = undefined};
              const bh = &value.data.block_header;

              self.advance();
              const check_swallow = if (self.cur == .diamond_open) blk: {
                bh.config = @as(model.BlockConfig, undefined);
                try self.readBlockConfig(&bh.config.?,
                  self.intpr().ctx.global());
                if (self.cur == .blocks_sep) {
                  self.advance();
                  break :blk true;
                } else break :blk false;
              } else true;
              if (check_swallow) {
                bh.swallow_depth = self.checkSwallow();
              }

              value.origin = self.intpr().input.between(start, self.cur_start);
              _ = try proc.push(proc, value.origin, .{.block_header = bh});
            }
          }
        }
      }
    }
  }

  const ConfigItemKind = enum {csym, syntax, map, off, fullast, empty, unknown};

  fn readBlockConfig(self: *Parser, into: *model.BlockConfig,
                     map_allocator: std.mem.Allocator) !void {
    std.debug.assert(self.cur == .diamond_open);
    var map_list = std.ArrayList(model.BlockConfig.Map).init(map_allocator);
    into.* = .{
      .syntax = null,
      .off_colon = null,
      .off_comment = null,
      .full_ast = null,
      .map = undefined,
    };
    var first = true;
    while (self.cur != .diamond_close and self.cur != .end_source) {
      while (true) {
        self.advance();
        if (self.cur != .space) break;
      }
      if (self.cur == .diamond_close or self.cur == .end_source) {
        if (!first) {
          self.logger().ExpectedXGotY(self.lexer.walker.posFrom(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
              .{.token = self.cur});
        }
        break;
      }
      first = false;
      std.debug.assert(self.cur == .identifier);
      const start = self.cur_start;
      const name = self.lexer.walker.contentFrom(self.cur_start.byte_offset);
      const kind: ConfigItemKind = switch (std.hash.Adler32.hash(name)) {
        std.hash.Adler32.hash("csym") => .csym,
        std.hash.Adler32.hash("syntax") => .syntax,
        std.hash.Adler32.hash("map") => .map,
        std.hash.Adler32.hash("off") => .off,
        std.hash.Adler32.hash("fullast") => .fullast,
        std.hash.Adler32.hash("") => .empty,
        else => blk: {
          self.logger().UnknownConfigDirective(
            self.lexer.walker.posFrom(start));
          break :blk .unknown;
        },
      };
      var recover = while (self.getNext()) {
        if (self.cur != .space) break false;
      } else true;
      if (!recover) consume_next: {
        switch (kind) {
          .csym => {
            if (self.cur == .ns_sym) {
              try map_list.append(.{
                .pos = self.lexer.walker.posFrom(start),
                .from = 0, .to = self.lexer.code_point});
            } else {
              self.logger().ExpectedXGotY(
                self.lexer.walker.posFrom(self.cur_start),
                &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
                .{.token = self.cur});
              recover = true;
            }
          },
          .syntax => {
            if (self.cur == .literal) {
              switch (std.hash.Adler32.hash(
                  self.lexer.walker.contentFrom(self.cur_start.byte_offset))) {
                std.hash.Adler32.hash("locations") => {
                  into.syntax = .{
                    .pos = model.Position.intrinsic(),
                    .index = 0,
                  };
                },
                std.hash.Adler32.hash("definitions") => {
                  into.syntax = .{
                    .pos = model.Position.intrinsic(),
                    .index = 1,
                  };
                },
                else =>
                  self.logger().UnknownSyntax(
                    self.lexer.walker.posFrom(self.cur_start)),
              }
            } else {
              self.logger().ExpectedXGotY(
                self.lexer.walker.posFrom(self.cur_start),
                &[_]errors.WrongItemError.ItemDescr{.{.token = .literal}},
                .{.token = self.cur});
              recover = true;
            }
          },
          .map => {
            if (self.cur == .ns_sym) {
              const from = self.lexer.code_point;
              recover = while (self.getNext()) {
                if (self.cur != .space) break self.cur != .ns_sym;
              } else true;
              if (!recover) {
                try map_list.append(.{
                  .pos = self.lexer.walker.posFrom(start),
                  .from = from, .to = self.lexer.code_point,
                });
              }
            } else recover = true;
            if (recover) {
              self.logger().ExpectedXGotY(
                self.lexer.walker.posFrom(self.cur_start),
                &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
                .{.token = self.cur});
            }
          },
          .off => {
            switch (self.cur) {
              .comment =>
                into.off_comment = self.lexer.walker.posFrom(self.cur_start),
              .block_name_sep =>
                into.off_colon = self.lexer.walker.posFrom(self.cur_start),
              .ns_sym =>
                try map_list.append(.{
                    .pos = self.lexer.walker.posFrom(start),
                    .from = self.lexer.code_point, .to = 0,
                  }),
              else => {
                self.logger().ExpectedXGotY(
                  self.lexer.walker.posFrom(self.cur_start),
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .ns_sym}, .{.character = '#'},
                    .{.character = ':'},
                  }, .{.token = self.cur});
                recover = true;
              }
            }
          },
          .fullast => {
            into.full_ast = self.lexer.walker.posFrom(self.cur_start);
            break :consume_next;
          },
          .empty => {
            self.logger().ExpectedXGotY(
                self.lexer.walker.posFrom(self.cur_start),
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.token = self.cur});
            recover = true;
            break :consume_next;
          },
          .unknown => break :consume_next,
        }
        while (!self.getNext()) {}
      }
      while (self.cur != .comma and self.cur != .diamond_close and
             self.cur != .end_source) : (while (!self.getNext()) {}) {
        if (self.cur != .space and !recover) {
          self.logger().ExpectedXGotY(self.lexer.walker.posFrom(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{
                .{.character = ','}, .{.character = '>'}
              }, .{.token = self.cur});
          recover = true;
        }
      }
    }
    if (self.cur == .diamond_close) {
      self.advance();
    } else {
      self.logger().ExpectedXGotY(self.lexer.walker.posFrom(self.cur_start),
        &[_]errors.WrongItemError.ItemDescr{.{.token = .diamond_close}},
        .{.token = self.cur});
    }
    into.map = map_list.items;
  }

  /// out-value used for processBlockHeader after the initial ':'.
  const PrimaryBlockExists = enum {unknown, maybe, yes};

  /// processes the content after a `:` that either started blocks or ended a
  /// block name. returns true iff swallowing has ocurred.
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
  fn processBlockHeader(self: *Parser, pb_exists: ?*PrimaryBlockExists) !bool {
    const parent = self.curLevel();
    const check_swallow = if (self.cur == .diamond_open) blk: {
      try self.readBlockConfig(&self.config_buffer, self.allocator());
      const pos = self.intpr().input.at(self.cur_start);
      if (pb_exists) |ind| {
        parent.command.pushPrimary(pos, true);
        try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                           else parent.fullast);
        ind.* = .yes;
      }
      try self.applyBlockConfig(pos, &self.config_buffer);
      if (self.cur == .blocks_sep) {
        self.advance();
        break :blk true;
      } else break :blk false;
    } else true;
    if (check_swallow) {
      if (self.checkSwallow()) |swallow_depth| {
        if (pb_exists) |ind| {
          if (ind.* == .unknown) {
            parent.command.pushPrimary(
              self.intpr().input.at(self.cur_start), false);
            try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                               else parent.fullast);
            if (parent.implicitBlockConfig()) |c| {
              try self.applyBlockConfig(
                self.intpr().input.at(self.cur_start), c);
            }
          }
          ind.* = .yes;
        } else try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                                  else parent.fullast);
        parent.command.swallow_depth = swallow_depth;
        if (swallow_depth != 0) {
          // now close all commands that have a swallow depth equal or greater
          // than the current one, excluding 0. To do this, we first determine
          // the actual level in which the current command is to be placed in
          // (we'll skip the innermost level which we just pushed). target_level
          // is the level into which the current command should be pushed.
          // cur_depth is the level we're checking. Since we may need to look
          // beyond levels with swallow depth 0, we need to keep these values in
          // separate vars.
          var target_level: usize = self.levels.items.len - 2;
          var cur_depth: usize = target_level;
          while (cur_depth > 0) : (cur_depth = cur_depth - 1) {
            if (self.levels.items[cur_depth - 1].command.swallow_depth)
                |level_depth| {
              if (level_depth != 0) {
                if (level_depth < swallow_depth) break;
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
            const end_cursor =
              if (parent.nodes.items.len == 0)
                last(parent.paragraphs.items).content.pos.end
              else last(parent.nodes.items).*.pos.end;

            var i = self.levels.items.len - 2;
            while (i > target_level) : (i -= 1) {
              const cur_parent = &self.levels.items[i - 1];
              try cur_parent.command.pushArg(
                try self.levels.items[i].finalize(self));
              try cur_parent.command.shift(self.intpr(), end_cursor);
              try cur_parent.append(
                self.intpr(), cur_parent.command.info.unknown);
            }
            // target_level's command has now been closed. therefore it is safe
            // to assign it to the previous parent's command
            // (which has not been touched).
            self.levels.items[target_level].command = parent.command;
            // finally, shift the new level on top of the target_level
            self.levels.items[target_level + 1] = last(self.levels.items).*;
            try self.levels.resize(self.allocator(), target_level + 1);
          }
        }

        while (self.cur == .space or self.cur == .indent or
               self.cur == .ws_break) self.advance();
        return true;
      } else if (pb_exists) |ind| {
        if (ind.* == .unknown) {
          parent.command.pushPrimary(
            self.intpr().input.at(self.cur_start), false);
          if (parent.implicitBlockConfig()) |c| {
            ind.* = .maybe;
            try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                               else parent.fullast);
            try self.applyBlockConfig(self.intpr().input.at(self.cur_start), c);
          }
        }
      }
    }
    return false;
  }

  fn checkSwallow(self: *Parser) ?u21 {
    return switch (self.cur) {
      .swallow_depth => blk: {
        const swallow_depth = self.lexer.code_point;
        self.advance();
        if (self.cur == .diamond_close) {
          self.advance();
        } else {
          self.logger().SwallowDepthWithoutDiamondClose(
            self.intpr().input.at(self.cur_start));
          break :blk null;
        }
        break :blk swallow_depth;
      },
      .diamond_close => blk: {
        self.advance();
        break :blk 0;
      },
      else => null,
    };
  }

  fn applyBlockConfig(self: *Parser, pos: model.Position,
                      config: *const model.BlockConfig) !void {
    var sf = std.heap.stackFallback(128, self.allocator());
    var alloc = sf.get();
    const lvl = self.curLevel();

    if (config.syntax) |s| {
      const syntax = self.intpr().syntax_registry[s.index];
      lvl.syntax_proc = try syntax.init(self.intpr());
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
            if (from_index != ns_mapping_failed) {
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
            } else break :blk ns_mapping_failed;
          });
        }
      }
      // establish all new namespaces
      for (config.map) |mapping, i| {
        if (resolved_indexes[i] == ns_mapping_no_from) {
          std.debug.assert(mapping.to != 0);
          if (self.intpr().command_characters.get(mapping.to)) |_| {
            // this is not an error, but we still record it as 'failed' so
            // that we know when reversing this block config, nothing needs to
            // be done.
            try self.ns_mapping_stack.append(self.allocator(), ns_mapping_failed);
          } else {
            try self.intpr().addNamespace(mapping.to);
            try self.ns_mapping_stack.append(self.allocator(), ns_mapping_succeeded);
          }
        }
      }
    }

    if (config.off_colon) |_| {
      self.lexer.disableColons();
    }
    if (config.off_comment) |_| {
      self.lexer.disableComments();
    }

    if (config.full_ast) |_| lvl.fullast = true;

    lvl.block_config = config;
  }

  fn revertBlockConfig(self: *Parser, config: *const model.BlockConfig) !void {
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
            self.intpr().removeNamespace(mapping.to);
          }
        }
        if (i == 0) break;
      }

      // get the indexes of namespaces that have been remapped.
      var ns_indexes = try alloc.alloc(u15, config.map.len);
      defer alloc.free(ns_indexes);
      for (config.map) |mapping, j| {
        if (mapping.from != 0 and mapping.to != 0) {
          ns_indexes[j] = self.intpr().command_characters.get(mapping.to).?;
        }
      }

      // reverse namespace remappings and re-enable characters that have been
      // disabled. This can be done in one run.
      i = config.map.len - 1;
      while (true) : (i = i - 1) {
        const mapping = &config.map[i];
        if (mapping.from != 0) {
          if (mapping.to != 0) {
            if (self.ns_mapping_stack.pop() == ns_mapping_succeeded) {
              const ns_index = ns_indexes[i];
              // only remove command character if it has not already been reset
              // to another namespace.
              if (self.intpr().command_characters.get(mapping.to).?
                  == ns_index) {
                _ = self.intpr().command_characters.remove(mapping.to);
              }
              // this cannot fail because command_characters will always be
              // large enough to add another item without requiring allocation.
              self.intpr().command_characters.put(
                self.allocator(), mapping.from, ns_index) catch unreachable;
            }
          } else {
            const ns_index = self.ns_mapping_stack.pop();
            if (ns_index != ns_mapping_failed) {
              // like above
              self.intpr().command_characters.put(
                self.allocator(), mapping.from, @intCast(u15, ns_index))
                catch unreachable;
            }
          }
        }
        if (i == 0) break;
      }
    }

    // off_colon, off_comment, and special syntax are reversed automatically by
    // the lexer. full_ast is automatically reversed by leaving the level.
  }
};