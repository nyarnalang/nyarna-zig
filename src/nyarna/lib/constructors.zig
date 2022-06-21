const std = @import("std");

const nyarna    = @import("../../nyarna.zig");
const system    = @import("system.zig");

const Context     = nyarna.Context;
const Evaluator   = nyarna.Evaluator;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

fn nodeToVarargsItemList(
  intpr: *Interpreter,
  node: *model.Node,
) ![]model.Node.Varargs.Item {
  return switch (node.data) {
    .varargs => |*va| va.content.items,
    else => blk: {
      const arr = try intpr.allocator().alloc(model.Node.Varargs.Item, 1);
      arr[0] = .{.direct = true, .node = node};
      break :blk arr;
    }
  };
}

pub const Types = lib.Provider.Wrapper(struct {

  pub fn @"Definition"(
    intpr: *Interpreter,
    pos  : model.Position,
    name : *model.Value.TextScalar,
    root : *model.Value.Enum,
    node : *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const expr = try intpr.interpret(node.root);
    var eval = intpr.ctx.evaluator();
    var val = try eval.evaluate(expr);
    switch (val.data) {
      .@"type", .funcref => {},
      .poison => return intpr.node_gen.poison(pos),
      else => {
        intpr.ctx.logger.EntityCannotBeNamed(val.origin);
        return intpr.node_gen.poison(pos);
      }
    }
    const def_val =
      try intpr.ctx.values.definition(pos, name, switch (val.data) {
        .@"type" => |tv| .{.@"type" = tv.t},
        .funcref => |fr| .{.func = fr.func},
        .poison  => return try intpr.node_gen.poison(pos),
        else => {
          intpr.ctx.logger.EntityCannotBeNamed(pos);
          return try intpr.node_gen.poison(pos);
        }
      }, val.origin);
    def_val.root = if (root.index == 1) root.value().origin else null;
    return intpr.genValueNode(def_val.value());
  }

  pub fn @"Enum"(
    eval : *Evaluator,
    pos  : model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return if (try eval.ctx.enumFrom(input.value().origin, input.content,
      &eval.target_type.named.data.@"enum")) |ev| ev.value()
    else try eval.ctx.values.poison(pos);
  }

  pub fn @"List"(
    _    : *Evaluator,
    pos  : model.Position,
    items: *model.Value.List,
  ) nyarna.Error!*model.Value {
    // implementation guarantees that items is a newly constructed list, even if
    // the value has been given via direct named argument.
    const ret = items.value();
    ret.origin = pos;
    return ret;
  }

  pub fn @"Location"(
    intpr  : *Interpreter,
    pos    : model.Position,
    name   : *model.Value.TextScalar,
    t      : ?*model.Value.TypeVal,
    primary: *model.Value.Enum,
    varargs: *model.Value.Enum,
    varmap : *model.Value.Enum,
    borrow : *model.Value.Enum,
    header : ?*model.Value.BlockHeader,
    default: ?*model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const default_expr = if (default) |node| (
      if (t) |given_type| (
        (
          try intpr.associate(
            node.root, given_type.t.at(given_type.value().origin),
            .{.kind = .final})
        ) orelse return intpr.node_gen.poison(pos)
      ) else try intpr.interpret(node.root)
    ) else null;

    const additionals = if (
      header != null or varargs.index == 1 or varmap.index == 1 or
      borrow.index == 1 or primary.index == 1
    ) blk: {
      const container =
        try intpr.ctx.global().create(model.Node.Location.Additionals);
      container.* = .{
        .primary = if (primary.index == 1) primary.value().origin else null,
        .varargs = if (varargs.index == 1) varargs.value().origin else null,
        .varmap  = if (varmap.index == 1)  varmap.value().origin  else null,
        .borrow  = if (borrow.index == 1)  borrow.value().origin  else null,
        .header  = header,
      };
      break :blk container;
    } else null;

    // just generate a location expression here, evaluating that will do all
    // necessary checks
    const expr = try intpr.ctx.global().create(model.Expression);
    expr.* = .{
      .pos = pos,
      .expected_type = intpr.ctx.types().location(),
      .data = .{.location = .{
        .name = try intpr.ctx.createValueExpr(name.value()),
        .@"type" =
          if (t) |tv| try intpr.ctx.createValueExpr(tv.value()) else null,
        .default = default_expr,
        .additionals = additionals,
      }},
    };
    return try intpr.node_gen.expression(expr);
  }

  pub fn @"Numeric"(
    eval : *Evaluator,
    pos  : model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return switch (eval.target_type.named.data) {
      .int => |*int| if (
        try eval.ctx.intFromText(input.value().origin, input.content, int)
      ) |nv| nv.value() else try eval.ctx.values.poison(pos),
      .float => |*fl| if (
        try eval.ctx.floatFromText(input.value().origin, input.content, fl)
      ) |nv| nv.value() else try eval.ctx.values.poison(pos),
      else => unreachable,
    };
  }

  pub fn @"Output"(
    intpr : *Interpreter,
    pos   : model.Position,
    name  : *model.Node,
    schema: ?*model.Node,
    body  : *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.output(pos, name, schema, body)).node();
  }

  pub fn @"SchemaDef"(
    intpr   : *Interpreter,
    pos     : model.Position,
    root    : *model.Node,
    public  : ?*model.Node,
    private : ?*model.Node,
    backends: ?*model.Node,
  ) nyarna.Error!*model.Node {
    // we generate the nodes into the global storage so that they survive the
    // finalization of current module's interpreter.
    const gen = model.NodeGenerator.init(intpr.ctx.global(), intpr.ctx);

    var collector = system.DefCollector{.dt = intpr.ctx.types().definition()};
    for ([_]?*model.Node{public, private}) |item| {
      if (item) |node| try collector.collect(node, intpr);
    }
    try collector.allocate(intpr.ctx.global());
    if (public)  |pnode| try collector.append(pnode, intpr, true, gen);
    if (private) |pnode| try collector.append(pnode, intpr, false, gen);
    var defs = collector.finish();

    var doc_var: ?model.Node.Capture.VarDef = null;
    var backend_defs: []*model.Node.Definition = if (backends) |bnode| blk: {
      var content = switch (bnode.data) {
        .capture => |*cap| cblk: {
          if (cap.val) |val| {
            doc_var = model.Node.Capture.VarDef{
              .ns   = val.ns,
              .name = try intpr.ctx.global().dupe(u8, val.name),
              .pos  = val.pos,
            };
          }
          inline for (.{.key, .index}) |f| if (@field(cap, @tagName(f))) |v| {
            intpr.ctx.logger.UnexpectedBlockVar(v.pos, @tagName(f));
          };
          break :cblk cap.content;
        },
        else => bnode,
      };

      collector = system.DefCollector{.dt = intpr.ctx.types().definition()};
      try collector.collect(content, intpr);
      try collector.allocate(intpr.ctx.global());
      try collector.append(content, intpr, false, gen);
      break :blk collector.finish();
    } else &.{};

    const val = try intpr.ctx.values.schemaDef(
      pos, defs, try gen.copy(root), backend_defs, doc_var);
    return try intpr.genValueNode(val.value());
  }

  pub fn @"Textual"(
    eval : *Evaluator,
    pos  : model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return if (try eval.ctx.textFromString(input.value().origin, input.content,
      &eval.target_type.named.data.textual)) |nv| nv.value()
    else try eval.ctx.values.poison(pos);
  }

  pub fn @"Void"(
    eval: *Evaluator,
    pos : model.Position,
  ) nyarna.Error!*model.Value {
    return try eval.ctx.values.@"void"(pos);
  }
});

