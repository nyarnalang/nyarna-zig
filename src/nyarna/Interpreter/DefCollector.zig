//! DefCollector collects definition nodes from a varargs List<Ast> input.

const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

count: usize = 0,
defs : []*model.Node.Definition = undefined,
dt   : model.Type,

pub fn collect(self: *@This(), node: *model.Node, intpr: *Interpreter) !void {
  switch (node.data) {
    .void, .poison => {},
    .definition => self.count += 1,
    .concat => |*con| self.count += con.items.len,
    else => {
      const expr = (
        try intpr.associate(node, (
          try intpr.ctx.types().concat(self.dt)
        ).?.predef(), .{.kind = .keyword})
      ) orelse {
        node.data = .void;
        return;
      };
      const value = try intpr.ctx.evaluator().evaluate(expr);
      if (value.data == .poison) {
        node.data = .poison;
        return;
      }
      self.count += value.data.concat.content.items.len;
      expr.data = .{.value = value};
      node.data = .{.expression = expr};
    }
  }
}

pub fn allocate(self: *@This(), allocator: std.mem.Allocator) !void {
  self.defs = try allocator.alloc(*model.Node.Definition, self.count);
  self.count = 0;
}

pub fn checkName(
  self    : *@This(),
  name    : []const u8,
  name_pos: model.Position,
  ctx     : nyarna.Context,
) bool {
  var i: usize = 0; while (i < self.count) : (i += 1) {
    if (std.mem.eql(u8, self.defs[i].name.content, name)) {
      ctx.logger.DuplicateSymbolName(
        name, name_pos, self.defs[i].name.node().pos);
      return false;
    }
  }
  return true;
}

fn asNode(
  intpr: *Interpreter,
  gen  : model.NodeGenerator,
  def  : *model.Node.Definition,
) !*model.Node.Definition {
  if (gen.allocator.ptr == intpr.allocator().ptr) return def;
  return &(try gen.copy(def.node())).data.definition;
}

fn appendValue(
  self : *@This(),
  value: *model.Value,
  ctx  : nyarna.Context,
  pdef : bool,
  gen  : model.NodeGenerator,
) nyarna.Error!void {
  switch (value.data) {
    .concat => |*con| for (con.content.items) |item| {
      try self.appendValue(item, ctx, pdef, gen);
    },
    .definition => |*def| {
      if (
        self.checkName(
          def.name.content, def.name.value().origin, ctx)
      ) {
        const content_value = switch (def.content) {
          .func => |f|
            (try ctx.values.funcRef(def.value().origin, f)).value(),
          .@"type" => |t|
            (try ctx.values.@"type"(def.value().origin, t)).value(),
        };
        const def_node = try gen.definition(def.value().origin, .{
          .name = try gen.literal(
            def.name.value().origin, .text, def.name.content),
          .content = try gen.expression(
            try ctx.createValueExpr(content_value)
          ),
          .merge  = def.merge,
          .public = pdef,
        });
        self.defs[self.count] = def_node;
        self.count += 1;
      }
    },
    .poison => {},
    else => {
      ctx.logger.ExpectedExprOfTypeXGotY(&.{
        try ctx.types().valueSpecType(value),
        ctx.types().definition().predef(),
      });
    },
  }
}

pub fn append(
  self : *@This(),
  node : *model.Node,
  intpr: *Interpreter,
  pdef : bool,
  gen  : model.NodeGenerator,
) nyarna.Error!void {
  switch (node.data) {
    .void, .poison => {},
    .definition => |*def| {
      if (self.checkName(def.name.content, def.name.node().pos, intpr.ctx)) {
        if (pdef) def.public = true;
        self.defs[self.count] = try asNode(intpr, gen, def);
        self.count += 1;
      }
    },
    .concat => |*con| for (con.items) |item| {
      try self.append(item, intpr, pdef, gen);
    },
    .expression => |expr| {
      const value = try intpr.ctx.evaluator().evaluate(expr);
      try self.appendValue(value, intpr.ctx, pdef, gen);
    },
    else => {
      const expr = try intpr.interpret(node);
      node.data = .{.expression = expr};
      try self.appendValue(
        try intpr.ctx.evaluator().evaluate(expr), intpr.ctx, pdef, gen);
    },
  }
}

pub fn finish(self: *@This()) []*model.Node.Definition {
  return self.defs[0..self.count];
}