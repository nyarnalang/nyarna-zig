const std = @import("std");

const graph = @import("graph.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const chains = @import("chains.zig");
const Interpreter = @import("interpret.zig").Interpreter;

fn isPrototype(ef: *model.Symbol.ExtFunc) bool {
  return ef.callable.kind == .prototype;
}

fn subjectIsType(uacc: *model.Node.UnresolvedAccess, t: model.Type) bool {
  return switch (uacc.subject.data) {
    .resolved_symref => |*rsym| switch (rsym.sym.data) {
      .@"type" => |st| st.eql(t),
      else => false,
    },
    .expression => |expr| switch (expr.data) {
      .value => |val| switch (val.data) {
        .@"type" => |tval| tval.t.eql(t),
        else => false,
      },
      else => false,
    },
    else => false,
  };
}

const TypeResolver = struct {
  ctx: graph.ResolutionContext,
  dres: *DeclareResolution,
  worklist: std.ArrayListUnmanaged(*model.Node) = .{},

  fn init(dres: *DeclareResolution) TypeResolver {
    return .{
      .dres = dres,
      .ctx = .{
        .resolveNameFn = linkTypes,
        .target = dres.in,
      },
    };
  }

  inline fn uStruct(gen: anytype) graph.ResolutionContext.Result {
    return .{.unfinished_type = .{.structural = gen.generated.?}};
  }

  fn linkTypes(
    ctx: *graph.ResolutionContext,
    name: []const u8,
    name_pos: model.Position,
  ) nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(TypeResolver, "ctx", ctx);
    for (self.dres.defs) |def| {
      if (std.mem.eql(u8, def.name.content, name)) {
        try self.process(def.content);
        switch (def.content.data) {
          .gen_concat => |*gc| return uStruct(gc),
          .gen_intersection => |*gi| return uStruct(gi),
          .gen_list => |*gl| return uStruct(gl),
          .gen_map => |*gm| return uStruct(gm),
          .gen_optional => |*go| return uStruct(go),
          .gen_paragraphs => |*gp| return uStruct(gp),
          .gen_record => |*gr| return graph.ResolutionContext.Result{
            .unfinished_type = .{.instantiated = gr.generated.?},
          },
          .funcgen => {
            self.dres.intpr.ctx.logger.NotAType(name_pos);
            return graph.ResolutionContext.Result.failed;
          },
          .poison, .expression =>
            return graph.ResolutionContext.Result.failed,
          else => unreachable,
        }
      }
    }
    return graph.ResolutionContext.Result.unknown;
  }

  fn process(self: *TypeResolver, node: *model.Node) !void {
    switch (node.data) {
      .expression, .poison, .gen_record, .funcgen => return,
      else => {},
    }
    for (self.worklist.items) |wli, index| if (wli == node) {
      const pos_list = try self.dres.intpr.allocator.alloc(
        model.Position, self.worklist.items.len - index - 1);
      for (pos_list) |*item, pindex| {
        item.* = self.worklist.items[self.worklist.items.len - 1 - pindex].pos;
      }
      self.dres.intpr.ctx.logger.CircularType(node.pos, pos_list);
      node.data = .poison;
      return;
    };
    try self.worklist.append(self.dres.intpr.allocator, node);
    defer _ = self.worklist.pop();

    if (try self.dres.intpr.tryInterpret(node,
        .{.kind = .final, .resolve = &self.ctx})) |expr| {
      node.data = .{.expression = expr};
    } else {
      node.data = .poison;
    }
  }
};

