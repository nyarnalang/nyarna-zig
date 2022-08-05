//! This is one of the following:
//!  * the root level of the current file
//!  * a block argument
//!  * a list argument.
//! The content level takes care of generating concatenations and sequences.

const std = @import("std");

const EncodedCharacter = @import("../unicode.zig").EncodedCharacter;
const Impl             = @import("Impl.zig");
const Mapper           = @import("Mapper.zig");
const nyarna           = @import("../../nyarna.zig");
const syntaxes         = @import("syntaxes.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

const last = @import("../helpers.zig").last;

const ContentLevel = @This();

/// Contains information about the current command's structure and processes
/// arguments to that command.
const Command = struct {
  start: model.Cursor,
  info: union(enum) {
    /// This state means that the command has just been created and awaits
    /// classification via the next lexer token.
    unknown        : *model.Node,
    resolved_call  : Mapper.ToSignature,
    unresolved_call: Mapper.Collect,
    import_call    : Mapper.ToImport,
    assignment     : Mapper.ToAssignment,
  },
  mapper: *Mapper,
  cur_cursor: union(enum) {
    mapped: Mapper.Cursor,
    failed,
    not_pushed
  },
  /// if set, this command is currently swallowing at the given depth and will
  /// end implicitly at the encounter of another command that has a lesser or
  /// equal swallow depth – excluding swallow depth 0, which will only end
  /// when a parent scope ends.
  swallow_depth: ?u21 = null,

  pub fn pushName(
    self  : *Command,
    pos   : model.Position,
    name  : []const u8,
    direct: bool,
    flag  : Mapper.ProtoArgFlag,
  ) !void {
    self.cur_cursor = if (
      try self.mapper.map(
        pos, if (direct) .{.direct = name} else .{.named = name}, flag)
    ) |mapped| .{
      .mapped = mapped,
    } else .failed;
  }

  pub fn pushNameExpr(
    self       : *Command,
    node       : *model.Node,
    with_config: bool,
  ) !void {
    self.cur_cursor = if (
      try self.mapper.map(
        node.pos, .{.name_expr = node},
        if (with_config) .block_with_config else .block_no_config)
    ) |mapped| .{
      .mapped = mapped,
    } else .failed;
  }

  pub fn pushArg(self: *Command, arg: *model.Node) !void {
    defer self.cur_cursor = .not_pushed;
    const cursor = switch (self.cur_cursor) {
      .mapped => |val| val,
      .failed => return,
      .not_pushed =>
        (try self.mapper.map(arg.pos, .position, .flow)) orelse return,
    };
    try self.mapper.push(cursor, arg);
  }

  pub fn pushPrimary(self: *Command, pos: model.Position, config: bool) !void {
    self.cur_cursor = if (
      try self.mapper.map(pos, .primary,
        if (config) .block_with_config else .block_no_config
    )) |cursor| .{
      .mapped = cursor,
    } else .failed;
  }

  /// returns the swallow depth if implicit swallowing occurs.
  pub fn checkAutoSwallow(self: *Command) ?u21 {
    switch (self.info) {
      .resolved_call => |*tosig| if (tosig.signature.auto_swallow) |as| {
        if (!tosig.filled[as.param_index]) {
          self.swallow_depth = as.depth;
          self.cur_cursor = .{.mapped = .{
            .param  = .{.index = as.param_index},
            .config = false,
            .direct = false,
          }};
          return as.depth;
        }
      },
      else => {}
    }
    return null;
  }

  pub fn shift(
    self   : *Command,
    intpr  : *Interpreter,
    source : *const model.Source,
    end    : model.Cursor,
    fullast: bool,
  ) !void {
    const newNode =
      try self.mapper.finalize(source.between(self.start, end));
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

  pub fn startAssignment(self: *Command, intpr: *Interpreter) void {
    const subject = self.info.unknown;
    self.info = .{.assignment = Mapper.ToAssignment.init(subject, intpr)};
    self.mapper = &self.info.assignment.mapper;
    self.cur_cursor = .not_pushed;
  }

  pub fn startResolvedCall(
    self  : *Command,
    intpr : *Interpreter,
    target: *model.Node,
    ns    : u15,
    sig   : *const model.Signature,
  ) !void {
    self.info = .{.resolved_call =
      try Mapper.ToSignature.init(intpr, target, ns, sig),
    };
    self.mapper = &self.info.resolved_call.mapper;
    self.cur_cursor = .not_pushed;
  }

  pub fn startUnresolvedCall(self: *Command, intpr: *Interpreter) !void {
    const subject = self.info.unknown;
    self.info = .{
      .unresolved_call = Mapper.Collect.init(subject, intpr),
    };
    self.mapper = &self.info.unresolved_call.mapper;
    self.cur_cursor = .not_pushed;
  }

  pub fn startImportCall(
    self  : *Command,
    intpr : *Interpreter,
    target: *model.Node.Import,
  ) !void {
    self.info = .{.import_call = Mapper.ToImport.init(target, intpr)};
    self.mapper = &self.info.import_call.mapper;
    self.cur_cursor = .not_pushed;
  }

  pub fn choseAstNodeParam(self: *Command) bool {
    return switch (self.cur_cursor) {
      .mapped => |cursor|
        if (self.mapper.paramType(cursor)) |t| (
          t.isNamed(.ast) or t.isNamed(.frame_root)
        ) else false,
      else => false,
    };
  }
};

/// used for generating void nodes.
start: model.Cursor,
/// Changes to command characters that occurred upon entering this level.
/// For implicit block configs, this links to the block config definition.
changes: ?[]model.BlockConfig.Map = null,
/// the currently open command on this content level. info === unknown if no
/// command is open or only the subject has been read.
/// every ContentLevel but the innermost one must have an open command.
command: Command,
/// whether this level has fullast semantics.
fullast: bool,
/// list of nodes in the current paragraph parsed at this content level.
nodes: std.ArrayListUnmanaged(*model.Node) = .{},
/// finished sequence items at this content level.
seq: std.ArrayListUnmanaged(model.Node.Seq.Item) = .{},
/// block configuration of this level. only applicable to block arguments.
block_config: ?*const model.BlockConfig = null,
/// capture variables of this block.
capture: []model.Value.Ast.VarDef,
/// syntax that parses this level. only applicable to block arguments.
syntax_proc: ?*syntaxes.SpecialSyntax.Processor = null,
/// recently parsed whitespace. might be either added to nodes to discarded
/// depending on the following item.
dangling: union(enum) {
  space: *model.Node,
  parsep: usize,
  none,
} = .none,
/// number of symbols existing in intpr.symbols when this level has been started
sym_start: usize,
semantics: enum{
  /// this level is for default content
  default,
  /// this level contains a block name expression
  block_name,
  /// this level contains a block name, but it's at top level and doesn't map
  /// to a call so it must be discarded.
  discarded_block_name,
} = .default,

pub fn append(
  self : *ContentLevel,
  intpr: *Interpreter,
  item : *model.Node,
) !void {
  if (self.syntax_proc) |proc| {
    const res = try proc.push(proc, item.pos, .{.node = item});
    std.debug.assert(res == .none);
  } else {
    switch (self.dangling) {
      .space  => |node|     try self.nodes.append(intpr.allocator(), node),
      .parsep => |newlines| try self.pushParagraph(intpr, newlines),
      .none   => {},
    }
    self.dangling = .none;
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
    try self.nodes.append(intpr.allocator(), res);
  }
}

/// finalizes current paragraph into node. normally part of finalize() but can
/// be called externally in scenarios without parser (i.e. when building the
/// backend in SchemaBuilder).
pub fn finalizeParagraph(
  self : *ContentLevel,
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
      self.nodes.items)).node(),
  };
}

