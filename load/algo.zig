const std = @import("std");

const graph = @import("graph.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
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

  fn init(dres: *DeclareResolution) TypeResolver {
    return .{
      .dres = dres,
      .ctx = .{
        .resolveInSiblingDefinitions = linkTypes,
        .target = dres.in,
      },
    };
  }

  inline fn uStruct(gen: anytype) graph.ResolutionContext.Result {
    return .{.unfinished_type = .{.structural = gen.generated.?}};
  }

  fn linkTypes(ctx: *graph.ResolutionContext, item: *model.Node)
      nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(TypeResolver, "ctx", ctx);
    switch (item.data) {
      .unresolved_call => {
        self.dres.intpr.ctx.logger.UnfinishedCallInTypeArg(item.pos);
        return .failed;
      },
      .unresolved_symref => |*uref| {
        for (self.dres.defs) |def| {
          if (std.mem.eql(u8, def.name.content, uref.name)) {
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
                self.dres.intpr.ctx.logger.NotAType(item.pos);
                return graph.ResolutionContext.Result.failed;
              },
              else => unreachable,
            }
          }
        }
        return graph.ResolutionContext.Result{.known = null};
      },
      else => unreachable,
    }
  }

  fn process(self: *TypeResolver, node: *model.Node) !void {
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
        .resolveInSiblingDefinitions = funcReturns,
        .target = dres.in,
      },
    };
  }

  fn funcReturns(ctx: *graph.ResolutionContext, item: *model.Node)
      nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(TypeResolver, "ctx", ctx);
    switch (item.data) {
      .unresolved_access => {
        // TODO: function or type could be used as value.
        return graph.ResolutionContext.Result.failed;
      },
      .unresolved_call => |*ucall| {
        const name = switch (self.dres.in) {
          .ns => ucall.target.data.unresolved_symref.name,
          .t => |t| blk: {
            const uacc = &ucall.target.data.unresolved_access;
            // TODO: deeper access chain
            if (subjectIsType(uacc, t)) {
              break :blk uacc.id;
            } else {
              const subject_type = (try self.dres.intpr.probeType(
                uacc.subject, .{.kind = .intermediate, .resolve = ctx})) orelse
                return graph.ResolutionContext.Result.failed;
              if (subject_type.eql(t)) {
                break :blk uacc.id;
              } else return graph.ResolutionContext.Result.failed;
            }
          }
        };

        // TODO: make chains support partial resolution and use that here
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
        unreachable;
      },
      .unresolved_symref => {
        // TODO: function could be used as value.
        self.dres.intpr.ctx.logger.UnknownSymbol(item.pos);
        return graph.ResolutionContext.Result.failed;
      },
      else => unreachable,
    }
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
        fgen.body, .{.kind = .intermediate, .resolve = &fc.ctx})).?;
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
        .resolveInSiblingDefinitions = discoverDependencies,
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
      else => unreachable,
    }
  }

  pub fn execute(self: *DeclareResolution) !void {
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
          .gen_concat => |*gc| try self.createStructural(gc),
          .gen_enum, .gen_float => unreachable,
          .gen_intersection => |*gi| try self.createStructural(gi),
          .gen_list => |*gl| try self.createStructural(gl),
          .gen_map => |*gm| try self.createStructural(gm),
          .gen_numeric => unreachable,
          .gen_optional => |*go| try self.createStructural(go),
          .gen_paragraphs => |*gp| try self.createStructural(gp),
          .gen_record => |*gr| try self.createInstantiated(gr),
          .gen_textual => unreachable,
          .funcgen => {},
          else => {},
        }
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
              def.content.data = .poison;
            },
            else => {},
          }
        };
      }

      // establish model.Function symbols with fully resolved signatures, and
      // all other symbols that can be constructed by now.
      const ns_data = switch (self.in) {
        .ns => |index| self.intpr.namespace(index),
        .t => |t| try self.intpr.type_namespace(t),
      };
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
          .poison => {},
          .expression => |expr| {
            const value = try self.intpr.ctx.evaluator().evaluate(expr);
            _ = try ns_data.tryRegister(self.intpr,
              try self.genSymFromValue(def.name, value, def.public));
            continue;
          },
          else => continue,
        }
        // also establish poison symbols
        const sym = try self.genSym(def.name, .poison, def.public);
        _ = try ns_data.tryRegister(self.intpr, sym);
        def.content.data = .poison;
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
      ctx: *graph.ResolutionContext, item: *model.Node)
      nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(DeclareResolution, "dep_discovery_ctx", ctx);
    switch (item.data) {
      .unresolved_access => |*uacc| {
        const res = try self.intpr.probeType(
          uacc.subject, .{.kind = .intermediate, .resolve = ctx});
        switch (self.in) {
          .ns => {},
          .t => if (res == null) {
            // typically means that we hit a variable in a function body. If so,
            // we just assume that this variable has the \declare type.
            // This means we'll resolve the name of this access in our defs to
            // discover dependencies.
            // This will overreach in rare cases but we accept that for now.
            for (self.defs) |def, i| {
              if (std.mem.eql(u8, def.name.content, uacc.id)) {
                return graph.ResolutionContext.Result{
                  .known = @intCast(u21, i)};
              }
            }
          },
        }
      },
      .unresolved_call => |*uc| {
        _ = try self.intpr.probeType(
          uc.target, .{.kind = .intermediate, .resolve = ctx});
        for (uc.proto_args) |*arg| {
          _ = try self.intpr.probeType(
            arg.content, .{.kind = .intermediate, .resolve = ctx});
        }
      },
      .unresolved_symref => |*ur| {
        for (self.defs) |def, i| if (std.mem.eql(u8, def.name.content, ur.name))
          return graph.ResolutionContext.Result{.known = @intCast(u21, i)};
      },
      else => unreachable,
    }
    // we don't know whether this is actually known but it would be a
    // function variable, so we'll leave reporting a potential error to later
    // steps.
    return graph.ResolutionContext.Result{.known = null};
  }
};