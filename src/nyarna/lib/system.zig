const std = @import("std");

const CycleResolution = @import("../Interpreter/CycleResolution.zig");
const DefCollector    = @import("../Interpreter/DefCollector.zig");
const Globals         = @import("../Globals.zig");
const nyarna          = @import("../../nyarna.zig");
const Resolver        = @import("../Interpreter/Resolver.zig");
const VarProcessor    = @import("../Interpreter/VarProcessor.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

const last        = @import("../helpers.zig").last;
const stringOrder = @import("../helpers.zig").stringOrder;

const Comparer = union(enum) {
  floats: struct {left: f64, right: f64},
  ints  : struct {left: i64, right: i64},

  fn init(left: *model.Value, right: *model.Value) Comparer {
    switch (left.data) {
      .float => |lf| switch (right.data) {
        .float => |rf|
          return .{.floats = .{.left = lf.content, .right = rf.content}},
        .int => |ri|
          return .{.floats = .{
            .left  = lf.content,
            .right = @intToFloat(f64, ri.content) /
                     @intToFloat(f64, ri.t.suffixes[ri.cur_unit].factor),
          }},
        else => unreachable,
      },
      .int => |li| switch (right.data) {
        .float => |rf|
          return .{.floats = .{
            .left  = @intToFloat(f64, li.content) /
                     @intToFloat(f64, li.t.suffixes[li.cur_unit].factor),
            .right = rf.content,
          }},
        .int => |ri|
          return .{.ints = .{.left = li.content, .right = ri.content}},
        else => unreachable,
      },
      else => unreachable,
    }
  }

  fn compare(self: Comparer, op: std.math.CompareOperator) bool {
    return switch (self) {
      .ints   => |ints|   std.math.compare(ints.left, op, ints.right),
      .floats => |floats| std.math.compare(floats.left, op, floats.right),
    };
  }
};

pub fn createMatchCases(
  intpr: *Interpreter,
  cases  : *model.Node.Varmap,
) nyarna.Error![]model.Node.Match.Case {
  const map_type = (
    try intpr.ctx.types().hashMap(
      intpr.ctx.types().@"type"(), intpr.ctx.types().ast())
  ).?;
  var collected = try std.ArrayList(model.Node.Match.Case).initCapacity(
    intpr.allocator(), cases.content.items.len);
  for (cases.content.items) |case| switch (case.key) {
    .direct => {
      const res = try intpr.interpret(case.value);
      if (!res.expected_type.isNamed(.poison)) {
        intpr.ctx.logger.ExpectedExprOfTypeXGotY(&.{
          res.expected_type.at(res.pos),
          map_type.predef(),
        });
      }
    },
    .node => |node| {
      const ast = &case.value.data.expression.data.value.data.ast;
      const T = std.meta.fieldInfo(model.Node.Match.Case, .variable).field_type;
      lib.reportCaptures(intpr, ast, 1);
      const variable: T =
        if (ast.capture.len == 0) .none else T{.def = ast.capture[0]};
      try collected.append(.{
        .t        = node,
        .content  = ast,
        .variable = variable,
      });
    },
  };
  return collected.items;
}

pub fn createRenderers(
  intpr    : *Interpreter,
  renderers: *model.Node.Varmap,
) nyarna.Error![]model.Node.Highlight.Renderer {
  const map_type = (
    try intpr.ctx.types().hashMap(
      intpr.ctx.types().literal(), intpr.ctx.types().ast())
  ).?;
  var collected = try std.ArrayList(model.Node.Highlight.Renderer).initCapacity(
    intpr.allocator(), renderers.content.items.len);
  for (renderers.content.items) |renderer| switch (renderer.key) {
    .direct => {
      const res = try intpr.interpret(renderer.value);
      if (!res.expected_type.isNamed(.poison)) {
        intpr.ctx.logger.ExpectedExprOfTypeXGotY(&.{
          res.expected_type.at(res.pos), map_type.predef()});
      }
    },
    .node => |node| {
      const name_expr = (
        try intpr.associate(
          node, intpr.ctx.types().literal().predef(), .{.kind = .keyword})
      ) orelse {
        node.data = .poison;
        continue;
      };
      const name_val = try intpr.ctx.evaluator().evaluate(name_expr);
      const name = switch (name_val.data) {
        .text   => |txt| txt.content,
        .poison => continue,
        else    => unreachable,
      };

      const ast = &renderer.value.data.expression.data.value.data.ast;
      const T = std.meta.fieldInfo(
        model.Node.Highlight.Renderer, .variable).field_type;
      lib.reportCaptures(intpr, ast, 1);
      const variable: T =
        if (ast.capture.len == 0) .none else T{.def = ast.capture[0]};
      try collected.append(.{
        .name = name, .content = ast, .variable = variable,
      });
    },
  };
  return collected.items;
}

pub const Impl = lib.Provider.Wrapper(struct {
  //---------
  // keywords
  //---------

  pub fn backend(
    intpr: *Interpreter,
    pos  : model.Position,
    vars : ?*model.Node,
    funcs: ?*model.Node,
    body : ?*model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const func_defs: []*model.Node.Definition = if (funcs) |items| blk: {
      var collector = DefCollector{.dt = intpr.ctx.types().definition()};
      try collector.collect(items, intpr);
      try collector.allocate(intpr.allocator());
      try collector.append(items, intpr, false, intpr.node_gen);
      break :blk collector.finish();
    } else &.{};

    return (try intpr.node_gen.backend(pos, vars, func_defs, body)).node();
  }

  pub fn block(
    intpr  : *Interpreter,
    pos    : model.Position,
    content: *model.Node,
  ) nyarna.Error!*model.Node {
    _ = intpr; _ = pos;
    return content;
  }

  pub fn builtin(
    intpr  : *Interpreter,
    pos    : model.Position,
    returns: *model.Node,
    params : ?*model.Node,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    return (try intpr.node_gen.builtinGen(
      pos, pnode, .{.node = returns})).node();
  }

  pub fn declare(
    intpr  : *Interpreter,
    pos    : model.Position,
    ns     : u15,
    parent : ?model.Type,
    public : ?*model.Node,
    private: ?*model.Node,
  ) nyarna.Error!*model.Node {
    var collector = DefCollector{.dt = intpr.ctx.types().definition()};
    for ([_]?*model.Node{public, private}) |item| {
      if (item) |node| try collector.collect(node, intpr);
    }
    try collector.allocate(intpr.allocator());

    if (public)  |pnode| {
      try collector.append(pnode, intpr, true, intpr.node_gen);
    }
    if (private) |pnode| {
      try collector.append(pnode, intpr, false, intpr.node_gen);
    }
    var res = try CycleResolution.create(
      intpr, collector.finish(), ns, parent);
    try res.execute();
    return intpr.node_gen.@"void"(pos);
  }

  pub fn @"for"(
    intpr    : *Interpreter,
    pos      : model.Position,
    input    : *model.Node,
    collector: ?*model.Node,
    body     : *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.@"for"(
      pos, input, collector, body.root, body.capture, body.container.?)).node();
  }

  pub fn fragment(
    intpr  : *Interpreter,
    pos    : model.Position,
    root   : *model.Node,
    options: ?*model.Node,
    params : ?*model.Node,
  ) nyarna.Error!*model.Node {
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        if (options) |input| {
          var list = std.ArrayList(model.locations.Ref).init(intpr.allocator());
          try intpr.collectLocations(input, &list);
          var registrar = intpr.loader.registerOptions();
          _ = try
            intpr.processLocations(&list.items, .{.kind = .final}, &registrar);
          try registrar.finalize(0);
        }
        return (
          try intpr.node_gen.rootDef(pos, .fragment, root, params)
        ).node();
      }
    }
    return try intpr.node_gen.poison(pos);
  }

  pub fn func(
    intpr    : *Interpreter,
    pos      : model.Position,
    ns       : u15,
    @"return": ?*model.Node,
    params   : ?*model.Node,
    body     : *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    lib.reportCaptures(intpr, body, 0);
    const pnode = params orelse try intpr.node_gen.void(pos);
    // type system ensures body.container isn't null here
    return (
      try intpr.node_gen.funcgen(
        pos, @"return", pnode, ns, body.root, body.container.?)
    ).node();
  }

  pub fn highlight(
    intpr     : *Interpreter,
    pos       : model.Position,
    syntax    : *model.Node,
    renderers : *model.Node.Varmap,
  ) nyarna.Error!*model.Node {
    const rlist = try createRenderers(intpr, renderers);
    return (try intpr.node_gen.highlight(pos, syntax, rlist)).node();
  }

  pub fn @"if"(
    intpr    : *Interpreter,
    pos      : model.Position,
    condition: *model.Node,
    then     : *model.Value.Ast,
    @"else"  : ?*model.Node,
  ) nyarna.Error!*model.Node {
    const ret = try intpr.allocator().create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = .{.@"if" = .{
        .condition = condition,
        .then      = then,
        .@"else"   = @"else",
      }},
    };
    return ret;
  }

  pub fn import(
    intpr  : *Interpreter,
    pos    : model.Position,
    ns     : u15,
    locator: *model.Node,
  ) nyarna.Error!*model.Node {
    const expr = (
      try intpr.associate(locator, intpr.ctx.types().text().predef(),
        .{.kind = .keyword})
    ) orelse return try intpr.node_gen.poison(pos);
    const value = try intpr.ctx.evaluator().evaluate(expr);
    if (value.data == .poison) return try intpr.node_gen.poison(pos);
    const parsed = model.Locator.parse(value.data.text.content) catch {
      intpr.ctx.logger.InvalidLocator(locator.pos);
      return try intpr.node_gen.poison(pos);
    };
    if (try intpr.loader.searchModule(locator.pos, parsed)) |index| {
      return (try intpr.node_gen.import(pos, ns, index)).node();
    } else {
      return try intpr.node_gen.poison(pos);
    }
  }

  pub fn keyword(
    intpr : *Interpreter,
    pos   : model.Position,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    const ast_val =
      (try intpr.ctx.values.@"type"(pos, intpr.ctx.types().ast())).value();
    return (try intpr.node_gen.builtinGen(
      pos, pnode, .{.expr = try intpr.ctx.createValueExpr(ast_val)})).node();
  }

  pub fn library(
    intpr  : *Interpreter,
    pos    : model.Position,
    options: ?*model.Node,
  ) nyarna.Error!*model.Node {
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        if (options) |input| {
          var list = std.ArrayList(model.locations.Ref).init(intpr.allocator());
          try intpr.collectLocations(input, &list);
          var registrar = intpr.loader.registerOptions();
          _ = try
            intpr.processLocations(&list.items, .{.kind = .final}, &registrar);
          try registrar.finalize(0);
        }
        return (
          try intpr.node_gen.rootDef(pos, .library, undefined, undefined)
        ).node();
      }
    }
    return try intpr.node_gen.poison(pos);
  }

  pub fn map(
    intpr    : *Interpreter,
    pos      : model.Position,
    input    : *model.Node,
    proc_func: ?*model.Node,
    collector: ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.map(pos, input, proc_func, collector)).node();
  }

  pub fn match(
    intpr  : *Interpreter,
    pos    : model.Position,
    subject: *model.Node,
    cases  : *model.Node.Varmap,
  ) nyarna.Error!*model.Node {
    const content = try createMatchCases(intpr, cases);
    return (try intpr.node_gen.match(pos, subject, content)).node();
  }

  pub fn matcher(
    intpr: *Interpreter,
    pos  : model.Position,
    cases: *model.Node.Varmap,
  ) nyarna.Error!*model.Node {
    const container = try intpr.ctx.global().create(model.VariableContainer);
    container.num_values = 1;
    const sym = try intpr.ctx.global().create(model.Symbol);
    sym.* = .{
      .defined_at = pos,
      .name       = "value",
      .data = .{.variable = .{
        // only set during interpretation.
        .spec      = undefined,
        .container = container,
        .offset    = 0,
        .kind      = .given,
      }},
    };
    const subject = try intpr.node_gen.rsymref(pos, .{
      .ns       = 0,
      .sym      = sym,
      .name_pos = pos,
    });

    const content = try match(intpr, pos, subject.node(), cases);

    return (try intpr.node_gen.matcher(
      pos, &content.data.match, container, &sym.data.variable)).node();
  }

  pub fn standalone(
    intpr  : *Interpreter,
    pos    : model.Position,
    options: ?*model.Node,
    params : ?*model.Node,
    schema : ?*model.Node,
  ) nyarna.Error!*model.Node {
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        if (options) |input| {
          if (try intpr.locationsCanGenVars(input, .{.kind = .keyword})) {
            var list =
              std.ArrayList(model.locations.Ref).init(intpr.allocator());
            try intpr.collectLocations(input, &list);
            var registrar = intpr.loader.registerOptions();
            _ = try intpr.processLocations(
              &list.items, .{.kind = .final}, &registrar);
            try registrar.finalize(0);
          }
        }
        return (
          try intpr.node_gen.rootDef(pos, .standalone, schema, params)
        ).node();
      }
    }
    return try intpr.node_gen.poison(pos);
  }

  pub fn unroll(
    intpr    : *Interpreter,
    pos      : model.Position,
    input    : *model.Node,
    collector: ?*model.Node,
    body     : *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    lib.reportCaptures(intpr, body, 2);
    const expr = (
      try intpr.tryInterpret(input, .{.kind = .keyword})
    ) orelse try return intpr.node_gen.poison(pos);
    if (
      !switch (expr.expected_type) {
        .structural => |strct| switch (strct.*) {
          .concat, .list, .optional, .sequence => true,
          else => false,
        },
        .named => false,
      }
    ) {
      intpr.ctx.logger.NotIterable(&.{expr.expected_type.at(expr.pos)});
      return try intpr.node_gen.poison(pos);
    }
    var value = try intpr.ctx.evaluator().evaluate(expr);
    var generated = std.ArrayListUnmanaged(*model.Node){};
    try generated.ensureTotalCapacityPrecise(intpr.allocator(),
      switch (value.data) {
      .concat   => |*con| con.content.items.len,
      .list     => |*lst| lst.content.items.len,
      .seq      => |*seq| seq.content.items.len,
      .poison   => return try intpr.node_gen.poison(pos),
      // next two can occur when input has been optional
      .void     => 0,
      else      => 1,
    });

    var ns =
      if (body.capture.len > 0) body.capture[0].ns else std.math.maxInt(u15);
    // TODO: allow different namespaces (?)
    std.debug.assert(body.capture.len <= 1 or body.capture[1].ns == ns);

    var cctx = Resolver.ComptimeContext.init(ns, intpr.allocator());
    var resolver =
      Resolver.init(intpr, .{.kind = .intermediate, .resolve_ctx = &cctx.ctx});

    var iter = model.Iterator.init(&value);
    var i: i64 = 0; while (iter.next()) |val| : (i += 1) {
      if (body.capture.len > 0) {
        try cctx.entries.put(body.capture[0].name, try intpr.genValueNode(val));
      }
      if (body.capture.len > 1) {
        const int_val = try intpr.ctx.intAsValue(
          value.origin, i, 0, &intpr.ctx.types().system.integer.named.data.int);
        try cctx.entries.put(
          body.capture[1].name, try intpr.genValueNode(int_val));
      }
      const root = try intpr.node_gen.copy(body.root);
      try resolver.resolve(root);
      generated.appendAssumeCapacity(root);
    }

    if (collector) |cnode| {
      const cexpr = try intpr.interpret(cnode);
      const cvalue = try intpr.ctx.evaluator().evaluate(cexpr);
      switch (cvalue.data) {
        .poison    => return intpr.node_gen.poison(pos),
        .prototype => |pv| switch (pv.pt) {
          .concat =>
            return (try intpr.node_gen.concat(pos, generated.items)).node(),
          .list, .sequence =>
            std.debug.panic("unrolling into non-concat not implemented", .{}),
          else => {},
        },
        else => {},
      }
      intpr.ctx.logger.InvalidCollector(expr.pos);
      return intpr.node_gen.poison(pos);
    } else return (try intpr.node_gen.concat(pos, generated.items)).node();
  }

  pub fn @"var"(
    intpr: *Interpreter,
    pos  : model.Position,
    ns   : u15,
    defs : *model.Node,
  ) nyarna.Error!*model.Node {
    return try (try VarProcessor.init(intpr, ns, pos)).node(defs);
  }

  //---------------------
  // prototype functions
  //---------------------

  pub fn @"Textual::len"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    self: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return (try eval.ctx.values.int(
      pos, &eval.ctx.types().system.natural.named.data.int,
      @intCast(i64, self.content.len), 0)).value();
  }

  pub fn @"Textual::eq"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    self : *model.Value.TextScalar,
    other: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    const index =
      if (std.mem.eql(u8, self.content, other.content)) @as(usize, 1) else 0;
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum", index)
    ).value();
  }

  pub fn @"Textual::slice"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    self : *model.Value.TextScalar,
    start: ?*model.Value.IntNum,
    end  : ?*model.Value.IntNum,
  ) nyarna.Error!*model.Value {
    const from: usize =
      if (start) |num| @intCast(usize, num.content - 1) else 0;
    const to: usize =
      if (end) |num| @intCast(usize, num.content - 1) else self.content.len;
    if (from > to) {
      const msg = try std.fmt.allocPrint(
        eval.ctx.global(), "invalid slice: {}..{}", .{from + 1, to + 1});
      eval.ctx.logger.IndexError(pos, msg);
      return try eval.ctx.values.poison(pos);
    } else if (to > self.content.len) {
      const msg = try std.fmt.allocPrint(
        eval.ctx.global(), "index out of range: {}", .{to + 1});
      eval.ctx.logger.IndexError(pos, msg);
      return try eval.ctx.values.poison(pos);
    }
    return (
      try eval.ctx.values.textScalar(pos, self.t, self.content[from..to])
    ).value();
  }

  pub fn @"Numeric::add"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    list: *model.Value.List,
  ) nyarna.Error!*model.Value {
    switch (eval.target_type.named.data) {
      .int => |*int| {
        var ret: i64 = 0;
        for (list.content.items) |item| {
          if (@addWithOverflow(i64, ret, item.data.int.content, &ret)) {
            eval.ctx.logger.OutOfRange(pos, eval.target_type, "<overflow>");
            return try eval.ctx.values.poison(pos);
          }
        }
        const unit = if (list.content.items.len == 0) 0
        else list.content.items[0].data.int.cur_unit;
        return try eval.ctx.intAsValue(pos, ret, unit, int);
      },
      .float => |*fl| {
        var ret: f64 = 0;
        for (list.content.items) |item| ret += item.data.float.content;
        const unit = if (list.content.items.len == 0) 0
        else list.content.items[0].data.float.cur_unit;
        return try eval.ctx.floatAsValue(pos, ret, unit, fl);
      },
      else => unreachable,
    }
  }

  pub fn @"Numeric::sub"(
    eval      : *nyarna.Evaluator,
    pos       : model.Position,
    minuend   : *model.Value,
    subtrahend: *model.Value,
  ) nyarna.Error!*model.Value {
    switch (eval.target_type.named.data) {
      .int => |*int| {
        var ret: i64 = undefined;
        if (
          @subWithOverflow(
            i64, minuend.data.int.content, subtrahend.data.int.content, &ret)
        ) {
          eval.ctx.logger.OutOfRange(pos, eval.target_type, "<overflow>");
          return try eval.ctx.values.poison(pos);
        }
        return try eval.ctx.intAsValue(
          pos, ret, minuend.data.int.cur_unit, int);
      },
      .float => |*fl| {
        return try eval.ctx.floatAsValue(
          pos, minuend.data.float.content - subtrahend.data.float.content,
          minuend.data.float.cur_unit, fl);
      },
      else => unreachable,
    }
  }

  pub fn @"Numeric::mult"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    list: *model.Value.List,
  ) nyarna.Error!*model.Value {
    switch (eval.target_type.named.data) {
      .int => |*int| {
        var ret: i64 = 1;
        for (list.content.items) |item| {
          if (@mulWithOverflow(i64, ret, item.data.int.content, &ret)) {
            eval.ctx.logger.OutOfRange(pos, eval.target_type, "<overflow>");
            return try eval.ctx.values.poison(pos);
          }
        }
        const unit = if (list.content.items.len == 0) 0
        else list.content.items[0].data.int.cur_unit;
        return try eval.ctx.intAsValue(pos, ret, unit, int);
      },
      .float => |*fl| {
        var ret: f64 = 1;
        for (list.content.items) |item| ret *= item.data.float.content;
        const unit = if (list.content.items.len == 0) 0
        else list.content.items[0].data.float.cur_unit;
        return try eval.ctx.floatAsValue(pos, ret, unit, fl);
      },
      else => unreachable,
    }
  }

  pub fn @"Numeric::lt"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.lt)) 1 else 0)
    ).value();
  }

  pub fn @"Numeric::lte"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.lte)) 1 else 0)
    ).value();
  }

  pub fn @"Numeric::eq"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.eq)) 1 else 0)
    ).value();
  }

  pub fn @"Numeric::gt"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.gt)) 1 else 0)
    ).value();
  }

  pub fn @"Numeric::gte"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.gte)) 1 else 0)
    ).value();
  }

  pub fn @"Numeric::neq"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    left : *model.Value,
    right: *model.Value,
  ) nyarna.Error!*model.Value {
    const comp = Comparer.init(left, right);
    return (
      try eval.ctx.values.@"enum"(
        pos, &eval.ctx.types().system.boolean.named.data.@"enum",
        if (comp.compare(.neq)) 1 else 0)
    ).value();
  }

  pub fn @"List::len"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    list: *model.Value.List,
  ) nyarna.Error!*model.Value {
    return (try eval.ctx.values.int(
      pos, &eval.ctx.types().system.natural.named.data.int,
      @intCast(i64, list.content.items.len), 0)).value();
  }

  pub fn @"List::item"(
    eval : *nyarna.Evaluator,
    pos  : model.Position,
    list : *model.Value.List,
    index: *model.Value.IntNum,
  ) nyarna.Error!*model.Value {
    if (index.content > list.content.items.len) {
      const msg = try std.fmt.allocPrint(
        eval.ctx.global(), "<List with {} items>: {}", .{
          list.content.items.len, index.content
        }
      );
      defer eval.ctx.global().free(msg);
      eval.ctx.logger.IndexError(pos, msg);
      return eval.ctx.values.poison(pos);
    }
    return list.content.items[@intCast(usize, index.content - 1)];
  }

  //----------------------
  // unique type functions
  //----------------------

  pub fn @"Location::name"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    this: *model.Value.Location,
  ) nyarna.Error!*model.Value {
    _ = eval; _ = pos;
    return this.name.value();
  }

  pub fn @"Location::type"(
    eval: *nyarna.Evaluator,
    pos : model.Position,
    this: *model.Value.Location,
  ) nyarna.Error!*model.Value {
    _ = pos;
    return (
      try eval.ctx.values.@"type"(this.spec.pos, this.spec.t)
    ).value();
  }

  pub fn @"SchemaDef::use"(
    intpr     : *Interpreter,
    pos       : model.Position,
    schema_def: *model.Value.SchemaDef,
    b_name    : ?*model.Value.TextScalar,
    extensions: *model.Value.List,
  ) nyarna.Error!*model.Node {
    const builder = try nyarna.Loader.SchemaBuilder.create(
      schema_def, intpr.ctx.data, b_name);
    for (extensions.content.items) |val| {
      try builder.pushExt(&val.data.schema_ext);
    }
    const schema = (
      try builder.finalize(pos)
    ) orelse {
      return intpr.node_gen.poison(pos);
    };
    return try intpr.genValueNode(schema.value());
  }
});

