const std = @import("std");
const data = @import("data");
const lex = @import("lex.zig");
const Source = @import("source.zig").Source;
const Context = @import("interpret.zig").Context;

/// The parser creates AST nodes.
/// Whenever an AST node is created, the parser checks whether it needs to be
/// evaluated immediately, and if so, asks the interpreter to do so, which will
/// yield the replacement for the original node.
pub const Parser = struct {
  /// Contains information about the current command's structure and processes
  /// arguments to that command.
  const Command = struct {
    subject: data.Node,
    info: union(enum) {
      unknown,
      resolved_call: struct {
        /// seen blocks? This determines whether the parser continues filling
        /// this command with arguments when blocks are encountered. If true,
        /// this command will be finalized and become subject of a new call.
        blocks: bool,
        // TODO: argument expressions mapped to subject's parameters
      },
      unresolved_call: struct {
        /// like .resolved_call.blocks.
        blocks: bool,
        // TODO: map of argument name/pos -> expression
      },
      access, // empty; received identifier will immediately be consumed
      assignment: struct {
        // expression
      }
    },
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
    changes: ?[]data.BlockConfig.CharChange,
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

    nodes: std.ArrayListUnmanaged(data.Node),
    parseps: std.ArrayListUnmanaged(struct{before: usize, newlines: usize}),

    fn add(l: *ContentLevel, alloc: *std.mem.Allocator) !*data.Node {
      return l.nodes.addOne(alloc);
    }

    fn finalizeSlice(l: *ContentLevel, start: usize, end: usize) data.Node {
      return switch(end - start) {
        0 => .{
          .pos = data.Position.inMod(l.source_name, l.start, l.start),
          .data = .voidNode,
        },
        1 => l.nodes.items[0],
        else => .{
          .pos = l.nodes.items[start].pos.span(l.nodes.items[end - 1].pos),
          .data = .{
            .concatenation = .{
              .content = l.nodes.items[start..end],
            },
          },
        }
      };
    }

    fn finalize(l: *ContentLevel, target: *data.Node, alloc: *std.mem.Allocator) !void {
      if (l.parseps.items.len == 0) {
        target.* = l.finalizeSlice(0, l.nodes.items.len);
      } else {
        target.* = .{
          .pos = l.nodes.items[0].pos.span(l.nodes.items[l.nodes.items.len - 1].pos),
          .data = .{
            .paragraphs = .{
              .content = try alloc.alloc(data.Node, l.parseps.items.len + 1),
              .separators = try alloc.alloc(usize, l.parseps.items.len),
            },
          },
        };
        var curStart: usize = 0;
        for (l.parseps.items) |parsep, i| {
          target.data.paragraphs.content[i] = l.finalizeSlice(curStart, parsep.before);
          target.data.paragraphs.separators[i] = parsep.newlines;
          curStart = parsep.before;
        }
        target.data.paragraphs.content[l.parseps.items.len] = l.finalizeSlice(curStart, l.nodes.items.len);
      }
    }
  };

  /// States of the parser.
  const State = enum {
    /// skips over any space it finds, then transitions to default.
    start,
    /// reading content of a block or list argument. Allows inner blocks,
    /// swallowing and paragraph separators besides inner nodes that get pushed
    /// to the current level. Will ditch trailing space. Lexer will not produce
    /// structures that are not allowed (i.e. swallowing or blocks start inside
    /// list argument, or consecutive parseps).
    default,
    /// Used to merge literals space, ws_break and escape together.
    textual,
    /// used after any command. The current level's .command field will be
    /// .unknown and hold the occurred command in .subject.
    /// When encountering command continuation (e.g. opening list or blocks),
    /// set the .level.command's kind appropriately and open a new level.
    /// When encountering content, will push .level.command.subject into .level
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
    /// This state processes block config.
    config,
  };

  /// stack of current levels. must have at least size of 1, with the first
  /// level being the current source's root.
  levels: std.ArrayListUnmanaged(ContentLevel),
  /// currently parsed block config. Filled in the .config state.
  config: ?data.BlockConfig,

  l: lex.Lexer,
  state: State,
  cur: lex.Token,
  curStart: data.Cursor,

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
      .state = .default,
      .cur = undefined,
      .curStart = undefined,
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

  pub fn parseSource(self: *Parser, source: *Source, context: *Context) !data.Node {
    self.l = try lex.Lexer.init(context, source);
    try self.levels.append(self.int(), ContentLevel{
      .source_name = undefined,
      .start = undefined,
      .changes = null,
      .ignored_changes = null,
      .command = Command{
        .subject = undefined,
        .info = .unknown,
      },
      .nodes = .{},
      .parseps = .{},
    });
    self.levels.items[0].start = self.l.recent_end;
    self.levels.items[0].source_name = source.name;
    try self.advance();
    return self.doParse();
  }

  pub fn resumeParse(self: *Parser) !data.Node {
    return self.doParse();
  }

  inline fn advance(self: *Parser) !void {
    self.curStart = self.l.recent_end;
    // TODO: recover from unicode errors?
    self.cur = try self.l.next();
  }

  fn doParse(self: *Parser) !data.Node {
    while (true) {
      switch (self.state) {
        .start => {
          while (self.cur == .space) try self.advance();
          self.state = .default;
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
                var target = try self.levels.items[self.levels.items.len - 1].add(self.int());
                try lvl.finalize(target, self.int());
                _ = self.levels.pop();
              }
              var ret: data.Node = undefined;
              try self.levels.items[0].finalize(&ret, self.int());
              return ret;
            },
            .symref => {

            },
            else => unreachable,
          }
        },
        .textual => {
          var content: std.ArrayListUnmanaged(u8) = .{};
          var non_space_len: usize = 0;
          while (true) : (try self.advance()) {
            switch (self.cur) {
              .space =>
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.curStart.byte_offset)),
              .literal => {
                try content.appendSlice(self.int(),
                    self.l.walker.contentFrom(self.curStart.byte_offset));
                non_space_len = content.items.len;
              },
              .ws_break => {
                try content.append(self.int(), '\n');
              },
              .escape => {
                try content.appendSlice(self.int(), self.l.walker.lastUtf8Unit());
                non_space_len = content.items.len;
              },
              else => break
            }
          }
          content.shrinkAndFree(self.int(),
              if (self.cur == .block_end_open or self.cur == .block_name_sep or
                self.cur == .comma or self.cur == .list_end)
                non_space_len
              else content.items.len);
          if (content.items.len > 0) {
            var node = try self.levels.items[self.levels.items.len - 1].add(self.int());
            node.* = .{
              .pos = self.l.walker.posFrom(self.curStart),
              .data = .{
                .literal = .{
                  .kind = if (non_space_len > 0) .text else .space,
                  .content = content.items
                },
              },
            };
          }
          self.state = .default;
        },
        .command => {
          // TODO
          unreachable;
        },
        .after_blocks_start => {
          // TODO
          unreachable;
        },
        .config => {
          // TODO
          unreachable;
        }
      }
    }
  }
};