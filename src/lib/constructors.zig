const std = @import("std");
const lib = @import("../lib.zig");
const nyarna = @import("../nyarna.zig");
const interpret = @import("../interpret.zig");
const Interpreter = interpret.Interpreter;
const Context = nyarna.Context;
const Evaluator = @import("../runtime.zig").Evaluator;
const model = nyarna.model;
const types = nyarna.types;

pub const Types = lib.Provider.Wrapper(struct {
  pub fn @"Raw"(
    _: *Evaluator,
    _: model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return input.value();
  }

  pub fn @"Location"(
    intpr: *Interpreter,
    pos: model.Position,
    name: *model.Value.TextScalar,
    t: ?model.Type,
    primary: *model.Value.Enum,
    varargs: *model.Value.Enum,
    varmap: *model.Value.Enum,
    mutable: *model.Value.Enum,
    header: ?*model.Value.BlockHeader,
    default: ?*model.Value.Ast,
  ) nyarna.Error!*model.Node {
    var expr = if (default) |node| blk: {
      var val = try intpr.interpret(node.root);
      if (val.expected_type.isInst(.poison)) return intpr.node_gen.poison(pos);
      if (t) |given_type| {
        if (
          !intpr.ctx.types().lesserEqual(val.expected_type, given_type) and
          !val.expected_type.isInst(.poison)
        ) {
          intpr.ctx.logger.ExpectedExprOfTypeXGotY(
            val.pos, &[_]model.Type{given_type, val.expected_type});
          return intpr.node_gen.poison(pos);
        }
      }
      break :blk val;
    } else null;
    var ltype = if (t) |given_type| given_type
                else if (expr) |given_expr| given_expr.expected_type else {
      unreachable; // TODO: evaluation error
    };
    // TODO: check various things here:
    // - varargs must have List type
    // - varmap must have Map type
    // - mutable must have non-virtual type
    // - special syntax in block config must yield expected type (?)
    if (varmap.index == 1) {
      if (varargs.index == 1) {
        intpr.ctx.logger.IncompatibleFlag("varmap",
          varmap.value().origin, varargs.value().origin);
        return intpr.node_gen.poison(pos);
      } else if (mutable.index == 1) {
        intpr.ctx.logger.IncompatibleFlag("varmap",
          varmap.value().origin, mutable.value().origin);
        return intpr.node_gen.poison(pos);
      }
    } else if (varargs.index == 1) if (mutable.index == 1) {
      intpr.ctx.logger.IncompatibleFlag("mutable",
        mutable.value().origin, varargs.value().origin);
      return intpr.node_gen.poison(pos);
    };

    const loc_val = try intpr.ctx.values.location(pos, name, ltype);
    loc_val.default = expr;
    loc_val.primary = if (primary.index == 1) primary.value().origin else null;
    loc_val.varargs = if (varargs.index == 1) varargs.value().origin else null;
    loc_val.varmap  = if (varmap.index  == 1)  varmap.value().origin else null;
    loc_val.mutable = if (mutable.index == 1) mutable.value().origin else null;
    loc_val.header = header;
    return intpr.genValueNode(loc_val.value());
  }

  pub fn @"Definition"(
    intpr: *Interpreter,
    pos: model.Position,
    name: *model.Value.TextScalar,
    root: *model.Value.Enum,
    node: *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const expr = try intpr.interpret(node.root);
    if (expr.expected_type.isInst(.poison)) {
      return intpr.genValueNode(try intpr.ctx.values.poison(pos));
    }
    var eval = intpr.ctx.evaluator();
    var val = try eval.evaluate(expr);
    std.debug.assert(val.data == .@"type" or val.data == .funcref); // TODO
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

  pub fn @"Textual"(
    eval: *Evaluator,
    pos: model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    _ = eval; _ = pos; _ = input;
    unreachable; // TODO
  }

  pub fn @"Numeric"(
    eval: *Evaluator,
    pos: model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return if (try eval.ctx.numberFrom(input.value().origin, input.content,
      &eval.target_type.instantiated.data.numeric)) |nv| nv.value()
    else try eval.ctx.values.poison(pos);
  }

  pub fn @"Float"(
    eval: *Evaluator,
    pos: model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    _ = eval; _ = pos; _ = input;
    unreachable; // TODO
  }

  pub fn @"Enum"(
    eval: *Evaluator,
    pos: model.Position,
    input: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return if (try eval.ctx.enumFrom(input.value().origin, input.content,
      &eval.target_type.instantiated.data.tenum)) |ev| ev.value()
    else try eval.ctx.values.poison(pos);
  }
});

pub const Prototypes = lib.Provider.Wrapper(struct {
  pub fn @"Optional"(
    intpr: *Interpreter,
    pos: model.Position,
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

  pub fn @"Concat"(
    intpr: *Interpreter,
    pos: model.Position,
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
    }) intpr.node_gen.poison(pos) else
      (try intpr.node_gen.tgConcat(pos, inner)).node();
  }

  pub fn @"List"(
    intpr: *Interpreter,
    pos: model.Position,
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

  pub fn @"Paragraphs"(
    intpr: *Interpreter,
    pos: model.Position,
    inners: []*model.Node,
    auto: ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgParagraphs(pos, inners, auto)).node();
  }

  pub fn @"Map"(
    intpr: *Interpreter,
    pos: model.Position,
    key: *model.Node,
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
    else (try intpr.node_gen.tgMap(pos, key,value)).node();
  }

  pub fn @"Record"(
    intpr: *Interpreter,
    pos: model.Position,
    fields: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const fnode = fields orelse try (intpr.node_gen.void(pos));
    return (try intpr.node_gen.tgRecord(pos, fnode)).node();
  }

  pub fn @"Intersection"(
    intpr: *Interpreter,
    pos: model.Position,
    input_types: *model.Node,
  ) nyarna.Error!*model.Node {
    const given_types = switch (input_types.data) {
      .varargs => |*va| va.content.items,
      else => blk: {
        const arr = try intpr.allocator.alloc(model.Node.Varargs.Item, 1);
        arr[0] = .{.direct = true, .node = input_types};
        break :blk arr;
      }
    };
    return (try intpr.node_gen.tgIntersection(pos, given_types)).node();
  }

  pub fn @"Textual"(
    intpr: *Interpreter,
    pos: model.Position,
    cats: []*model.Node,
    include: *model.Node,
    exclude: *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgTextual(pos, cats, include, exclude)).node();
  }

  pub fn @"Numeric"(
    intpr: *Interpreter,
    pos: model.Position,
    min: ?*model.Node,
    max: ?*model.Node,
    decimals: ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgNumeric(pos, min, max, decimals)).node();
  }

  pub fn @"Float"(
    intpr: *Interpreter,
    pos: model.Position,
    precision: *model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgFloat(pos, precision)).node();
  }

  pub fn @"Enum"(
    intpr: *Interpreter,
    pos: model.Position,
    values: []*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgEnum(pos, values)).node();
  }
});