const std = @import("std");
const nyarna = @import("nyarna.zig");
const Interpreter = @import("load/interpret.zig").Interpreter;
const Context = nyarna.Context;
const Evaluator = @import("runtime.zig").Evaluator;
const model = nyarna.model;
const types = nyarna.types;
const algo = @import("load/algo.zig");
const unicode = @import("load/unicode.zig");

/// A provider implements all external functions for a certain Nyarna module.
pub const Provider = struct {
  pub const KeywordWrapper = fn(
    ctx: *Interpreter, pos: model.Position,
    stack_frame: [*]model.StackItem) nyarna.Error!*model.Node;
  pub const BuiltinWrapper = fn(
    ctx: *Evaluator, pos: model.Position,
    stack_frame: [*]model.StackItem) nyarna.Error!*model.Value;

  getKeyword: fn(name: []const u8) ?KeywordWrapper,
  getBuiltin: fn(name: []const u8) ?BuiltinWrapper,

  fn Params(comptime fn_decl: std.builtin.TypeInfo.Fn) type {
    var fields: [fn_decl.args.len]std.builtin.TypeInfo.StructField = undefined;
    var buf: [2*fn_decl.args.len]u8 = undefined;
    for (fn_decl.args) |arg, index| {
      fields[index] = .{
        .name = std.fmt.bufPrint(buf[2*index..2*index+2], "{}", .{index})
          catch unreachable,
        .field_type = arg.arg_type.?,
        .is_comptime = false,
        .alignment = 0,
        .default_value = null
      };
    }

    return @Type(std.builtin.TypeInfo{
      .Struct = .{
        .layout = .Auto,
        .fields = &fields,
        .decls = &[_]std.builtin.TypeInfo.Declaration{},
        .is_tuple = true
      },
    });
  }

  /// Wrapper takes a struct containing only function definitions, and returns
  /// a type that has an init() function and a `provider` field.
  /// init() will fill provider.functions with wrapper functions that unwrap
  /// the given args and calls the original function.
  pub fn Wrapper(comptime impls: type) type {
    comptime {
      std.debug.assert(@typeInfo(impls) == .Struct);
    }

    const decls = @typeInfo(impls).Struct.decls;

    return struct {
      const Self = @This();

      provider: Provider,

      fn getTypedValue(comptime T: type, v: *model.Value) T {
        return switch (T) {
          model.Type => v.data.@"type".t,
          else => switch (@typeInfo(T)) {
            .Optional => |opt| if (v.data == .void) null
                               else getTypedValue(opt.child, v),
            .Pointer => |ptr| switch (ptr.child) {
              model.Value.TextScalar => &v.data.text,
              model.Value.Number => &v.data.number,
              model.Value.FloatNumber => &v.data.float,
              model.Value.Enum => &v.data.@"enum",
              model.Value.Record => &v.data.record,
              model.Value.Concat => &v.data.concat,
              model.Value.List => &v.data.list,
              model.Value.Map => &v.data.map,
              model.Value.TypeVal => &v.data.@"type",
              model.Value.FuncRef => &v.data.funcref,
              model.Value.Location => &v.data.location,
              model.Value.Definition => &v.data.definition,
              model.Value.Ast => &v.data.ast,
              model.Value.BlockHeader => &v.data.block_header,
              model.Value => v,
              model.Node => v.data.ast.root,
              u8 =>
                if (ptr.is_const and ptr.size == .Slice)
                  v.data.text.content
                else std.debug.panic(
                  "invalid native parameter type: {s}", .{@typeName(T)}),
              else => std.debug.panic(
                "invalid native parameter type: {s}", .{@typeName(T)}),
            },
            .Int => @intCast(T, v.data.number.content),
            else => unreachable,
          },
        };
      }

      fn SingleWrapper(comptime FirstArg: type,
                       comptime decl: std.builtin.TypeInfo.Declaration,
                       comptime Ret: type) type {
        return struct {
          fn wrapper(ctx: FirstArg, pos: model.Position,
                     stack_frame: [*]model.StackItem) nyarna.Error!*Ret {
            var unwrapped: Params(@typeInfo(decl.data.Fn.fn_type).Fn) =
              undefined;
            inline for (@typeInfo(@TypeOf(unwrapped)).Struct.fields)
                |f, index| {
              unwrapped[index] = switch (index) {
                0 => ctx,
                1 => pos,
                else =>
                  getTypedValue(f.field_type, stack_frame[index - 2].value),
              };
            }
            return @call(.{}, @field(impls, decl.name), unwrapped);
          }
        };
      }

      fn ImplWrapper(comptime keyword: bool, comptime F: type) type {
        const FirstArg = if (keyword) *Interpreter else *Evaluator;
        return struct {
          fn getImpl(name: []const u8) ?F {
            inline for (decls) |decl| {
              if (decl.data != .Fn) {
                std.debug.panic("unexpected item in provider " ++
                  "(expected only fn decls): {s}", .{@tagName(decl.data)});
                unreachable;
              }
              if (@typeInfo(decl.data.Fn.fn_type).Fn.args[0].arg_type.? !=
                  FirstArg) continue;
              if (std.hash_map.eqlString(name, decl.name)) {
                return SingleWrapper(FirstArg, decl,
                  if (keyword) model.Node else model.Value).wrapper;
              }
            }
            return null;
          }
        };
      }

      fn getKeyword(name: []const u8) ?KeywordWrapper {
        return ImplWrapper(true, KeywordWrapper).getImpl(name);
      }

      fn getBuiltin(name: []const u8) ?BuiltinWrapper {
        return ImplWrapper(false, BuiltinWrapper).getImpl(name);
      }

      pub fn init() Self {
        return .{
          .provider = .{
            .getKeyword = getKeyword,
            .getBuiltin = getBuiltin,
          },
        };
      }
    };
  }
};

