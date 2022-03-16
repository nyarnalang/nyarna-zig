const std = @import("std");
const lib = @import("../lib.zig");
const algo = @import("../interpret/algo.zig");
const nyarna = @import("../nyarna.zig");
const interpret = @import("../interpret.zig");
const model = @import("../model.zig");
const Interpreter = interpret.Interpreter;

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
          try intpr.associate(node, (try intpr.ctx.types().concat(self.dt)).?,
            .{.kind = .keyword}))
          orelse {
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
    const expr = (try intpr.associate(locator, intpr.ctx.types().raw(),
      .{.kind = .keyword}))
    orelse return try intpr.node_gen.poison(pos);
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
    // TODO: can body.container be null here?
    return (try intpr.node_gen.funcgen(
      pos, @"return", pnode, ns, body.root, body.container.?, false
    )).node();
  }

  pub fn method(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    @"return": ?*model.Node,
    params: ?*model.Node,
    body: *model.Value.Ast,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    return (try intpr.node_gen.funcgen(
      pos, @"return", pnode, ns, body.root, body.container.?, true)).node();
  }

  pub fn keyword(
    intpr: *Interpreter,
    pos: model.Position,
    params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    const pnode = params orelse try intpr.node_gen.void(pos);
    return (try intpr.node_gen.builtinGen(
      pos, pnode, .{.value =
        try intpr.ctx.values.@"type"(pos, intpr.ctx.types().ast())})).node();
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
            const t = if (loc.@"type") |tnode| blk: {
              const expr = (try self.ip.associate(
                tnode, self.ip.ctx.types().@"type"(),
                .{.kind = .keyword}
              )) orelse return self.empty();
              const val = try self.ip.ctx.evaluator().evaluate(expr);
              switch (val.data) {
                .poison => return try self.empty(),
                .@"type" => |*tv| break :blk tv.t,
                else => unreachable,
              }
            } else
              (try self.ip.probeType(loc.default.?, .{.kind = .intermediate}))
              orelse self.ip.ctx.types().every();
            return try self.variable(loc.name.node().pos, t,
              try self.ip.ctx.global().dupe(u8, loc.name.content),
              loc.default orelse (try self.defaultValue(t, n.pos)) orelse {
                self.ip.ctx.logger.MissingInitialValue(loc.name.node().pos);
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
            const expr = (try self.ip.tryInterpret(n, .{.kind = .keyword}))
              orelse return self.empty();
            return self.expression(expr);
          }
        }
      }

      fn expression(self: *@This(), expr: *model.Expression) !*model.Node {
        if (expr.data == .poison) return try self.empty();
        if (!self.ip.ctx.types().lesserEqual(
            expr.expected_type, self.concat_loc)) {
          self.ip.ctx.logger.ExpectedExprOfTypeXGotY(
            expr.pos, &[_]model.Type{self.concat_loc, expr.expected_type});
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
                  loc.tloc, item.origin)) orelse {
                self.ip.ctx.logger.MissingInitialValue(loc.name.value().origin);
                items[index] =
                  try self.ip.node_gen.void(loc.name.value().origin);
                continue;
              };
              items[index] = try self.variable(
                loc.name.value().origin, loc.tloc, loc.name.content, initial);
            }
            return (try self.ip.node_gen.concat(
              self.keyword_pos, .{.items = items})).node();
          },
          else => unreachable,
        }
      }

      fn variable(
        self: *@This(),
        name_pos: model.Position,
        t: model.Type,
        name: []const u8,
        initial: *model.Node,
      ) !*model.Node {
        const sym = try self.ip.ctx.global().create(model.Symbol);
        const offset =
          @intCast(u15, self.ip.variables.items.len - self.ac.offset);
        sym.* = .{
          .defined_at = name_pos,
          .name = name,
          .data = .{.variable = .{
            .t = t,
            .container = self.ac.container,
            .offset = offset,
            .assignable = true,
          }},
          .parent_type = null,
        };
        if (try self.namespace.tryRegister(self.ip, sym)) {
          try self.ip.variables.append(
            self.ip.allocator, .{.ns = self.ns_index});
          if (offset + 1 > self.ac.container.num_values) {
            self.ac.container.num_values = offset + 1;
          }
          const replacement = if (t.isInst(.every))
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
              .t = t,
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
            .concat, .optional, .paragraphs => try self.ip.node_gen.void(vpos),
            .list => null, // TODO: call list constructor
            .map => null, // TODO: call map constructor
            .callable, .intersection => null,
          },
          .instantiated => |inst| switch (inst.data) {
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
});