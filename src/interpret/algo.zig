const std = @import("std");

const graph = @import("graph.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const chains = @import("chains.zig");
const lib = @import("../lib.zig");
const interpret = @import("../interpret.zig");
const Interpreter = interpret.Interpreter;

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

/// A graph.ResolutionContext that resolves the name "This" to the .prototype
/// type. Used for loading prototype functions.
const PrototypeFuncs = struct {
  ctx: graph.ResolutionContext,
  nctx: nyarna.Context,

  fn init(dres: *DeclareResolution) PrototypeFuncs {
    return .{
      .ctx = .{
        .resolveNameFn = resolvePt,
        .target = dres.in,
      },
      .nctx = dres.intpr.ctx,
    };
  }

  fn resolvePt(
    ctx: *graph.ResolutionContext,
    name: []const u8,
    name_pos: model.Position,
  ) nyarna.Error!graph.ResolutionContext.Result {
    const self = @fieldParentPtr(PrototypeFuncs, "ctx", ctx);
    if (std.mem.eql(u8, name, "This")) {
      return graph.ResolutionContext.Result{
        .unfinished_type = self.nctx.types().prototype(),
      };
    } else {
      self.nctx.logger.UnknownSymbol(name_pos, name);
      return graph.ResolutionContext.Result.failed;
    }
  }
};

/// A graph.ResolutionContext that resolves symbol references to type symbols
/// within the same \declare call. The referenced types are unfinished and must
/// only be used to construct types, never be called or used as value while this
/// context is active.
const TypeResolver = struct {
  ctx: graph.ResolutionContext,
  dres: *DeclareResolution,
  worklist: std.ArrayListUnmanaged(*model.Node) = .{},
  ns_data: *interpret.Namespace,

  fn init(dres: *DeclareResolution, ns: *interpret.Namespace) TypeResolver {
    return .{
      .dres = dres,
      .ctx = .{
        .resolveNameFn = linkTypes,
        .target = dres.in,
      },
      .ns_data = ns,
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
        try self.process(def);
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
          .gen_unique => |*gu| return graph.ResolutionContext.Result{
            .unfinished_type = gu.generated,
          },
          .builtingen, .funcgen, .gen_prototype => {
            self.dres.intpr.ctx.logger.NotAType(name_pos);
            return graph.ResolutionContext.Result.failed;
          },
          .expression => |expr| switch (expr.data) {
            .poison => return graph.ResolutionContext.Result.failed,
            .value => |value| switch (value.data) {
              .poison => return graph.ResolutionContext.Result.failed,
              .@"type" => |vt| {
                return graph.ResolutionContext.Result{
                  .unfinished_type = vt.t,
                };
              },
              else => {
                const tt = self.dres.intpr.ctx.types().@"type"();
                self.dres.intpr.ctx.logger.ExpectedExprOfTypeXGotY(
                  name_pos, &[_]model.Type{tt, expr.expected_type});
                return graph.ResolutionContext.Result.failed;
              }
            },
            else => unreachable,
          },
          .poison => return graph.ResolutionContext.Result.failed,
          else => unreachable,
        }
      }
    }
    return graph.ResolutionContext.Result.unknown;
  }

  fn process(self: *TypeResolver, def: *model.Node.Definition) !void {
    switch (def.content.data) {
      .expression, .poison, .gen_record, .gen_unique, .funcgen => return,
      .gen_concat, .gen_intersection, .gen_list, .gen_map, .gen_optional,
      .gen_paragraphs, .gen_prototype => {},
      else => unreachable,
    }
    for (self.worklist.items) |wli, index| if (wli == def.content) {
      const pos_list = try self.dres.intpr.allocator.alloc(
        model.Position, self.worklist.items.len - index - 1);
      for (pos_list) |*item, pindex| {
        item.* = self.worklist.items[self.worklist.items.len - 1 - pindex].pos;
      }
      self.dres.intpr.ctx.logger.CircularType(def.content.pos, pos_list);
      def.content.data = .poison;
      return;
    };
    try self.worklist.append(self.dres.intpr.allocator, def.content);
    defer _ = self.worklist.pop();

    const sym = if (try self.dres.intpr.tryInterpret(def.content,
        .{.kind = .final, .resolve = &self.ctx})) |expr| blk: {
      const value = try self.dres.intpr.ctx.evaluator().evaluate(expr);
      switch (value.data) {
        .poison => {
          def.content.data = .poison;
          break :blk try self.dres.genSym(def.name, .poison, def.public);
        },
        .@"type" => {
          def.content.data = .{
            .expression = try self.dres.intpr.ctx.createValueExpr(value),
          };
          break :blk try self.dres.genSymFromValue(def.name, value, def.public);
        },
        else => unreachable,
      }
    } else blk: {
      def.content.data = .poison;
      break :blk try self.dres.genSym(def.name, .poison, def.public);
    };
    _ = try self.ns_data.tryRegister(self.dres.intpr, sym);
  }
};