pub const Intrinsics = Provider.Wrapper(struct {
  //---------
  // keywords
  //---------

  fn declare(intpr: *Interpreter, pos: model.Position, ns: u15,
             parent: ?model.Type, public: *model.Node, private: *model.Node)
      nyarna.Error!*model.Node {
    var def_count: usize = 0;
    for ([_]*model.Node{public, private}) |node| switch (node.data) {
      .void, .poison => {},
      .definition => def_count += 1,
      .concat => |*con| def_count += con.items.len,
      else => {
        const expr = (try intpr.associate(
          node, (try intpr.ctx.types().concat(
            model.Type{.intrinsic = .definition})).?, .{.kind = .keyword}))
          orelse {
            node.data = .void;
            continue;
          };
        const value = try intpr.ctx.evaluator().evaluate(expr);
        if (value.data == .poison) {
          node.data = .poison;
          continue;
        }
        def_count += value.data.concat.content.items.len;
        expr.data = .{.value = value};
        node.data = .{.expression = expr};
      }
    };

    var defs = try intpr.allocator().alloc(*model.Node.Definition, def_count);
    def_count = 0;
    for ([_]*model.Node{public, private}) |node, i| switch (node.data) {
      .void, .poison => {},
      .definition => |*def| {
        if (i == 0) def.public = true;
        defs[def_count] = def;
        def_count += 1;
      },
      .concat => |*con| for (con.items) |item| {
        // TODO: check for definition
        const def = &item.data.definition;
        if (i == 0) def.public = true;
        defs[def_count] = def;
        def_count += 1;
      },
      .expression => |expr| {
        for (expr.data.value.data.concat.content.items) |item| {
          const def = &item.data.definition;
          defs[def_count] = try intpr.node_gen.definition(item.origin, .{
            .name = try intpr.node_gen.literal(def.name.value().origin, .{
              .kind = .text, .content = def.name.content,
            }),
            .root = def.root,
            .content = try intpr.node_gen.expression(
              try intpr.ctx.createValueExpr(def.content)),
            .public = i == 0,
          });
          def_count += 1;
        }
      },
      else => unreachable,
    };
    var res = try algo.DeclareResolution.create(intpr, defs, ns, parent);
    try res.execute();
    return intpr.node_gen.@"void"(pos);
  }

  fn @"if"(intpr: *Interpreter, pos: model.Position,
           condition: *model.Value.Ast, then: *model.Value.Ast,
           @"else": *model.Value.Ast) nyarna.Error!*model.Node {
    const nodes = try intpr.allocator().alloc(*model.Node, 2);
    nodes[1] = then.root;
    nodes[0] = @"else".root;

    const ret = try intpr.allocator().create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .branches = .{
          .condition = condition.root,
          .branches = nodes,
        },
      },
    };
    return ret;
  }

  fn func(intpr: *Interpreter, pos: model.Position, ns: u15,
          @"return": *model.Node, params: *model.Node, body: *model.Node)
      nyarna.Error!*model.Node {
    const returns_node: ?*model.Node = switch (@"return".data) {
      .poison, .void => null,
      else => @"return",
    };
    return (try intpr.node_gen.funcgen(
      pos, returns_node, params, ns, body, false)).node();
  }

  fn method(intpr: *Interpreter, pos: model.Position, ns: u15,
            @"return": *model.Node, params: *model.Node, body: *model.Node)
      nyarna.Error!*model.Node {
    const returns_node: ?*model.Node = switch (@"return".data) {
      .poison, .void => null,
      else => @"return",
    };
    return (try intpr.node_gen.funcgen(
      pos, returns_node, params, ns, body, true)).node();
  }

  //-----------------------
  // prototype constructors
  //-----------------------

  fn @"Optional"(intpr: *Interpreter, pos: model.Position,
                 inner: *model.Node) nyarna.Error!*model.Node {
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

  fn @"Concat"(intpr: *Interpreter, pos: model.Position,
               inner: *model.Node) nyarna.Error!*model.Node {
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

  fn @"List"(intpr: *Interpreter, pos: model.Position,
             inner: *model.Node) nyarna.Error!*model.Node {
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

  fn @"Paragraphs"(intpr: *Interpreter, pos: model.Position,
                   inners: []*model.Node, auto: ?*model.Node)
      nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgParagraphs(pos, inners, auto)).node();
  }

  fn @"Map"(intpr: *Interpreter, pos: model.Position,
            key: *model.Node, value: *model.Node) nyarna.Error!*model.Node {
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

  fn @"Record"(intpr: *Interpreter, pos: model.Position,
            fields: *model.Value.Concat) nyarna.Error!*model.Node {
    var res = try intpr.ctx.global().create(model.Type.Instantiated);
    res.* = .{
      .at = pos,
      .name = null,
      .data = .{
        .record = undefined,
      },
    };
    const res_type = model.Type{.instantiated = res};

    var finder = types.CallableReprFinder.init(intpr.ctx.types());
    for (fields.content.items) |field| try finder.push(&field.data.location);
    const finder_result = try finder.finish(res_type, true);
    std.debug.assert(finder_result.found.* == null);

    var b = try types.SigBuilder.init(intpr.ctx, fields.content.items.len,
      res_type, finder_result.needs_different_repr);
    for (fields.content.items) |field| try b.push(&field.data.location);
    const builder_res = b.finish();

    res.data.record = .{
      .constructor =
        try builder_res.createCallable(intpr.ctx.global(), .@"type"),
    };
    return try intpr.genValueNode(
      (try intpr.ctx.values.@"type"(pos, res_type)).value());
  }

  fn @"Intersection"(intpr: *Interpreter, pos: model.Position,
                     input_types: []*model.Node) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgIntersection(pos, input_types)).node();
  }

  fn @"Textual"(intpr: *Interpreter, pos: model.Position,
                cats: []*model.Node, include: *model.Node,
                exclude: *model.Node) nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgTextual(pos, cats, include, exclude)).node();
  }

  fn @"Numeric"(intpr: *Interpreter, pos: model.Position, min: *model.Node,
                max: *model.Node, decimals: *model.Node)
      nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgNumeric(pos, min, max, decimals)).node();
  }

  fn @"Float"(intpr: *Interpreter, pos: model.Position, precision: *model.Node)
      nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgFloat(pos, precision)).node();
  }

  fn @"Enum"(intpr: *Interpreter, pos: model.Position, values: []*model.Node)
      nyarna.Error!*model.Node {
    return (try intpr.node_gen.tgEnum(pos, values)).node();
  }

  //------------------
  // type constructors
  //------------------

  fn constrRaw(_: *Evaluator, _: model.Position,
            input: *model.Value.TextScalar) nyarna.Error!*model.Value {
    return input.value();
  }

  fn constrLocation(
      intpr: *Interpreter, pos: model.Position, name: *model.Value.TextScalar,
      t: ?model.Type, primary: *model.Value.Enum, varargs: *model.Value.Enum,
      varmap: *model.Value.Enum, mutable: *model.Value.Enum,
      header: ?*model.Value.BlockHeader, default: ?*model.Value.Ast)
      nyarna.Error!*model.Node {
    var expr = if (default) |node| blk: {
      var val = try intpr.interpret(node.root);
      if (val.expected_type.is(.poison))
        return intpr.node_gen.poison(pos);
      if (t) |given_type| {
        if (!intpr.ctx.types().lesserEqual(val.expected_type, given_type)
            and !val.expected_type.is(.poison)) {
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

  fn constrDefinition(
      intpr: *Interpreter, pos: model.Position, name: *model.Value.TextScalar,
      root: *model.Value.Enum, node: *model.Value.Ast)
      nyarna.Error!*model.Node {
    const expr = try intpr.interpret(node.root);
    if (expr.expected_type.is(.poison)) {
      return intpr.genValueNode(try intpr.ctx.values.poison(pos));
    }
    var eval = intpr.ctx.evaluator();
    var val = try eval.evaluate(expr);
    std.debug.assert(val.data == .@"type" or val.data == .funcref); // TODO
    const def_val = try intpr.ctx.values.definition(pos, name, val);
    def_val.root = if (root.index == 1) root.value().origin else null;
    return intpr.genValueNode(def_val.value());
  }

  fn constrTextual(eval: *Evaluator, pos: model.Position,
                   input: *model.Value.TextScalar) nyarna.Error!*model.Value {
    _ = eval; _ = pos; _ = input;
    unreachable; // TODO
  }

  fn constrNumeric(eval: *Evaluator, pos: model.Position,
                   input: *model.Value.TextScalar) nyarna.Error!*model.Value {
    _ = eval; _ = pos; _ = input;
    unreachable; // TODO
  }

  fn constrFloat(eval: *Evaluator, pos: model.Position,
                 input: *model.Value.TextScalar) nyarna.Error!*model.Value {
    _ = eval; _ = pos; _ = input;
    unreachable; // TODO
  }

  fn constrEnum(eval: *Evaluator, pos: model.Position,
                input: *model.Value.TextScalar) nyarna.Error!*model.Value {
    const enum_type = &eval.target_type.instantiated.data.tenum;
    return if (enum_type.values.getIndex(input.content)) |index|
      (try eval.ctx.values.@"enum"(pos, enum_type, index)).value()
    else blk: {
      eval.ctx.logger.NotInEnum(pos, eval.target_type);
      break :blk try eval.ctx.values.poison(pos);
    };
  }
});

fn registerExtImpl(ctx: Context, p: *const Provider, name: []const u8,
                   bres: types.SigBuilderResult) !usize {
  return if (bres.sig.isKeyword()) blk: {
    const impl = p.getKeyword(name) orelse
      std.debug.panic("don't know keyword: {s}\n", .{name});
    try ctx.data.keyword_registry.append(ctx.global(), impl);
    break :blk ctx.data.keyword_registry.items.len - 1;
  } else blk: {
    const impl = p.getBuiltin(name) orelse
      std.debug.panic("don't know keyword: {s}\n", .{name});
    try ctx.data.builtin_registry.append(ctx.global(), impl);
    break :blk ctx.data.builtin_registry.items.len - 1;
  };
}

fn registerGenericImpl(ctx: Context, p: *const Provider, name: []const u8)
    !usize {
  const impl = p.getBuiltin(name) orelse
    std.debug.panic("don't know generic builtin: {s}\n", .{name});
  try ctx.data.builtin_registry.append(ctx.global(), impl);
  return ctx.data.builtin_registry.items.len - 1;
}

fn extFunc(ctx: Context, name: *model.Symbol, bres: types.SigBuilderResult,
           ns_dependent: bool, p: *const Provider) !*model.Function {
  const ret = try ctx.global().create(model.Function);
  ret.* = .{
    .callable = try bres.createCallable(ctx.global(), .function),
    .defined_at = model.Position.intrinsic(),
    .data = .{
      .ext = .{
        .ns_dependent = ns_dependent,
        .impl_index = try registerExtImpl(ctx, p, name.name, bres),
      },
    },
    .name = name,
  };
  return ret;
}

fn extFuncSymbol(ctx: Context, name: []const u8, ns_dependent: bool,
                 bres: types.SigBuilderResult, p: *Provider) !*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.defined_at = model.Position.intrinsic();
  ret.name = name;
  ret.data = .{.func = try extFunc(ctx, ret, bres, ns_dependent, p)};
  return ret;
}

fn typeSymbol(ctx: Context, name: []const u8, t: model.Type)
    !*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.@"type" = t},
    .parent_type = null,
  };
  return ret;
}

