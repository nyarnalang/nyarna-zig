const std = @import("std");

const graph = @import("graph.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const Interpreter = @import("interpret.zig").Interpreter;

fn isPrototype(ef: *model.Symbol.ExtFunc) bool {
  return ef.callable.kind == .prototype;
}

const TypeResolver = struct {
  ctx: graph.ResolutionContext,
  dres: *DeclareResolution,

  fn init(dres: *DeclareResolution) TypeResolver {
    return .{
      .dres = dres,
      .ctx = .{
        .resolveInSiblingDefinitions = linkTypes,
        .ns = dres.ns,
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
        self.dres.intpr.ctx.logger.UnfinishedCallAsTypeArg(item.pos);
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
        unreachable;
      },
      else => unreachable,
    }
  }

  fn process(self: *TypeResolver, node: *model.Node) !void {
    const expr = (try self.dres.intpr.tryInterpret(node,
      .{.kind = .intermediate, .resolve = &self.ctx})) orelse return;
    node.data = .{.expression = expr};
  }
};

pub const DeclareResolution = struct {
  const Processor = graph.GraphProcessor(*DeclareResolution);

  defs: []*model.Node.Definition,
  processor: Processor,
  dep_discovery_ctx: graph.ResolutionContext,
  intpr: *Interpreter,
  ns: u15,

  pub fn create(intpr: *Interpreter,
                defs: []*model.Node.Definition,
                ns: u15) !*DeclareResolution {
    var res = try intpr.allocator().create(DeclareResolution);
    res.* = .{
      .defs = defs,
      .processor = try Processor.init(intpr.allocator(), res),
      .dep_discovery_ctx = .{
        .resolveInSiblingDefinitions = discoverDependencies,
        .ns = ns,
      },
      .intpr = intpr,
      .ns = ns,
    };
    return res;
  }

  inline fn createStructural(self: *DeclareResolution, gen: anytype) !void {
    gen.generated = try self.intpr.ctx.global().create(model.Type.Structural);
  }

  inline fn createInstantiated(self: *DeclareResolution, gen: anytype) !void {
    gen.generated = try self.intpr.ctx.global().create(model.Type.Instantiated);
  }

  pub fn execute(self: *DeclareResolution) !void {
    try self.processor.firstStep();
    try self.processor.secondStep(self.intpr.allocator());
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
            .gen_paragraphs, .gen_record => try tr.process(def.content),
            else => {},
          }
        }
      }

      // our types are now usable. based on those, do a fixpoint iteration to
      // calculate the return types of all functions.
      // TODO.

      // establish model.Function values with fully resolved signatures. TODO.

      // interpret function bodies and default expressions using the established
      // function definitions. TODO.

      // finally, generate symbols for all entities
      const ns_data = self.intpr.namespace(self.ns);
      for (defs) |def| {
        const expr = try self.intpr.interpret(def.content);
        const value = try self.intpr.ctx.evaluator().evaluate(expr);
        const sym = try self.intpr.ctx.global().create(model.Symbol);
        sym.* = .{
          .defined_at = def.name.node().pos,
          .name = def.name.content,
          .data = undefined,
        };
        switch (value.data) {
          .@"type" => |t| {
            sym.data = .{.@"type" = t.t};
            switch (t.t) {
              .instantiated => |inst| inst.name = sym,
              else => {},
            }
          },
          .@"funcref" => |f| {
            sym.data = .{.func = f.func};
            f.func.name = sym;
          },
          .poison => unreachable,
          else => unreachable,
        }
        _ = try ns_data.tryRegister(self.intpr, sym);
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
      .unresolved_symref => |*ur| {
        for (self.defs) |def, i| if (std.mem.eql(u8, def.name.content, ur.name))
          return graph.ResolutionContext.Result{.known = @intCast(u21, i)};
        return graph.ResolutionContext.Result.failed;
      },
      .unresolved_call => |*uc| {
        _ = try self.intpr.probeType(
          uc.target, .{.kind = .intermediate, .resolve = ctx});
        for (uc.proto_args) |*arg| {
          _ = try self.intpr.probeType(
            arg.content, .{.kind = .intermediate, .resolve = ctx});
        }
        return graph.ResolutionContext.Result{.known = null};
      },
      else => unreachable,
    }
  }

};