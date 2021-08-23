const std = @import("std");
const data = @import("data");
const lex = @import("lex.zig");
const Source = @import("source.zig").Source;
const Context = @import("interpret.zig").Context;
const mapper = @import("mapper.zig");

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

    fn pushName(c: *Command, pos: data.Position, name: []const u8, direct: bool,
        flag: mapper.Mapper.ParamFlag) void {
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
        .not_pushed => c.mapper.map(arg.pos, .position, .flow) orelse return,
      };
      try c.mapper.push(alloc, cursor, arg);
    }

    fn pushPrimary(c: *Command, pos: data.Position, config: bool) void {
      c.cur_cursor = if (c.mapper.map(pos, .primary,
          if (config) .block_with_config else .block_no_config)) |cursor| .{
            .mapped = cursor,
          } else .failed;
    }

    fn shift(c: *Command, alloc: *std.mem.Allocator, src_name: []const u8, end: data.Cursor) !void {
      const newNode = try c.mapper.finalize(alloc, data.Position.inMod(src_name, c.start, end));
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
  };

  /// This is either the root level of the current file,
  /// a block argument or a list argument.
  /// The content level takes care of generating concatenations and paragraphs.
  const ContentLevel = struct {
    /// used for generating void nodes.
    source_name: []const u8,
    /// used for generating void nodes.
    start: data.Cursor,
    /// Changes to command characters that occurred upon entering this level.
    /// For implicit block configs, this links to the block config definition.
    changes: ?[]data.BlockConfig.Map,
    /// When the used block configuration defines the definiton of a command
    /// character, but that command character already exists, nothing will
    /// happen. Therefore, we must not revert that change when leaving this
    /// content level (which would remove a command character that is defined
    /// in an upper level). For explicit block configs, this issue is handled by
    /// directly removing the change from the config, but implicit block configs
    /// can be referred to in multiple places and therefore must not be modified
    /// when they are used. For those cases, we set this variable to the index
    /// of all changes that are not to be reverted when the content level will
    // be left.
    ignored_changes: ?[]usize,
    /// the currently open command on this content level. info === unknown if no
    /// command is open or only the subject has been read.
    /// every ContentLevel but the innermost one must have an open command.
    command: Command,

    nodes: std.ArrayListUnmanaged(*data.Node),
    paragraphs: std.ArrayListUnmanaged(data.Node.Paragraphs.Item),

    fn append(l: *ContentLevel, alloc: *std.mem.Allocator, item: *data.Node) !void {
      try l.nodes.append(alloc, item);
    }

    fn finalizeParagraph(l: *ContentLevel, alloc: *std.mem.Allocator) !*data.Node {
      switch(l.nodes.items.len) {
        0 => {
          var ret = try alloc.create(data.Node);
          ret.* = .{
            .pos = data.Position.inMod(l.source_name, l.start, l.start),
            .data = .voidNode,
          };
          return ret;
        },
        1 => return l.nodes.items[0],
        else => {
          var ret = try alloc.create(data.Node);
          ret.* = .{
            .pos = l.nodes.items[0].pos.span(l.nodes.items[l.nodes.items.len - 1].pos),
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

    fn finalize(l: *ContentLevel, alloc: *std.mem.Allocator) !*data.Node {
      if (l.paragraphs.items.len == 0) {
        return l.finalizeParagraph(alloc);
      } else {
        if (l.nodes.items.len > 0) {
          try l.paragraphs.append(alloc, .{
            .content = try l.finalizeParagraph(alloc),
            .lf_after = 0,
          });
        }

        var target = try alloc.create(data.Node);
        target.* = .{
          .pos = l.paragraphs.items[0].content.pos.span(l.paragraphs.items[l.paragraphs.items.len - 1].content.pos),
          .data = .{
            .paragraphs = .{
              .items = l.paragraphs.items,
            },
          },
        };
        return target;
      }
    }

    fn pushParagraph(l: *ContentLevel, alloc: *std.mem.Allocator, lf_after: usize) !void {
      if (l.nodes.items.len > 0) {
        try l.paragraphs.append(alloc, .{
          .content = try l.finalizeParagraph(alloc),
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
    /// This state checks whether a primary block exists after a blocks start
    /// without a block config (which forces a primary block).
    /// A primary block exists when either any non-space content appears before
    /// the occurrence of a block name, or an \end() command directly closes the
    /// blocks.
    ///
    /// When we are in this state, a ContentLevel has already been created to
    /// honor any implicit block config that may be defined by the chosen target
    /// parameter. If no primary block exists, that ContentLevel will be
    /// discarded and its changes will be reverted.
    after_blocks_start,
    /// This state reads in a block name, possibly a block configuration, and
    /// then pushes a level to read the block content.
    block_name,
  };

  /// stack of current levels. must have at least size of 1, with the first
  /// level being the current source's root.
  levels: std.ArrayListUnmanaged(ContentLevel),
  /// currently parsed block config. Filled in the .config state.
  config: ?data.BlockConfig,

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
      .levels = .{},
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

  fn pushLevel(self: *Parser) !void {
    try self.levels.append(self.int(), ContentLevel{
      .source_name = self.l.walker.source.name,
      .start = self.l.recent_end,
      .changes = null,
      .ignored_changes = null,
      .command = undefined,
      .nodes = .{},
      .paragraphs = .{},
    });
  }

  pub fn parseSource(self: *Parser, source: *Source, context: *Context) !*data.Node {
    self.l = try lex.Lexer.init(context, source);
    try self.advance();
    return self.doParse();
  }

  pub fn resumeParse(self: *Parser) !*data.Node {
    return self.doParse();
  }

  inline fn advance(self: *Parser) !void {
    self.cur_start = self.l.recent_end;
    // TODO: recover from unicode errors?
    self.cur = try self.l.next();
    std.debug.print("  << {s}\n", .{@tagName(self.cur)});
  }

  fn doParse(self: *Parser) !*data.Node {
    while (true) {
      std.debug.print("parse step. state={s}, level stack =\n", .{@tagName(self.state)});
      for (self.levels.items) |lvl| {
        std.debug.print("  level(command = {s})\n", .{@tagName(lvl.command.info)});
      }

      switch (self.state) {
        .start => {
          while (self.cur == .space) try self.advance();
          try self.pushLevel();
          self.state = .default;
        },
        .possible_start => {
          while (self.cur == .space) try self.advance();
          if (self.cur == .list_end) {
            self.state = .after_list;
          } else {
            try self.pushLevel();
            self.state = .default;
          }
        },
        .default => {
          switch (self.cur) {
            .space, .escape, .literal, .ws_break => {
              self.state = .textual;
              continue;
            },
            .end_source => {
              while (self.levels.items.len > 1) {
                var lvl = &self.levels.items[self.levels.items.len - 1];
                try self.levels.items[self.levels.items.len - 1].append(self.int(),
                    try lvl.finalize(self.int()));
                _ = self.levels.pop();
              }
              return self.levels.items[0].finalize(self.int());
            },
            .symref => {
              self.levels.items[self.levels.items.len - 1].command = .{
                .start = self.cur_start,
                .info = .{
                  .unknown = try self.ctx().resolveSymbol(
                      self.l.walker.posFrom(self.cur_start), self.l.ns, self.l.recent_id),
                },
                .mapper = undefined,
                .cur_cursor = undefined,
              };
              self.state = .command;
              try self.advance();
            },
            .list_end, .comma => {
              var lvl = &self.levels.items[self.levels.items.len - 1];
              var parent = &self.levels.items[self.levels.items.len - 2];
              std.debug.print("{s}: parent command={s}\n", .{@tagName(self.cur), @tagName(parent.command.info)});
              try parent.command.pushArg(self.int(),
                  try lvl.finalize(self.int()));
              _ = self.levels.pop();
              if (self.cur == .comma) {
                try self.advance();
                self.state = .start;
              } else self.state = .after_list;
            },
            .parsep => {
              try self.levels.items[self.levels.items.len - 1].pushParagraph(self.int(), self.l.newline_count);
              try self.advance();
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
          var non_space_end: data.Cursor = undefined;
          const textual_start = self.cur_start;
          while (true) : (try self.advance()) {
            switch (self.cur) {
              .space =>
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.cur_start.byte_offset)),
              .literal => {
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.cur_start.byte_offset));
                non_space_len = content.items.len;
                non_space_end = self.l.recent_end;
              },
              .ws_break => {
                try content.append(self.int(), '\n');
              },
              .escape => {
                try content.appendSlice(self.int(), self.l.walker.lastUtf8Unit());
                non_space_len = content.items.len;
                non_space_end = self.l.recent_end;
              },
              else => break
            }
          }
          const lvl = &self.levels.items[self.levels.items.len - 1];
          const pos =
            if (self.cur == .block_end_open or self.cur == .block_name_sep or
                self.cur == .comma or self.cur == .name_sep or self.cur == .list_end) blk: {
              content.shrinkAndFree(self.int(), non_space_len);
              break :blk data.Position.inMod(lvl.source_name, textual_start, non_space_end);
            } else self.l.walker.posFrom(textual_start);
          if (content.items.len > 0) {
            if (self.cur == .name_sep) {
              if (lvl.nodes.items.len > 0) {
                unreachable; // TODO: error: equals not allowed here
              }
              self.levels.items[self.levels.items.len - 2].command.pushName(
                  pos, content.items, pos.module.end.byte_offset - pos.module.start.byte_offset == 2, .flow);
              while (true) {
                try self.advance();
                if (self.cur != .space) break;
              }
            } else {
              var node = try self.int().create(data.Node);
              node.* = .{
                .pos = pos,
                .data = .{
                  .literal = .{
                    .kind = if (non_space_len > 0) .text else .space,
                    .content = content.items
                  },
                },
              };
              try lvl.append(self.int(), node);
              self.state = .default;
            }
          } else self.state = .default; // can happen with space at block/arg end
        },
        .command => {
          var lvl = &self.levels.items[self.levels.items.len - 1];
          switch(self.cur) {
            .access => {
              try self.advance();
              if (self.cur != .identifier) unreachable; // TODO: recover
              var node = try self.int().create(data.Node);
              node.* = .{
                .pos = self.l.walker.posFrom(lvl.command.info.unknown.pos.module.start),
                .data = .{
                  .access = .{
                    .subject = lvl.command.info.unknown,
                    .id = self.l.recent_id,
                  },
                },
              };
              lvl.command.info.unknown = node;
              try self.advance();
            },
            .assign => {
              try self.advance();
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
              try self.advance();
            },
            .list_start => {
              const target = lvl.command.info.unknown;
              switch (target.data) {
                .symref, .access => {
                  const res = try self.ctx().resolveChain(target, self.ext());
                  switch (res) {
                    .var_chain => |chain| {
                      unreachable; // TODO
                    },
                    .func_ref => |func| {
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
              try self.advance();
              self.state = .possible_start;
            },
            .blocks_sep => {
              // TODO
              unreachable;
            },
            .closer => {
              try lvl.append(self.int(), lvl.command.info.unknown);
              try self.advance();
              self.state = .default;
            },
            else => {
              try lvl.append(self.int(), lvl.command.info.unknown);
              self.state = .default;
            }
          }
        },
        .after_list => {
          const end = self.l.recent_end;
          try self.advance();
          if (self.cur == .blocks_sep) {
            // call continues
            self.state = .after_blocks_start;
            try self.advance();
          } else {
            self.state = .command;
            try self.levels.items[self.levels.items.len - 1].command.shift(self.int(), self.l.walker.source.name, end);
          }
        },
        .after_blocks_start => {
          const parent = &self.levels.items[self.levels.items.len - 1];

          var primary_config: data.BlockConfig = undefined;

          if (self.cur == .diamond_open) {
            try self.readBlockConfig(&primary_config, self.int());
            parent.command.pushPrimary(self.l.walker.posFrom(self.l.recent_end), true);
          } else {
            // TODO: try and fetch block config from parameter
            unreachable;
          }
          // TODO: apply block config
          while (self.cur == .space) try self.advance();
          if (self.cur == .block_name_sep) {
            self.state = .block_name;
          } else {
            try self.pushLevel();
            self.state = .default;
          }
        },
        .block_name => {
          std.debug.assert(self.cur == .block_name_sep);
          while (true) {
            try self.advance();
            if (self.cur != .space) break;
          }
          const parent = &self.levels.items[self.levels.items.len - 1];
          if (self.cur == .identifier) {
            const name = self.l.walker.contentFrom(self.cur_start.byte_offset);
            const name_pos = self.l.walker.posFrom(self.cur_start);
            var recover = false;
            while (true) {
              try self.advance();
              if (self.cur == .block_name_sep or self.cur == .missing_block_name_sep) break;
              if (self.cur != .space and !recover) {
                self.ctx().eh.expected_token_x_got_y(
                    self.l.walker.posFrom(self.cur_start), .block_name_sep, self.cur);
                recover = true;
              }
            }
            if (self.cur == .missing_block_name_sep) {
              self.ctx().eh.missing_block_name_end(
                data.Position.inMod(self.l.walker.source.name, self.cur_start, self.cur_start));
            }
            try self.advance();
            parent.command.pushName(name_pos, name, false,
                if (self.cur == .diamond_open) .block_with_config else .block_no_config);
            var config: data.BlockConfig = undefined;
            if (self.cur == .diamond_open) {
              try self.readBlockConfig(&config, self.int());
            } else {
              // TODO: try and fetch block config from parameter
              unreachable;
            }
            // TODO: apply block config
          } else {
            self.ctx().eh.expected_token_x_got_y(
                self.l.walker.posFrom(self.cur_start), .identifier, self.cur);
            while (self.cur != .block_name_sep and self.cur != .missing_block_name_sep) {
              try self.advance();
            }
            if (self.cur == .diamond_open) {
              var config: data.BlockConfig = undefined;
              try self.readBlockConfig(&config, self.int());
              // TODO: apply block config
            }
            parent.command.cur_cursor = .failed;
          }
          try self.pushLevel();
          self.state = .start;
        },
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
    while (self.cur != .diamond_close and self.cur != .end_source) {
      while (true) {
        try self.advance();
        if (self.cur != .space) break;
      }
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
          self.ctx().eh.unknown_config_directive(self.l.walker.posFrom(start));
          break :blk .unknown;
        },
      };
      while (true) {
        try self.advance();
        if (self.cur != .space) break;
      }
      var recover = false;
      switch (kind) {
        .csym => {
          if (self.cur == .ns_sym) {
            try mapList.append(alloc, .{
              .pos = self.l.walker.posFrom(start),
              .from = 0, .to = self.l.code_point});
          } else {
            self.ctx().eh.expected_token_x_got_y(
                self.l.walker.posFrom(self.cur_start), .ns_sym, self.cur);
            recover = true;
          }
        },
        .syntax => {
          if (self.cur == .identifier) {
            // TODO
          } else {
            self.ctx().eh.expected_token_x_got_y(
                self.l.walker.posFrom(self.cur_start), .identifier, self.cur);
            recover = true;
          }
        },
        .map => {
          if (self.cur == .ns_sym) {
            const from = self.l.code_point;
            while (true) {
              try self.advance();
              if (self.cur != .space) break;
            }
            if (self.cur == .ns_sym) {
              try mapList.append(alloc, .{
                .pos = self.l.walker.posFrom(start),
                .from = from, .to = self.l.code_point,
              });
            } else recover = true;
          } else recover = true;
          if (recover) {
            self.ctx().eh.expected_token_x_got_y(
                self.l.walker.posFrom(self.cur_start), .ns_sym, self.cur);
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
              self.ctx().eh.expected_token_x_got_y(
                  self.l.walker.posFrom(self.cur_start), .ns_sym, self.cur);
              recover = true;
            }
          }
        },
        .fullast => into.full_ast = self.l.walker.posFrom(self.cur_start),
        .empty => {
          self.ctx().eh.expected_token_x_got_y(
              self.l.walker.posFrom(self.cur_start), .identifier, self.cur);
          recover = true;
        },
        .unknown => {}
      }
      try self.advance();
      while (self.cur != .comma and self.cur != .diamond_close and self.cur != .end_source) {
        if (self.cur != .space and !recover) {
          self.ctx().eh.expected_token_x_got_y(
              self.l.walker.posFrom(self.cur_start), .comma, self.cur);
          recover = true;
        }
        try self.advance();
      }
    }
    if (self.cur == .diamond_close) {
      try self.advance();
    } else {
      self.ctx().eh.expected_token_x_got_y(
          self.l.walker.posFrom(self.cur_start), .diamond_close, self.cur);
    }
    into.map = mapList.items;
  }
};