fn prototypeSymbol(ctx: Context, name: []const u8, pt: model.Prototype)
    !*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.prototype = pt},
    .parent_type = null,
  };
  return ret;
}

fn typeConstructor(ctx: Context, p: *Provider, name: []const u8,
                   bres: types.SigBuilderResult) !types.Constructor {
  return types.Constructor{
    .callable = try bres.createCallable(ctx.global(), .@"type"),
    .impl_index = try registerExtImpl(ctx, p, name, bres),
  };
}

fn prototypeConstructor(ctx: Context, p: *Provider, name: []const u8,
                        bres: types.SigBuilderResult) !types.Constructor {
  return types.Constructor{
    .callable = try bres.createCallable(ctx.global(), .prototype),
    .impl_index = try registerExtImpl(ctx, p, name, bres),
  };
}

pub fn intrinsicModule(ctx: Context) !*model.Module {
  var ret = try ctx.global().create(model.Module);
  ret.root = try ctx.createValueExpr(
    try ctx.values.void(model.Position.intrinsic()));
  ret.symbols = try ctx.global().alloc(*model.Symbol, 19);
  var index: usize = 0;

  var ip = Intrinsics.init();

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

  //-------------
  // type symbols
  //-------------

  // Raw
  var b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .raw}, true);
  try b.push((try ctx.values.intLocation(
    "input", model.Type{.intrinsic = .raw})).withPrimary(
      model.Position.intrinsic()));
  ctx.types().constructors.raw = try
    typeConstructor(ctx, &ip.provider, "constrRaw", b.finish());
  ret.symbols[index] = try typeSymbol(ctx, "Raw", .{.intrinsic = .raw});
  index += 1;

  // Location
  b = try types.SigBuilder.init(ctx, 8, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("name", .{.intrinsic = .literal})); // TODO: identifier
  try b.push(try ctx.values.intLocation("type", .{.intrinsic = .@"type"}));
  try b.push(try ctx.values.intLocation(
    "primary", ctx.types().getBoolean().typedef()));
  try b.push(try ctx.values.intLocation(
    "varargs", ctx.types().getBoolean().typedef()));
  try b.push(try ctx.values.intLocation(
    "varmap", ctx.types().getBoolean().typedef()));
  try b.push(try ctx.values.intLocation(
    "mutable", ctx.types().getBoolean().typedef()));
  try b.push(try ctx.values.intLocation("header", (try ctx.types().optional(
      .{.intrinsic = .block_header})).?));
  try b.push((try ctx.values.intLocation(
    "default", (try ctx.types().optional(
      .{.intrinsic = .ast_node})).?)).withPrimary(model.Position.intrinsic()));
  ctx.types().constructors.location = try
    typeConstructor(ctx, &ip.provider, "constrLocation", b.finish());
  ret.symbols[index] = try
    typeSymbol(ctx, "Location", model.Type{.intrinsic = .location});
  index += 1;

  // Definition
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("name", .{.intrinsic = .literal})); // TODO: identifier
  try b.push(try ctx.values.intLocation(
    "root", ctx.types().getBoolean().typedef()));
  try b.push(try ctx.values.intLocation("item", .{.intrinsic = .ast_node}));
  ctx.types().constructors.definition = try
    typeConstructor(ctx, &ip.provider, "constrDefinition", b.finish());
  ret.symbols[index] = try
    typeSymbol(ctx, "Definition", .{.intrinsic = .definition});
  index += 1;

  // Boolean
  ret.symbols[index] = ctx.types().boolean.name.?;
  index += 1;

  // instantiated scalars
  ctx.types().constructors.generic.textual =
    try registerGenericImpl(ctx, &ip.provider, "constrTextual");
  ctx.types().constructors.generic.numeric =
    try registerGenericImpl(ctx, &ip.provider, "constrNumeric");
  ctx.types().constructors.generic.float =
    try registerGenericImpl(ctx, &ip.provider, "constrFloat");
  ctx.types().constructors.generic.@"enum" =
    try registerGenericImpl(ctx, &ip.provider, "constrEnum");

  //------------------
  // prototype symbols
  //------------------

  // Optional
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("inner", .{.intrinsic = .ast_node}
    )).withPrimary(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.optional = try
    prototypeConstructor(ctx, &ip.provider, "Optional", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Optional", .optional);
  index += 1;

  // Concat
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("inner", .{.intrinsic = .ast_node}
    )).withPrimary(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.concat = try
    prototypeConstructor(ctx, &ip.provider, "Concat", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Concat", .concat);
  index += 1;

  // List
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("inner", .{.intrinsic = .ast_node}
    )).withPrimary(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.list = try
    prototypeConstructor(ctx, &ip.provider, "List", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "List", .list);
  index += 1;

  // Paragraphs
  b = try types.SigBuilder.init(ctx, 2, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("inners", (try ctx.types().list(
    .{.intrinsic = .ast_node})).?)).withVarargs(model.Position.intrinsic()
    ).withPrimary(model.Position.intrinsic()));
  try b.push(try ctx.values.intLocation("auto", (try ctx.types().optional(
    .{.intrinsic = .ast_node})).?));
  ctx.types().constructors.prototypes.paragraphs = try
    prototypeConstructor(ctx, &ip.provider, "Paragraphs", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Paragraphs", .paragraphs);
  index += 1;

  // Map
  b = try types.SigBuilder.init(ctx, 2, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("key", .{.intrinsic = .ast_node}));
  try b.push(try ctx.values.intLocation("value", .{.intrinsic = .ast_node}));
  ctx.types().constructors.prototypes.map = try
    prototypeConstructor(ctx, &ip.provider, "Map", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Map", .map);
  index += 1;

  // Record
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  // TODO: allow record to extend other record (?)
  try b.push((try ctx.values.intLocation("fields", (try ctx.types().concat(
    model.Type{.intrinsic = .location})).?)).withHeader(
      location_block).withPrimary(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.record = try
    prototypeConstructor(ctx, &ip.provider, "Record", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Record", .record);
  index += 1;

  // Intersection
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("types", (try ctx.types().list(
    .{.intrinsic = .@"type"})).?)).withVarargs(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.intersection = try
    prototypeConstructor(ctx, &ip.provider, "Intersection", b.finish());
  ret.symbols[index] =
    try prototypeSymbol(ctx, "Intersection", .intersection);
  index += 1;

  // Textual
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("cats", .{.intrinsic = .ast_node}));
  try b.push(try ctx.values.intLocation("include", .{.intrinsic = .ast_node}));
  try b.push(try ctx.values.intLocation("exclude", .{.intrinsic = .ast_node}));
  ctx.types().constructors.prototypes.textual = try
    prototypeConstructor(ctx, &ip.provider, "Textual", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Textual", .textual);
  index += 1;

  // Numeric
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("min", .{.intrinsic = .ast_node}));
  try b.push(try ctx.values.intLocation("max", .{.intrinsic = .ast_node}));
  try b.push(try ctx.values.intLocation("decimals", .{.intrinsic = .ast_node}));
  ctx.types().constructors.prototypes.numeric = try
    prototypeConstructor(ctx, &ip.provider, "Numeric", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Numeric", .numeric);
  index += 1;

  // Float
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("precision", .{.intrinsic = .ast_node}));
  ctx.types().constructors.prototypes.float = try
    prototypeConstructor(ctx, &ip.provider, "Float", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Float", .float);
  index += 1;

  // Enum
  b = try types.SigBuilder.init(ctx, 1, .{.intrinsic = .ast_node}, false);
  try b.push((try ctx.values.intLocation("values", (try ctx.types().list(
    .{.intrinsic = .raw})).?)).withVarargs(model.Position.intrinsic()));
  ctx.types().constructors.prototypes.@"enum" = try
    prototypeConstructor(ctx, &ip.provider, "Enum", b.finish());
  ret.symbols[index] = try prototypeSymbol(ctx, "Enum", .@"enum");
  index += 1;

  //-------------------
  // external symbols
  //-------------------

  // declare
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("namespace", (try ctx.types().optional(
      .{.intrinsic = .@"type"})).?));
  try b.push((try ctx.values.intLocation("public", .{.intrinsic = .ast_node})
    ).withPrimary(model.Position.intrinsic()).withHeader(definition_block));
  try b.push((try ctx.values.intLocation("private", .{.intrinsic = .ast_node})
    ).withHeader(definition_block));
  ret.symbols[index] =
    try extFuncSymbol(ctx, "declare", true, b.finish(), &ip.provider);
  index += 1;

  // if
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation(
    "condition", .{.intrinsic = .ast_node}));
  try b.push((try ctx.values.intLocation(
    "then", .{.intrinsic = .ast_node})).withPrimary(
      model.Position.intrinsic()));
  try b.push(try ctx.values.intLocation("else", .{.intrinsic = .ast_node}));
  ret.symbols[index] =
    try extFuncSymbol(ctx, "if", false, b.finish(), &ip.provider);
  index += 1;

  // func
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("return", .{.intrinsic = .ast_node}));
  try b.push((try ctx.values.intLocation(
    "params", .{.intrinsic = .ast_node})).withPrimary(
      model.Position.intrinsic()).withHeader(location_block));
  try b.push(try ctx.values.intLocation("body", .{.intrinsic = .ast_node}));
  ret.symbols[index] =
    try extFuncSymbol(ctx, "func", true, b.finish(), &ip.provider);
  index += 1;

  // method
  b = try types.SigBuilder.init(ctx, 3, .{.intrinsic = .ast_node}, false);
  try b.push(try ctx.values.intLocation("return", .{.intrinsic = .ast_node}));
  try b.push((try ctx.values.intLocation(
    "params", .{.intrinsic = .ast_node})).withPrimary(
      model.Position.intrinsic()).withHeader(location_block));
  try b.push(try ctx.values.intLocation("body", .{.intrinsic = .ast_node}));
  ret.symbols[index] =
    try extFuncSymbol(ctx, "method", true, b.finish(), &ip.provider);
  index += 1;

  std.debug.assert(index == ret.symbols.len);

  return ret;
}