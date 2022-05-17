//! Builds Match expressions

const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model = nyarna.model;

match: *model.Expression.Match,
intpr: *nyarna.Interpreter,

pub fn init(intpr: *nyarna.Interpreter, pos: model.Position) !@This() {
  const expr = try intpr.ctx.global().create(model.Expression);
  expr.* = .{
    .pos  = pos,
    .data = .{.match = .{
      .cases = .{},
      .subject = undefined,
    }},
    .expected_type = undefined,
  };
  return @This(){
    .match = &expr.data.match,
    .intpr = intpr,
  };
}

inline fn types(self: *@This()) *nyarna.Types {
  return self.intpr.ctx.types();
}

pub fn push(self: *@This(), t: model.SpecType, expr: *model.Expression) !void {
  var iter = self.match.cases.iterator();
  while (iter.next()) |item| {
    if (
      self.types().lesserEqual(t.t, item.key_ptr.t) or
      self.types().greater(t.t, item.key_ptr.t)
    ) {
      self.intpr.ctx.logger.TypesNotDisjoint(&.{t, item.key_ptr.*});
      return;
    } else if (item.key_ptr.t.isScalar() and t.t.isScalar()) {
      self.intpr.ctx.logger.MultipleScalarTypes(&.{t, item.key_ptr.*});
      return;
    }
  }
  try self.match.cases.putNoClobber(self.intpr.ctx.global(), t, expr);
}

pub fn finalize(self: *@This(), subject: *model.Node) !*model.Expression {
  var in_type = self.types().every();
  var out_type = self.types().every();
  var iter = self.match.cases.iterator();
  var seen_poison = false;
  while (iter.next()) |item| {
    const new_in = try self.types().sup(in_type, item.key_ptr.t);
    if (new_in.isNamed(.poison)) {
      self.intpr.ctx.logger.IncompatibleTypes(
        &.{item.key_ptr.*, in_type.at(self.match.expr().pos)});
      seen_poison = true;
    } else {
      in_type = new_in;
    }
    const new_out =
      try self.types().sup(out_type, item.value_ptr.*.expected_type);
    if (new_out.isNamed(.poison)) {
      self.intpr.ctx.logger.IncompatibleTypes(
        &.{item.value_ptr.*.expected_type.at(item.value_ptr.*.pos),
           out_type.at(self.match.expr().pos)});
      seen_poison = true;
    } else {
      out_type = new_out;
    }
  }
  if (!seen_poison) {
    if (
      try self.intpr.associate(
        subject, in_type.at(self.match.expr().pos), .{.kind = .final})
    ) |expr| {
      self.match.subject = expr;
    } else {
      seen_poison = true;
    }
  }

  const expr = self.match.expr();
  if (seen_poison) {
    expr.data = .poison;
    expr.expected_type = self.types().poison();
  } else {
    expr.expected_type = out_type;
  }
  return expr;
}