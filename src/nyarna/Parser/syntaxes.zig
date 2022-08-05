const std = @import("std");

const nyarna      = @import("../../nyarna.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

pub const SpecialSyntax = struct {
  pub const Item = union(enum) {
    literal     : []const u8,
    space       : []const u8,
    escaped     : []const u8,
    special_char: u21,
    node        : *model.Node,
    newlines    : usize, // 1 for newlines, >1 for parseps.
    block_header: *model.Value.BlockHeader,
  };

  pub const Processor = struct {
    pub const Action = enum {none, read_block_header};

    push: fn(
      self: *@This(),
      pos : model.Position,
      item: Item,
    ) nyarna.Error!Action,
    finish: fn(self: *@This(), pos: model.Position) nyarna.Error!*model.Node,
  };

  init: fn init(
    intpr: *Interpreter,
    source: *const model.Source,
  ) std.mem.Allocator.Error!*Processor,
  comments_include_newline: bool,
};

pub const SymbolDefs = struct {
  const State = fn(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action;

  const Variant = enum {locs, defs};
  const Processor = SpecialSyntax.Processor;

  intpr    : *Interpreter,
  source   : *const model.Source,
  proc     : Processor,
  state    : State,
  produced : std.ArrayListUnmanaged(*model.Node),
  variant  : Variant,
  last_item: model.Position,
  // ----- current line ------
  start  : model.Cursor,
  names  : std.ArrayListUnmanaged(*model.Node.Literal) = .{},
  merge  : ?model.Position = null,
  primary: ?model.Position = null,
  varargs: ?model.Position = null,
  varmap : ?model.Position = null,
  borrow : ?model.Position = null,
  header : ?*model.Value.BlockHeader = null,
  @"type": ?*model.Node = null,
  expr   : ?*model.Node = null,
  surplus_flags_start: ?model.Position = null, // more than one {…} in line.
  // -------------------------

  const after_name_items_arr = [_]errors.WrongItemError.ItemDescr{
    .{.character = ','}, .{.character = '{'}, .{.character = '='},
    .{.character = ':'}
  };
  const after_flags_items_arr = [_]errors.WrongItemError.ItemDescr{
    .{.character = '='}, .{.character = ';'}, .{.character = ':'},
    .{.token = .ws_break}
  };

  fn afterNameItems(self: *@This()) []const errors.WrongItemError.ItemDescr {
    return after_name_items_arr[
      0..if (self.variant == .locs) @as(usize, 4) else 3];
  }

  pub fn locations() SpecialSyntax {
    return .{
      .init = SymbolDefs.initLocations,
      .comments_include_newline = false,
    };
  }

  pub fn definitions() SpecialSyntax {
    return .{
      .init = SymbolDefs.initDefinitions,
      .comments_include_newline = false,
    };
  }

  fn init(
    intpr  : *Interpreter,
    source : *const model.Source,
    variant: Variant,
  ) std.mem.Allocator.Error!*Processor {
    const ret = try intpr.allocator().create(SymbolDefs);
    ret.* = .{
      .intpr  = intpr,
      .source = source,
      .proc   = .{
        .push   = push,
        .finish = finish,
      },
      .state     = initial,
      .names     = .{},
      .produced  = .{},
      .variant   = variant,
      .last_item = model.Position.intrinsic(),
      .start     = undefined,
    };
    return &ret.proc;
  }

  fn logger(self: *SymbolDefs) *errors.Handler {
    return self.intpr.ctx.logger;
  }

  fn initLocations(
    intpr : *Interpreter,
    source: *const model.Source,
  ) !*Processor {
    return init(intpr, source, .locs);
  }

  fn initDefinitions(
    intpr : *Interpreter,
    source: *const model.Source,
  ) !*Processor {
    return init(intpr, source, .defs);
  }

  fn reset(l: *SymbolDefs) void {
    l.merge   = null;
    l.primary = null;
    l.varargs = null;
    l.varmap  = null;
    l.borrow  = null;
    l.header  = null;
    l.@"type" = null;
    l.expr    = null;
    l.surplus_flags_start = null;
    l.names.clearRetainingCapacity();
  }

  fn initial(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space, .newlines => return .none,
      .node => |node| {
        try self.produced.append(self.intpr.allocator(), node);
        self.state = afterNodeVal;
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos,
          &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
          .{.token = .escape});
        return .none;
      },
      else => {
        self.start = pos.start;
        self.state = names;
        return null;
      },
    }
  }

  fn names(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space   => return .none,
      .literal => |name| {
        try self.names.append(self.intpr.allocator(),
          try self.intpr.node_gen.literal(
            pos, .{.kind = .text, .content = name}));
        self.state = afterName;
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos,
          &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
          .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        '|', '=', '{' => {
          self.logger().PrematureToken(
            pos.before(),
            &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
            .{.character = c});
          self.state = afterName;
          return null;
        },
        ':' => if (self.variant == .locs) {
          self.logger().PrematureToken(
            pos.before(),
            &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
            .{.character = c});
          self.state = afterName;
          return null;
        } else {
          self.logger().IllegalItem(pos,
            &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
            .{.character = c});
          return .none;
        },
        ';' => {
          self.logger().PrematureToken(pos,
            &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
            .{.character = ';'});
          self.state = atEnd;
          return null;
        },
        else => {
          self.logger().IllegalItem(pos,
            &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
            .{.character = c});
          return .none;
        },
      },
      .node => {
        self.logger().IllegalItem(pos,
          &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}}, .node);
        return .none;
      },
      .newlines => {
        self.logger().PrematureToken(pos,
          &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
          .{.token = .ws_break});
        self.reset();
        return .none;
      },
      .block_header => unreachable,
    }
  }

  fn afterName(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().MissingToken(
          pos.before(),
          &[_]errors.WrongItemError.ItemDescr{.{.character = ','}},
          .{.token = .identifier});
        self.state = names;
        return null;
      },
      .escaped => {
        self.logger().IllegalItem(
          pos.before(), self.afterNameItems(), .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        ',' => {
          self.state = names;
          return .none;
        },
        ':' => {
          if (self.variant == .locs) {
            self.state = ltype;
            return .none;
          }
          self.logger().IllegalItem(
            pos, self.afterNameItems(), .{.character = c});
          return .none;
        },
        '{' => {
          self.state = flags;
          return .none;
        },
        '=' => {
          self.state = atExpr;
          return .none;
        },
        ';' => {
          self.state = atEnd;
          return null;
        },
        else => if (self.variant == .defs and c == '|') {
          self.state = afterPipe;
          self.merge = pos;
          return .none;
        } else {
          self.logger().IllegalItem(
            pos, self.afterNameItems(), .{.character = c});
          return .none;
        },
      },
      .node => {
        self.logger().IllegalItem(pos, self.afterNameItems(), .node);
        return .none;
      },
      .newlines => {
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn afterPipe(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .special_char => |c| if (c == '=') {
        self.merge = self.merge.?.span(pos);
        self.state = atExpr;
        return .none;
      },
      else => {},
    }
    self.logger().IllegalItem(
      self.merge.?, self.afterNameItems(), .{.character = '|'});
    self.merge = null;
    return .none;
  }

  fn ltype(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(pos,
          &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .literal});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos,
            &[_]errors.WrongItemError.ItemDescr{.node},
            .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        '{', '=', ';' => {
          self.logger().PrematureToken(
            pos, &[_]errors.WrongItemError.ItemDescr{.node},
            .{.character = c});
          self.state = afterLtype;
          return null;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{.node},
            .{.character = c});
          return .none;
        },
      },
      .node => |n| {
        self.@"type" = n;
        self.state = afterLtype;
        return .none;
      },
      .newlines => {
        self.logger().PrematureToken(
          pos, &[_]errors.WrongItemError.ItemDescr{.node},
          .{.token = .ws_break});
        self.state = afterLtype;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn afterLtype(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = '='}, .{.character = ';'}, .{.token = .ws_break},
          }, .{.token = .identifier});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = '='}, .{.character = ';'}, .{.token = .ws_break},
          }, .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        '{' => {
          self.state = flags;
          return .none;
        },
        '=' => {
          self.state = atExpr;
          return .none;
        },
        ';' => {
          self.state = atEnd;
          return null;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.character = '='}, .{.character = ';'},
              .{.token = .ws_break},
            }, .{.character = c});
          return .none;
        },
      },
      .node => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = '='}, .{.character = ';'}, .{.token = .ws_break},
          }, .node);
        return .none;
      },
      .newlines => {
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn flags(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => |id| {
        if (self.surplus_flags_start == null) {
          const target = switch (std.hash.Adler32.hash(id)) {
            std.hash.Adler32.hash("primary") => &self.primary,
            std.hash.Adler32.hash("varargs") => &self.varargs,
            std.hash.Adler32.hash("borrow")  => &self.borrow,
            std.hash.Adler32.hash("varmap")  => &self.varmap,
            else => {
              self.logger().UnknownFlag(pos, id);
              return .none;
            }
          };
          if (target.*) |prev| {
            self.logger().DuplicateFlag(id, pos, prev);
          } else target.* = pos;
        }
        self.state = afterFlag;
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.token = .identifier}, .{.character = '}'},
          }, .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        '}' => {
          self.state = afterFlags;
          return .none;
        },
        ',' => {
          self.logger().PrematureToken(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.token = .identifier}, .{.character = '}'},
            }, .{.character = ','});
          return .none;
        },
        ';' => {
          self.logger().PrematureToken(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.token = .identifier}, .{.character = '}'},
            }, .{.character = ';'});
          self.state = atEnd;
          return null;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.token = .identifier}, .{.character = '}'},
            }, .{.character = c});
          return .none;
        }
      },
      .node => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.token = .identifier}, .{.character = '}'},
          }, .node);
        self.state = afterFlag;
        return .none;
      },
      .newlines => {
        self.logger().PrematureToken(
          pos, &[_]errors.WrongItemError.ItemDescr{
            .{.token = .identifier}, .{.character = '}'},
          }, .{.token = .ws_break});
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn afterFlag(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ','}, .{.character = '}'},
          }, .{.token = .identifier});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ','}, .{.character = '}'}
          }, .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        ',' => {
          self.state = flags;
          return .none;
        },
        '}' => {
          self.state = afterFlags;
          return .none;
        },
        ';' => {
          self.logger().PrematureToken(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.character = ','}, .{.character = '}'}
            }, .{.character = ';'});
          self.state = atEnd;
          return null;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.character = ','}, .{.character = '}'}
            }, .{.character = c});
          return .none;
        }
      },
      .node => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ','}, .{.character = '}'}
          }, .node);
        return .none;
      },
      .newlines => {
        self.logger().PrematureToken(
          pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ','}, .{.character = '}'}
          }, .{.character = ';'});
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn afterFlags(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    if (self.surplus_flags_start) |start| blk: {
      switch (item) {
        .special_char => |c| switch (c) {
          ':' => break :blk,
          else => {},
        },
        else => {},
      }
      self.intpr.ctx.logger.SurplusFlags(model.Position{
        .source = start.source, .start = start.start, .end = pos.start,
      });
      self.surplus_flags_start = null;
    }
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(
          pos, &after_flags_items_arr, .{.token = .identifier});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(
          pos, &after_flags_items_arr, .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        '=' => {
          self.state = atExpr;
          return .none;
        },
        ';' => {
          self.state = atEnd;
          return null;
        },
        '{' => {
          self.surplus_flags_start = pos;
          self.state = flags;
          return .none;
        },
        ':' => {
          self.state = blockHeader;
          return .read_block_header;
        },
        else => {
          self.logger().IllegalItem(
            pos, &after_flags_items_arr, .{.character = c});
          return .none;
        },
      },
      .node => {
        self.logger().IllegalItem(pos, &after_flags_items_arr, .node);
        return .none;
      },
      .newlines => {
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn blockHeader(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    if (self.surplus_flags_start == null) {
      if (self.header != null) {
        self.logger().DuplicateBlockHeader(
          "block header", pos, item.block_header.value().origin);
      } else self.header = item.block_header;
    }
    self.state = afterFlags;
    return .none;
  }

  fn atExpr(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(
          pos, &[_]errors.WrongItemError.ItemDescr{.node},
          .{.token = .identifier});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(
          pos, &[_]errors.WrongItemError.ItemDescr{.node},
          .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        ';' => {
          self.logger().PrematureToken(
            pos, &[_]errors.WrongItemError.ItemDescr{.node},
            .{.character = ';'});
          self.state = atEnd;
          return null;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{.node},
            .{.character = c});
          return .none;
        },
      },
      .node => |n| {
        self.expr = n;
        self.state = atEnd;
        return .none;
      },
      .newlines => {
        self.logger().PrematureToken(
          pos, &[_]errors.WrongItemError.ItemDescr{.node},
          .{.token = .ws_break});
        self.state = atEnd;
        return null;
      },
      .block_header => unreachable,
    }
  }

  fn atEnd(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .literal => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ';'}, .{.token = .ws_break}
          }, .{.token = .identifier});
        return .none;
      },
      .escaped => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ';'}, .{.token = .ws_break}
          }, .{.token = .escape});
        return .none;
      },
      .special_char => |c| switch (c) {
        ';' => {
          try self.finishLine(pos);
          self.state = initial;
          return .none;
        },
        else => {
          self.logger().IllegalItem(
            pos, &[_]errors.WrongItemError.ItemDescr{
              .{.character = ';'}, .{.token = .ws_break}
            }, .{.character = c});
          return .none;
        },
      },
      .node => {
        self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
            .{.character = ';'}, .{.token = .ws_break}
          }, .node);
        return .none;
      } ,
      .newlines => {
        try self.finishLine(pos);
        self.state = initial;
        return .none;
      },
      .block_header => unreachable,
    }
  }

  fn afterNodeVal(
    self: *SymbolDefs,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) std.mem.Allocator.Error!?Processor.Action {
    switch (item) {
      .space => return .none,
      .newlines => {
        self.state = initial;
        return Processor.Action.none;
      },
      .special_char => |c| switch (c) {
        ';' => {
          self.state = initial;
          return Processor.Action.none;
        },
        else => {},
      },
      else => {},
    }
    // generate same error as atEnd
    return try self.atEnd(pos, item);
  }

  fn push(
    p   : *Processor,
    pos : model.Position,
    item: SpecialSyntax.Item,
  ) nyarna.Error!Processor.Action {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    self.last_item = pos;
    while (true) if (try self.state(self, pos, item)) |action| return action;
  }

  fn finish(p: *Processor, pos: model.Position) nyarna.Error!*model.Node {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    if (self.state != initial) {
      _ = try p.push(
        p, self.last_item.after(), SpecialSyntax.Item{.newlines = 1});
    }
    return (try self.intpr.node_gen.concat(pos, self.produced.items)).node();
  }

  fn genLineNode(
             self: *SymbolDefs,
             name: *model.Node.Literal,
             pos : model.Position,
    comptime kind                : []const u8,
    comptime content_field       : []const u8,
    comptime additionals_field   : ?[]const u8,
    comptime optional_pos_fields : []const []const u8,
    comptime optional_node_fields: []const []const u8,
  ) !*model.Node {
    const ret = try self.intpr.allocator().create(model.Node);
    ret.pos = pos;
    ret.data = @unionInit(@TypeOf(ret.data), kind, undefined);
    const val = &@field(ret.data, kind);
    if (@TypeOf(val.name) == *model.Node) val.name = name.node()
    else val.name = name;
    const pos_into = if (additionals_field) |a| blk: {
      const af = try self.intpr.ctx.global().create(
        @typeInfo(
          @typeInfo(@TypeOf(@field(val, a))).Optional.child
        ).Pointer.child);
      @field(val, a) = af;
      break :blk af;
    } else val;
    inline for (optional_pos_fields) |f| {
      @field(pos_into, f) = @field(self, f);
    }
    inline for (optional_node_fields) |f| {
      @field(val, f) = @field(self, f);
    }
    if (@typeInfo(@TypeOf(@field(val, content_field))) == .Optional)
      @field(val, content_field) = self.expr
    else
      @field(val, content_field) = self.expr.?;
    return ret;
  }

  fn finishLine(
    self: *SymbolDefs,
    pos : model.Position,
  ) std.mem.Allocator.Error!void {
    defer self.reset();
    if (self.names.items.len == 0) {
      // we reported this as error in the syntax
      return;
    }
    switch (self.variant) {
      .defs => if (self.expr == null) {
        self.logger().MissingSymbolEntity(pos);
        return;
      },
      .locs => if (self.@"type" == null and self.expr == null) {
        self.logger().MissingSymbolType(pos);
        return;
      }
    }

    const line_pos = self.source.between(self.start, pos.end);
    for (self.names.items) |name| {
      const node = try switch (self.variant) {
        .locs => blk: {
          break :blk self.genLineNode(
            name, line_pos, "location", "default", "additionals",
            &[_][]const u8{"primary", "varargs", "varmap", "borrow", "header"},
            &[_][]const u8{"type"});
        },
        .defs => blk: {
          inline for (.{"primary", "varargs", "varmap", "borrow"}) |item| {
            if (@field(self, item)) |p|
              self.logger().NonDefinitionFlag(p);
          }
          if (self.header) |bh| {
            self.logger().BlockHeaderNotAllowedForDefinition(bh.value().origin);
          }
          break :blk self.genLineNode(
            name, line_pos, "definition", "content", null,
            &[_][]const u8{"merge"}, &[_][]const u8{});
        },
      };
      try self.produced.append(self.intpr.allocator(), node);
    }
  }
};