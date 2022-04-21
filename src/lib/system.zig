const std = @import("std");


const algo      = @import("../interpret/algo.zig");
const errors    = @import("../errors.zig");
const interpret = @import("../interpret.zig");
const lib       = @import("../lib.zig");
const nyarna    = @import("../nyarna.zig");
const model     = @import("../model.zig");

const Interpreter = interpret.Interpreter;
const stringOrder = @import("../helpers.zig").stringOrder;

pub const DefCollector = struct {
  count: usize = 0,
  defs: []*model.Node.Definition = undefined,
  dt: model.Type,

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
    self: *@This(),
    name: []const u8,
    name_pos: model.Position,
    intpr: *Interpreter,
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
    self: *@This(),
    node: *model.Node,
    intpr: *Interpreter,
    pdef: bool,
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

pub const Impl = lib.Provider.Wrapper(struct {
  //---------
  // keywords
  //---------

  pub fn declare(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    parent: ?model.Type,
    public: ?*model.Node,
    private: ?*model.Node,
  ) nyarna.Error!*model.Node {
    var collector = DefCollector{.dt = intpr.ctx.types().definition()};
    for ([_]?*model.Node{public, private}) |item| {
      if (item) |node| try collector.collect(node, intpr);
    }
    try collector.allocate(intpr.allocator);

    if (public) |pnode| try collector.append(pnode, intpr, true);
    if (private) |pnode| try collector.append(pnode, intpr, false);
    var res = try algo.DeclareResolution.create(
      intpr, collector.finish(), ns, parent);
    try res.execute();
    return intpr.node_gen.@"void"(pos);
  }

  pub fn @"if"(
    intpr: *Interpreter,
    pos: model.Position,
    condition: *model.Node,
    then: ?*model.Node,
    @"else": ?*model.Node,
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
          .branches = nodes,
        },
      },
    };
    return ret;
  }

  pub fn import(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    locator: *model.Node,
  ) nyarna.Error!*model.Node {
    const expr = (
      try intpr.associate(locator, intpr.ctx.types().raw().predef(),
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

  pub fn func(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    @"return": ?*model.Node,
    params: ?*model.Node,
    body: *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    // type system ensures body.container isn't null here
    return (try intpr.node_gen.funcgen(
      pos, @"return", pnode, ns, body.root, body.container.?
    )).node();
  }

  pub fn keyword(
    intpr: *Interpreter,
    pos: model.Position,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    const ast_val =
      (try intpr.ctx.values.@"type"(pos, intpr.ctx.types().ast())).value();
    return (try intpr.node_gen.builtinGen(
      pos, pnode, .{.expr = try intpr.ctx.createValueExpr(ast_val)})).node();
  }

  pub fn block(
    intpr: *Interpreter,
    pos: model.Position,
    content: *model.Node,
  ) nyarna.Error!*model.Node {
    _ = intpr; _ = pos;
    return content;
  }

  pub fn builtin(
    intpr: *Interpreter,
    pos: model.Position,
    returns: *model.Node,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    return (try intpr.node_gen.builtinGen(
      pos, pnode, .{.node = returns})).node();
  }

  pub fn @"var"(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    defs: *model.Node,
  ) nyarna.Error!*model.Node {
    const Proc = struct {
      ip: *Interpreter,
      keyword_pos: model.Position,
      concat_loc: model.Type,
      ac: *Interpreter.ActiveVarContainer,
      namespace: *interpret.Namespace,
      ns_index: u15,

      fn init(
        ip: *Interpreter,
        index: u15,
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
              }, if (loc.additionals) |a| a.borrow != null else false);
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
            const expr = (try self.ip.tryInterpret(n, .{.kind = .keyword}))
              orelse return self.empty();
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
        return self.value(val);
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
                loc.name.value().origin, loc.spec, loc.name.content, initial,
                loc.borrow != null);
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
        borrowed: bool,
      ) !*model.Node {
        const sym = try self.ip.ctx.global().create(model.Symbol);
        const offset =
          @intCast(u15, self.ip.variables.items.len - self.ac.offset);
        sym.* = .{
          .defined_at = name_pos,
          .name = name,
          .data = .{.variable = .{
            .spec = spec,
            .container = self.ac.container,
            .offset = offset,
            .assignable = true,
            .borrowed = borrowed,
          }},
          .parent_type = null,
        };
        if (try self.namespace.tryRegister(self.ip, sym)) {
          try self.ip.variables.append(
            self.ip.allocator, .{.ns = self.ns_index});
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
        t: model.Type,
        vpos: model.Position,
      ) !?*model.Node {
        return switch (t) {
          .structural => |strct| switch (strct.*) {
            .concat, .optional, .sequence => try self.ip.node_gen.void(vpos),
            .list => null, // TODO: call list constructor
            .map => null, // TODO: call map constructor
            .callable, .intersection => null,
          },
          .named => |named| switch (named.data) {
            .textual => (try self.ip.node_gen.literal(vpos, .{
              .kind = .space,
              .content = "",
            })).node(),
            .numeric => |*num| {
              const val: i64 = if (num.min <= 0)
                if (num.max >= 0) 0 else num.max
              else num.min;
              const nval = try self.ip.ctx.values.number(vpos, num, val);
              return try self.ip.genValueNode(nval.value());
            },
            .float => |*fl| {
              const fval = try self.ip.ctx.values.float(vpos, fl,
                switch (fl.precision) {
                  .half => .{.half = 0},
                  .single => .{.single = 0},
                  .double => .{.double = 0},
                  .quadruple, .octuple => .{.quadruple = 0},
                });
              return try self.ip.genValueNode(fval.value());
            },
            .tenum => |*en| {
              const eval = try self.ip.ctx.values.@"enum"(vpos, en, 0);
              return try self.ip.genValueNode(eval.value());
            },
            .record => null,
            .ast, .frame_root, .void, .every =>
              try self.ip.node_gen.void(vpos),
            .space, .literal, .raw =>
              (try self.ip.node_gen.literal(vpos, .{
                .kind = .space,
                .content = "",
              })).node(),
            else => return null,
          },
        };
      }
    };
    return try (try Proc.init(intpr, ns, pos)).node(defs);
  }

  pub fn library(
    intpr: *Interpreter,
    pos: model.Position,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    _ = params; // TODO
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        intpr.specified_content = .{.library = pos};
      }
    }
    return intpr.node_gen.@"void"(pos);
  }

  pub fn standalone(
    intpr: *Interpreter,
    pos: model.Position,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    _ = params; // TODO
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        intpr.specified_content = .{.standalone = .{
          .pos = pos,
          .root_type = intpr.ctx.types().raw(), // TODO
        }};
      }
    }
    return intpr.node_gen.@"void"(pos);
  }

  pub fn fragment(
    intpr: *Interpreter,
    pos: model.Position,
    root: *model.Value.TypeVal,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    _ = params; // TODO
    switch (intpr.specified_content) {
      .library => |lpos|
        intpr.ctx.logger.MultipleModuleKinds("library", pos, lpos),
      .standalone => |*s|
        intpr.ctx.logger.MultipleModuleKinds("standalone", pos, s.pos),
      .fragment => |*f|
        intpr.ctx.logger.MultipleModuleKinds("fragment", pos, f.pos),
      .unspecified => {
        intpr.specified_content = .{.fragment = .{
          .pos = pos,
          .root_type = root.t,
        }};
      }
    }
    return intpr.node_gen.@"void"(pos);
  }

  pub fn @"Raw::len"(
    eval: *nyarna.Evaluator,
    pos: model.Position,
    self: *model.Value.TextScalar,
  ) nyarna.Error!*model.Value {
    return (try eval.ctx.values.number(
      pos, &eval.ctx.types().system.natural.named.data.numeric,
      @intCast(i64, self.content.len))).value();
  }

  pub fn @"Numeric::add"(
    eval: *nyarna.Evaluator,
    pos: model.Position,
    list: *model.Value.List,
  ) nyarna.Error!*model.Value {
    var ret: i64 = 0;
    for (list.content.items) |item| {
      if (@addWithOverflow(i64, ret, item.data.number.content, &ret)) {
        eval.ctx.logger.OutOfRange(pos, eval.target_type, "<overflow>");
        return try eval.ctx.values.poison(pos);
      }
    }
    return try eval.ctx.numberFromInt(
      pos, ret, &eval.target_type.named.data.numeric);
  }

  pub fn @"Numeric::sub"(
    eval: *nyarna.Evaluator,
    pos: model.Position,
    minuend: *model.Value.Number,
    subtrahend: *model.Value.Number,
  ) nyarna.Error!*model.Value {
    var ret: i64 = undefined;
    if (@subWithOverflow(i64, minuend.content, subtrahend.content, &ret)) {
      eval.ctx.logger.OutOfRange(pos, eval.target_type, "<overflow>");
      return try eval.ctx.values.poison(pos);
    }
    return try eval.ctx.numberFromInt(
      pos, ret, &eval.target_type.named.data.numeric);
  }

  pub fn @"List::len"(
    eval: *nyarna.Evaluator,
    pos: model.Position,
    list: *model.Value.List,
  ) nyarna.Error!*model.Value {
    return (try eval.ctx.values.number(
      pos, &eval.ctx.types().system.natural.named.data.numeric,
      @intCast(i64, list.content.items.len))).value();
  }

  pub fn @"List::item"(
    eval: *nyarna.Evaluator,
    pos: model.Position,
    list: *model.Value.List,
    index: *model.Value.Number,
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
      fn init(lattice: *nyarna.types.Lattice) ArrayType {
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
                &@field(lattice.system, @tagName(tuple.@"2"))
              else null
            };
          }
        }
        return ret;
      }
    };
  }

  const ExpectedDataInst = ExpectedData(.{
    .{"Ast", .ast},
    .{"Bool", .tenum, .boolean},
    .{"Concat", .prototype},
    .{"Definition", .definition},
    .{"Enum", .prototype},
    .{"Float", .prototype},
    .{"Identifier", .textual, .identifier},
    .{"Integer", .numeric, .integer},
    .{"Intersection", .prototype},
    .{"List", .prototype},
    .{"Location", .location},
    .{"Map", .prototype},
    .{"Natural", .numeric, .natural},
    .{"Numeric", .prototype},
    .{"Optional", .prototype},
    .{"Positive", .numeric},
    .{"Raw", .raw},
    .{"Raw::len", .builtin},
    .{"Record", .prototype},
    .{"Sequence", .prototype},
    .{"Text", .textual},
    .{"Textual", .prototype},
    .{"Type", .@"type"},
    .{"UnicodeCategory", .tenum, .unicode_category},
    .{"Void", .void},
    .{"block", .keyword},
    .{"builtin", .keyword},
    .{"fragment", .keyword},
    .{"if", .keyword},
    .{"keyword", .keyword},
    .{"library", .keyword},
    .{"standalone", .keyword},
  });

  data: ExpectedDataInst.Array,
  logger: *nyarna.errors.Handler,
  buffer: [256]u8 = undefined,

  pub inline fn init(
    lattice: *nyarna.types.Lattice,
    logger: *nyarna.errors.Handler,
  ) Checker {
    return .{
      .data = ExpectedDataInst.init(lattice),
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
    self: *Checker,
    desc: *const model.Source.Descriptor,
    types: *const nyarna.types.Lattice,
  ) void {
    const pos = model.Position{
      .source = desc,
      .start = model.Cursor.unknown(),
      .end = model.Cursor.unknown(),
    };
    for (self.data) |*cur| {
      if (!cur.seen) switch (cur.kind) {
        .@"type" => self.logger.MissingType(pos, cur.name),
        .prototype => self.logger.MissingPrototype(pos, cur.name),
        .keyword => self.logger.MissingKeyword(pos, cur.name),
        .builtin => self.logger.MissingBuiltin(pos, cur.name),
      };
    }
    inline for (.{.@"enum", .numeric, .textual, .float}) |f| {
      if (@field(types.prototype_funcs, @tagName(f)).constructor == null) {
        self.logger.MissingConstructor(pos, @tagName(f));
      }
    }
  }
};