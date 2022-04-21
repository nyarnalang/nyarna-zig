const std = @import("std");
const builtin = @import("builtin");
const nyarna = @import("nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const Interpreter = @import("interpret.zig").Interpreter;

const lex = @import("parse/lex.zig");
const mapper = @import("parse/mapper.zig");
const unicode = @import("unicode.zig");
const syntaxes = @import("parse/syntaxes.zig");
const chains = @import("interpret/chains.zig");

const last = @import("helpers.zig").last;

pub const LiteralNumber = @import("parse/numbers.zig").LiteralNumber;

/// The parser can return one of these if outside action is required before
/// resuming parsing.
pub const UnwindReason = error {
  /// emitted when an \import is encountered, but the referred module has not
  /// been processed far enough.
  ///
  /// if arguments are given to the import, the referred module needs only to
  /// be processed up until its parameter declaration.
  ///
  /// if arguments have been processed or none have been given, the referred
  /// module needs tob e fully loaded.
  referred_module_unavailable,
  /// emitted when a module's parameter declaration has been encountered. Caller
  /// may inspect declared parameters, push available arguments, then resume
  /// parsing.
  ///
  /// Caller is not required to check whether all parameters get an argument or
  /// whether pushed arguments can be bound. This will be checked and handled by
  /// the parser, errors will be logged.
  encountered_parameters,
};

pub const Error = nyarna.Error || UnwindReason;

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

  fn pushName(
    self: *Command,
    pos: model.Position,
    name: []const u8,
    direct: bool,
    flag: mapper.Mapper.ProtoArgFlag,
  ) !void {
    self.cur_cursor = if (
      try self.mapper.map(
        pos, if (direct) .{.direct = name} else .{.named = name}, flag)
    ) |mapped| .{
      .mapped = mapped,
    } else .failed;
  }

  fn pushArg(self: *Command, arg: *model.Node) !void {
    defer self.cur_cursor = .not_pushed;
    const cursor = switch (self.cur_cursor) {
      .mapped => |val| val,
      .failed => return,
      .not_pushed =>
        (try self.mapper.map(arg.pos, .position, .flow)) orelse return,
    };
    try self.mapper.push(cursor, arg);
  }

  fn pushPrimary(self: *Command, pos: model.Position, config: bool) !void {
    self.cur_cursor = if (
      try self.mapper.map(pos, .primary,
        if (config) .block_with_config else .block_no_config
    )) |cursor| .{
      .mapped = cursor,
    } else .failed;
  }

  fn shift(
    self: *Command,
    intpr: *Interpreter,
    end: model.Cursor,
    fullast: bool,
  ) !void {
    const newNode =
      try self.mapper.finalize(intpr.input.between(self.start, end));
    switch (newNode.data) {
      .resolved_call => |*rcall| {
        if (rcall.sig.isKeyword()) {
          if (fullast) {
            switch (rcall.target.data) {
              .resolved_symref => |*rsym| {
                if (std.mem.eql(u8, "import", rsym.sym.name)) {
                  intpr.ctx.logger.ImportIllegalInFullast(newNode.pos);
                  newNode.data = .poison;
                }
              },
              else => {}
            }
          } else {
            // try to immediately call keywords.
            if (try intpr.tryInterpret(
                newNode, .{.kind = .intermediate})) |expr| {
              newNode.data = .{.expression = expr};
            }
          }
        }
      },
      else => {},
    }
    self.info = .{.unknown = newNode};
  }

  fn startAssignment(self: *Command, intpr: *Interpreter) void {
    const subject = self.info.unknown;
    self.info = .{.assignment = mapper.AssignmentMapper.init(subject, intpr)};
    self.mapper = &self.info.assignment.mapper;
    self.cur_cursor = .not_pushed;
  }

  fn startResolvedCall(
    self: *Command,
    intpr: *Interpreter,
    target: *model.Node,
    ns: u15,
    sig: *const model.Signature,
  ) !void {
    self.info = .{.resolved_call =
      try mapper.SignatureMapper.init(intpr, target, ns, sig),
    };
    self.mapper = &self.info.resolved_call.mapper;
    self.cur_cursor = .not_pushed;
  }

  fn startUnresolvedCall(self: *Command, intpr: *Interpreter) !void {
    const subject = self.info.unknown;
    self.info = .{
      .unresolved_call = mapper.CollectingMapper.init(subject, intpr),
    };
    self.mapper = &self.info.unresolved_call.mapper;
    self.cur_cursor = .not_pushed;
  }

  fn choseAstNodeParam(self: *Command) bool {
    return switch (self.cur_cursor) {
      .mapped => |cursor|
        if (self.mapper.paramType(cursor)) |t| (
          t.isNamed(.ast) or t.isNamed(.frame_root)
        ) else false,
      else => false,
    };
  }
};