const FixpointContext = struct {
  ctx: graph.ResolutionContext,
  dres: *DeclareResolution,

  fn init(dres: *DeclareResolution) FixpointContext {
    return .{
      .dres = dres,
      .ctx = .{
        .resolveNameFn = funcReturns,
        .target = dres.in,
      },
    };
  }

  fn funcReturns(
    ctx: *graph.ResolutionContext,
    name: []const u8,
    name_pos: model.Position,
  ) nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(TypeResolver, "ctx", ctx);
    for (self.dres.defs) |def| {
      if (std.mem.eql(u8, def.name.content, name)) {
        switch (def.content.data) {
          .gen_record => |*gr| return graph.ResolutionContext.Result{
            .unfinished_function = .{.instantiated = gr.generated.?},
          },
          .funcgen => |*fgen| {
            return graph.ResolutionContext.Result{
              .unfinished_function = fgen.cur_returns,
            };
          },
          // types other than gen_record are guaranteed to have been
          // constructed at this point since they can't contain default
          // expressions which would reference sibling functions.
          else => unreachable,
        }
      }
    }
    self.dres.intpr.ctx.logger.UnknownSymbol(name_pos, name);
    return graph.ResolutionContext.Result.failed;
  }

  fn probe(fc: *FixpointContext, fgen: *model.Node.Funcgen) !bool {
    const new_type = if (fgen.returns) |returns| blk: {
      const expr = try fc.dres.intpr.interpret(returns);
      const val = try fc.dres.intpr.ctx.evaluator().evaluate(expr);
      switch (val.data) {
        .poison => break :blk model.Type{.intrinsic = .poison},
        .@"type" => |*tval| break :blk tval.t,
        else => unreachable,
      }
    } else (try fc.dres.intpr.probeType(
        fgen.body, .{.kind = .intermediate, .resolve = &fc.ctx})) orelse blk: {
          // this happens if there are still unknown symbols in the function
          // body. These are errors since everything resolvable has been
          // resolved at this point. we call interpret solely for issuing error
          // messages.
          _ = try fc.dres.intpr.interpret(fgen.body);
          fgen.body.data = .poison;
          break :blk model.Type{.intrinsic = .poison};
        };
    if (new_type.eql(fgen.cur_returns)) return false
    else {
      fgen.cur_returns = new_type;
      return true;
    }
  }
};

