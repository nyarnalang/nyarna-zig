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

pub const Locations = struct {
  const State = enum {
    initial, names, after_name, ltype, after_ltype, flags, after_flag, after_flags, default, at_end
  };

  ctx: *Context,
  proc: SpecialSyntax.Processor,
  state: State,
  produced: std.ArrayListUnmanaged(*data.Node),
  // ----- current line ------
  start: data.Cursor,
  names: std.ArrayListUnmanaged(*data.Node),
  primary: ?data.Position.Input,
  varargs: ?data.Position.Input,
  varmap: ?data.Position.Input,
  ltype: ?*data.Node,
  default: ?*data.Node,
  // -------------------------


  pub fn syntax() SpecialSyntax {
    return .{
      .init = Locations.init,
      .comments_include_newline = false,
    };
  }

  fn init(ctx: *Context) std.mem.Allocator.Error!*SpecialSyntax.Processor {
    const alloc = &ctx.temp_nodes.allocator;
    const ret = try alloc.create(Locations);
    ret.ctx = ctx;
    ret.proc = .{
      .push = Locations.push,
      .finish = Locations.finish,
    };
    ret.state = .initial;
    ret.names = .{};
    ret.produced = .{};
    ret.reset();
    return &ret.proc;
  }

  fn reset(l: *Locations) void {
    l.primary = null;
    l.varargs = null;
    l.varmap = null;
    l.ltype = null;
    l.default = null;
    l.names.clearRetainingCapacity();
  }

  fn push(p: *SpecialSyntax.Processor, pos: data.Position.Input,
          item: SpecialSyntax.Item) std.mem.Allocator.Error!void {
    const self = @fieldParentPtr(Locations, "proc", p);
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
            ':', '=', '{' => {
              self.ctx.eh.MissingToken(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.token = .identifier}},
                  .{.character = c});
              self.state = .after_name;
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
            self.ctx.eh.MissingToken(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = ':'}, .{.character = '{'}, .{.character = '='}
                }, .{.token = .identifier});
            self.state = .names;
          },
          .escaped => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{
                  .{.character = ','}, .{.character = ':'}, .{.character = '{'}, .{.character = '='}
                }, .{.token = .escape});
            return;
          },
          .special_char => |c| switch (c) {
            ',' => break .names,
            ':' => break .ltype,
            '{' => break .flags,
            '=' => break .default,
            ';' => self.state = .at_end,
            else => {
              self.ctx.eh.IllegalItem(pos,
                  &[_]errors.WrongItemError.ItemDescr{.{.character = ','},
                    .{.character = '{'}, .{.character = ':'}, .{.character = '='}},
                  .{.character = c});
              return;
            },
          },
          .node => {
            self.ctx.eh.IllegalItem(pos,
                &[_]errors.WrongItemError.ItemDescr{.{.character = ','},
                  .{.character = '{'}, .{.character = ':'}, .{.character = '='}},
                .node);
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
            '=' => break .default,
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
            '=' => break .default,
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
        .default => switch(item) {
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
            self.default = n;
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
    const self = @fieldParentPtr(Locations, "proc", p);
    const ret = try self.ctx.temp_nodes.allocator.create(data.Node);
    ret.pos = .{.input = pos};
    ret.data = .{
      .concatenation = .{
        .content = self.produced.items,
      }
    };
    return ret;
  }

  fn finishLine(self: *Locations, pos: data.Position.Input) !void {
    defer self.reset();
    if (self.names.items.len == 0) {
      self.ctx.eh.MissingSymbolName(pos);
      return;
    }
    if (self.ltype == null and self.default == null) {
      self.ctx.eh.MissingSymbolType(pos);
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
              .intrinsic = .location
            }
          }
        }
      }
    };

    for (self.names.items) |name| {
      const args = try self.ctx.temp_nodes.allocator.alloc(*data.Node, 6);
      args[0] = name;
      args[1] = self.ltype orelse blk: {
        const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
        vn.pos = .{.input = pos};
        vn.data = .voidNode;
        break :blk vn;
      };
      args[2] = self.default orelse blk: {
        const vn = try self.ctx.temp_nodes.allocator.create(data.Node);
        vn.pos = .{.input = pos};
        vn.data = .voidNode;
        break :blk vn;
      };
      args[3] = try self.boolFrom(self.primary, pos);
      args[4] = try self.boolFrom(self.varargs, pos);
      args[5] = try self.boolFrom(self.varmap, pos);
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

  fn boolFrom(self: *Locations, pos: ?data.Position.Input, at: data.Position.Input) !*data.Node {
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