const std = @import("std");
const lib = @import("../lib.zig");
const constructors = @import("constructors.zig");
const system = @import("system.zig");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const types = nyarna.types;
const interpret = @import("../interpret.zig");
const Interpreter = interpret.Interpreter;
const Context = nyarna.Context;

fn registerMagicFunc(
  intpr: *Interpreter,
  namespace: *interpret.Namespace,
  sym: *model.Symbol,
) !void {
  try intpr.ctx.data.generic_symbols.append(intpr.ctx.global(), sym);
  const res = try namespace.data.getOrPut(intpr.allocator, sym.name);
  if (res.found_existing) {
    std.debug.print("magic: overriding '{s}'\n", .{sym.name});
  }
  res.value_ptr.* = sym;
}

fn extFuncSymbol(
  ctx: Context,
  name: []const u8,
  ns_dependent: bool,
  bres: types.SigBuilderResult,
  p: *const lib.Provider,
) !?*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.defined_at = model.Position.intrinsic();
  ret.name = name;
  if (try lib.extFunc(ctx, name, bres, ns_dependent, p)) |func| {
    func.name = ret;
    ret.data = .{.func = func};
    return ret;
  } else {
    ctx.global().destroy(ret);
    return null;
  }
}

const Impl = lib.Provider.Wrapper(struct {
  /// \magic defines the functions implicitly available in every namespace.
  pub fn magic(
    intpr: *Interpreter,
    pos: model.Position,
    ns: u15,
    arg: *model.Node,
  ) nyarna.Error!*model.Node {
    var collector = system.DefCollector{.dt = intpr.ctx.types().definition()};
    try collector.collect(arg, intpr);
    try collector.allocate(intpr.allocator);
    try collector.append(arg, intpr, false);
    const decls = collector.finish();

    const namespace = intpr.namespace(ns);
    for (decls) |decl| {
      switch (decl.content.data) {
        .gen_concat, .gen_enum, .gen_float, .gen_intersection, .gen_list,
        .gen_map, .gen_numeric, .gen_optional, .gen_sequence, .gen_prototype,
        .gen_record, .gen_textual, .gen_unique =>
          intpr.ctx.logger.TypeInMagic(decl.node().pos),
        .funcgen => intpr.ctx.logger.NyFuncInMagic(decl.node().pos),
        .builtingen => |*bg| {
          if (try intpr.tryInterpretBuiltin(bg, .{.kind = .intermediate})) {
            const ret_type = switch (
              (try intpr.ctx.evaluator().evaluate(bg.returns.expr)).data
            ) {
              .poison => continue,
              .@"type" => |tv| tv.t,
              else => unreachable,
            };
            const locations = &bg.params.resolved.locations;
            var finder = (try intpr.processLocations(
              locations, .{.kind = .final})) orelse continue;
            const finder_res = try finder.finish(ret_type, false);
            var builder = try types.SigBuilder.init(
              intpr.ctx, locations.len, ret_type,
              finder_res.needs_different_repr);
            for (locations.*) |loc| try builder.push(loc.value);
            const builder_res = builder.finish();

            const sym = (
              try extFuncSymbol(
                intpr.ctx, try intpr.ctx.global().dupe(u8, decl.name.content),
                true, builder_res, &system.instance.provider)
            ) orelse continue;
            sym.defined_at = decl.name.node().pos;
            try registerMagicFunc(intpr, namespace, sym);
          }
        },
        else => intpr.ctx.logger.EntityCannotBeNamed(decl.node().pos),
      }
    }
    return intpr.node_gen.void(pos);
  }

  pub fn unique(
    intpr        : *Interpreter,
    pos          : model.Position,
    constr_params: ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgUnique(pos, constr_params)).node();
  }

  pub fn prototype(
    intpr      : *Interpreter,
    pos        : model.Position,
    _          : u15,
    params     : *model.Node,
    constructor: ?*model.Node,
    funcs      : ?*model.Node,
  ) nyarna.Error!*model.Node {
    return (
      try intpr.node_gen.tgPrototype(pos, params, constructor, funcs)
    ).node();
  }
});

fn typeSymbol(
  ctx : Context,
  name: []const u8,
  t   : model.Type,
) !*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.@"type" = t},
    .parent_type = null,
  };
  return ret;
}

fn prototypeSymbol(
  ctx : Context,
  name: []const u8,
  pt  : model.Prototype,
) !*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.prototype = pt},
    .parent_type = null,
  };
  return ret;
}