/// This is either the root level of the current file,
/// a block argument or a list argument.
/// The content level takes care of generating concatenations and sequences.
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
  /// list of nodes in the current paragraph parsed at this content level.
  nodes: std.ArrayListUnmanaged(*model.Node),
  /// finished sequence items at this content level.
  seq: std.ArrayListUnmanaged(model.Node.Seq.Item),
  /// block configuration of this level. only applicable to block arguments.
  block_config: ?*const model.BlockConfig,
  /// syntax that parses this level. only applicable to block arguments.
  syntax_proc: ?*syntaxes.SpecialSyntax.Processor = null,
  /// recently parsed whitespace. might be either added to nodes to discarded
  /// depending on the following item.
  dangling_space: ?*model.Node = null,
  /// number of variables existing in intpr.variables when this level has
  /// been started.
  variable_start: usize,

  fn append(
    self: *ContentLevel,
    intpr: *Interpreter,
    item: *model.Node,
  ) !void {
    if (self.syntax_proc) |proc| {
      const res = try proc.push(proc, item.pos, .{.node = item});
      std.debug.assert(res == .none);
    } else {
      if (self.dangling_space) |space_node| {
        try self.nodes.append(intpr.allocator, space_node);
        self.dangling_space = null;
      }
      const res = if (self.fullast) item else switch (item.data) {
        .literal, .unresolved_call, .unresolved_symref, .expression, .void =>
          item,
        else =>
          if (try intpr.tryInterpret(item, .{.kind = .intermediate})) |expr|
            try intpr.node_gen.expression(expr) else item,
      };
      switch (res.data) {
        .void => return,
        .expression => |expr| if (expr.data == .void) return,
        else => {}
      }
      try self.nodes.append(intpr.allocator, res);
    }
  }

  fn finalizeParagraph(
    self: *ContentLevel,
    intpr: *Interpreter,
  ) !?*model.Node {
    return switch (self.nodes.items.len) {
      0 => null,
      1 => blk: {
        const node = self.nodes.items[0];
        break :blk switch (node.data) {
          .void => null,
          .expression => |expr| if (expr.data == .void) null else node,
          else => node,
        };
      },
      else => (try intpr.node_gen.concat(
        self.nodes.items[0].pos.span(last(self.nodes.items).*.pos),
        .{.items = self.nodes.items})).node(),
    };
  }

  fn implicitBlockConfig(self: *ContentLevel) ?*model.BlockConfig {
    return switch (self.command.cur_cursor) {
      .mapped => |c| self.command.mapper.config(c),
      else => null,
    };
  }

  fn finalize(self: *ContentLevel, p: *Parser) !*model.Node {
    if (self.block_config) |c| try p.revertBlockConfig(c);
    const ip = p.intpr();
    while (ip.variables.items.len > self.variable_start) {
      const av = ip.variables.pop();
      const ns = ip.namespace(av.ns);
      ns.data.shrinkRetainingCapacity(ns.data.count() - 1);
    }

    const alloc = p.allocator();
    if (self.syntax_proc) |proc| {
      return try proc.finish(
        proc, ip.input.between(self.start, p.cur_start));
    } else if (self.seq.items.len == 0) {
      return (try self.finalizeParagraph(p.intpr())) orelse
        try ip.node_gen.void(p.intpr().input.at(self.start));
    } else {
      if (self.nodes.items.len > 0) {
        if (try self.finalizeParagraph(p.intpr())) |content| {
          try self.seq.append(alloc, .{
            .content = content,
            .lf_after = 0,
          });
        }
      }
      return (try ip.node_gen.seq(
        self.seq.items[0].content.pos.span(
          last(self.seq.items).content.pos),
        .{.items = self.seq.items})).node();
    }
  }

  fn pushParagraph(
    self: *ContentLevel,
    intpr: *Interpreter,
    lf_after: usize,
  ) !void {
    if (self.nodes.items.len > 0) {
      if (try self.finalizeParagraph(intpr)) |content| {
        try self.seq.append(intpr.allocator, .{
          .content = content,
          .lf_after = lf_after
        });
      }
      self.nodes = .{};
    }
  }
};

