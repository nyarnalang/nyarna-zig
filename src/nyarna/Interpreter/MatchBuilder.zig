//! Builds Match expressions

const std = @import("std");

const IntersectionChecker = @import("IntersectionChecker.zig");
const nyarna              = @import("../../nyarna.zig");

const model = nyarna.model;
const Types = nyarna.Types;

match  : *model.Expression.Match,
intpr  : *nyarna.Interpreter,
builder: Types.IntersectionBuilder,
checker: IntersectionChecker,

pub fn init(
  intpr    : *nyarna.Interpreter,
  pos      : model.Position,
  num_cases: usize,
) !@This() {
  const expr = try intpr.ctx.global().create(model.Expression);
  expr.* = .{
    .pos  = pos,
    .data = .{.match = .{
      .cases   = .{},
      .subject = undefined,
    }},
    .expected_type = undefined,
  };
  return @This(){
    .match   = &expr.data.match,
    .intpr   = intpr,
    .builder =
      try Types.IntersectionBuilder.init(num_cases, intpr.ctx.global()),
    .checker = IntersectionChecker.init(intpr, true),
  };
}

inline fn types(self: *@This()) *nyarna.Types {
  return self.intpr.ctx.types();
}

pub fn push(
  self     : *@This(),
  t        : *const model.Type,
  pos      : model.Position,
  expr     : *model.Expression,
  container: *model.VariableContainer,
  has_var  : bool,
) !void {
  if (try self.checker.push(&self.builder, t, pos)) {
    try self.match.cases.putNoClobber(self.intpr.ctx.global(), t.at(pos), .{
      .expr      = expr,
      .container = container,
      .has_var   = has_var,
    });
  }
}

pub fn finalize(
  self: *@This(),
  subject: *model.Expression,
) !*model.Expression {
  var out_type = self.types().every();
  var iter = self.match.cases.iterator();
  var seen_poison = false;
  while (iter.next()) |item| {
    const new_out =
      try self.types().sup(out_type, item.value_ptr.expr.expected_type);
    if (new_out.isNamed(.poison)) {
      self.intpr.ctx.logger.IncompatibleTypes(
        &.{item.value_ptr.expr.expected_type.at(item.value_ptr.expr.pos),
           out_type.at(self.match.expr().pos)});
      seen_poison = true;
    } else {
      out_type = new_out;
    }
  }

  const expr = self.match.expr();
  if (seen_poison) {
    expr.data = .poison;
    expr.expected_type = self.types().poison();
  } else {
    self.match.subject = subject;
    expr.expected_type = out_type;
  }
  return expr;
}