pub const DeclareResolution = struct {
  const Processor = graph.GraphProcessor(*DeclareResolution);

  defs: []*model.Node.Definition,
  processor: Processor,
  dep_discovery_ctx: graph.ResolutionContext,
  intpr: *Interpreter,
  in: graph.ResolutionContext.Target,

  pub fn create(intpr: *Interpreter,
                defs: []*model.Node.Definition,
                ns: u15, parent: ?model.Type) !*DeclareResolution {
    const in = if (parent) |ptype| graph.ResolutionContext.Target{.t = ptype}
               else graph.ResolutionContext.Target{.ns = ns};
    const res = try intpr.allocator.create(DeclareResolution);
    res.* = .{
      .defs = defs,
      .processor = try Processor.init(intpr.allocator, res),
      .dep_discovery_ctx = .{
        .resolveNameFn = discoverDependencies,
        .target = in,
      },
      .intpr = intpr,
      .in = in,
    };
    return res;
  }

  inline fn createStructural(self: *DeclareResolution, gen: anytype) !void {
    gen.generated = try self.intpr.ctx.global().create(model.Type.Structural);
  }

  inline fn createInstantiated(self: *DeclareResolution, gen: anytype) !void {
    gen.generated = try self.intpr.ctx.global().create(model.Type.Instantiated);
  }

  inline fn genSym(self: *DeclareResolution, name: *model.Node.Literal,
                   content: model.Symbol.Data, publish: bool) !*model.Symbol {
    const sym = try self.intpr.ctx.global().create(model.Symbol);
    sym.* = .{
      .defined_at = name.node().pos,
      .name = try self.intpr.ctx.global().dupe(u8, name.content),
      .data = content,
      .parent_type = switch (self.in) {
        .t => |t| t,
        .ns => null,
      },
    };
    if (publish) {
      try self.intpr.public_namespace.append(self.intpr.ctx.global(), sym);
    }
    return sym;
  }

  fn genSymFromValue(self: *DeclareResolution, name: *model.Node.Literal,
                     value: *model.Value, publish: bool) !*model.Symbol {
    switch (value.data) {
      .@"type" => |tref| {
        const sym = try self.genSym(name, .{.@"type" = tref.t}, publish);
        switch (tref.t) {
          .instantiated => |inst| inst.name = sym,
          else => {},
        }
        return sym;
      },
      .funcref => |fref| {
        const sym = try self.genSym(name, .{.func = fref.func}, publish);
        fref.func.name = sym;
        return sym;
      },
      .poison => return try self.genSym(name, .poison, publish),
      else => {
        self.intpr.ctx.logger.EntityCannotBeNamed(value.origin);
        return try self.genSym(name, .poison, publish);
      },
    }
  }

  pub fn execute(self: *DeclareResolution) !void {
    const ns_data = switch (self.in) {
      .ns => |index| self.intpr.namespace(index),
      .t => |t| try self.intpr.type_namespace(t),
    };

    try self.processor.firstStep();
    try self.processor.secondStep(self.intpr.allocator);
    // third step: process components in reverse topological order.

    for (self.processor.components) |first_index, cmpt_index| {
      const num_nodes = if (cmpt_index == self.processor.components.len - 1)
        self.defs.len - first_index
      else
        self.processor.components[cmpt_index + 1] - first_index;
      const defs = self.defs[first_index..first_index+num_nodes];

      // allocate all types and create their symbols. This allows referring to
      // them even when not all information (record field types, inner types,
      // default expressions) has been resolved.
      for (defs) |def| {
        switch (def.content.data) {
          .unresolved_call, .unresolved_symref => {
            // could be function defined in a previous component (that would be
            // fine). Try resolving.
            if (
              try self.intpr.tryInterpret(def.content, .{.kind = .intermediate})
            ) |expr| {
              def.content.data = .{.expression = expr};
            } else switch (def.content.data) {
              .unresolved_call, .unresolved_symref => {
                // still unresolved => cannot be resolved.
                // force error generation.
                const res = try self.intpr.interpret(def.content);
                def.content.data = .{.expression = res};
              },
              else => {},
            }
          },
          else => {},
        }

        switch (def.content.data) {
          .gen_concat => |*gc| {
            try self.createStructural(gc); continue;
          },
          .gen_enum, .gen_float => unreachable,
          .gen_intersection => |*gi| {
            try self.createStructural(gi); continue;
          },
          .gen_list => |*gl| {
            try self.createStructural(gl); continue;
          },
          .gen_map => |*gm| {
            try self.createStructural(gm); continue;
          },
          .gen_numeric => unreachable,
          .gen_optional => |*go| {
            try self.createStructural(go); continue;
          },
          .gen_paragraphs => |*gp| {
            try self.createStructural(gp); continue;
          },
          .gen_record => |*gr| {
            try self.createInstantiated(gr); continue;
          },
          .gen_textual => unreachable,
          .funcgen => continue,
          .poison => {},
          // anything that is an expression is already finished and can
          // immediately be established.
          // actually, if we encounter this, it is guaranteed to be the sole
          // entry in this component.
          .expression => |expr| switch (expr.data) {
            .poison => {},
            .value => |value| {
              const sym = try self.genSymFromValue(def.name, value, def.public);
              _ = try ns_data.tryRegister(self.intpr, sym);
              continue;
            },
            else => self.intpr.ctx.logger.EntityCannotBeNamed(def.content.pos),
          },
          else => self.intpr.ctx.logger.EntityCannotBeNamed(def.content.pos),
        }
        // establish poison symbols
        const sym = try self.genSym(def.name, .poison, def.public);
        _ = try ns_data.tryRegister(self.intpr, sym);
        def.content.data = .poison;
      }

      // resolve all references to other types in the generated types'
      // arguments. this leaves only nodes defining default values for record
      // fields unresolved, and only if the field type is explicitly given.
      {
        var tr = TypeResolver.init(self);
        for (defs) |def| {
          switch (def.content.data) {
            .gen_concat, .gen_intersection, .gen_list, .gen_map, .gen_optional,
            .gen_paragraphs =>
              try tr.process(def.content),
            .gen_record => |*rgen| {
              for (rgen.fields) |field| {
                if (field.@"type") |tnode| try tr.process(tnode);
              }
            },
            .funcgen => |*fgen| {
              if (fgen.params == .unresolved) {
                const success = switch (self.in) {
                  .ns => try self.intpr.tryInterpretFuncParams(
                    fgen, .{.kind = .final, .resolve = &tr.ctx}, null),
                  .t => |t| try self.intpr.tryInterpretFuncParams(
                    fgen, .{.kind = .final, .resolve = &tr.ctx}, t),
                };
                if (!success) {
                  const sym = try self.genSym(def.name, .poison, def.public);
                  _ = try ns_data.tryRegister(self.intpr, sym);
                  def.content.data = .poison;
                  continue;
                }
              }
            },
            else => {},
          }
        }
      }

      // do a fixpoint iteration to calculate the return types of all functions.
      // the cur_returns value of each Funcgen node is initially .every which
      // is the starting point for the iteration.
      {
        var fc = FixpointContext.init(self);

        var changed = true;
        // a maximum of 3 iterations is attempted:
        //  * first one establishes return types based on resolvable content in
        //    body.
        //  * second one re-calculates base on the return types of other
        //    functions.
        //  * third one re-calculates again to propagate changes in return types
        //    from single value to concat.
        //  * there can't be any change afterwards since there is no change that
        //    still has a fixpoint apart from transition from single-value to
        //    concat.
        // the typical worst-case – iterating against call graph order – is
        // avoided since Tarjan ordered the component contents in order.
        var iteration: u8 = 0;
        while (changed and iteration <= 2) : (iteration += 1) {
          changed = false;
          for (defs) |def| {
            switch (def.content.data) {
              .funcgen => |*fgen| if (try fc.probe(fgen)) {
                changed = true;
              },
              else => {},
            }
          }
        }
        // check if anything changes, which is then an error
        if (changed) for (defs) |def| {
          switch (def.content.data) {
            .funcgen => |*fgen| if (try fc.probe(fgen)) {
              self.intpr.ctx.logger.FailedToCalculateReturnType(
                def.content.pos);
              const sym = try self.genSym(def.name, .poison, def.public);
              _ = try ns_data.tryRegister(self.intpr, sym);
              def.content.data = .poison;
            },
            else => {},
          }
        };
      }

      // establish model.Function symbols with fully resolved signatures, and
      // all other symbols that can be constructed by now.
      for (defs) |def| {
        switch (def.content.data) {
          .funcgen => |*fgen| blk: {
            const func = (try self.intpr.tryPregenFunc(
              fgen, fgen.cur_returns, .{.kind = .final})) orelse {
                def.content.data = .poison;
                break :blk;
              };
            func.callable.sig.returns = fgen.cur_returns;
            const sym = try self.genSym(def.name, .{.func = func}, def.public);
            func.name = sym;
            _ = try ns_data.tryRegister(self.intpr, sym);
            continue;
          },
          else => {},
        }
      }

      // interpret function bodies and generate symbols for records
      for (defs) |def| {
        switch (def.content.data) {
          .gen_record => {
            const expr = try self.intpr.interpret(def.content);
            const value = try self.intpr.ctx.evaluator().evaluate(expr);
            _ = try ns_data.tryRegister(self.intpr,
              try self.genSymFromValue(def.name, value, def.public));
          },
          .funcgen => |*fgen| {
            const func = &fgen.params.pregen.data.ny;
            func.body = (try self.intpr.tryInterpretFuncBody(
              fgen, fgen.cur_returns, .{.kind = .final})).?;
          },
          else => {}
        }
      }
    }
  }

  //----------------
  // graph interface
  //----------------

  pub fn length(self: *const DeclareResolution) usize {
    return self.defs.len;
  }

  pub fn collectDeps(self: *DeclareResolution, index: usize,
                     edges: *[]usize) !void {
    self.dep_discovery_ctx.dependencies = .{};
    _ = try self.intpr.probeType(self.defs[index].content,
      .{.kind = .intermediate, .resolve = &self.dep_discovery_ctx});
    edges.* = self.dep_discovery_ctx.dependencies.items;
  }

  pub fn swap(self: *DeclareResolution, x: usize, y: usize) void {
    const tmp = self.defs[x];
    self.defs[x] = self.defs[y];
    self.defs[y] = tmp;
  }

  //----------------------------
  // ResolutionContext interface
  //----------------------------

  fn discoverDependencies(
    ctx: *graph.ResolutionContext,
    name: []const u8,
    _: model.Position,
  ) nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(DeclareResolution, "dep_discovery_ctx", ctx);
    for (self.defs) |def, i| if (std.mem.eql(u8, def.name.content, name)) {
      return graph.ResolutionContext.Result{.known = @intCast(u21, i)};
    };
    // we don't know whether this is actually known but it would be a
    // function variable, so we'll leave reporting a potential error to later
    // steps.
    return graph.ResolutionContext.Result.unknown;
  }
};