const std = @import("std");
const data = @import("data");
const lex = @import("lex.zig");
const Source = @import("source.zig").Source;
const Context = @import("interpret.zig").Context;
const mapper = @import("mapper.zig");
const unicode = @import("unicode.zig");
const errors = @import("errors");
const syntaxes = @import("syntaxes.zig");

/// The parser creates AST nodes.
/// Whenever an AST node is created, the parser checks whether it needs to be
/// evaluated immediately, and if so, asks the interpreter to do so, which will
/// yield the replacement for the original node.
pub const Parser = struct {
  /// Contains information about the current command's structure and processes
  /// arguments to that command.
  const Command = struct {
    start: data.Cursor,
    info: union(enum) {
      /// This state means that the command has just been created and awaits
      /// classification via the next lexer token.
      unknown: *data.Node,
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

    fn pushName(c: *Command, pos: data.Position.Input, name: []const u8, direct: bool,
        flag: mapper.Mapper.ProtoArgFlag) void {
      c.cur_cursor = if (c.mapper.map(pos,
          if (direct) .{.direct = name} else .{.named = name}, flag)
      ) |mapped| .{
        .mapped = mapped,
      } else .failed;
    }

    fn pushArg(c: *Command, alloc: *std.mem.Allocator, arg: *data.Node) !void {
      defer c.cur_cursor = .not_pushed;
      const cursor = switch (c.cur_cursor) {
        .mapped => |val| val,
        .failed => return,
        .not_pushed => c.mapper.map(arg.pos.input, .position, .flow) orelse return,
      };
      try c.mapper.push(alloc, cursor, arg);
    }

    fn pushPrimary(c: *Command, pos: data.Position.Input, config: bool) void {
      c.cur_cursor = if (c.mapper.map(pos, .primary,
          if (config) .block_with_config else .block_no_config)) |cursor| .{
            .mapped = cursor,
          } else .failed;
    }

    fn shift(c: *Command, context: *Context, end: data.Cursor) !void {
      const newNode = try c.mapper.finalize(
        &context.temp_nodes.allocator, context.input.between(c.start, end));
      c.info = .{.unknown = newNode};
    }

    fn startAssignment(c: *Command) void {
      const subject = c.info.unknown;
      c.info = .{.assignment = mapper.AssignmentMapper.init(subject)};
      c.mapper = &c.info.assignment.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn startResolvedCall(c: *Command, alloc: *std.mem.Allocator, target: *data.Expression, sig: *data.Signature) !void {
      c.info = .{.resolved_call = try mapper.SignatureMapper.init(alloc, target, sig)};
      c.mapper = &c.info.resolved_call.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn startUnresolvedCall(c: *Command, alloc: *std.mem.Allocator) !void {
      const subject = c.info.unknown;
      c.info = .{.unresolved_call = mapper.CollectingMapper.init(subject)};
      c.mapper = &c.info.unresolved_call.mapper;
      c.cur_cursor = .not_pushed;
    }

    fn choseAstNodeParam(c: *Command) bool {
      return switch (c.cur_cursor) {
        .mapped => |cursor| if (c.mapper.paramType(cursor)) |t| switch (t) {
          .intrinsic => |i| i == .ast_node,
          else => false,
        } else false,
        else => false,
      };
    }
  };

  /// This is either the root level of the current file,
  /// a block argument or a list argument.
  /// The content level takes care of generating concatenations and paragraphs.
  const ContentLevel = struct {
    /// used for generating void nodes.
    start: data.Cursor,
    /// Changes to command characters that occurred upon entering this level.
    /// For implicit block configs, this links to the block config definition.
    changes: ?[]data.BlockConfig.Map,
    /// the currently open command on this content level. info === unknown if no
    /// command is open or only the subject has been read.
    /// every ContentLevel but the innermost one must have an open command.
    command: Command,
    /// whether this level has fullast semantics.
    fullast: bool,

    nodes: std.ArrayListUnmanaged(*data.Node),
    paragraphs: std.ArrayListUnmanaged(data.Node.Paragraphs.Item),

    block_config: ?*const data.BlockConfig,
    syntax_proc: ?*syntaxes.SpecialSyntax.Processor = null,
    dangling_space: ?*data.Node = null,

    fn append(l: *ContentLevel, alloc: *std.mem.Allocator, item: *data.Node) !void {
      if (l.syntax_proc) |proc| {
        const res = try proc.push(proc, item.pos.input, .{.node = item});
        std.debug.assert(res == .none);
      } else {
        if (l.dangling_space) |space_node| {
          std.debug.print("appending dangling space (kind={s})\n", .{@tagName(space_node.data.literal.kind)});
          try l.nodes.append(alloc, space_node);
          l.dangling_space = null;
        }
        try l.nodes.append(alloc, item);
      }
    }

    fn finalizeParagraph(l: *ContentLevel, c: *Context) !*data.Node {
      switch(l.nodes.items.len) {
        0 => {
          var ret = try c.temp_nodes.allocator.create(data.Node);
          ret.* = .{
            .pos = .{.input = c.input.at(l.start)},
            .data = .voidNode,
          };
          return ret;
        },
        1 => return l.nodes.items[0],
        else => {
          var ret = try c.temp_nodes.allocator.create(data.Node);
          ret.* = .{
            .pos = .{.input = l.nodes.items[0].pos.input.span(l.nodes.items[l.nodes.items.len - 1].pos.input)},
            .data = .{
              .concatenation = .{
                .content = l.nodes.items,
              },
            },
          };
          return ret;
        }
      }
    }

    fn implicitBlockConfig(l: *ContentLevel) ?*data.BlockConfig {
      return switch (l.command.cur_cursor) {
        .mapped => |c| l.command.mapper.config(c),
        else => null,
      };
    }

    fn finalize(l: *ContentLevel, p: *Parser) !*data.Node {
      if (l.block_config) |c| {
        try p.revertBlockConfig(c);
      }
      const alloc = p.int();
      if (l.syntax_proc) |proc| {
        return proc.finish(proc, p.ctx().input.between(l.start, p.cur_start));
      } else if (l.paragraphs.items.len == 0) {
        return l.finalizeParagraph(p.ctx());
      } else {
        if (l.nodes.items.len > 0) {
          try l.paragraphs.append(alloc, .{
            .content = try l.finalizeParagraph(p.ctx()),
            .lf_after = 0,
          });
        }

        var target = try alloc.create(data.Node);
        target.* = .{
          .pos = .{.input = l.paragraphs.items[0].content.pos.input.span(
            l.paragraphs.items[l.paragraphs.items.len - 1].content.pos.input)},
          .data = .{
            .paragraphs = .{
              .items = l.paragraphs.items,
            },
          },
        };
        return target;
      }
    }

    fn pushParagraph(l: *ContentLevel, context: *Context, lf_after: usize) !void {
      if (l.nodes.items.len > 0) {
        try l.paragraphs.append(&context.temp_nodes.allocator, .{
          .content = try l.finalizeParagraph(context),
          .lf_after = lf_after
        });
        l.nodes = .{};
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
  config: ?*data.BlockConfig,
  /// buffer for inline block config.
  config_buffer: data.BlockConfig,
  /// stack of currently active namespace mapping statuses.
  /// namespace mappings create a new namespace, disable a namespace, or map a
  /// namespace from one character to another.
  /// if a namespace is disabled, its index is pushed onto the stack.
  /// for other operations, either ns_mapping_failed or ns_mapping_succeeded is pushed.
  ns_mapping_stack: std.ArrayListUnmanaged(u16),

  l: lex.Lexer,
  state: State,
  cur: data.Token,
  cur_start: data.Cursor,

  fn int(self: *@This()) *std.mem.Allocator {
    return &self.ctx().temp_nodes.allocator;
  }

  fn ext(self: *@This()) *std.mem.Allocator {
    return &self.ctx().source_content.allocator;
  }

  fn ctx(self: *@This()) *Context {
    return self.l.context;
  }

  pub fn init() Parser {
    return Parser{
      .config = null,
      .config_buffer = undefined,
      .levels = .{},
      .ns_mapping_stack = .{},
      .l = undefined,
      .state = .start,
      .cur = undefined,
      .cur_start = undefined,
    };
  }

  pub fn parseFile(self: *Parser, path: []const u8, locator: data.Locator, context: *Context) !*data.Node {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, (try file.stat()).size + 4);
    file_contents[file_contents.len - 4..] = "\x04\x04\x04\x04";
    return self.parseSource(&Source{
      .content = file_contents,
      .offsets = .{.line = 0, .column = 0},
      .name = path,
      .locator = locator,
      .locator_ctx = locator.parent()
    }, context);
  }

  fn pushLevel(self: *Parser, fullast: bool) !void {
    try self.levels.append(self.int(), ContentLevel{
      .start = self.l.recent_end,
      .changes = null,
      .command = undefined,
      .nodes = .{},
      .paragraphs = .{},
      .block_config = null,
      .fullast = fullast,
    });
  }

  /// parse context.input. If it returns interpret.Errors.referred_source_unavailable,
  /// parsing may be resumed via resumeParse() after the referred source has been
  /// loaded. Other returned errors are not recoverable.
  ///
  /// Errors in the given input are not returned as errors of this function.
  /// Instead, they are handed to the context's errors.Handler. To check whether
  /// errors have occurred, check if the handler's error_count has been increased.
  pub fn parseSource(self: *Parser, context: *Context, fullast: bool) !*data.Node {
    self.l = try lex.Lexer.init(context);
    self.advance();
    return self.doParse(fullast);
  }

  /// continue parsing. Precondition: Either parseSource() or resumeParse()
  /// have returned with interpret.Errors.referred_source_unavailable
  /// previously on the given parser, and have never returned a *data.Node.
  ///
  /// Apart from the precondition, this function has the same semantics as
  /// parseSource(), including that it may return interpret.Errors.referred_source_unavailable.
  pub fn resumeParse(self: *Parser) !*data.Node {
    // when resuming, the fullast value is irrelevant since it is only inspected
    // when encountering the first non-space token in the file – which will always
    // be before parsing is interrupted.
    return self.doParse(undefined);
  }

  /// retrieves the next valid token from the lexer.
  /// emits errors for any invalid token along the way.
  inline fn advance(self: *Parser) void {
    while (true) {
      self.cur_start = self.l.recent_end;
      (switch (self.l.next() catch |e| blk: {
        const start = self.cur_start;
        const next = while (true) {
          break self.l.next() catch continue;
        } else unreachable;
        self.ctx().eh.InvalidUtf8Encoding(self.l.walker.posFrom(start));
        break :blk next;
      }) {
        // the following errors are not handled here since they indicate structure:
        //   missing_block_name_sep (ends block name)
        //
        .illegal_code_point => errors.Handler.IllegalCodePoint,
        .illegal_opening_parenthesis => errors.Handler.IllegalOpeningParenthesis,
        .illegal_blocks_start_in_args => errors.Handler.IllegalBlocksStartInArgs,
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
      })(&self.ctx().eh, self.l.walker.posFrom(self.cur_start));
    }
    if (std.builtin.mode == .Debug) {
      if (@enumToInt(self.cur) >= @enumToInt(data.Token.skipping_call_id)) {
        std.debug.print("  << skipping_call_id({})\n", .{@enumToInt(self.cur) - @enumToInt(data.Token.skipping_call_id) + 1});
      } else {
        std.debug.print("  << {s}\n", .{@tagName(self.cur)});
      }
    }
  }

  /// retrieves the next token from the lexer. returns true iff that token is valid.
  /// if false is returned, self.cur must be considered undefined.
  inline fn getNext(self: *Parser) bool {
    self.cur_start = self.l.recent_end;
    (switch (self.l.next() catch |e| {
      self.ctx().eh.InvalidUtf8Encoding(self.l.walker.posFrom(self.cur_start));
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
        if (@enumToInt(t) > @enumToInt(data.Token.skipping_call_id))
          unreachable;
        self.cur = t;
        if (std.builtin.mode == .Debug) {
          std.debug.print("  << {s}\n", .{@tagName(self.cur)});
        }
        return true;
      }
    })(&self.ctx().eh, self.l.walker.posFrom(self.cur_start));
    return false;
  }

  fn leaveLevel(self: *Parser) !void {
    var lvl = &self.levels.items[self.levels.items.len - 1];
    var parent = &self.levels.items[self.levels.items.len - 2];
    const lvl_node = try lvl.finalize(self);
    if (std.builtin.mode == .Debug) {
      if (@enumToInt(self.cur) >= @enumToInt(data.Token.skipping_call_id)) {
        std.debug.print("skipping_call_id({}): pushing {s} into command {s}\n",
            .{@enumToInt(self.cur) - @enumToInt(data.Token.skipping_call_id) + 1,
            @tagName(lvl_node.data), @tagName(parent.command.info)});
      } else {
        std.debug.print("{s}: pushing {s} into command {s}\n",
            .{@tagName(self.cur), @tagName(lvl_node.data), @tagName(parent.command.info)});
      }
    }
    try parent.command.pushArg(self.int(), lvl_node);
    _ = self.levels.pop();
  }

  inline fn curLevel(self: *Parser) *ContentLevel {
    return &self.levels.items[self.levels.items.len - 1];
  }

  fn doParse(self: *Parser, implicit_fullast: bool) !*data.Node {
    while (true) {
      std.debug.print("parse step. state={s}, level stack =\n", .{@tagName(self.state)});
      for (self.levels.items) |lvl| {
        std.debug.print("  level(command = {s}, special = {})\n",
            .{@tagName(lvl.command.info), lvl.syntax_proc != null});
      }

      switch (self.state) {
        .start => {
          while (self.cur == .space or self.cur == .indent) self.advance();
          // this state is used for initial top-level and for list arguments.
          // list arguments do not change block configuration and so will always
          // inherit parent's fullast. the top-level will not be fullast unless
          // instructed by the caller.
          try self.pushLevel(
            if (self.levels.items.len == 0) implicit_fullast else self.curLevel().fullast);
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
                const parent = &self.levels.items[self.levels.items.len - 1];
                try parent.command.shift(self.ctx(), self.cur_start);
                try parent.append(self.int(), parent.command.info.unknown);
              }
              return self.levels.items[0].finalize(self);
            },
            .symref => {
              self.levels.items[self.levels.items.len - 1].command = .{
                .start = self.cur_start,
                .info = .{
                  .unknown = try self.ctx().resolveSymbol(
                      .{.input = self.l.walker.posFrom(self.cur_start)},
                      self.l.ns, self.l.recent_id),
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
              const newline_count = self.l.newline_count;
              self.advance();
              if (self.cur != .block_end_open and self.cur != .end_source) {
                try self.levels.items[self.levels.items.len - 1].pushParagraph(self.ctx(), newline_count);
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
                  const cmd_start = self.levels.items[self.levels.items.len - 2].command.start;
                  self.ctx().eh.WrongCallId(self.l.walker.posFrom(self.cur_start),
                      self.l.recent_expected_id, self.l.recent_id,
                      self.ctx().input.at(cmd_start));
                },
                else => {
                  std.debug.assert(@enumToInt(self.cur) >= @enumToInt(data.Token.skipping_call_id));
                  const cmd_start = self.levels.items[self.levels.items.len - 2].command.start;
                  self.ctx().eh.SkippingCallId(self.l.walker.posFrom(self.cur_start),
                      self.l.recent_expected_id, self.l.recent_id,
                      self.ctx().input.at(cmd_start));
                  var i = @as(u32, 0);
                  while (i < data.Token.numSkippedEnds(self.cur)) : (i = i + 1) {
                    try self.leaveLevel();
                  }
                },
              }
              try self.leaveLevel();
              self.advance();
              if (self.cur == .list_end) {
                self.advance();
              } else {
                self.ctx().eh.MissingClosingParenthesis(self.ctx().input.at(self.cur_start));
              }
              self.state = .command;
              try self.levels.items[self.levels.items.len - 1].command.shift(
                  self.ctx(), self.cur_start);
            },
            else => {
              std.debug.print("unexpected token in default: {s}\n", .{@tagName(self.cur)});
              unreachable;
            }
          }
        },
        .textual => {
          var content: std.ArrayListUnmanaged(u8) = .{};
          var non_space_len: usize = 0;
          var non_space_line_len: usize = 0;
          var non_space_end: data.Cursor = undefined;
          const textual_start = self.cur_start;
          while (true) {
            switch (self.cur) {
              .space =>
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.cur_start.byte_offset)),
              .literal => {
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.cur_start.byte_offset));
                non_space_len = content.items.len;
                non_space_line_len = non_space_len;
                non_space_end = self.l.recent_end;
              },
              .ws_break => {
                // dump whitespace before newline
                content.shrinkRetainingCapacity(non_space_line_len);
                try content.append(self.int(), '\n');
                non_space_line_len = content.items.len;
              },
              .escape => {
                try content.appendSlice(self.int(), self.l.recent_id);
                non_space_len = content.items.len;
                non_space_line_len = non_space_len;
                non_space_end = self.l.recent_end;
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
          const lvl = &self.levels.items[self.levels.items.len - 1];
          const pos = switch(self.cur) {
            .block_end_open, .block_name_sep, .comma, .name_sep, .list_end,
            .end_source => blk: {
              content.shrinkAndFree(self.int(), non_space_len);
              break :blk self.ctx().input.between(textual_start, non_space_end);
            },
            else => self.l.walker.posFrom(textual_start),
          };
          if (content.items.len > 0) {
            if (self.cur == .name_sep) {
              if (lvl.nodes.items.len > 0) {
                unreachable; // TODO: error: equals not allowed here
              }
              self.levels.items[self.levels.items.len - 2].command.pushName(
                pos, content.items, pos.end.byte_offset - pos.start.byte_offset == 2, .flow);
              while (true) {
                self.advance();
                if (self.cur != .space) break;
              }
            } else {
              var node = try self.int().create(data.Node);
              node.* = .{
                .pos = .{.input = pos},
                .data = .{
                  .literal = .{
                    .kind = if (non_space_len > 0) .text else .space,
                    .content = content.items
                  },
                },
              };
              std.debug.print("  push literal (kind={s}): \"{}\"\n", .{@tagName(node.data.literal.kind), std.zig.fmtEscapes(content.items)});
              // dangling space will be postponed for the case of a following,
              // swallowing command that ends the current level.
              if (non_space_len > 0) try lvl.append(self.int(), node)
              else lvl.dangling_space = node;
              self.state = .default;
            }
          } else self.state = .default; // can happen with space at block/arg end
        },
        .command => {
          var lvl = &self.levels.items[self.levels.items.len - 1];
          switch(self.cur) {
            .access => {
              self.advance();
              if (self.cur != .identifier) unreachable; // TODO: recover
              var node = try self.int().create(data.Node);
              node.* = .{
                .pos = .{.input = self.l.walker.posFrom(lvl.command.info.unknown.pos.input.start)},
                .data = .{
                  .access = .{
                    .subject = lvl.command.info.unknown,
                    .id = self.l.recent_id,
                  },
                },
              };
              lvl.command.info.unknown = node;
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
              lvl.command.startAssignment();
              self.advance();
            },
            .list_start, .blocks_sep => {
              const target = lvl.command.info.unknown;
              switch (target.data) {
                .resolved_symref, .unresolved_symref, .access => {
                  const res = try self.ctx().resolveChain(target, self.ext());
                  switch (res) {
                    .var_chain => |chain| {
                      unreachable; // TODO
                    },
                    .func_ref => |func| {
                      unreachable; // TODO
                    },
                    .expr_chain => |chain| {
                      unreachable; // TODO
                    },
                    .type_ref => |t| {
                      unreachable; // TODO
                    },
                    .failed => {
                      try lvl.command.startUnresolvedCall(self.int());
                    },
                    .poison => unreachable //TODO
                  }
                },
                else => unreachable // TODO
              }
              self.state = if (self.cur == .list_start) .possible_start else .after_blocks_start;
              self.advance();
            },
            .closer => {
              try lvl.append(self.int(), lvl.command.info.unknown);
              self.advance();
              self.state = if (self.levels.items[self.levels.items.len - 1].syntax_proc != null) .special else .default;
            },
            else => {
              try lvl.append(self.int(), lvl.command.info.unknown);
              self.state = if (self.levels.items[self.levels.items.len - 1].syntax_proc != null) .special else .default;
              std.debug.print("state reset after command, now {s}\n", .{@tagName(self.state)});
            }
          }
        },
        .after_list => {
          const end = self.l.recent_end;
          self.advance();
          if (self.cur == .blocks_sep) {
            // call continues
            self.state = .after_blocks_start;
            self.advance();
          } else {
            self.state = .command;
            try self.curLevel().command.shift(self.ctx(), end);
          }
        },
        .after_blocks_start => {
          var pb_exists = PrimaryBlockExists.unknown;
          std.debug.print("after_blocks_start: processing header…\n", .{});
          if (try self.processBlockHeader(&pb_exists)) {
            std.debug.print("  … swallowing.\n", .{});
            self.state = if (self.curLevel().syntax_proc != null) .special else .default;
          } else {
            const pos = self.ctx().input.at(self.cur_start);
            while (self.cur == .space or self.cur == .indent) self.advance();
            if (self.cur == .block_name_sep) {
              std.debug.print("  … no primary block.\n", .{});
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
              std.debug.print("  … primary block.\n", .{});
              if (pb_exists == .unknown) {
                const lvl = self.curLevel();
                // neither explicit nor implicit block config. fullast is thus
                // inherited except when an AstNode parameter has been chosen.
                try self.pushLevel(if (lvl.command.choseAstNodeParam()) false else lvl.fullast);
              }
              self.state = if (self.curLevel().syntax_proc != null) .special else .default;
            }
          }
          std.debug.print("  … state is now {s}\n", .{@tagName(self.state)});
        },
        .block_name => {
          std.debug.assert(self.cur == .block_name_sep);
          while (true) {
            self.advance();
            if (self.cur != .space) break;
          }
          const parent = &self.levels.items[self.levels.items.len - 1];
          if (self.cur == .identifier) {
            const name = self.l.walker.contentFrom(self.cur_start.byte_offset);
            const name_pos = self.l.walker.posFrom(self.cur_start);
            var recover = false;
            while (true) {
              self.advance();
              if (self.cur == .block_name_sep or self.cur == .missing_block_name_sep) break;
              if (self.cur != .space and !recover) {
                self.ctx().eh.ExpectedXGotY(
                    self.l.walker.posFrom(self.cur_start),
                    &[_]errors.WrongItemError.ItemDescr{.{.token = .block_name_sep}},
                    .{.token = self.cur});
                recover = true;
              }
            }
            if (self.cur == .missing_block_name_sep) {
              self.ctx().eh.MissingBlockNameEnd(self.ctx().input.at(self.cur_start));
            }
            parent.command.pushName(name_pos, name, false,
                if (self.cur == .diamond_open) .block_with_config else .block_no_config);
          } else {
            self.ctx().eh.ExpectedXGotY(self.ctx().input.at(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
              .{.token = self.cur});
            while (self.cur != .block_name_sep and self.cur != .missing_block_name_sep) {
              self.advance();
            }
            parent.command.cur_cursor = .failed;
          }
          self.advance();
          // initialize level with fullast according to chosen param type.
          // may be overridden by block config in following processBlockHeader.
          try self.pushLevel(if (parent.command.choseAstNodeParam()) false else parent.fullast);
          if (!(try self.processBlockHeader(null))) {
            while (self.cur == .space or self.cur == .indent) self.advance();
          }
          self.state = if (self.levels.items[self.levels.items.len - 1].syntax_proc != null) .special else .default;
        },
        .special => {
          const proc = self.curLevel().syntax_proc.?;
          const result = try switch (self.cur) {
            .indent => syntaxes.SpecialSyntax.Processor.Action.none,
            .space => proc.push(proc, self.l.walker.posFrom(self.cur_start),
                .{.space = self.l.walker.contentFrom(self.cur_start.byte_offset)}),
            .escape => proc.push(proc, self.l.walker.posFrom(self.cur_start),
                .{.escaped = self.l.recent_id}),
            .identifier => proc.push(proc, self.l.walker.posFrom(self.cur_start),
                .{.literal = self.l.recent_id}),
            .special => proc.push(proc, self.l.walker.posFrom(self.cur_start),
                .{.special_char = self.l.code_point}),
            .ws_break => // TODO: discard if at end of block
              proc.push(proc, self.l.walker.posFrom(self.cur_start), .{.newlines = 1}),
            .parsep => proc.push(proc, self.l.walker.posFrom(self.cur_start), .{.newlines = self.l.newline_count}),
            .end_source, .symref, .block_name_sep, .block_end_open => {
              self.state = .default;
              continue;
            },
            else => {
              std.debug.print("unexpected token in special: {s}\n", .{@tagName(self.cur)});
              unreachable;
            }
          };
          switch (result) {
            .none => self.advance(),
            .read_block_header => {
              const start = self.cur_start;
              self.l.readBlockHeader();
              const expr = try self.ext().create(data.Expression);
              expr.data = .{
                .literal = .{
                  .value = .{
                    .origin = undefined,
                    .data = .{.block_header = undefined},
                  },
                },
              };
              const bh = &expr.data.literal.value.data.block_header;

              self.advance();
              const check_swallow = if (self.cur == .diamond_open) blk: {
                bh.config = @as(data.BlockConfig, undefined);
                try self.readBlockConfig(&bh.config.?, self.ext());
                if (self.cur == .blocks_sep) {
                  self.advance();
                  break :blk true;
                } else break :blk false;
              } else true;
              if (check_swallow) {
                bh.swallow_depth = self.checkSwallow();
              }
              const pos = self.ctx().input.between(start, self.cur_start);
              expr.data.literal.value.origin = pos;
              expr.pos = .{.input = pos};
              _ = try proc.push(proc, pos, .{.block_header = bh});
            }
          }
        }
      }
    }
  }

  const ConfigItemKind = enum {csym, syntax, map, off, fullast, empty, unknown};

  fn readBlockConfig(self: *Parser, into: *data.BlockConfig, alloc: *std.mem.Allocator) !void {
    std.debug.assert(self.cur == .diamond_open);
    var mapList: std.ArrayListUnmanaged(data.BlockConfig.Map) = .{};
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
          self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
              .{.token = self.cur});
        }
        break;
      }
      first = false;
      std.debug.assert(self.cur == .identifier);
      const start = self.cur_start;
      const name = self.l.walker.contentFrom(self.cur_start.byte_offset);
      const kind: ConfigItemKind = switch (std.hash.Adler32.hash(name)) {
        std.hash.Adler32.hash("csym") => .csym,
        std.hash.Adler32.hash("syntax") => .syntax,
        std.hash.Adler32.hash("map") => .map,
        std.hash.Adler32.hash("off") => .off,
        std.hash.Adler32.hash("fullast") => .fullast,
        std.hash.Adler32.hash("") => .empty,
        else => blk: {
          self.ctx().eh.UnknownConfigDirective(self.l.walker.posFrom(start));
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
              try mapList.append(alloc, .{
                .pos = self.l.walker.posFrom(start),
                .from = 0, .to = self.l.code_point});
            } else {
              self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
                  .{.token = self.cur});
              recover = true;
            }
          },
          .syntax => {
            if (self.cur == .literal) {
              switch (std.hash.Adler32.hash(self.l.walker.contentFrom(self.cur_start.byte_offset))) {
                std.hash.Adler32.hash("locations") => {
                  into.syntax = .{
                    .pos = .intrinsic,
                    .index = 0,
                  };
                },
                std.hash.Adler32.hash("definitions") => {
                  into.syntax = .{
                    .pos = .intrinsic,
                    .index = 1,
                  };
                },
                else => {
                  self.ctx().eh.UnknownSyntax(self.l.walker.posFrom(self.cur_start));
                }
              }
            } else {
              self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .literal}},
                  .{.token = self.cur});
              recover = true;
            }
          },
          .map => {
            if (self.cur == .ns_sym) {
              const from = self.l.code_point;
              recover = while (self.getNext()) {
                if (self.cur != .space) break self.cur != .ns_sym;
              } else true;
              if (!recover) {
                try mapList.append(alloc, .{
                  .pos = self.l.walker.posFrom(start),
                  .from = from, .to = self.l.code_point,
                });
              }
            } else recover = true;
            if (recover) {
              self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}},
                  .{.token = self.cur});
            }
          },
          .off => {
            switch (self.cur) {
              .comment => into.off_comment = self.l.walker.posFrom(self.cur_start),
              .block_name_sep => into.off_colon = self.l.walker.posFrom(self.cur_start),
              .ns_sym => try mapList.append(alloc, .{
                .pos = self.l.walker.posFrom(start), .from = self.l.code_point, .to = 0
              }),
              else => {
                self.ctx().eh.ExpectedXGotY(
                    self.l.walker.posFrom(self.cur_start),
                    &[_]errors.WrongItemError.ItemDescr{.{.token = .ns_sym}, .{.character = '#'}, .{.character = ':'}},
                    .{.token = self.cur});
                recover = true;
              }
            }
          },
          .fullast => {
            into.full_ast = self.l.walker.posFrom(self.cur_start);
            break :consume_next;
          },
          .empty => {
            self.ctx().eh.ExpectedXGotY(
                self.l.walker.posFrom(self.cur_start),
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.token = self.cur});
            recover = true;
            break :consume_next;
          },
          .unknown => break :consume_next,
        }
        while (!self.getNext()) {}
      }
      while (self.cur != .comma and self.cur != .diamond_close and self.cur != .end_source) : (while (!self.getNext()) {}) {
        if (self.cur != .space and !recover) {
          self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
              &[_]errors.WrongItemError.ItemDescr{.{.character = ','}, .{.character = '>'}},
              .{.token = self.cur});
          recover = true;
        }
      }
    }
    if (self.cur == .diamond_close) {
      self.advance();
    } else {
      self.ctx().eh.ExpectedXGotY(self.l.walker.posFrom(self.cur_start),
          &[_]errors.WrongItemError.ItemDescr{.{.token = .diamond_close}},
          .{.token = self.cur});
    }
    into.map = mapList.items;
  }

  /// out-value used for processBlockHeader after the initial ':'.
  const PrimaryBlockExists = enum {unknown, maybe, yes};

  /// processes the content after a `:` that either started blocks or ended a
  /// block name. returns true iff swallowing has ocurred.
  /// pb_exists shall be non-null iff the ':' starts block parameters (i.e. we
  /// are not after a block name). its initial value shall be .unknown.
  /// the out value of pb_exists indicates the following:
  ///   .unknown => no level has been pushed since neither explicit nor implicit
  ///               block configuration has been encountered. the current level's
  ///               primary param has been entered to check for implicit block config.
  ///   .maybe   => level has been pushed and command entered its primary param,
  ///               but existence of primary block is not known. This happens if
  ///               a call target does have a primary parameter that supplies an
  ///               implicit block config. This block config must be activated
  ///               before reading the block content, since it may change the
  ///               lexer's behavior. If there is, in fact, no primary block,
  ///               the pushed level is to be discarded.
  ///   .yes     => level has been pushed and command entered its primary param
  ///               due to explicit block config.
  fn processBlockHeader(self: *Parser, pb_exists: ?*PrimaryBlockExists) !bool {
    const parent = self.curLevel();
    const check_swallow = if (self.cur == .diamond_open) blk: {
      try self.readBlockConfig(&self.config_buffer, self.int());
      std.debug.print("block header has map length of {}\n", .{self.config_buffer.map.len});
      const pos = self.ctx().input.at(self.cur_start);
      if (pb_exists) |ind| {
        parent.command.pushPrimary(pos, true);
        try self.pushLevel(if (parent.command.choseAstNodeParam()) false else parent.fullast);
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
            parent.command.pushPrimary(self.ctx().input.at(self.cur_start), false);
            try self.pushLevel(if (parent.command.choseAstNodeParam()) false else parent.fullast);
            if (parent.implicitBlockConfig()) |c| {
              try self.applyBlockConfig(self.ctx().input.at(self.cur_start), c);
            }
          }
          ind.* = .yes;
        } else try self.pushLevel(if (parent.command.choseAstNodeParam()) false else parent.fullast);
        parent.command.swallow_depth = swallow_depth;
        if (swallow_depth != 0) {
          // now close all commands that have a swallow depth equal or greater than the current one,
          // excluding 0. To do this, we first determine the actual level in which the current
          // command is to be placed in (we'll skip the innermost level which we just pushed).
          // target_level is the level into which the current command should be pushed.
          // cur_depth is the level we're checking. Since we may need to look beyond levels
          // with swallow depth 0, we need to keep these values in separate vars.
          var target_level: usize = self.levels.items.len - 2;
          var cur_depth: usize = target_level;
          while (cur_depth > 0) : (cur_depth = cur_depth - 1) {
            if (self.levels.items[cur_depth - 1].command.swallow_depth) |level_depth| {
              if (level_depth != 0) {
                if (level_depth < swallow_depth) break;
                target_level = cur_depth - 1;
              }
              // if level_depth is 0, we don't set target_level but still look if it
              // has parents that have a depth greater 0 and are ended by the current
              // swallow.
            } else break;
          }
          if (target_level < self.levels.items.len - 2) {
            // one or more levels need closing.
            // calculate the end of the most recent node, which will be the end
            // cursor for all levels that will now be closed.
            // this cursor is not necesserily the start of the current
            // swallowing command, since whitespace before that command is dumped.
            const end_cursor = if (parent.nodes.items.len == 0)
                parent.paragraphs.items[parent.paragraphs.items.len - 1].content.pos.input.end
              else parent.nodes.items[parent.nodes.items.len - 1].pos.input.end;

            var i = self.levels.items.len - 2;
            while (i > target_level) : (i -= 1) {
              const cur_parent = &self.levels.items[i - 1];
              try cur_parent.command.pushArg(self.int(), try self.levels.items[i].finalize(self));
              try cur_parent.command.shift(self.ctx(), end_cursor);
              try cur_parent.append(self.int(), cur_parent.command.info.unknown);
            }
            // target_level's command has now been closed.
            // therefore it is safe to assign it to the previous parent's command
            // (which has not been touched).
            self.levels.items[target_level].command = parent.command;
            // finally, shift the new level on top of the target_level
            self.levels.items[target_level + 1] = self.levels.items[self.levels.items.len - 1];
            try self.levels.resize(self.int(), target_level + 1);
          }
        }

        while (self.cur == .space or self.cur == .indent or self.cur == .ws_break) self.advance();
        return true;
      } else if (pb_exists) |ind| {
        if (ind.* == .unknown) {
          parent.command.pushPrimary(self.ctx().input.at(self.cur_start), false);
          if (parent.implicitBlockConfig()) |c| {
            ind.* = .maybe;
            try self.pushLevel(if (parent.command.choseAstNodeParam()) false else parent.fullast);
            try self.applyBlockConfig(self.ctx().input.at(self.cur_start), c);
          }
        }
      }
    }
    return false;
  }

  fn checkSwallow(self: *Parser) ?u21 {
    return switch (self.cur) {
      .swallow_depth => blk: {
        const swallow_depth = self.l.code_point;
        self.advance();
        if (self.cur == .diamond_close) {
          self.advance();
        } else {
          self.ctx().eh.SwallowDepthWithoutDiamondClose(self.ctx().input.at(self.cur_start));
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

  fn applyBlockConfig(self: *Parser, pos: data.Position.Input, config: *const data.BlockConfig) !void {
    var sf = std.heap.stackFallback(128, self.int());
    var alloc = sf.get();
    const lvl = self.curLevel();

    if (config.syntax) |s| {
      const syntax = self.ctx().syntax_registry[s.index];
      lvl.syntax_proc = try syntax.init(self.ctx());
      self.l.enableSpecialSyntax(syntax.comments_include_newline);
    }

    if (config.map.len > 0) {
      var resolved_indexes = try alloc.alloc(u16, config.map.len);
      defer alloc.free(resolved_indexes);
      try self.ns_mapping_stack.ensureUnusedCapacity(self.int(), config.map.len);
      // resolve all given from characters in the current set of command characters.
      for (config.map) |mapping, i| {
        resolved_indexes[i] = if (mapping.from == 0) ns_mapping_no_from else
            if (self.ctx().command_characters.get(mapping.from)) |from_index| @intCast(u16, from_index) else blk: {
          const ec = unicode.EncodedCharacter.init(mapping.from);
          self.ctx().eh.IsNotANamespaceCharacter(ec.repr(), pos, mapping.pos);
          break :blk ns_mapping_failed;
        };
      }
      // disable all command characters that need disabling.
      for (config.map) |mapping, i| {
        if (mapping.to == 0) {
          const from_index = resolved_indexes[i];
          if (from_index != ns_mapping_failed) {
            _ = self.ctx().command_characters.remove(mapping.from);
          }
          try self.ns_mapping_stack.append(self.int(), from_index);
        }
      }
      // execute all namespace remappings
      for (config.map) |mapping, i| {
        const from_index = resolved_indexes[i];
        if (mapping.to != 0 and from_index != ns_mapping_no_from) {
          try self.ns_mapping_stack.append(self.int(), blk: {
            if (from_index != ns_mapping_failed) {
              if (self.ctx().command_characters.get(mapping.to)) |_| {
                // check if an upcoming remapping will remove this command character
                var found = false;
                for (config.map[i+1..]) |upcoming| {
                  if (upcoming.from == mapping.to) {
                    found = true;
                    break;
                  }
                }
                if (!found) {
                  const ec = unicode.EncodedCharacter.init(mapping.to);
                  self.ctx().eh.AlreadyANamespaceCharacter(ec.repr(), pos, mapping.pos);
                  break :blk ns_mapping_failed;
                }
              }
              try self.ctx().command_characters.put(self.int(), mapping.to, @intCast(u15, from_index));
              // only remove old command character if it has not previously been remapped.
              if (self.ctx().command_characters.get(mapping.from)) |cur_from_index| {
                if (cur_from_index == from_index) {
                  _ = self.ctx().command_characters.remove(mapping.from);
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
          if (self.ctx().command_characters.get(mapping.to)) |_| {
            // this is not an error, but we still record it as 'failed' so
            // that we know when reversing this block config, nothing needs to
            // be done.
            try self.ns_mapping_stack.append(self.int(), ns_mapping_failed);
          } else {
            try self.ctx().addNamespace(self.int(), mapping.to);
            try self.ns_mapping_stack.append(self.int(), ns_mapping_succeeded);
          }
        }
      }
    }

    if (config.off_colon) |_| {
      self.l.disableColons();
    }
    if (config.off_comment) |_| {
      self.l.disableComments();
    }

    if (config.full_ast) |_| lvl.fullast = true;

    lvl.block_config = config;
  }

  fn revertBlockConfig(self: *Parser, config: *const data.BlockConfig) !void {
    // config.syntax does not need to be reversed, this happens automatically by
    // leaving the level.

    if (config.map.len > 0) {
      var sf = std.heap.stackFallback(128, self.int());
      var alloc = sf.get();

      // reverse establishment of new namespaces
      var i = config.map.len - 1;
      while (true) : (i = i - 1) {
        const mapping = &config.map[i];
        if (mapping.from == 0) {
          if (self.ns_mapping_stack.pop() == ns_mapping_succeeded) {
            self.ctx().removeNamespace(mapping.to);
          }
        }
        if (i == 0) break;
      }

      // get the indexes of namespaces that have been remapped.
      var ns_indexes = try alloc.alloc(u15, config.map.len);
      defer alloc.free(ns_indexes);
      for (config.map) |mapping, j| {
        if (mapping.from != 0 and mapping.to != 0) {
          ns_indexes[j] = self.ctx().command_characters.get(mapping.to).?;
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
              if (self.ctx().command_characters.get(mapping.to).? == ns_index) {
                _ = self.ctx().command_characters.remove(mapping.to);
              }
              // this cannot fail because command_characters will always be large enough to
              // add another item without requiring allocation.
              self.ctx().command_characters.put(self.int(), mapping.from, ns_index) catch unreachable;
            }
          } else {
            const ns_index = self.ns_mapping_stack.pop();
            if (ns_index != ns_mapping_failed) {
              // like above
              self.ctx().command_characters.put(self.int(), mapping.from, @intCast(u15, ns_index)) catch unreachable;
            }
          }
        }
        if (i == 0) break;
      }
    }

    // off_colon, off_comment, and special syntax are reversed automatically by the lexer.
    // full_ast is automatically reversed by leaving the level.
  }
};