pub const instance = Impl.init();

pub const Checker = struct {
  const TagType = @typeInfo(model.Type.Named.Data).Union.tag_type.?;
  const ExpectedSymbol = struct {
    name: []const u8,
    kind: union(enum) {
      @"type": TagType,
      prototype, keyword, builtin,
    },
    seen: bool = false,
    /// pointer into types.Lattice where the type should be hooked into
    t_hook: ?*model.Type = null,
    /// pointer into Globals where the index of the function implementation
    /// should be hooked into.
    f_hook: ?*usize = null,
  };

  fn ExpectedData(tuples: anytype) type {
    const ArrayType = @Type(.{.Array = .{
      .len = tuples.len,
      .child = ExpectedSymbol,
      .sentinel = null,
    }});
    return struct {
      const Array = ArrayType;
      fn init(types: *nyarna.Types, data: *Globals) ArrayType {
        var ret: ArrayType = undefined;
        inline for (tuples) |tuple, i| {
          if (i > 0) if (stringOrder(tuple.@"0", tuples[i-1].@"0") != .gt) {
            std.debug.panic("wrong order: \"{s}\" >= \"{s}\"",
              .{tuples[i-1].@"0", tuple.@"0"});
          };
          if (comptime std.mem.eql(u8, @tagName(tuple.@"1"), "prototype")) {
            ret[i] = .{.name = tuple.@"0", .kind = .prototype};
          } else if (
            comptime std.mem.eql(u8, @tagName(tuple.@"1"), "keyword")
          ) {
            ret[i] = .{
              .name   = tuple.@"0",
              .kind   = .keyword,
              .f_hook = if (tuple.len == 3)
                &@field(data.system_keywords, @tagName(tuple.@"2"))
              else null,
            };
          } else if (
            comptime std.mem.eql(u8, @tagName(tuple.@"1"), "builtin")
          ) {
            ret[i] = .{.name = tuple.@"0", .kind = .builtin};
          } else {
            ret[i] = .{
              .name   = tuple.@"0",
              .kind   = .{.@"type" = tuple.@"1"},
              .t_hook = if (tuple.len == 3)
                &@field(types.system, @tagName(tuple.@"2"))
              else null
            };
          }
        }
        return ret;
      }
    };
  }

  const ExpectedDataInst = ExpectedData(.{
    .{"Ast",             .ast},
    .{"Bool",            .@"enum", .boolean},
    .{"Concat",          .prototype},
    .{"Definition",      .definition},
    .{"Enum",            .prototype},
    .{"HashMap",         .prototype},
    .{"Identifier",      .textual, .identifier},
    .{"Integer",         .int, .integer},
    .{"Intersection",    .prototype},
    .{"List",            .prototype},
    .{"Location",        .location},
    .{"Location::name",  .builtin},
    .{"Location::type",  .builtin},
    .{"Natural",         .int, .natural},
    .{"Numeric",         .prototype},
    .{"NumericImpl",     .@"enum", .numeric_impl},
    .{"Optional",        .prototype},
    .{"Output",          .output},
    .{"OutputName",      .textual, .output_name},
    .{"Positive",        .int, .positive},
    .{"Record",          .prototype},
    .{"Schema",          .schema},
    .{"SchemaDef",       .schema_def},
    .{"SchemaDef::use",  .keyword},
    .{"SchemaExt",       .schema_ext},
    .{"Sequence",        .prototype},
    .{"Text",            .textual, .text},
    .{"Textual",         .prototype},
    .{"Type",            .@"type"},
    .{"UnicodeCategory", .@"enum", .unicode_category},
    .{"Void",            .void},
    .{"backend",         .keyword},
    .{"block",           .keyword},
    .{"builtin",         .keyword},
    .{"for",             .keyword},
    .{"fragment",        .keyword},
    .{"highlight",       .keyword},
    .{"if",              .keyword},
    .{"keyword",         .keyword},
    .{"library",         .keyword},
    .{"map",             .keyword},
    .{"match",           .keyword},
    .{"matcher",         .keyword, .matcher},
    .{"standalone",      .keyword},
    .{"unroll",          .keyword},
  });

  data  : ExpectedDataInst.Array,
  logger: *nyarna.errors.Handler,
  buffer: [256]u8 = undefined,

  pub fn init(
    data  : *Globals,
    logger: *nyarna.errors.Handler,
  ) Checker {
    return .{
      .data   = ExpectedDataInst.init(&data.types, data),
      .logger = logger,
    };
  }

  fn implName(self: *Checker, sym: *model.Symbol) []const u8 {
    return if (sym.parent_type) |t| blk: {
      const t_name = switch (t) {
        .named => |named| named.name.?.name,
        .structural => |struc| @tagName(struc.*),
      };
      std.mem.copy(u8, &self.buffer, t_name);
      std.mem.copy(u8, self.buffer[t_name.len..], "::");
      std.mem.copy(u8, self.buffer[t_name.len + 2..], sym.name);
      break :blk self.buffer[0..t_name.len + 2 + sym.name.len];
    } else sym.name;
  }

  pub fn check(self: *Checker, sym: *model.Symbol) void {
    const impl_name = self.implName(sym);

    // list of expected items is sorted by name, so we'll do a binary search
    var data: []ExpectedSymbol = &self.data;
    while (data.len > 0) {
      const index = @divTrunc(data.len, 2);
      const cur = &data[index];
      data = switch (stringOrder(impl_name, cur.name)) {
        .lt => data[0..index],
        .gt => data[index+1..],
        .eq => {
          switch (cur.kind) {
            .prototype => if (sym.data != .prototype) {
              self.logger.ShouldBePrototype(sym.defined_at, impl_name);
            },
            .@"type" => |t| switch (sym.data) {
              .@"type" => |st| if (
                st == .named and st.named.data == t
              ) {
                if (cur.t_hook) |target| target.* = st;
              } else {
                self.logger.WrongType(sym.defined_at, impl_name);
              },
              else => self.logger.ShouldBeType(sym.defined_at, impl_name),
            },
            .keyword => if (
              sym.data == .func and sym.data.func.callable.sig.isKeyword()
            ) {
              if (cur.f_hook) |target| {
                target.* = sym.data.func.data.ext.impl_index;
              }
            } else self.logger.ShouldBeKeyword(sym.defined_at, impl_name),
            .builtin => if (
              sym.data != .func or sym.data.func.callable.sig.isKeyword()
            ) self.logger.ShouldBeBuiltin(sym.defined_at, impl_name),
          }
          cur.seen = true;
          return;
        }
      };
    }
    self.logger.UnknownSystemSymbol(sym.defined_at, impl_name);
  }

  pub fn finish(
    self : *Checker,
    desc : *const model.Source.Descriptor,
    types: nyarna.Types,
  ) void {
    const pos = model.Position{
      .source = desc,
      .start  = model.Cursor.unknown(),
      .end    = model.Cursor.unknown(),
    };
    for (self.data) |*cur| {
      if (!cur.seen) switch (cur.kind) {
        .@"type"   => self.logger.MissingType(pos, cur.name),
        .prototype => self.logger.MissingPrototype(pos, cur.name),
        .keyword   => self.logger.MissingKeyword(pos, cur.name),
        .builtin   => self.logger.MissingBuiltin(pos, cur.name),
      };
    }
    inline for (.{.@"enum", .numeric, .textual}) |f| {
      if (@field(types.prototype_funcs, @tagName(f)).constructor == null) {
        self.logger.MissingConstructor(pos, @tagName(f));
      }
    }
  }
};