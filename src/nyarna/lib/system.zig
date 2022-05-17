const std = @import("std");

const algo      = @import("../Interpreter/algo.zig");
const nyarna    = @import("../../nyarna.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

const stringOrder = @import("../helpers.zig").stringOrder;

pub const DefCollector = struct {
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
    intpr   : *Interpreter,
  ) bool {
    var i: usize = 0; while (i < self.count) : (i += 1) {
      if (std.mem.eql(u8, self.defs[i].name.content, name)) {
        intpr.ctx.logger.DuplicateSymbolName(
          name, name_pos, self.defs[i].name.node().pos);
        return false;
      }
    }
    return true;
  }

  pub fn append(
    self : *@This(),
    node : *model.Node,
    intpr: *Interpreter,
    pdef : bool,
  ) nyarna.Error!void {
    switch (node.data) {
      .void, .poison => {},
      .definition => |*def| {
        if (self.checkName(def.name.content, def.name.node().pos, intpr)) {
          if (pdef) def.public = true;
          self.defs[self.count] = def;
          self.count += 1;
        }
      },
      .concat => |*con| for (con.items) |item| {
        try self.append(item, intpr, pdef);
      },
      .expression => |expr| {
        for (expr.data.value.data.concat.content.items) |item| {
          const def = &item.data.definition;
          if (self.checkName(
            def.name.content,
            def.name.value().origin,
            intpr)
          ) {
            const content_value = switch (def.content) {
              .func => |f|
                (try intpr.ctx.values.funcRef(item.origin, f)).value(),
              .@"type" => |t|
                (try intpr.ctx.values.@"type"(item.origin, t)).value(),
            };
            const def_node = try intpr.node_gen.definition(item.origin, .{
              .name = try intpr.node_gen.literal(def.name.value().origin, .{
                .kind = .text, .content = def.name.content,
              }),
              .root = def.root,
              .content = try intpr.node_gen.expression(
                try intpr.ctx.createValueExpr(content_value)
              ),
              .public = pdef,
            });
            self.defs[self.count] = def_node;
            self.count += 1;
          }
        }
      },
      else => unreachable,
    }
  }

  pub fn finish(self: *@This()) []*model.Node.Definition {
    return self.defs[0..self.count];
  }
};

