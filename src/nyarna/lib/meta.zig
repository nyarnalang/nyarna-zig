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
    exclude : *model.Node,
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

    var excluded = std.StringHashMap(void).init(intpr.allocator());
    var excl_items = try intpr.node_gen.toVarargsItemList(exclude);
    const id_list = (
      try intpr.ctx.types().list(intpr.ctx.types().system.identifier)
    ).?;
    for (excl_items) |item| if (item.direct) {
      if (
        try intpr.associate(item.node, id_list.predef(), .{.kind = .keyword})
      ) |dir_expr| {
        const dir_value = try intpr.ctx.evaluator().evaluate(dir_expr);
        switch (dir_value.data) {
          .list => |*lst| for (lst.content.items) |list_item| {
            try excluded.put(list_item.data.text.content, .{});
          },
          .poison => {},
          else    => unreachable,
        }
      }
    } else if (
      try intpr.associate(
        item.node, intpr.ctx.types().system.identifier.predef(),
        .{.kind = .keyword})
    ) |item_expr| {
      const item_value = try intpr.ctx.evaluator().evaluate(item_expr);
      switch (item_value.data) {
        .text   => |*txt| try excluded.put(txt.content, .{}),
        .poison => {},
        else    => unreachable,
      }
    };

    const t = (try intpr.ctx.types().list(intpr.ctx.types().location())).?;
    const list = try intpr.ctx.values.list(pos, &t.structural.list);
    for (vt.structural.callable.locations) |loc| {
      if (
        !excluded.contains(loc.data.location.name.content)
      ) try list.content.append(loc);
    }
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