fn prototypeConstructor(
  ctx : Context,
  name: []const u8,
  bres: types.SigBuilderResult,
) !types.Constructor {
  const prototypes = constructors.Prototypes.init();
  return types.Constructor{
    .callable = try bres.createCallable(ctx.global(), .prototype),
    .impl_index = (try lib.registerExtImpl(
      ctx, &prototypes.provider, name, bres.sig.isKeyword())).?,
  };
}

/// magicModule creates and returns the module that is to be loaded in order to
/// interpret system.ny.
pub fn magicModule(ctx: Context) !*model.Module {
  const module = try ctx.global().create(model.Module);
  module.root = try ctx.createValueExpr(
    try ctx.values.@"void"(model.Position.intrinsic()));
  module.symbols = try ctx.global().alloc(*model.Symbol, 9);
  var index: usize = 0;

  const impl = Impl.init();
  const systemImpl = system.Impl.init();
  const t = ctx.types();
  var b: types.SigBuilder = undefined;

  const loc_syntax = // zig 0.9.0 crashes when inlining this
    model.BlockConfig.SyntaxDef{.pos = model.Position.intrinsic(), .index = 0};
  const location_block = try ctx.values.blockHeader(
    model.Position.intrinsic(), model.BlockConfig{
      .syntax = loc_syntax,
      .map = &.{},
      .off_colon = null,
      .off_comment = null,
      .full_ast = null,
    }, null);

  const def_syntax = // zig 0.9.0 crashes when inlining this
    model.BlockConfig.SyntaxDef{.pos = model.Position.intrinsic(), .index = 1};
  const definition_block = try ctx.values.blockHeader(
    model.Position.intrinsic(), model.BlockConfig{
      .syntax = def_syntax,
      .map = &.{},
      .off_colon = null,
      .off_comment = null,
      .full_ast = null,
    }, null);

  //-------------------------------
  // types we need inside of \magic
  //-------------------------------

  module.symbols[index] = try typeSymbol(ctx, "Type", t.@"type"());
  index += 1;

  module.symbols[index] = try typeSymbol(ctx, "Ast", t.ast());
  index += 1;

  module.symbols[index] = try typeSymbol(ctx, "FrameRoot", t.frameRoot());
  index += 1;

  module.symbols[index] = try prototypeSymbol(ctx, "Optional", .optional);
  index += 1;
  // Optional gets called in \magic so we also need to pre-register its
  // constructor.
  b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
  try b.push((try ctx.values.intLocation("inner", t.ast())).withPrimary(
    model.Position.intrinsic()));
  ctx.types().constructors.prototypes.optional = try
    prototypeConstructor(ctx, "Optional", b.finish());

  module.symbols[index] = try prototypeSymbol(ctx, "List", .list);
  index += 1;

  b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
  try b.push((try ctx.values.intLocation("inner", t.ast())).withPrimary(
    model.Position.intrinsic()));
  ctx.types().constructors.prototypes.list = try
    prototypeConstructor(ctx, "List", b.finish());

  //-------------------
  // available keywords
  //-------------------

  b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
  try b.push(
    (try ctx.values.intLocation("decls", ctx.types().ast())).withPrimary(
      model.Position.intrinsic()).withHeader(definition_block));
  module.symbols[index] =
    (try extFuncSymbol(ctx, "magic", true, b.finish(), &impl.provider)).?;
  index += 1;

  b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
  try b.push((try ctx.values.intLocation("params", t.ast())).withPrimary(
    model.Position.intrinsic()).withHeader(location_block));
  module.symbols[index] = (
    try extFuncSymbol(
      ctx, "keyword", false, b.finish(), &systemImpl.provider)
  ).?;
  index += 1;

  b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
  try b.push((try ctx.values.intLocation(
    "constrParams", (try ctx.types().optional(t.ast())).?
  )).withPrimary(model.Position.intrinsic()).withHeader(location_block));
  module.symbols[index] = (
    try extFuncSymbol(ctx, "unique", false, b.finish(), &impl.provider)
  ).?;
  index += 1;

  b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
  try b.push((try ctx.values.intLocation("params", t.ast())).withPrimary(
    model.Position.intrinsic()).withHeader(location_block));
  try b.push((try ctx.values.intLocation(
    "constructor", (try t.optional(t.ast())).?)).withHeader(location_block));
  try b.push((
    try ctx.values.intLocation("funcs", (try t.optional(t.ast())).?)
  ).withHeader(definition_block));
  module.symbols[index] = (
    try extFuncSymbol(ctx, "prototype", true, b.finish(), &impl.provider)
  ).?;
  index += 1;

  std.debug.assert(index == module.symbols.len);

  return module;
}