//! VarProcessor collects variable definitions from vargs List<Ast> locations.
//! For each such variable, it establishes a variable symbol in the given
//! namespace and returns an assignment node that sets the variable's initial
//! value.

const nyarna = @import("../../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

ip         : *Interpreter,
keyword_pos: model.Position,
concat_loc : model.Type,
ac         : *Interpreter.ActiveVarContainer,
namespace  : *Interpreter.Namespace,
ns_index   : u15,

const last = @import("../helpers.zig").last;

pub fn init(
  ip         : *Interpreter,
  index      : u15,
  keyword_pos: model.Position,
) !@This() {
  return @This(){
    .ip = ip,
    .keyword_pos = keyword_pos,
    .concat_loc =
      (try ip.ctx.types().concat(ip.ctx.types().location())).?,
    .ac = last(ip.var_containers.items),
    .namespace = ip.namespace(index),
    .ns_index = index,
  };
}

fn empty(self: @This()) !*model.Node {
  return try self.ip.node_gen.void(self.keyword_pos);
}

pub fn node(self: @This(), n: *model.Node) nyarna.Error!*model.Node {
  switch (n.data) {
    .location => |*loc| {
      const name_expr = (
        try self.ip.associate(loc.name,
          self.ip.ctx.types().literal().predef(), .{.kind = .keyword})
      ) orelse return try self.empty();
      loc.name.data = .{.expression = name_expr};
      const name = switch (
        (try self.ip.ctx.evaluator().evaluate(name_expr)).data
      ) {
        .text   => |*txt| txt.content,
        .poison => return try self.empty(),
        else => unreachable,
      };

      const spec: model.SpecType = if (loc.@"type") |tnode| blk: {
        const expr = (try self.ip.associate(
          tnode, self.ip.ctx.types().@"type"().predef(),
          .{.kind = .keyword}
        )) orelse return self.empty();
        const val = try self.ip.ctx.evaluator().evaluate(expr);
        switch (val.data) {
          .poison => return try self.empty(),
          .@"type" => |*tv| break :blk tv.t.at(val.origin),
          else => unreachable,
        }
      } else if (
        try self.ip.probeType(
          loc.default.?, .{.kind = .intermediate}, false)
      ) |t| t.at(loc.default.?.pos)
      else self.ip.ctx.types().every().predef();
      return try self.variable(loc.name.pos, spec, name,
        loc.default orelse (try self.defaultValue(spec.t, n.pos)) orelse {
          self.ip.ctx.logger.MissingInitialValue(loc.name.pos);
          return try self.empty();
        });
    },
    .concat => |*con| {
      const items =
        try self.ip.allocator().alloc(*model.Node, con.items.len);
      for (con.items) |item, index| items[index] = try self.node(item);
      return (try self.ip.node_gen.concat(self.keyword_pos, items)).node();
    },
    .expression => |expr| return self.expression(expr),
    .poison, .void => return try self.empty(),
    else => {
      const expr = (
        try self.ip.tryInterpret(n, .{.kind = .keyword})
      ) orelse return self.empty();
      return self.expression(expr);
    }
  }
}

pub fn expression(
  self: @This(),
  expr: *model.Expression,
) nyarna.Error!*model.Node {
  if (expr.data == .poison) return try self.empty();
  if (!self.ip.ctx.types().lesserEqual(
      expr.expected_type, self.concat_loc)) {
    self.ip.ctx.logger.ExpectedExprOfTypeXGotY(&[_]model.SpecType{
      expr.expected_type.at(expr.pos), self.concat_loc.predef(),
    });
    return try self.empty();
  }
  expr.expected_type = self.concat_loc;
  const val = try self.ip.ctx.evaluator().evaluate(expr);
  return try self.value(val);
}

pub fn value(self: @This(), val: *model.Value) !*model.Node {
  switch (val.data) {
    .poison => return try self.empty(),
    .concat => |*con| {
      const items =
        try self.ip.allocator().alloc(*model.Node, con.content.items.len);
      for (con.content.items) |item, index| {
        const loc = &item.data.location;
        const initial = if (loc.default) |expr|
          try self.ip.node_gen.expression(expr)
        else (try self.defaultValue(
            loc.spec.t, item.origin)) orelse {
          self.ip.ctx.logger.MissingInitialValue(loc.name.value().origin);
          items[index] =
            try self.ip.node_gen.void(loc.name.value().origin);
          continue;
        };
        items[index] = try self.variable(
          loc.name.value().origin, loc.spec, loc.name.content, initial);
      }
      return (try self.ip.node_gen.concat(self.keyword_pos, items)).node();
    },
    else => unreachable,
  }
}

fn variable(
  self    : @This(),
  name_pos: model.Position,
  spec    : model.SpecType,
  name    : []const u8,
  initial : *model.Node,
) !*model.Node {
  const sym = try self.ip.ctx.global().create(model.Symbol);
  const offset = @intCast(u15, self.ip.symbols.items.len - self.ac.offset);
  sym.* = .{
    .defined_at = name_pos,
    .name       = name,
    .data       = .{.variable = .{
      .spec       = spec,
      .container  = self.ac.container,
      .offset     = offset,
      .kind       = .assignable,
    }},
    .parent_type = null,
  };
  if (try self.namespace.tryRegister(self.ip, sym)) {
    if (offset + 1 > self.ac.container.num_values) {
      self.ac.container.num_values = offset + 1;
    }
    const replacement = if (spec.t.isNamed(.every))
      // t being .every means that it depends on the initial expression,
      // and that expression can't be interpreted right now. This commonly
      // happens if an argument value is assigned (argument variables are
      // established after a function body has been read in). To
      // accomodate for that, we create a variable but with „every“ type.
      // references to this variable mustn't be resolved until the type
      // has been update. Updating the type happens by using the special
      // VarTypeSetter node, which we create here for the initial
      // assignment.
      try self.ip.node_gen.vtSetter(&sym.data.variable, initial)
    else initial;
    return (try self.ip.node_gen.assign(initial.pos, .{
      .target = .{.resolved = .{
        .target = &sym.data.variable,
        .path = &.{},
        .spec = spec,
        .pos = initial.pos,
      }},
      .replacement = replacement,
    })).node();
  } else return try self.empty();
}

fn defaultValue(
  self: @This(),
  t   : model.Type,
  vpos: model.Position,
) !?*model.Node {
  return switch (t) {
    .structural => |strct| switch (strct.*) {
      .concat, .optional, .sequence => try self.ip.node_gen.void(vpos),
      .hashmap => |*hm| try self.ip.genValueNode(
        (try self.ip.ctx.values.hashMap(vpos, hm)).value()
      ),
      .list => |*lst| try self.ip.genValueNode(
        (try self.ip.ctx.values.list(vpos, lst)).value()
      ),
      .callable, .intersection => null,
    },
    .named => |named| switch (named.data) {
      .textual, .space, .literal => (
        try self.ip.node_gen.literal(vpos, .space, "")
      ).node(),
      .int => |*int| {
        const val: i64 = if (int.min <= 0)
          if (int.max >= 0) 0 else int.max
        else int.min;
        const ival = try self.ip.ctx.values.int(vpos, int, val, 0);
        return try self.ip.genValueNode(ival.value());
      },
      .float => |*fl| {
        const val: f64 = if (fl.min <= 0)
          if (fl.max >= 0) 0 else fl.max
        else fl.min;
        const fval = try self.ip.ctx.values.float(vpos, fl, val, 0);
        return try self.ip.genValueNode(fval.value());
      },
      .@"enum" => |*en| {
        const eval = try self.ip.ctx.values.@"enum"(vpos, en, 0);
        return try self.ip.genValueNode(eval.value());
      },
      .record => null,
      .ast, .frame_root, .void, .every =>
        try self.ip.node_gen.void(vpos),
      else => return null,
    },
  };
}