const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const Interpreter = nyarna.Interpreter;
const errors = nyarna.errors;

pub const SpecialSyntax = struct {
  pub const Item = union(enum) {
    literal: []const u8,
    space: []const u8,
    escaped: []const u8,
    special_char: u21,
    node: *model.Node,
    newlines: usize, // 1 for newlines, >1 for parseps.
    block_header: *model.Value.BlockHeader,
  };

  pub const Processor = struct {
    pub const Action = enum {none, read_block_header};

    push: fn(self: *@This(), pos: model.Position, item: Item)
      nyarna.Error!Action,
    finish: fn(self: *@This(), pos: model.Position)
      nyarna.Error!*model.Node,
  };

  init: fn init(intpr: *Interpreter) std.mem.Allocator.Error!*Processor,
  comments_include_newline: bool,
};

pub const SymbolDefs = struct {
  const State = enum {
    initial, names, after_name, ltype, after_ltype, flags, after_flag,
    after_flags, block_header, expr, at_end
  };
  const Variant = enum {locs, defs};
  const Processor = SpecialSyntax.Processor;

  intpr: *Interpreter,
  proc: Processor,
  state: State,
  produced: std.ArrayListUnmanaged(*model.Node),
  variant: Variant,
  // ----- current line ------
  start: model.Cursor,
  names: std.ArrayListUnmanaged(*model.Node.Literal),
  primary: ?model.Position,
  varargs: ?model.Position,
  varmap: ?model.Position,
  mutable: ?model.Position,
  root: ?model.Position,
  header: ?*model.Value.BlockHeader,
  @"type": ?*model.Node,
  expr: ?*model.Node,
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

  fn init(intpr: *Interpreter, variant: Variant)
      std.mem.Allocator.Error!*Processor {
    const ret = try intpr.allocator().create(SymbolDefs);
    ret.intpr = intpr;
    ret.proc = .{
      .push = SymbolDefs.push,
      .finish = SymbolDefs.finish,
    };
    ret.state = .initial;
    ret.names = .{};
    ret.produced = .{};
    ret.variant = variant;
    ret.reset();
    return &ret.proc;
  }

  inline fn logger(self: *SymbolDefs) *errors.Handler {
    return &self.intpr.loader.logger;
  }

  fn initLocations(intpr: *Interpreter) !*Processor {
    return init(intpr, .locs);
  }

  fn initDefinitions(intpr: *Interpreter) !*Processor {
    return init(intpr, .defs);
  }

  fn reset(l: *SymbolDefs) void {
    l.primary = null;
    l.varargs = null;
    l.varmap = null;
    l.mutable = null;
    l.header = null;
    l.root = null;
    l.@"type" = null;
    l.expr = null;
    l.names.clearRetainingCapacity();
  }

  fn push(p: *Processor, pos: model.Position,
          item: SpecialSyntax.Item) nyarna.Error!Processor.Action {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    self.state = while (true) {
      switch (self.state) {
        .initial => switch(item) {
          .space, .newlines => return .none,
          else => {
            self.start = pos.start;
            self.state = .names;
          },
        },
        .names => switch (item) {
          .space => return .none,
          .literal => |name| {
            try self.names.append(self.intpr.allocator(),
              try self.intpr.node_gen.literal(
                pos, .{.kind = .text, .content = name}));
            break .after_name;
          },
          .escaped => {
            self.logger().IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '=', '{' => {
              self.logger().MissingToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = c});
              self.state = .after_name;
            },
            ':' => if (self.variant == .locs) {
              self.logger().MissingToken(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.character = c});
              self.state = .after_name;
            } else {
              self.logger().ExpectedXGotY(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.character = c});
              return .none;
            },
            ';' => {
              self.logger().PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = ';'});
              self.state = .at_end;
            },
            else => {
              self.logger().ExpectedXGotY(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = c});
              return .none;
            },
          },
          .node => {
            self.logger().IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .node);
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
        },
        .after_name => switch (item) {
          .space => return .none,
          .literal => {
            self.logger().MissingToken(
              pos, self.afterNameItems(), .{.token = .identifier});
            self.state = .names;
          },
          .escaped => {
            self.logger().IllegalItem(
              pos, self.afterNameItems(), .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            ',' => break .names,
            ':' => {
              if (self.variant == .locs) break .ltype;
              self.logger().IllegalItem(
                pos, self.afterNameItems(), .{.character = c});
            },
            '{' => break .flags,
            '=' => break .expr,
            ';' => self.state = .at_end,
            else => {
              self.logger().IllegalItem(
                pos, self.afterNameItems(), .{.character = c});
              return .none;
            },
          },
          .node => {
            self.logger().IllegalItem(pos, self.afterNameItems(), .node);
            return .none;
          },
          .newlines => self.state = .at_end,
          .block_header => unreachable,
        },
        .ltype => switch(item) {
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
              self.state = .after_ltype;
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
            break .after_ltype;
          },
          .newlines => {
            self.logger().PrematureToken(
              pos, &[_]errors.WrongItemError.ItemDescr{.node},
              .{.token = .ws_break});
            self.state = .after_ltype;
          },
          .block_header => unreachable,
        },
        .after_ltype => switch (item) {
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
            '{' => break .flags,
            '=' => break .expr,
            ';' => self.state = .at_end,
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
          .newlines => self.state = .at_end,
          .block_header => unreachable,
        },
        .flags => switch (item) {
          .space => return .none,
          .literal => |id| {
            const target = switch (std.hash.Adler32.hash(id)) {
              std.hash.Adler32.hash("primary") => &self.primary,
              std.hash.Adler32.hash("varargs") => &self.varargs,
              std.hash.Adler32.hash("mutable") => &self.mutable,
              std.hash.Adler32.hash("varmap") => &self.varmap,
              std.hash.Adler32.hash("root") => &self.root,
              else => {
                self.logger().UnknownFlag(pos);
                return .none;
              }
            };
            if (target.*) |prev| {
              self.logger().DuplicateFlag(id, pos, prev);
            } else target.* = pos;
            break .after_flag;
          },
          .escaped => {
            self.logger().IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{
                .{.token = .identifier}, .{.character = '}'},
              }, .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '}' => break .after_flags,
            ',' => {
              self.logger().MissingToken(
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
              self.state = .at_end;
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
            break .after_flag;
          },
          .newlines => {
            self.logger().PrematureToken(
              pos, &[_]errors.WrongItemError.ItemDescr{
                .{.token = .identifier}, .{.character = '}'},
              }, .{.token = .ws_break});
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .after_flag => switch(item) {
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
            ',' => break .flags,
            '}' => break .after_flags,
            ';' => {
              self.logger().PrematureToken(
                pos, &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = '}'}
                }, .{.character = ';'});
              self.state = .at_end;
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
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .after_flags => switch (item) {
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
            '=' => break .expr,
            ';' => self.state = .at_end,
            '{' => break .flags,
            ':' => {
              self.state = .block_header;
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
          .newlines => self.state = .at_end,
          .block_header => unreachable,
        },
        .block_header => {
          if (self.header != null) {
            self.logger().DuplicateBlockHeader(
              "block header", pos, item.block_header.value().origin);
          } else self.header = item.block_header;
          break .after_flags;
        },
        .expr => switch(item) {
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
              self.state = .at_end;
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
            break .at_end;
          },
          .newlines => {
            self.logger().PrematureToken(
              pos, &[_]errors.WrongItemError.ItemDescr{.node},
              .{.token = .ws_break});
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .at_end => switch (item) {
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
              break .initial;
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
            break .initial;
          },
          .block_header => unreachable,
        },
      }
    } else unreachable;
    return .none;
  }

  fn finish(p: *Processor, pos: model.Position)
      std.mem.Allocator.Error!*model.Node {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    return (try self.intpr.node_gen.concat(
      pos, .{.items = self.produced.items})).node();
  }

  fn genLineNode(
      self: *SymbolDefs, name: *model.Node.Literal, pos: model.Position,
      comptime kind: []const u8, comptime content_field: []const u8,
      comptime additionals_field: ?[]const u8,
      comptime optional_pos_fields: []const []const u8,
      comptime optional_node_fields: []const []const u8) !*model.Node {
    const ret = try self.intpr.allocator().create(model.Node);
    ret.pos = pos;
    ret.data = @unionInit(@TypeOf(ret.data), kind, undefined);
    const val = &@field(ret.data, kind);
    val.name = name;
    const pos_into = if (additionals_field) |a| blk: {
      const af = try self.intpr.allocator().create(
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

  fn finishLine(self: *SymbolDefs, pos: model.Position) nyarna.Error!void {
    defer self.reset();
    if (self.names.items.len == 0) {
      self.logger().MissingSymbolName(pos);
      return;
    }
    if (self.variant == .defs and self.expr == null) {
        self.logger().MissingSymbolEntity(pos);
      return;
    }
    const line_pos = self.intpr.input.between(self.start, pos.end);

    for (self.names.items) |name| {
      const node = try switch (self.variant) {
        .locs => blk: {
          if (self.root) |rpos| self.logger().NonLocationFlag(rpos);
          break :blk self.genLineNode(
            name, line_pos, "location", "default", "additionals",
            &[_][]const u8{"primary", "varargs", "varmap", "mutable", "header"},
            &[_][]const u8{"type"});
        },
        .defs => blk: {
          inline for (.{"primary", "varargs", "varmap", "mutable"}) |item|
            if (@field(self, item)) |p|
              self.logger().NonDefinitionFlag(p);
          if (self.header) |bh|
            self.logger().BlockHeaderNotAllowedForDefinition(bh.value().origin);
          break :blk self.genLineNode(
            name, line_pos, "definition", "content", null,
            &[_][]const u8{"root"}, &[_][]const u8{});
        },
      };
      try self.produced.append(self.intpr.allocator(), node);
    }
  }

  fn boolFrom(self: *SymbolDefs, pos: ?model.Position, at: model.Position)
      !*model.Node {
    return self.intpr.genValueNode(pos orelse at, .{
      .enumval = .{
        .t = self.intpr.loader.context.types.getBoolean(),
        .index = if (pos) |_| 1 else 0,
      }
    });
  }
};