pub fn implicitBlockConfig(self: *ContentLevel) ?*model.BlockConfig {
  return switch (self.command.cur_cursor) {
    .mapped => |c| self.command.mapper.config(c),
    else => null,
  };
}

pub fn finalize(self: *ContentLevel, p: *Impl) !*model.Node {
  const ip = p.intpr();
  if (self.block_config) |c| try p.revertBlockConfig(c.*);

  ip.resetSyms(self.sym_start);

  const alloc = p.allocator();
  const content_node = if (self.syntax_proc) |proc| (
    try proc.finish(
      proc, p.lexer.walker.source.between(self.start, p.cur_start))
  ) else if (self.seq.items.len == 0) (
    (
      try self.finalizeParagraph(p.intpr())
    ) orelse try ip.node_gen.void(p.lexer.walker.source.at(self.start))
  ) else blk: {
    if (self.nodes.items.len > 0) {
      if (try self.finalizeParagraph(p.intpr())) |content| {
        try self.seq.append(alloc, .{
          .content  = content,
          .lf_after = 0,
        });
      }
    }
    break :blk (try ip.node_gen.seq(
      self.seq.items[0].content.pos.span(
        last(self.seq.items).content.pos),
      .{.items = self.seq.items})).node();
  };
  if (self.capture.len > 0) {
    const c_node = try p.intpr().node_gen.capture(
      content_node.pos, self.capture, content_node);
    return c_node.node();
  } else return content_node;
}

pub fn pushParagraph(
  self    : *ContentLevel,
  intpr   : *Interpreter,
  lf_after: usize,
) !void {
  if (self.nodes.items.len > 0) {
    if (try self.finalizeParagraph(intpr)) |content| {
      try self.seq.append(intpr.allocator(), .{
        .content = content,
        .lf_after = lf_after
      });
    }
    self.nodes = .{};
  }
}