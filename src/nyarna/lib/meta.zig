const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

pub const Impl = lib.Provider.Wrapper(struct {
  //---------
  // keywords
  //---------

  pub fn params(
    intpr   : *Interpreter,
    pos     : model.Position,
    callable: *model.Node,
  ) nyarna.Error!*model.Node {
    const expr = (
      try intpr.tryInterpret(callable, .{.kind = .keyword})
    ) orelse return try intpr.node_gen.poison(pos);
    const value = try intpr.ctx.evaluator().evaluate(expr);
    const vt = try intpr.ctx.types().valueType(value);
    if (vt.isNamed(.poison)) return intpr.node_gen.poison(pos);
    if (!vt.isStruc(.callable)) {
      intpr.ctx.logger.HasNoParameters(&.{vt.at(pos)});
      return try intpr.node_gen.poison(pos);
    }
    const t = (try intpr.ctx.types().list(intpr.ctx.types().location())).?;
    const list = try intpr.ctx.values.list(pos, &t.structural.list);
    for (vt.structural.callable.locations) |loc| try list.content.append(loc);
    return try intpr.genValueNode(list.value());
  }

  pub fn access(
    intpr  : *Interpreter,
    pos    : model.Position,
    subject: *model.Node,
    name   : *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.uAccess(pos, subject, name, 0)).node();
  }
});

pub const instance = Impl.init();