///
const VarProc = struct {
  ip         : *Interpreter,
  keyword_pos: model.Position,
  concat_loc : model.Type,
  ac         : *Interpreter.ActiveVarContainer,
  namespace  : *Interpreter.Namespace,
  ns_index   : u15,

  fn init(
    ip         : *Interpreter,
    index      : u15,
    keyword_pos: model.Position,
  ) !@This() {
    return @This(){
      .ip = ip,
      .keyword_pos = keyword_pos,
      .concat_loc =
        (try ip.ctx.types().concat(ip.ctx.types().location())).?,
      .ac = &ip.var_containers.items[ip.var_containers.items.len - 1],
      .namespace = ip.namespace(index),
      .ns_index = index,
    };
  }

  inline fn empty(self: *@This()) !*model.Node {
    return try self.ip.node_gen.void(self.keyword_pos);
  }

  fn node(self: *@This(), n: *model.Node) nyarna.Error!*model.Node {
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
          try self.ip.allocator.alloc(*model.Node, con.items.len);
        for (con.items) |item, index| items[index] = try self.node(item);
        return (try self.ip.node_gen.concat(
          self.keyword_pos, .{.items = items})).node();
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

  fn expression(
    self: *@This(),
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

  fn value(self: *@This(), val: *model.Value) !*model.Node {
    switch (val.data) {
      .poison => return try self.empty(),
      .concat => |*con| {
        const items =
          try self.ip.allocator.alloc(*model.Node, con.content.items.len);
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
        return (try self.ip.node_gen.concat(
          self.keyword_pos, .{.items = items})).node();
      },
      else => unreachable,
    }
  }

  fn variable(
    self    : *@This(),
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
    self: *@This(),
    t   : model.Type,
    vpos: model.Position,
  ) !?*model.Node {
    return switch (t) {
      .structural => |strct| switch (strct.*) {
        .concat, .optional, .sequence => try self.ip.node_gen.void(vpos),
        .list => |*lst| try self.ip.genValueNode(
          (try self.ip.ctx.values.list(vpos, lst)).value()
        ),
        .map => |*map| try self.ip.genValueNode(
          (try self.ip.ctx.values.map(vpos, map)).value()
        ),
        .callable, .intersection => null,
      },
      .named => |named| switch (named.data) {
        .textual, .space, .literal => (
          try self.ip.node_gen.literal(vpos, .{
            .kind = .space,
            .content = "",
          })
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
};

pub fn createMatch(
  intpr: *Interpreter,
  pos    : model.Position,
  cases  : *model.Node.Varmap,
) nyarna.Error!*model.Node.Match {
  const map_type = (
    try intpr.ctx.types().map(
      intpr.ctx.types().@"type"(), intpr.ctx.types().ast())
  ).?;
  var collected = try std.ArrayList(model.Node.Match.Case).initCapacity(
    intpr.allocator, cases.content.items.len);
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
      const variable: T = if (ast.capture) |capture| blk: {
        if (capture.key) |key| {
          intpr.ctx.logger.UnexpectedBlockVar(key.pos, "key");
        }
        if (capture.index) |index| {
          intpr.ctx.logger.UnexpectedBlockVar(index.pos, "index");
        }
        break :blk @as(T, if (capture.val) |val| .{.def = val} else .none);
      } else T.none;
      try collected.append(.{
        .t        = node,
        .content  = ast,
        .variable = variable,
      });
    },
  };
  return try intpr.node_gen.match(pos, collected.items);
}

pub const Impl = lib.Provider.Wrapper(struct {
  //---------
  // keywords
  //---------

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
    try collector.allocate(intpr.allocator);

    if (public)  |pnode| try collector.append(pnode, intpr, true);
    if (private) |pnode| try collector.append(pnode, intpr, false);
    var res = try algo.DeclareResolution.create(
      intpr, collector.finish(), ns, parent);
    try res.execute();
    return intpr.node_gen.@"void"(pos);
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
          var list = std.ArrayList(model.locations.Ref).init(intpr.allocator);
          try intpr.collectLocations(input, &list);
          var registrar =
            nyarna.ModuleLoader.OptionRegistrar{.ml = intpr.ctx.loader.?};
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
    const pnode = params orelse try intpr.node_gen.void(pos);
    // type system ensures body.container isn't null here
    return (try intpr.node_gen.funcgen(
      pos, @"return", pnode, ns, body.root, body.container.?
    )).node();
  }

  pub fn @"if"(
    intpr    : *Interpreter,
    pos      : model.Position,
    condition: *model.Node,
    then     : ?*model.Node,
    @"else"  : ?*model.Node,
  ) nyarna.Error!*model.Node {
    const nodes = try intpr.allocator.alloc(*model.Node, 2);
    nodes[1] = then orelse try intpr.node_gen.void(pos);
    nodes[0] = @"else" orelse try intpr.node_gen.void(pos);

    const ret = try intpr.allocator.create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .branches = .{
          .condition = condition,
          .cond_type = intpr.ctx.types().system.boolean,
          .branches  = nodes,
        },
      },
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
    if (try intpr.ctx.searchModule(locator.pos, parsed)) |index| {
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
          var list = std.ArrayList(model.locations.Ref).init(intpr.allocator);
          try intpr.collectLocations(input, &list);
          var registrar =
            nyarna.ModuleLoader.OptionRegistrar{.ml = intpr.ctx.loader.?};
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

  pub fn match(
    intpr: *Interpreter,
    pos    : model.Position,
    subject: *model.Node,
    cases  : *model.Node.Varmap,
  ) nyarna.Error!*model.Node {
    const ret = try createMatch(intpr, pos, cases);
    ret.subject = subject;
    return ret.node();
  }

  pub fn matcher(
    intpr: *Interpreter,
    pos    : model.Position,
    cases  : *model.Node.Varmap,
  ) nyarna.Error!*model.Node {
    return (try createMatch(intpr, pos, cases)).node();
  }

  pub fn standalone(
    intpr  : *Interpreter,
    pos    : model.Position,
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
          if (try intpr.locationsCanGenVars(input, .{.kind = .keyword})) {
            var list = std.ArrayList(model.locations.Ref).init(intpr.allocator);
            try intpr.collectLocations(input, &list);
            var registrar =
              nyarna.ModuleLoader.OptionRegistrar{.ml = intpr.ctx.loader.?};
            _ = try intpr.processLocations(
              &list.items, .{.kind = .final}, &registrar);
            try registrar.finalize(0);
          }
        }
        return ( // TODO: schema
          try intpr.node_gen.rootDef(pos, .standalone, undefined, params)
        ).node();
      }
    }
    return try intpr.node_gen.poison(pos);
  }

  pub fn @"var"(
    intpr: *Interpreter,
    pos  : model.Position,
    ns   : u15,
    defs : *model.Node,
  ) nyarna.Error!*model.Node {
    return try (try VarProc.init(intpr, ns, pos)).node(defs);
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
    hook: ?*model.Type = null,
  };

  fn ExpectedData(tuples: anytype) type {
    const ArrayType = @Type(.{.Array = .{
      .len = tuples.len,
      .child = ExpectedSymbol,
      .sentinel = null,
    }});
    return struct {
      const Array = ArrayType;
      fn init(types: *nyarna.Types) ArrayType {
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
            ret[i] = .{.name = tuple.@"0", .kind = .keyword};
          } else if (
            comptime std.mem.eql(u8, @tagName(tuple.@"1"), "builtin")
          ) {
            ret[i] = .{.name = tuple.@"0", .kind = .builtin};
          } else {
            ret[i] = .{
              .name = tuple.@"0",
              .kind = .{.@"type" = tuple.@"1"},
              .hook = if (tuple.len == 3)
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
    .{"Identifier",      .textual, .identifier},
    .{"Integer",         .int, .integer},
    .{"Intersection",    .prototype},
    .{"List",            .prototype},
    .{"Location",        .location},
    .{"Map",             .prototype},
    .{"Natural",         .int, .natural},
    .{"Numeric",         .prototype},
    .{"NumericImpl",     .@"enum", .numeric_impl},
    .{"Optional",        .prototype},
    .{"Positive",        .int},
    .{"Record",          .prototype},
    .{"Sequence",        .prototype},
    .{"Text",            .textual, .text},
    .{"Textual",         .prototype},
    .{"Type",            .@"type"},
    .{"UnicodeCategory", .@"enum", .unicode_category},
    .{"Void",            .void},
    .{"block",           .keyword},
    .{"builtin",         .keyword},
    .{"fragment",        .keyword},
    .{"if",              .keyword},
    .{"keyword",         .keyword},
    .{"library",         .keyword},
    .{"match",           .keyword},
    .{"matcher",         .keyword},
    .{"standalone",      .keyword},
  });

  data  : ExpectedDataInst.Array,
  logger: *nyarna.errors.Handler,
  buffer: [256]u8 = undefined,

  pub inline fn init(
    types : *nyarna.Types,
    logger: *nyarna.errors.Handler,
  ) Checker {
    return .{
      .data   = ExpectedDataInst.init(types),
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
                if (cur.hook) |target| target.* = st;
              } else {
                self.logger.WrongType(sym.defined_at, impl_name);
              },
              else => self.logger.ShouldBeType(sym.defined_at, impl_name),
            },
            .keyword => if (
              sym.data != .func or !sym.data.func.callable.sig.isKeyword()
            ) self.logger.ShouldBeKeyword(sym.defined_at, impl_name),
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