/// parses block configuration inside `:<…>`.
/// aborts on first syntax error so that syntax errors such as missing `>`
/// do not lead to large parts of the input being parsed as block config.
const BlockConfigParser = struct {
  into: *model.BlockConfig,
  map_list: std.ArrayList(model.BlockConfig.Map),
  parser: *Parser,
  cur_item_start: model.Cursor,

  fn init(
    into: *model.BlockConfig,
    allocator: std.mem.Allocator,
    parser: *Parser,
  ) BlockConfigParser {
    return .{
      .into = into,
      .map_list = std.ArrayList(model.BlockConfig.Map).init(allocator),
      .parser = parser,
      .cur_item_start = undefined,
    };
  }

  const ConfigItemKind = enum {
    csym, empty, fullast, map, off,syntax, unknown,
  };

  inline fn getItemKind(self: *BlockConfigParser, first: bool) ?ConfigItemKind {
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

  inline fn procCsym(self: *BlockConfigParser) !bool {
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

  inline fn procSyntax(self: *BlockConfigParser) bool {
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

  inline fn procMap(self: *BlockConfigParser) !bool {
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

  inline fn procOff(self: *BlockConfigParser) !ResultAction {
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

  fn parse(self: *BlockConfigParser) !void {
    std.debug.assert(self.parser.cur == .diamond_open);
    self.into.* = .{
      .syntax = null,
      .off_colon = null,
      .off_comment = null,
      .full_ast = null,
      .map = undefined,
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
          .csym => if (!(try self.procCsym())) {recover = true;},
          .syntax => if (!self.procSyntax()) {recover = true;},
          .map => if (!(try self.procMap())) {recover = true;},
          .off => switch (try self.procOff()) {
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
};

/// The parser creates AST nodes.
/// Whenever an AST node is created, the parser checks whether it needs to be
/// evaluated immediately, and if so, asks the interpreter to do so, which will
/// yield the replacement for the original node.
pub const Parser = struct {
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

  lexer: lex.Lexer,
  state: State,
  cur: model.Token,
  cur_start: model.Cursor,

  pub fn init() Parser {
    return Parser{
      .config = null,
      .levels = .{},
      .ns_mapping_stack = .{},
      .lexer = undefined,
      .state = .start,
      .cur = undefined,
      .cur_start = undefined,
    };
  }

  inline fn allocator(self: *Parser) std.mem.Allocator {
    return self.intpr().allocator;
  }

  inline fn intpr(self: *Parser) *Interpreter {
    return self.lexer.intpr;
  }

  inline fn logger(self: *Parser) *errors.Handler {
    return self.intpr().ctx.logger;
  }

  pub fn parseFile(
    self: *Parser,
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

  fn pushLevel(self: *Parser, fullast: bool) !void {
    if (self.levels.items.len > 0) {
      std.debug.assert(self.curLevel().command.info != .unknown);
    }
    try self.levels.append(self.allocator(), ContentLevel{
      .start = self.lexer.recent_end,
      .changes = null,
      .command = undefined,
      .nodes = .{},
      .seq = .{},
      .block_config = null,
      .fullast = fullast,
      .variable_start = self.intpr().variables.items.len,
    });
  }

  /// parse context.input. If it returns .referred_source_unavailable, parsing
  /// may be resumed via resumeParse() after the referred source has been
  /// loaded. Other returned errors are not recoverable.
  ///
  /// Errors in the given input are not returned as errors of this function.
  /// Instead, they are handed to the loader's errors.Handler. To check whether
  /// errors have occurred, check for increase of the handler's error_count.
  pub fn parseSource(
    self: *Parser,
    context: *Interpreter,
    fullast: bool,
  ) Error!*model.Node {
    self.lexer = try lex.Lexer.init(context);
    self.advance();
    return self.doParse(fullast);
  }

  /// continue parsing. Precondition: parseSource() or resumeParse() have
  /// returned with an UnwindReason previously on the given parser, and have
  /// never returned a *model.Node.
  ///
  /// Apart from the precondition, this function has the same semantics as
  /// parseSource(), including that it may return .referred_source_unavailable.
  pub fn resumeParse(self: *Parser) Error!*model.Node {
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

  fn leaveLevel(self: *Parser) !void {
    var lvl = self.curLevel();
    const parent = &self.levels.items[self.levels.items.len - 2];
    const lvl_node = try lvl.finalize(self);
    try parent.command.pushArg(lvl_node);
    _ = self.levels.pop();
  }

  inline fn curLevel(self: *Parser) *ContentLevel {
    return last(self.levels.items);
  }

  inline fn procStart(self: *Parser, implicit_fullast: bool) !void {
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

  inline fn procPossibleStart(self: *Parser) !void {
    while (self.cur == .space) self.advance();
    if (self.cur == .list_end) {
      self.state = .after_list;
    } else {
      try self.pushLevel(self.curLevel().fullast);
      self.state = .default;
    }
  }

  inline fn procEndSource(self: *Parser) !void {
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
          self.intpr().ctx.logger.MissingEndCommand(
            name, parent.command.mapper.subject_pos,
            self.lexer.walker.posFrom(self.cur_start));
        }
      }
      try parent.command.shift(
        self.intpr(), self.cur_start, parent.fullast);
      try parent.append(self.intpr(), parent.command.info.unknown);
    }
  }

  inline fn procSymref(self: *Parser) !void {
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

  inline fn procLeaveArg(self: *Parser) !void {
    try self.leaveLevel();
    if (self.cur == .comma) {
      self.advance();
      self.state = .start;
    } else self.state = .after_list;
  }

  inline fn procParagraphEnd(self: *Parser) !void {
    const newline_count = self.lexer.newline_count;
    self.advance();
    if (self.cur != .block_end_open and self.cur != .end_source) {
      try self.curLevel().pushParagraph(self.intpr(), newline_count);
    }
  }

  inline fn procBlockNameStart(self: *Parser) !void {
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
        self.advance();
        var colon_start: ?model.Position = null;
        var buffer: model.BlockConfig = undefined;
        const check_swallow = if (self.cur == .diamond_open) blk: {
          try BlockConfigParser.init(
            &buffer, self.allocator(), self).parse();
          if (self.cur == .blocks_sep) {
            colon_start = self.lexer.walker.posFrom(self.cur_start);
            self.advance();
            break :blk true;
          } else break :blk false;
        } else true;
        if (check_swallow) _ = self.checkSwallow(colon_start);
        self.logger().BlockNameAtTopLevel(self.lexer.walker.posFrom(start));
      } else self.advance();
    } else {
      try self.leaveLevel();
      self.state = .block_name;
    }
  }

  inline fn procEndCommand(self: *Parser) !void {
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
          self.intpr().input.at(cmd_start));
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
          self.intpr().input.at(cmd_start));
        const num_skipped = model.Token.numSkippedEnds(self.cur);
        var i: u32 = 0; while (i < num_skipped) : (i += 1) {
          try self.leaveLevel();
          const lvl = self.curLevel();
          try lvl.command.shift(self.intpr(), self.cur_start, lvl.fullast);
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
      self.logger().MissingClosingParenthesis(
        self.intpr().input.at(self.cur_start));
    }
    if (do_shift) {
      self.state = .command;
      try self.curLevel().command.shift(
        self.intpr(), self.cur_start, self.curLevel().fullast);
    }
  }

  inline fn procIllegalNameSep(self: *Parser) void {
    self.logger().IllegalNameSep(self.lexer.walker.posFrom(self.cur_start));
    self.advance();
  }

  inline fn procIdSet(self: *Parser) void {
    self.state = .before_id;
    self.advance();
  }

  inline fn procTextual(self: *Parser) !void {
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
        break :blk self.intpr().input.between(textual_start, non_space_end);
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
        else lvl.dangling_space = node;
        self.state = .default;
      }
    } else self.state = .default; // happens with space at block/arg end
  }

  inline fn procCommand(self: *Parser) !void {
    var lvl = self.curLevel();
    switch (lvl.command.info.unknown.data) {
      .import => |*import| {
        if (self.cur != .list_start and self.cur != .blocks_sep) {
          // import that isn't called. must load.
          const me = &self.intpr().ctx.data.known_modules.values()[
            import.module_index];
          switch (me.*) {
            .require_params => |ml| {
              me.* = .{.require_module = ml};
              return UnwindReason.referred_module_unavailable;
            },
            .require_module => {
              // if another module set require_module already, it had taken
              // priority over the current module and therefore would have
              // already been loaded.
              unreachable;
            },
            .loaded => |module| {
              try self.intpr().importModuleSyms(module, import.ns_index);
              import.node().data = .{.expression = module.root};
            },
          }
        }
      },
      else => {}
    }
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
          self.intpr().ctx.logger.MissingSymbolName(
            self.intpr().input.at(self.cur_start));
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
              .source = self.lexer.walker.source.meta,
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
          .import => unreachable, // TODO
          else => {},
        }
        const ctx = try chains.CallContext.fromChain(
          self.intpr(), target, try chains.Resolver.init(
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
          .unknown => try lvl.command.startUnresolvedCall(self.intpr()),
          .poison => {
            target.data = .poison;
            try lvl.command.startUnresolvedCall(self.intpr());
          }
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

  inline fn procAfterList(self: *Parser) !void {
    const end = self.lexer.recent_end;
    self.advance();
    if (self.cur == .blocks_sep) {
      // call continues
      self.state = .after_blocks_start;
      self.advance();
    } else {
      self.state = .command;
      try self.curLevel().command.shift(
        self.intpr(), end, self.curLevel().fullast);
    }
  }

  inline fn procAfterBlocksStart(self: *Parser) !void {
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
          try self.pushLevel(
            if (lvl.command.choseAstNodeParam()) false else lvl.fullast);
        }
        self.state =
          if (self.curLevel().syntax_proc != null) .special else .default;
      }
    }
  }

  inline fn procBlockName(self: *Parser) !void {
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
        self.logger().MissingBlockNameEnd(
          self.intpr().input.at(self.cur_start));
      }
      try parent.command.pushName(name_pos, name, false,
        if (self.cur == .diamond_open) .block_with_config else .block_no_config
      );
    } else {
      self.logger().ExpectedXGotY(self.intpr().input.at(self.cur_start),
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
        try self.applyBlockConfig(self.intpr().input.at(self.cur_start), c);
      }
      while (self.cur == .space or self.cur == .indent) self.advance();
    }
    self.state = if (
      self.curLevel().syntax_proc != null
    ) .special else .default;
  }

  inline fn procBeforeId(self: *Parser) !void {
    while (self.cur == .space) self.advance();
    if (self.cur == .call_id) {
      self.advance();
    } else {
      self.logger().MissingId(
        self.lexer.walker.posFrom(self.cur_start).before());
    }
    self.state = .after_id;
  }

  inline fn procAfterId(self: *Parser) !void {
    while (self.cur == .space) self.advance();
    switch (self.cur) {
      .comma => {
        self.state = .start;
        self.advance();
        _ = self.levels.pop();
      },
      .list_end => {
        self.state = .after_list;
        self.advance();
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

  inline fn procSpecial(self: *Parser) !void {
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
          .end_source, .block_name_sep, .block_end_open => {
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
      .end_source, .symref, .block_name_sep, .block_end_open => {
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
        const check_swallow: ?model.Position =
          if (self.cur == .diamond_open) blk: {
            bh.config = @as(model.BlockConfig, undefined);
            try BlockConfigParser.init(
              &bh.config.?, self.intpr().ctx.global(), self).parse();
            if (self.cur == .blocks_sep) {
              defer self.advance();
              break :blk self.lexer.walker.posFrom(self.cur_start);
            } else break :blk null;
          } else self.lexer.walker.source.between(start, self.cur_start);
        if (check_swallow) |colon_pos| {
          bh.swallow_depth = self.checkSwallow(colon_pos);
        }

        value.origin = self.intpr().input.between(start, self.cur_start);
        _ = try proc.push(proc, value.origin, .{.block_header = bh});
      }
    }
  }

  fn doParse(self: *Parser, implicit_fullast: bool) Error!*model.Node {
    while (true) {
      switch (self.state) {
        .start => try self.procStart(implicit_fullast),
        .possible_start => try self.procPossibleStart(),
        .default => switch (self.cur) {
          .indent => self.advance(),
          .space, .escape, .literal, .ws_break => self.state = .textual,
          .end_source => {
            try self.procEndSource();
            return self.levels.items[0].finalize(self);
          },
          .symref => try self.procSymref(),
          .list_end, .comma => try self.procLeaveArg(),
          .parsep => try self.procParagraphEnd(),
          .block_name_sep => try self.procBlockNameStart(),
          .block_end_open => try self.procEndCommand(),
          .name_sep => self.procIllegalNameSep(),
          .id_set => self.procIdSet(),
          else => std.debug.panic(
            "unexpected token in default: {s} at {}\n",
            .{@tagName(self.cur), self.cur_start.formatter()}),
        },
        .textual => try self.procTextual(),
        .command => try self.procCommand(),
        .after_list => try self.procAfterList(),
        .after_blocks_start => try self.procAfterBlocksStart(),
        .block_name => try self.procBlockName(),
        .before_id => try self.procBeforeId(),
        .after_id => try self.procAfterId(),
        .special => try self.procSpecial(),
      }
    }
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
    // on named blocks, the new level has already been pushed
    const parent = &self.levels.items[
      self.levels.items.len - if (pb_exists == null) @as(usize, 2) else 1];
    // position of the colon *after* a block header, for additional swallow
    var colon_start: ?model.Position = null;
    const check_swallow = if (self.cur == .diamond_open) blk: {
      const config = try self.allocator().create(model.BlockConfig);
      try BlockConfigParser.init(config, self.allocator(), self).parse();
      const pos = self.intpr().input.at(self.cur_start);
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
    if (check_swallow) {
      if (self.checkSwallow(colon_start)) |swallow_depth| {
        if (pb_exists) |ind| {
          if (ind.* == .unknown) {
            try parent.command.pushPrimary(
              self.intpr().input.at(self.cur_start), false);
            try self.pushLevel(if (parent.command.choseAstNodeParam()) false
                               else parent.fullast);
            if (parent.implicitBlockConfig()) |c| {
              try self.applyBlockConfig(
                self.intpr().input.at(self.cur_start), c);
            }
          }
          ind.* = .yes;
        }
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
                last(parent.seq.items).content.pos.end
              else last(parent.nodes.items).*.pos.end;

            var i = self.levels.items.len - 2;
            while (i > target_level) : (i -= 1) {
              const cur_parent = &self.levels.items[i - 1];
              try cur_parent.command.pushArg(
                try self.levels.items[i].finalize(self));
              try cur_parent.command.shift(
                self.intpr(), end_cursor, cur_parent.fullast);
              try cur_parent.append(
                self.intpr(), cur_parent.command.info.unknown);
            }
            // target_level's command has now been closed. therefore it is safe
            // to assign it to the previous parent's command
            // (which has not been touched).
            const tl = &self.levels.items[target_level];
            tl.command = parent.command;
            tl.command.mapper = switch (tl.command.info) {
              .resolved_call => |*sm| &sm.mapper,
              .unresolved_call => |*uc| &uc.mapper,
              .assignment => |*as| &as.mapper,
              .unknown => unreachable,
            };
            // finally, shift the new level on top of the target_level
            self.levels.items[target_level + 1] = last(self.levels.items).*;
            const ll = &self.levels.items[target_level + 1];
            ll.command.mapper = switch (ll.command.info) {
              .resolved_call => |*sm| &sm.mapper,
              .unresolved_call => |*uc| &uc.mapper,
              .assignment => |*as| &as.mapper,
              .unknown => unreachable,
            };
            try self.levels.resize(self.allocator(), target_level + 2);
          }
        }

        while (self.cur == .space or self.cur == .indent or
               self.cur == .ws_break) self.advance();
        return true;
      } else if (pb_exists) |ind| {
        if (ind.* == .unknown) {
          try parent.command.pushPrimary(
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

  /// if colon_pos is given, assumes that swallowing *must* occur and issues an
  /// error using the colon_pos if non occurs.
  fn checkSwallow(self: *Parser, colon_pos: ?model.Position) ?u21 {
    switch (self.cur) {
      .swallow_depth => {
        const swallow_depth = self.lexer.code_point;
        const start = self.cur_start;
        self.advance();
        if (self.cur == .diamond_close) {
          self.advance();
        } else {
          self.logger().SwallowDepthWithoutDiamondClose(
            self.lexer.walker.source.between(start, self.cur_start));
          return null;
        }
        return swallow_depth;
      },
      .diamond_close => {
        self.advance();
        return 0;
      },
      else => {
        if (colon_pos) |pos| {
          self.intpr().ctx.logger.IllegalColon(pos);
        }
        return null;
      }
    }
  }

  fn applyBlockConfig(
    self: *Parser,
    pos: model.Position,
    config: *const model.BlockConfig,
  ) !void {
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
    // the lexer. full_ast is automatically reversed by leaving the level.
  }
};