pub const types = Types.init();

pub const Prototypes = lib.Provider.Wrapper(struct {
  pub fn @"Concat"(
    intpr: *Interpreter,
    pos  : model.Position,
    inner: *model.Node,
  ) nyarna.Error!*model.Node {
    return if (switch (inner.data) {
      .void => blk: {
        intpr.ctx.logger.MissingParameterArgument(
          "inner", pos, model.Position.intrinsic());
        break :blk true;
      },
      .poison => true,
      else => false,
    }) intpr.node_gen.poison(pos) else (
      try intpr.node_gen.tgConcat(pos, inner)
    ).node();
  }

  pub fn @"Enum"(
    intpr : *Interpreter,
    pos   : model.Position,
    values: *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgEnum(
      pos, try nodeToVarargsItemList(intpr, values))).node();
  }

  pub fn @"Intersection"(
    intpr      : *Interpreter,
    pos        : model.Position,
    input_types: *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgIntersection(
      pos, try nodeToVarargsItemList(intpr, input_types))).node();
  }

  pub fn @"List"(
    intpr: *Interpreter,
    pos  : model.Position,
    inner: *model.Node,
  ) nyarna.Error!*model.Node {
    return if (switch (inner.data) {
      .void => blk: {
        intpr.ctx.logger.MissingParameterArgument(
          "inner", pos, model.Position.intrinsic());
        break :blk true;
      },
      .poison => true,
      else => false,
    }) intpr.node_gen.poison(pos) else (
      try intpr.node_gen.tgList(pos, inner)).node();
  }

  pub fn @"HashMap"(
    intpr: *Interpreter,
    pos  : model.Position,
    key  : *model.Node,
    value: *model.Node,
  ) nyarna.Error!*model.Node {
    var invalid = switch (key.data) {
      .void => blk: {
        intpr.ctx.logger.MissingParameterArgument(
          "key", pos, model.Position.intrinsic());
        break :blk true;
      },
      .poison => true,
      else => false
    };
    switch (value.data) {
      .void => {
        intpr.ctx.logger.MissingParameterArgument(
          "value", pos, model.Position.intrinsic());
        invalid = true;
      },
      .poison => invalid = true,
      else => {}
    }
    return if (invalid) intpr.node_gen.poison(pos)
    else (try intpr.node_gen.tgHashMap(pos, key,value)).node();
  }

  pub fn @"Numeric"(
    intpr   : *Interpreter,
    pos     : model.Position,
    backend : *model.Node,
    min     : ?*model.Node,
    max     : ?*model.Node,
    suffixes: *model.Node,
  ) nyarna.Error!*model.Node {
    const expr = try intpr.interpret(suffixes);
    const value = try intpr.ctx.evaluator().evaluate(expr);
    switch (value.data) {
      .hashmap => |*m| {
        return (
          try intpr.node_gen.tgNumeric(pos, backend, min, max, m)
        ).node();
      },
      .poison => return try intpr.node_gen.poison(pos),
      else => unreachable,
    }
  }

  pub fn @"Optional"(
    intpr: *Interpreter,
    pos  : model.Position,
    inner: *model.Node,
  ) nyarna.Error!*model.Node {
    return if (switch (inner.data) {
      .void => blk: {
        intpr.ctx.logger.MissingParameterArgument(
          "inner", pos, model.Position.intrinsic());
        break :blk true;
      },
      .poison => true,
      else => false
    }) intpr.node_gen.poison(pos) else
      (try intpr.node_gen.tgOptional(pos, inner)).node();
  }

  pub fn @"Record"(
    intpr : *Interpreter,
    pos   : model.Position,
    fields: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const fnode = fields orelse try (intpr.node_gen.void(pos));
    return (try intpr.node_gen.tgRecord(pos, fnode)).node();
  }

  pub fn @"Sequence"(
    intpr : *Interpreter,
    pos   : model.Position,
    inner : *model.Node,
    direct: ?*model.Node,
    auto  : ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgSequence(
      pos, direct, try nodeToVarargsItemList(intpr, inner), auto)).node();
  }

  pub fn @"Textual"(
    intpr  : *Interpreter,
    pos    : model.Position,
    cats   : *model.Node,
    include: ?*model.Node,
    exclude: ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgTextual(
      pos, try nodeToVarargsItemList(intpr, cats), include, exclude)).node();
  }
});

pub const prototypes = Prototypes.init();