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
  };

  pub const Processor = struct {
    push: fn(self: *@This(), pos: data.Position.Input, item: Item) std.mem.Allocator.Error!void,
    finish: fn(self: *@This(), pos: data.Position.Input) std.mem.Allocator.Error!*data.Node,
  };

  init: fn init(ctx: *Context) std.mem.Allocator.Error!*Processor,
  comments_include_newline: bool,
};

pub const SymbolDefs = struct {
  const State = enum {
    initial, names, after_name, ltype, after_ltype, flags, after_flag, after_flags, expr, at_end
  };
  const Variant = enum {locs, defs};

  ctx: *Context,
  proc: SpecialSyntax.Processor,
  state: State,
  produced: std.ArrayListUnmanaged(*data.Node),
  variant: Variant,
  // ----- current line ------
  start: data.Cursor,
  names: std.ArrayListUnmanaged(*data.Node),
  primary: ?data.Position.Input,
  varargs: ?data.Position.Input,
  varmap: ?data.Position.Input,
  root: ?data.Position.Input,
  ltype: ?*data.Node,
  expr: ?*data.Node,
  // -------------------------

  const after_name_items_arr = [_]errors.WrongItemError.ItemDescr{
    .{.character = ','}, .{.character = '{'}, .{.character = '='}, .{.character = ':'}
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

  fn init(ctx: *Context, variant: Variant) std.mem.Allocator.Error!*SpecialSyntax.Processor {
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

  fn initLocations(ctx: *Context) !*SpecialSyntax.Processor {
    return init(ctx, .locs);
  }

  fn initDefinitions(ctx: *Context) !*SpecialSyntax.Processor {
    return init(ctx, .defs);
  }

  fn reset(l: *SymbolDefs) void {
    l.primary = null;
    l.varargs = null;
    l.varmap = null;
    l.root = null;
    l.ltype = null;
    l.expr = null;
    l.names.clearRetainingCapacity();
  }

  fn push(p: *SpecialSyntax.Processor, pos: data.Position.Input,
          item: SpecialSyntax.Item) std.mem.Allocator.Error!void {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    self.state = while (true) {
      switch (self.state) {
        .initial => switch(item) {
          .space, .newlines => return,
          else => {
            self.start = pos.start;
            self.state = .names;
          },
        },
        .names => switch (item) {
          .space => return,
          .literal => |name| {
            const name_node = try self.ctx.temp_nodes.allocator.create(data.Node);
            name_node.pos = .{.input = pos};
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
            return;
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
              return;
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
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .node);
            return;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                .{.token = .ws_break});
            self.reset();
            return;
          }
        },
        .after_name => switch (item) {
          .space => return,
          .literal => |name| {
            self.ctx.eh.MissingToken(pos, self.afterNameItems(), .{.token = .identifier});
            self.state = .names;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .{.token = .escape});
            return;
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
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos, self.afterNameItems(), .node);
            return;
          },
          .newlines => self.state = .at_end,
        },
        .ltype => switch(item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos, &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .literal});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node},
                .{.token = .escape});
            return;
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
              return;
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
        },
        .after_ltype => switch (item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .identifier});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .escape});
            return;
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
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .node);
            return;
          },
          .newlines => self.state = .at_end,
        },
        .flags => switch (item) {
          .space => return,
          .literal => |id| {
            const target = switch (std.hash.Adler32.hash(id)) {
              std.hash.Adler32.hash("primary") => &self.primary,
              std.hash.Adler32.hash("varargs") => &self.varargs,
              std.hash.Adler32.hash("varmap") => &self.varmap,
              std.hash.Adler32.hash("root") => &self.root,
              else => {
                self.ctx.eh.UnknownFlag(pos);
                return;
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
            return;
          },
          .special_char => |c| switch (c) {
            '}' => break .after_flags,
            ',' => {
              self.ctx.eh.MissingToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{
                    .{.token = .identifier}, .{.character = '}'}
                  }, .{.character = ','});
              return;
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
              return;
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
        },
        .after_flag => switch(item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = '}'}
                }, .{.token = .identifier});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.character = ','}, .{.character = '}'}
                }, .{.token = .escape});
            return;
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
              return;
            }
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                    .{.character = ','}, .{.character = '}'}},
                    .node);
            return;
          },
          .newlines => {
            self.ctx.eh.PrematureToken(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = '}'}},
                .{.character = ';'});
            self.state = .at_end;
          },
        },
        .after_flags => switch (item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .identifier});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = '='}, .{.character = ';'}, .{.token = .ws_break}
                }, .{.token = .escape});
            return;
          },
          .special_char => |c| switch (c) {
            '=' => break .expr,
            ';' => self.state = .at_end,
            '{' => break .flags,
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.character = '='}, .{.character = ';'}, .{.token = .ws_break}},
                  .{.character = c});
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = '='}, .{.character = ';'}, .{.token = .ws_break}},
                .node);
            return;
          },
          .newlines => self.state = .at_end,
        },
        .expr => switch(item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .identifier});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.node}, .{.token = .escape});
            return;
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
              return;
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
        },
        .at_end => switch (item) {
          .space => return,
          .literal => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .{.token = .identifier});
            return;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .{.token = .escape});
            return;
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
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ';'}, .{.token = .ws_break}},
                .node);
            return;
          },
          .newlines => {
            try self.finishLine(pos);
            break .initial;
          },
        },
      }
    } else unreachable;
  }

  fn finish(p: *SpecialSyntax.Processor, pos: data.Position.Input) std.mem.Allocator.Error!*data.Node {
    const self = @fieldParentPtr(SymbolDefs, "proc", p);
    const ret = try self.ctx.temp_nodes.allocator.create(data.Node);
    ret.pos = .{.input = pos};
    ret.data = .{
      .concatenation = .{
        .content = self.produced.items,
      }
    };
    return ret;
  }

  fn finishLine(self: *SymbolDefs, pos: data.Position.Input) !void {
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
    const line_pos = .{.input = self.ctx.input.between(self.start, pos.end)};

    const lexpr = try self.ctx.source_content.allocator.create(data.Expression);
    lexpr.pos = line_pos;
    lexpr.data = .{
      .literal = .{
        .value = .{
          .origin = line_pos,
          .data = .{
            .typeval = .{
              .intrinsic = if (self.variant == .locs) .location else .definition
            }
          }
        }
      }
    };

    for (self.names.items) |name| {
      const args = try self.ctx.temp_nodes.allocator.alloc(*data.Node,
          switch (self.variant) {.locs => @as(usize, 6), .defs => 3});
      args[0] = name;
      const additionals = switch (self.variant) {
        .locs => ptr: {
          args[1] = self.ltype orelse blk: {
            const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
            vn.pos = .{.input = pos};
            vn.data = .voidNode;
            break :blk vn;
          };
          break :ptr args.ptr + 2;
        },
        .defs => args.ptr + 1,
      };
      additionals[0] = self.expr orelse blk: {
        const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
        vn.pos = .{.input = pos};
        vn.data = .voidNode;
        break :blk vn;
      };
      switch (self.variant) {
        .locs => {
          additionals[1] = try self.boolFrom(self.primary, pos);
          additionals[2] = try self.boolFrom(self.varargs, pos);
          additionals[3] = try self.boolFrom(self.varmap, pos);
          if (self.root) |rpos| self.ctx.eh.NonLocationFlag(rpos);
        },
        .defs => {
          additionals[1] = try self.boolFrom(self.root, pos);
          if (self.primary) |ppos| self.ctx.eh.NonDefinitionFlag(ppos);
          if (self.varargs) |vpos| self.ctx.eh.NonDefinitionFlag(vpos);
          if (self.varmap) |mpos| self.ctx.eh.NonDefinitionFlag(mpos);
        }
      }

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

  fn boolFrom(self: *SymbolDefs, pos: ?data.Position.Input, at: data.Position.Input) !*data.Node {
    const expr = try self.ctx.source_content.allocator.create(data.Expression);
    expr.pos = .{.input = pos orelse at};
    expr.data = .{
      .literal = .{
        .value = .{
          .origin = expr.pos,
          .data = .{
            .enumval = .{
              .t = self.ctx.getBoolean(),
              .index = if (pos) |_| 1 else 0,
            }
          }
        }
      }
    };
    const ret = try self.ctx.temp_nodes.allocator.create(data.Node);
    ret.data = .{
      .expression = expr,
    };
    ret.pos = expr.pos;
    return ret;
  }
};