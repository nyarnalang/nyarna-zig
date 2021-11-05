const std = @import("std");
const data = @import("data");
const Context = @import("interpret.zig").Context;
const errors = @import("errors");

pub const SpecialSyntax = struct {
  pub const Item = union(enum) {
    literal: []const u8,
    space: []const u8,
    escaped: []const u8,
    special_char: u21,
    node: *data.Node,
    newlines: usize, // 1 for newlines, >1 for parseps.
    block_header: *data.Value.BlockHeader,
  };

  pub const Processor = struct {
    pub const Action = enum {none, read_block_header};

    push: fn(self: *@This(), pos: data.Position, item: Item) std.mem.Allocator.Error!Action,
    finish: fn(self: *@This(), pos: data.Position) std.mem.Allocator.Error!*data.Node,
  };

  init: fn init(ctx: *Context) std.mem.Allocator.Error!*Processor,
  comments_include_newline: bool,
};

pub const SymbolDefs = struct {
  const State = enum {
    initial, names, after_name, ltype, after_ltype, flags, after_flag, after_flags,
    block_header, expr, at_end
  };
  const Variant = enum {locs, defs};
  const Processor = SpecialSyntax.Processor;

  ctx: *Context,
  proc: Processor,
  state: State,
  produced: std.ArrayListUnmanaged(*data.Node),
  variant: Variant,
  // ----- current line ------
  start: data.Cursor,
  names: std.ArrayListUnmanaged(*data.Node),
  primary: ?data.Position,
  varargs: ?data.Position,
  varmap: ?data.Position,
  mutable: ?data.Position,
  root: ?data.Position,
  header: ?*data.Value.BlockHeader,
  ltype: ?*data.Node,
  expr: ?*data.Node,
  // -------------------------

  const after_name_items_arr = [_]errors.WrongItemError.ItemDescr{
    .{.character = ','}, .{.character = '{'}, .{.character = '='}, .{.character = ':'}
  };
  const after_flags_items_arr = [_]errors.WrongItemError.ItemDescr{
    .{.character = '='}, .{.character = ';'}, .{.character = ':'}, .{.token = .ws_break}
  };

  fn afterNameItems(self: *@This()) []const errors.WrongItemError.ItemDescr {
    return after_name_items_arr[0..if (self.variant == .locs) @as(usize, 4) else 3];
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

  fn init(ctx: *Context, variant: Variant) std.mem.Allocator.Error!*Processor {
    const alloc = &ctx.temp_nodes.allocator;
    const ret = try alloc.create(SymbolDefs);
    ret.ctx = ctx;
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

  fn initLocations(ctx: *Context) !*Processor {
    return init(ctx, .locs);
  }

  fn initDefinitions(ctx: *Context) !*Processor {
    return init(ctx, .defs);
  }

  fn reset(l: *SymbolDefs) void {
    l.primary = null;
    l.varargs = null;
    l.varmap = null;
    l.mutable = null;
    l.header = null;
    l.root = null;
    l.ltype = null;
    l.expr = null;
    l.names.clearRetainingCapacity();
  }

  fn push(p: *Processor, pos: data.Position,
          item: SpecialSyntax.Item) std.mem.Allocator.Error!Processor.Action {
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
            const name_node = try self.ctx.temp_nodes.allocator.create(data.Node);
            name_node.pos = pos;
            name_node.data = .{
              .literal = .{
                .kind = .text,
                .content = name,
              }
            };
            try self.names.append(&self.ctx.temp_nodes.allocator, name_node);
            break .after_name;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '=', '{' => {
              self.ctx.eh.MissingToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = c});
              self.state = .after_name;
            },
            ':' => if (self.variant == .locs) {
              self.ctx.eh.MissingToken(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.character = c});
              self.state = .after_name;
            } else {
              self.ctx.eh.ExpectedXGotY(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.character = c});
              return .none;
            },
            ';' => {
              self.ctx.eh.PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = ';'});
              self.state = .at_end;
            },
            else => {
              self.ctx.eh.ExpectedXGotY(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = c});
              return .none;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .node);
            return .none;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
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
            self.ctx.eh.MissingToken(pos, self.afterNameItems(), .{.token = .identifier});
            self.state = .names;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            ',' => break .names,
            ':' => {
              if (self.variant == .locs) break .ltype;
              self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .{.character = c});
            },
            '{' => break .flags,
            '=' => break .expr,
            ';' => self.state = .at_end,
            else => {
              self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .{.character = c});
              return .none;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .node);
            return .none;
          },
          .newlines => self.state = .at_end,
          .block_header => unreachable,
        },
        .ltype => switch(item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .literal});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node},
                .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '{', '=', ';' => {
              self.ctx.eh.PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.node}, .{.character = c});
              self.state = .after_ltype;
            },
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{.node}, .{.character = c});
              return .none;
            },
          },
          .node => |n| {
            self.ltype = n;
            break .after_ltype;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .ws_break});
            self.state = .after_ltype;
          },
          .block_header => unreachable,
        },
        .after_ltype => switch (item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .identifier});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '{' => break .flags,
            '=' => break .expr,
            ';' => self.state = .at_end,
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                  }, .{.character = c});
              return .none;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
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
                self.ctx.eh.UnknownFlag(pos);
                return .none;
              }
            };
            if (target.*) |prev| {
              self.ctx.eh.DuplicateFlag(id, pos, prev);
            } else target.* = pos;
            break .after_flag;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}
                }, .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            '}' => break .after_flags,
            ',' => {
              self.ctx.eh.MissingToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}
                  }, .{.character = ','});
              return .none;
            },
            ';' => {
              self.ctx.eh.PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                      .{.token = .identifier}, .{.character = '}'}},
                  .{.character = ';'});
              self.state = .at_end;
            },
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}},
                    .{.character = c});
              return .none;
            }
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}},
                    .node);
            break .after_flag;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}},
                .{.token = .ws_break});
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .after_flag => switch(item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = '}'}
                }, .{.token = .identifier});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.character = ','}, .{.character = '}'}
                }, .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            ',' => break .flags,
            '}' => break .after_flags,
            ';' => {
              self.ctx.eh.PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.character = ','}, .{.character = '}'}},
                  .{.character = ';'});
              self.state = .at_end;
            },
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                      .{.character = ','}, .{.character = '}'}}, .{.character = c});
              return .none;
            }
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.character = ','}, .{.character = '}'}},
                    .node);
            return .none;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = '}'}},
                .{.character = ';'});
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .after_flags => switch (item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos, &after_flags_items_arr, .{.token = .identifier});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos, &after_flags_items_arr, .{.token = .escape});
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
              self.ctx.eh.IllegalItem(pos, &after_flags_items_arr, .{.character = c});
              return .none;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos, &after_flags_items_arr, .node);
            return .none;
          },
          .newlines => self.state = .at_end,
          .block_header => unreachable,
        },
        .block_header => {
          if (self.header != null) {
            self.ctx.eh.DuplicateBlockHeader("block header", pos, item.block_header.value().origin);
          } else self.header = item.block_header;
          break .after_flags;
        },
        .expr => switch(item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .identifier});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            ';' => {
              self.ctx.eh.PrematureToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.node}, .{.character = ';'});
              self.state = .at_end;
            },
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{.node}, .{.character = c});
              return .none;
            },
          },
          .node => |n| {
            self.expr = n;
            break .at_end;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .ws_break});
            self.state = .at_end;
          },
          .block_header => unreachable,
        },
        .at_end => switch (item) {
          .space => return .none,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .{.token = .identifier});
            return .none;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .{.token = .escape});
            return .none;
          },
          .special_char => |c| switch (c) {
            ';' => {
              try self.finishLine(pos);
              break .initial;
            },
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                  .{.character = c});
              return .none;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .node);
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

  fn finish(p: *Processor, pos: data.Position) std.mem.Allocator.Error!*data.Node {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    const ret = try self.ctx.temp_nodes.allocator.create(data.Node);
    ret.pos = pos;
    ret.data = .{
      .concatenation = .{
        .content = self.produced.items,
      }
    };
    return ret;
  }

  fn finishLine(self: *SymbolDefs, pos: data.Position) !void {
    defer self.reset();
    if (self.names.items.len == 0) {
      self.ctx.eh.MissingSymbolName(pos);
      return;
    }
    if (self.ltype == null and self.expr == null) {
      if (self.variant == .locs)
        self.ctx.eh.MissingSymbolType(pos)
      else
        self.ctx.eh.MissingSymbolEntity(pos);
      return;
    }
    const line_pos = self.ctx.input.between(self.start, pos.end);

    const lexpr = try self.ctx.source_content.allocator.create(data.Expression);
    lexpr.* = data.Expression.literal(line_pos, .{
      .typeval = .{
        .t = .{
          .intrinsic = if (self.variant == .locs) .location else .definition
        },
      },
    });

    for (self.names.items) |name| {
      const args = try self.ctx.temp_nodes.allocator.alloc(*data.Node,
          switch (self.variant) {.locs => @as(usize, 8), .defs => 3});
      args[0] = name;
      var additionals = switch (self.variant) {
        .locs => ptr: {
          args[1] = self.ltype orelse blk: {
            const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
            vn.pos = pos;
            vn.data = .voidNode;
            break :blk vn;
          };
          break :ptr args.ptr + 2;
        },
        .defs => args.ptr + 1,
      };
      switch (self.variant) {
        .locs => {
          additionals[0] = try self.boolFrom(self.primary, pos);
          additionals[1] = try self.boolFrom(self.varargs, pos);
          additionals[2] = try self.boolFrom(self.varmap, pos);
          additionals[3] = try self.boolFrom(self.mutable, pos);
          const bhn = try self.ctx.temp_nodes.allocator.create(data.Node);
          if (self.header) |bh| {
            bhn.pos = bh.value().origin;
            bhn.data = .{
              .expression = @fieldParentPtr(data.Expression.Literal, "value", bh.value()).expr(),
            };
          } else {
            bhn.pos = pos;
            bhn.data = .voidNode;
          }
          additionals[4] = bhn;
          if (self.root) |rpos| self.ctx.eh.NonLocationFlag(rpos);
          additionals += 5;
        },
        .defs => {
          additionals[0] = try self.boolFrom(self.root, pos);
          if (self.primary) |ppos| self.ctx.eh.NonDefinitionFlag(ppos);
          if (self.varargs) |vpos| self.ctx.eh.NonDefinitionFlag(vpos);
          if (self.varmap) |mpos| self.ctx.eh.NonDefinitionFlag(mpos);
          if (self.mutable) |mpos| self.ctx.eh.NonDefinitionFlag(mpos);
          if (self.header) |bh| self.ctx.eh.BlockHeaderNotAllowedForDefinition(bh.value().origin);
          additionals += 1;
        }
      }
      additionals.* = self.expr orelse blk: {
        const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
        vn.pos = pos;
        vn.data = .voidNode;
        break :blk vn;
      };

      const constructor = try self.ctx.temp_nodes.allocator.create(data.Node);
      constructor.pos = line_pos;
      constructor.data = .{
        .resolved_call = .{
          .target = lexpr,
          .args = args,
        }
      };
      try self.produced.append(&self.ctx.temp_nodes.allocator, constructor);
    }
  }

  fn boolFrom(self: *SymbolDefs, pos: ?data.Position, at: data.Position) !*data.Node {
    const expr = try self.ctx.source_content.allocator.create(data.Expression);
    expr.pos = pos orelse at;
    expr.* = data.Expression.literal(pos orelse at, .{
      .enumval = .{
        .t = self.ctx.types.getBoolean(),
        .index = if (pos) |_| 1 else 0,
      }
    });
    const ret = try self.ctx.temp_nodes.allocator.create(data.Node);
    ret.data = .{
      .expression = expr,
    };
    ret.pos = expr.pos;
    return ret;
  }
};