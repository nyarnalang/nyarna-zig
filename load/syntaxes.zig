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
  names: std.ArrayListUnmanaged(*model.Node),
  primary: ?model.Position,
  varargs: ?model.Position,
  varmap: ?model.Position,
  mutable: ?model.Position,
  root: ?model.Position,
  header: ?*model.Value.BlockHeader,
  ltype: ?*model.Node,
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
    const alloc = &intpr.storage.allocator;
    const ret = try alloc.create(SymbolDefs);
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
    l.ltype = null;
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
            const name_node =
              try self.intpr.storage.allocator.create(model.Node);
            name_node.* = .{
              .pos = pos,
              .data = .{
                .literal = .{
                  .kind = .text,
                  .content = name,
                },
              },
            };
            try self.names.append(&self.intpr.storage.allocator, name_node);
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
            self.ltype = n;
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
    const ret = try self.intpr.storage.allocator.create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .concatenation = .{
          .content = self.produced.items,
        },
      },
    };
    return ret;
  }

  fn finishLine(self: *SymbolDefs, pos: model.Position) nyarna.Error!void {
    defer self.reset();
    if (self.names.items.len == 0) {
      self.logger().MissingSymbolName(pos);
      return;
    }
    if (self.ltype == null and self.expr == null) {
      if (self.variant == .locs)
        self.logger().MissingSymbolType(pos)
      else
        self.logger().MissingSymbolEntity(pos);
      return;
    }
    const line_pos = self.intpr.input.between(self.start, pos.end);

    const lexpr = try self.intpr.genPublicLiteral(line_pos, .{
      .@"type" = .{
        .t = .{
          .intrinsic = if (self.variant == .locs) .location else .definition
        },
      },
    });

    names_loop: for (self.names.items) |name| {
      const args = try self.intpr.storage.allocator.alloc(*model.Node,
          switch (self.variant) {.locs => @as(usize, 8), .defs => 3});
      args[0] = name;
      var additionals = switch (self.variant) {
        .locs => ptr: {
          args[1] = self.ltype orelse blk: {
            const vn = try self.intpr.storage.allocator.create(model.Node);
            vn.* = .{
              .pos = pos,
              .data = .voidNode,
            };
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
          const bhn = try self.intpr.storage.allocator.create(model.Node);
          bhn.* = if (self.header) |bh| .{
            .pos = bh.value().origin,
            .data = .{
              .expression = @fieldParentPtr(
                model.Expression.Literal, "value", bh.value()).expr(),
            },
          } else .{
            .pos = pos,
            .data = .voidNode,
          };
          additionals[4] = bhn;
          if (self.root) |rpos| self.logger().NonLocationFlag(rpos);
          additionals += 5;
        },
        .defs => {
          additionals[0] = try self.boolFrom(self.root, pos);
          if (self.primary) |ppos| self.logger().NonDefinitionFlag(ppos);
          if (self.varargs) |vpos| self.logger().NonDefinitionFlag(vpos);
          if (self.varmap) |mpos| self.logger().NonDefinitionFlag(mpos);
          if (self.mutable) |mpos| self.logger().NonDefinitionFlag(mpos);
          if (self.header) |bh|
            self.logger().BlockHeaderNotAllowedForDefinition(bh.value().origin);
          additionals += 1;
        }
      }
      additionals.* = self.expr orelse blk: {
        const vn = try self.intpr.storage.allocator.create(model.Node);
        vn.* = .{
          .pos = pos,
          .data = .voidNode,
        };
        break :blk vn;
      };

      const constructor = try self.intpr.storage.allocator.create(model.Node);
      constructor.* = .{
        .pos = line_pos,
        .data = .{
          .resolved_call = .{
            .ns = 0, // location constructor resides in the primary namespace.
            .target = lexpr,
            .args = args,
          },
        },
      };
      const interpreted =
        try self.intpr.tryInterpret(constructor, false, null);
      try self.produced.append(&self.intpr.storage.allocator, interpreted);
      if (interpreted.data == .poisonNode) break :names_loop;
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