/// A graph.ResolutionContext that returns the current return type of a
/// referenced, unfinished function. That type must only be used to calculate
/// the return type of other unfinished functions. Only when a fixpoint is
/// reached will the calculated type become the definite return type of the
/// function.
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
        .poison => break :blk fc.dres.intpr.ctx.types().poison(),
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
        break :blk fc.dres.intpr.ctx.types().poison();
      };
    if (new_type.eql(fgen.cur_returns)) {
      return false;
    } else {
      fgen.cur_returns = new_type;
      return true;
    }
  }
};

/// A graph.Processor that handles symbols declared within a \declare call.
pub const DeclareResolution = struct {
  const Processor = graph.Processor(*DeclareResolution);

  defs: []*model.Node.Definition,
  processor: Processor,
  dep_discovery_ctx: graph.ResolutionContext,
  intpr: *Interpreter,
  in: graph.ResolutionContext.Target,

  pub fn create(
    intpr: *Interpreter,
    defs: []*model.Node.Definition,
    ns: u15,
    parent: ?model.Type,
  ) !*DeclareResolution {
    const in: graph.ResolutionContext.Target =
      if (parent) |ptype| .{.t = ptype} else .{.ns = ns};
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

  fn genSym(
    self: *DeclareResolution,
    name: *model.Node.Literal,
    content: model.Symbol.Data,
    publish: bool,
  ) !*model.Symbol {
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

  fn genSymFromValue(
    self: *DeclareResolution,
    name: *model.Node.Literal,
    value: *model.Value,
    publish: bool,
  ) !*model.Symbol {
    switch (value.data) {
      .@"type" => |tref| {
        const sym = try self.genSym(name, .{.@"type" = tref.t}, publish);
        switch (tref.t) {
          .instantiated => |inst| if (inst.name == null) {inst.name = sym;},
          else => {},
        }
        return sym;
      },
      .funcref => |fref| {
        const sym = try self.genSym(name, .{.func = fref.func}, publish);
        if (fref.func.name == null) {fref.func.name = sym;}
        return sym;
      },
      .poison => return try self.genSym(name, .poison, publish),
      else => {
        self.intpr.ctx.logger.EntityCannotBeNamed(value.origin);
        return try self.genSym(name, .poison, publish);
      },
    }
  }

  fn genConstructor(
    self: *DeclareResolution,
    def: *model.Node.Definition,
    params: *model.locations.List(void),
    ret_type: model.Type,
    provider: *const lib.Provider,
    resolve: ?*graph.ResolutionContext,
  ) !?nyarna.types.Constructor {
    if (
      (try self.intpr.tryInterpretLocationsList(
        params, .{.kind = .final, .resolve = resolve}))
    ) {
      var finder = (
        try self.intpr.processLocations(
          &params.resolved.locations, .{.kind = .final})
      ) orelse return null;

      const finder_res = try finder.finish(ret_type, true);
      var builder = try nyarna.types.SigBuilder.init(
        self.intpr.ctx, params.resolved.locations.len, ret_type,
        finder_res.needs_different_repr);
      for (params.resolved.locations) |loc| try builder.push(loc.value);
      const builder_res = builder.finish();

      const index = (
        try lib.registerExtImpl(
          self.intpr.ctx, provider, def.name.content,
          builder_res.sig.isKeyword())
      ) orelse {
        self.intpr.ctx.logger.DoesntHaveConstructor(
          def.name.node().pos, def.name.content);
        return null;
      };
      return nyarna.types.Constructor{
        .impl_index = index,
        .callable = try builder_res.createCallable(
          self.intpr.ctx.global(), .@"type"),
      };
    } else return null;
  }

  fn genParams(
    self: *DeclareResolution,
    refs: []model.locations.Ref,
  ) ![]*model.Value.Location {
    const locs =
      try self.intpr.ctx.global().alloc(*model.Value.Location, refs.len);
    var next_loc: usize = 0;
    for (refs) |input| {
      switch (input) {
        .node => |node| {
          const expr = try self.intpr.interpret(node.node());
          const value = try self.intpr.ctx.evaluator().evaluate(expr);
          switch (value.data) {
            .poison => {},
            .location => |*lvalue| {
              locs[next_loc] = lvalue;
              next_loc += 1;
            },
            else => unreachable,
          }
        },
        .value => |value| {
          locs[next_loc] = value;
          next_loc += 1;
        }
      }
    }
    return locs[0..next_loc];
  }

  fn definePrototype(
    self: *DeclareResolution,
    def: *model.Node.Definition,
    gp: *model.Node.tg.Prototype,
    ns_data: *interpret.Namespace,
  ) !bool {
    const constructor = (
      try self.genConstructor(
        def, &gp.params, self.intpr.ctx.types().ast(),
        &lib.constructors.prototypes.provider, null)
    ) orelse return false;
    const types = self.intpr.ctx.types();
    const prototype: model.Prototype =
      switch (std.hash.Adler32.hash(def.name.content)) {
      std.hash.Adler32.hash("Concat") => .concat,
      std.hash.Adler32.hash("Enum") => .@"enum",
      std.hash.Adler32.hash("Float") => .float,
      std.hash.Adler32.hash("Intersection") => .intersection,
      std.hash.Adler32.hash("List") => .list,
      std.hash.Adler32.hash("Map") => .map,
      std.hash.Adler32.hash("Numeric") => .numeric,
      std.hash.Adler32.hash("Optional") => .optional,
      std.hash.Adler32.hash("Paragraphs") => .paragraphs,
      std.hash.Adler32.hash("Record") => .record,
      std.hash.Adler32.hash("Textual") => .textual,
      else => unreachable,
    };
    const sym =
      try self.genSym(def.name, .{.prototype = prototype}, def.public);
    _ = try ns_data.tryRegister(self.intpr, sym);
    const pt: *nyarna.types.PrototypeFuncs = switch (prototype) {
      .concat   => blk: {
        types.constructors.prototypes.concat       = constructor;
        break :blk &types.prototype_funcs.concat;
      },
      .@"enum"  => blk: {
        types.constructors.prototypes.@"enum"      = constructor;
        break :blk &types.prototype_funcs.@"enum";
      },
      .float    => blk: {
        types.constructors.prototypes.float        = constructor;
        break :blk &types.prototype_funcs.float;
      },
      .intersection => blk: {
        types.constructors.prototypes.intersection = constructor;
        break :blk &types.prototype_funcs.intersection;
      },
      .list     => blk: {
        types.constructors.prototypes.list         = constructor;
        break :blk &types.prototype_funcs.list;
      },
      .map      => blk: {
        types.constructors.prototypes.map          = constructor;
        break :blk &types.prototype_funcs.map;
      },
      .numeric  => blk: {
        types.constructors.prototypes.numeric      = constructor;
        break :blk &types.prototype_funcs.numeric;
      },
      .optional => blk: {
        types.constructors.prototypes.optional     = constructor;
        break :blk &types.prototype_funcs.optional;
      },
      .paragraphs => blk: {
        types.constructors.prototypes.paragraphs   = constructor;
        break :blk &types.prototype_funcs.paragraphs;
      },
      .record   => blk: {
        types.constructors.prototypes.record       = constructor;
        break :blk &types.prototype_funcs.record;
      },
      .textual  => blk: {
        types.constructors.prototypes.textual      = constructor;
        break :blk &types.prototype_funcs.textual;
      },
    };
    if (gp.funcs) |funcs| {
      var pfuncs = PrototypeFuncs.init(self);
      var collector = lib.system.DefCollector{
        .dt = types.definition(),
      };
      try collector.collect(funcs, self.intpr);
      try collector.allocate(self.intpr.allocator);
      try collector.append(funcs, self.intpr, false);
      const func_defs = collector.finish();
      const def_items = try self.intpr.ctx.global().alloc(
        nyarna.types.PrototypeFuncs.Item, func_defs.len);
      var next: usize = 0;
      for (func_defs) |fdef| switch (fdef.content.data) {
        .unresolved_call, .unresolved_symref => {
          if (
            try self.intpr.tryInterpret(fdef.content, .{.kind = .intermediate})
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
        else => {}
      };

      for (func_defs) |fdef| {
        switch (fdef.content.data) {
          .builtingen => |*bg| if (
            try self.intpr.tryInterpretBuiltin(
              bg, .{.kind = .intermediate, .resolve = &pfuncs.ctx})
          ) {
            const impl_name = try self.intpr.allocator.alloc(
              u8, def.name.content.len + 2 + fdef.name.content.len
            );
            std.mem.copy(u8, impl_name, def.name.content);
            std.mem.copy(u8, impl_name[def.name.content.len..], "::");
            std.mem.copy(
              u8, impl_name[def.name.content.len + 2..], fdef.name.content);
            const impl_index = (
              try lib.registerExtImpl(self.intpr.ctx,
                self.intpr.builtin_provider.?, impl_name, false)
            ) orelse {
              self.intpr.ctx.logger.UnknownBuiltin(
                fdef.name.node().pos, impl_name);
              self.intpr.allocator.free(impl_name);
              continue;
            };


            def_items[next] = .{
              .name = try self.intpr.ctx.values.textScalar(
                fdef.node().pos, types.raw(),
                try self.intpr.ctx.global().dupe(u8, fdef.name.content)),
              .params = try self.genParams(bg.params.resolved.locations),
              .returns = bg.returns.value,
              .impl_index = impl_index,
            };
            next += 1;
          } else {
            _ = try self.intpr.tryInterpretBuiltin(bg, .{.kind = .final});
          },
          .expression => |expr| {
            if (!expr.expected_type.isInst(.poison)) {
              self.intpr.ctx.logger.IllegalContentInPrototypeFuncs(
                fdef.node().pos);
            }
          },
          else => self.intpr.ctx.logger.IllegalContentInPrototypeFuncs(
            fdef.node().pos),
        }
      }
      pt.set(def_items[0..next]);
    }
    if (gp.constructor) |constr| {
      const impl_index = (
        try lib.registerExtImpl(self.intpr.ctx,
          &lib.constructors.types.provider, def.name.content, false)
      ) orelse {
        self.intpr.ctx.logger.DoesntHaveConstructor(
          constr.pos, def.name.content);
        return true;
      };

      var list: model.locations.List(void) = .{.unresolved = constr};
      if (try self.intpr.tryInterpretLocationsList(&list, .{.kind = .final})) {
        pt.constructor = .{
          .impl_index = impl_index,
          .params = try self.genParams(list.resolved.locations),
        };
      }
    }
    return true;
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

      // ensure no more unresolved calls or expressions exist
      for (defs) |def| switch (def.content.data) {
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
      };

      // allocate all types and create their symbols. This allows referring to
      // them even when not all information (record field types, inner types,
      // default expressions) has been resolved.
      alloc_types: for (defs) |def| {
        while (true) switch (def.content.data) {
          .gen_concat => |*gc| {
            try self.createStructural(gc); continue :alloc_types;
          },
          .gen_enum, .gen_float => unreachable,
          .gen_intersection => |*gi| {
            try self.createStructural(gi); continue :alloc_types;
          },
          .gen_list => |*gl| {
            try self.createStructural(gl); continue :alloc_types;
          },
          .gen_map => |*gm| {
            try self.createStructural(gm); continue :alloc_types;
          },
          .gen_numeric => unreachable,
          .gen_optional => |*go| {
            try self.createStructural(go); continue :alloc_types;
          },
          .gen_paragraphs => |*gp| {
            try self.createStructural(gp); continue :alloc_types;
          },
          .gen_prototype => |*gp| {
            if (try self.definePrototype(def, gp, ns_data))
              continue :alloc_types
            else break;
          },
          .gen_record => |*gr| {
            const inst =
              try self.intpr.ctx.global().create(model.Type.Instantiated);
            inst.* = .{
              .at = def.content.pos,
              .name = null,
              .data = .{.record = .{.constructor = undefined}},
            };
            gr.generated = inst;
            continue :alloc_types;
          },
          .gen_textual => unreachable,
          .gen_unique => |*gu| {
            const types = self.intpr.ctx.types();
            gu.generated = switch (std.hash.Adler32.hash(def.name.content)) {
              std.hash.Adler32.hash("Ast") => types.ast(),
              std.hash.Adler32.hash("BlockHeader") => types.blockHeader(),
              std.hash.Adler32.hash("Definition") => types.definition(),
              std.hash.Adler32.hash("FrameRoot") => types.frameRoot(),
              std.hash.Adler32.hash("Literal") => types.literal(),
              std.hash.Adler32.hash("Location") => types.location(),
              std.hash.Adler32.hash("Raw") => types.raw(),
              std.hash.Adler32.hash("Space") => types.space(),
              std.hash.Adler32.hash("Type") => types.@"type"(),
              std.hash.Adler32.hash("Void") => types.@"void"(),
              else => {
                self.intpr.ctx.logger.UnknownUnique(
                  def.name.node().pos, def.name.content);
                break;
              }
            };
            const sym = try self.genSym(
              def.name, .{.@"type" = gu.generated}, def.public);
            if (try ns_data.tryRegister(self.intpr, sym)) {
              std.debug.assert(gu.generated.instantiated.name == null);
              gu.generated.instantiated.name = sym;
            }
            continue :alloc_types;
          },
          .funcgen, .builtingen => continue :alloc_types,
          .poison => break,
          // anything that is an expression is already finished and can
          // immediately be established.
          // actually, if we encounter this, it is guaranteed to be the sole
          // entry in this component.
          .expression => |expr| switch (expr.data) {
            .poison => break,
            .value => |value| {
              const sym = try self.genSymFromValue(def.name, value, def.public);
              _ = try ns_data.tryRegister(self.intpr, sym);
              continue :alloc_types;
            },
            else => {
              const value = try self.intpr.ctx.evaluator().evaluate(expr);
              expr.data = .{.value = value};
            },
          },
          else => {
            const expr = try self.intpr.interpret(def.content);
            def.content.data = .{.expression = expr};
          }
        };
        // establish poison symbols
        const sym = try self.genSym(def.name, .poison, def.public);
        _ = try ns_data.tryRegister(self.intpr, sym);
        def.content.data = .poison;
      }

      // resolve all references to other types in the generated types'
      // arguments. this leaves only nodes defining default values for record
      // fields unresolved, and only if the field type is explicitly given.
      {
        var tr = TypeResolver.init(self, ns_data);
        for (defs) |def| {
          switch (def.content.data) {
            .builtingen => |*bgen| {
              if (
                (try self.intpr.tryInterpretLocationsList(
                 &bgen.params, .{.kind = .final, .resolve = &tr.ctx}))
              ) blk: {
                switch (bgen.returns) {
                  .value => continue,
                  .node => |rnode| {
                    const value = try self.intpr.ctx.evaluator().evaluate(
                      (
                        try self.intpr.associate(
                          rnode, self.intpr.ctx.types().@"type"(),
                          .{.kind = .final})
                      ) orelse break :blk
                    );
                    switch (value.data) {
                      .@"type" => |*tv| {
                        bgen.returns = .{.value = tv};
                        break;
                      },
                      .poison => break :blk,
                      else => unreachable,
                    }
                    continue;
                  }
                }
              }
              const sym = try self.genSym(def.name, .poison, def.public);
              _ = try ns_data.tryRegister(self.intpr, sym);
              def.content.data = .poison;
            },
            .gen_concat, .gen_intersection, .gen_list, .gen_map, .gen_optional,
            .gen_paragraphs => try tr.process(def),
            .gen_record => |*rgen| {
              if (
                !(try self.intpr.tryInterpretLocationsList(
                  &rgen.fields, .{.kind = .final, .resolve = &tr.ctx}))
              ) {
                const sym = try self.genSym(def.name, .poison, def.public);
                _ = try ns_data.tryRegister(self.intpr, sym);
                def.content.data = .poison;
              }
            },
            .gen_unique => |*gu| if (gu.constr_params) |params| {
              const ret_type = switch (gu.generated.instantiated.data) {
                // location and definition types have a keyword constructor
                // that returns an ast.
                .location, .definition => self.intpr.ctx.types().ast(),
                else => gu.generated,
              };
              var locs: model.locations.List(void) = .{.unresolved = params};
              const constructor = (
                try self.genConstructor(
                  def, &locs, ret_type, &lib.constructors.types.provider,
                  &tr.ctx)
              ) orelse continue;
              const types = self.intpr.ctx.types();
              switch (gu.generated.instantiated.data) {
                .raw        => types.constructors.raw = constructor,
                .location   => types.constructors.location = constructor,
                .definition => types.constructors.definition = constructor,
                else => unreachable,
              }
            },
            .funcgen => |*fgen| {
              if (fgen.params == .unresolved) {
                const success = try self.intpr.tryInterpretFuncParams(
                    fgen, .{.kind = .final, .resolve = &tr.ctx});
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
              .funcgen => |*fgen| if (try fc.probe(fgen)) {changed = true;},
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
          .builtingen => |*bgen| {
            if (
              try self.intpr.tryInterpretBuiltin(bgen, .{.kind = .intermediate})
            ) {
              if (self.intpr.builtin_provider) |provider| blk: {
                const ret_type = bgen.returns.value;
                const locations = &bgen.params.resolved.locations;
                var finder = (try self.intpr.processLocations(
                  locations, .{.kind = .final})) orelse break :blk;
                const finder_res = try finder.finish(ret_type.t, false);
                var builder = try nyarna.types.SigBuilder.init(
                  self.intpr.ctx, locations.len, ret_type.t,
                  finder_res.needs_different_repr);
                for (locations.*) |loc| try builder.push(loc.value);
                const builder_res = builder.finish();

                const impl_name = switch (self.in) {
                  .ns => def.name.content,
                  .t => |t| tblk: {
                    const t_name = switch (t) {
                      .instantiated => |inst| inst.name.?.name,
                      .structural => |struc| @tagName(struc.*),
                    };
                    const buffer = try self.intpr.allocator.alloc(
                      u8, t_name.len + 2 + def.name.content.len);
                    std.mem.copy(u8, buffer, t_name);
                    std.mem.copy(u8, buffer[t_name.len..], "::");
                    std.mem.copy(
                      u8, buffer[t_name.len + 2..], def.name.content);
                    break :tblk buffer;
                  }
                };
                defer if (self.in == .t) self.intpr.allocator.free(impl_name);

                const sym = try self.genSym(def.name, undefined, def.public);
                sym.data = if (
                  try lib.extFunc(
                    self.intpr.ctx, impl_name, builder_res, false, provider)
                ) |func| fblk: {
                  func.name = sym;
                  break :fblk .{.func = func};
                } else ublk: {
                  self.intpr.ctx.logger.UnknownBuiltin(
                    def.content.pos, def.name.content);
                  break :ublk .poison;
                };
                _ = try ns_data.tryRegister(self.intpr, sym);
                continue;
              } else {
                self.intpr.ctx.logger.NoBuiltinProvider(def.content.pos);
              }
              const sym = try self.genSym(def.name, .poison, def.public);
              _ = try ns_data.tryRegister(self.intpr, sym);
              def.content.data = .poison;
            }
          },
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
            const func = fgen.params.pregen;
            func.data.ny.body = (try self.intpr.tryInterpretFuncBody(
              fgen, fgen.cur_returns, .{.kind = .final})).?;
            // so that following components can call it
            def.content.data = .{.expression =
              try self.intpr.ctx.createValueExpr(
                (try self.intpr.ctx.values.funcRef(def.content.pos, func)
                ).value()),
            };
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

  pub fn collectDeps(
    self: *DeclareResolution,
    index: usize,
    edges: *[]usize,
  ) !void {
    self.dep_discovery_ctx.dependencies = .{};
    if (try self.intpr.tryInterpret(self.defs[index].content,
      .{.kind = .resolve, .resolve = &self.dep_discovery_ctx})) |expr| {
     self.defs[index].content.data = .{.expression = expr};
    }
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