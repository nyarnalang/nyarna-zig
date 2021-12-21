const std = @import("std");
const nyarna = @import("nyarna.zig");
const Interpreter = nyarna.Interpreter;
const Context = nyarna.Context;
const Evaluator = nyarna.Evaluator;
const model = nyarna.model;
const types = nyarna.types;
const algo = @import("load/algo.zig");

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
              model.Value.Enum => &v.data.enumval,
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
  fn @"Location"(
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
        if (!intpr.types().lesserEqual(val.expected_type, given_type)
            and !val.expected_type.is(.poison)) {
          intpr.loader.logger.ExpectedExprOfTypeXGotY(
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
        intpr.loader.logger.IncompatibleFlag("varmap",
          varmap.value().origin, varargs.value().origin);
        return intpr.node_gen.poison(pos);
      } else if (mutable.index == 1) {
        intpr.loader.logger.IncompatibleFlag("varmap",
          varmap.value().origin, mutable.value().origin);
        return intpr.node_gen.poison(pos);
      }
    } else if (varargs.index == 1) if (mutable.index == 1) {
      intpr.loader.logger.IncompatibleFlag("mutable",
        mutable.value().origin, varargs.value().origin);
      return intpr.node_gen.poison(pos);
    };

    return intpr.genValueNode(pos, .{
      .location = .{
        .name = name,
        .tloc = ltype,
        .default = expr,
        .primary = if (primary.index == 1) primary.value().origin else null,
        .varargs = if (varargs.index == 1) varargs.value().origin else null,
        .varmap  = if (varmap.index  == 1)  varmap.value().origin else null,
        .mutable = if (mutable.index == 1) mutable.value().origin else null,
        .block_header = header,
      },
    });
  }

  fn @"Definition"(
      intpr: *Interpreter, pos: model.Position, name: *model.Value.TextScalar,
      root: *model.Value.Enum, node: *model.Value.Ast) !*model.Node {
    const expr = try intpr.interpret(node.root);
    if (expr.expected_type.is(.poison)) return intpr.genValueNode(pos, .poison);
    var eval = nyarna.Evaluator.init(intpr.loader.context);
    var val = try eval.evaluate(expr);
    std.debug.assert(val.data == .@"type" or val.data == .funcref); // TODO
    return intpr.genValueNode(pos, .{
      .definition = .{
        .name = name,
        .content = val,
        .root = if (root.index == 1) root.value().origin else null,
      },
    });
  }

  fn declare(intpr: *Interpreter, pos: model.Position, ns: u15,
             _: ?model.Type, public: *model.Node, private: *model.Node)
      nyarna.Error!*model.Node {
    var def_count: usize = 0;
    for ([_]*model.Node{public, private}) |node| switch (node.data) {
      .void => {},
      .definition => def_count += 1,
      .concat => |*con| def_count += con.items.len,
      else => unreachable, // TODO: error msg
    };

    var defs = try intpr.allocator().alloc(*model.Node.Definition,
      def_count);
    def_count = 0;
    for ([_]*model.Node{public, private}) |node| switch (node.data) {
      .void => {},
      .definition => |*def| {
        defs[def_count] = def;
        def_count += 1;
      },
      .concat => |*con| for (con.items) |item| {
        defs[def_count] = &item.data.definition; // TODO: check for definition
        def_count += 1;
      },
      else => unreachable,
    };
    var res = try algo.DeclareResolution.create(intpr, defs, ns);
    try res.execute();
    return intpr.node_gen.@"void"(pos);
  }

  fn @"Record"(intpr: *Interpreter, pos: model.Position,
            fields: *model.Value.Concat) nyarna.Error!*model.Node {
    var res = try intpr.createPublic(model.Type.Instantiated);
    res.* = .{
      .at = pos,
      .name = null,
      .data = .{
        .record = undefined,
      },
    };
    const res_type = model.Type{.instantiated = res};

    var finder = types.CallableReprFinder.init(intpr.types());
    for (fields.content.items) |field| try finder.push(&field.data.location);
    const finder_result = try finder.finish(res_type, true);
    std.debug.assert(finder_result.found.* == null);

    var b = try types.SigBuilder(.userdef).init(intpr, fields.content.items.len,
      res_type, finder_result.needs_different_repr);
    for (fields.content.items) |field| try b.push(&field.data.location);
    const builder_res = b.finish() orelse
      return intpr.node_gen.poison(pos);

    const structural = try intpr.createPublic(model.Type.Structural);
    structural.* = .{
      .callable = .{
        .sig = builder_res.sig,
        .kind = .@"type",
        .repr = undefined,
      },
    };
    structural.callable.repr = if (builder_res.repr) |repr_sig| blk: {
      const repr = try intpr.createPublic(model.Type.Structural);
      repr.* = .{
        .callable = .{
          .sig = repr_sig,
          .kind = .@"type",
          .repr = undefined,
        },
      };
      repr.callable.repr = &repr.callable;
      break :blk &repr.callable;
    } else &structural.callable;


    res.data.record = .{
      .callable = & structural.callable,
    };
    return try intpr.genValueNode(pos, .{
      .@"type" = .{
        .t = res_type
      },
    });
  }

  fn @"Raw"(_: *Evaluator, _: model.Position,
            input: *model.Value.TextScalar) !*model.Value {
    return input.value();
  }

  fn @"if"(intpr: *Interpreter, pos: model.Position,
           condition: *model.Value.Ast, then: *model.Value.Ast,
           @"else": *model.Value.Ast) !*model.Node {
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
});

fn registerExtImpl(context: *Context, p: *const Provider, name: []const u8,
                   bres: types.SigBuilderResult) !usize {
  return if (bres.sig.isKeyword()) blk: {
    const impl = p.getKeyword(name) orelse
      std.debug.panic("don't know keyword: {s}\n", .{name});
    try context.keyword_registry.append(context.allocator(), impl);
    break :blk context.keyword_registry.items.len - 1;
  } else blk: {
    const impl = p.getBuiltin(name) orelse
      std.debug.panic("don't know keyword: {s}\n", .{name});
    try context.builtin_registry.append(context.allocator(), impl);
    break :blk context.builtin_registry.items.len - 1;
  };
}

fn extFunc(context: *Context, name: []const u8, bres: types.SigBuilderResult,
           ns_dependent: bool, p: *const Provider) !model.Symbol.ExtFunc {
  return model.Symbol.ExtFunc{
    .callable = try bres.createCallable(context.allocator(), .function),
    .ns_dependent = ns_dependent,
    .impl_index = try registerExtImpl(context, p, name, bres),
    .cur_frame = null,
  };
}

fn extFuncSymbol(context: *Context, name: []const u8, ns_dependent: bool,
                 bres: types.SigBuilderResult, p: *Provider) !*model.Symbol {
  const ret = try context.allocator().create(model.Symbol);
  ret.defined_at = model.Position.intrinsic();
  ret.name = name;
  ret.data = .{
    .ext_func = try extFunc(context, name, bres, ns_dependent, p),
  };
  return ret;
}

pub inline fn intLoc(context: *Context, name: []const u8, t: model.Type)
    !*model.Value.Location {
  const name_val = try context.allocator().create(model.Value);
  name_val.* = .{
    .origin = model.Position.intrinsic(),
    .data = .{
      .text = .{
        .t = model.Type{.intrinsic = .literal},
        .content = name,
      },
    },
  };

  const value = try context.allocator().create(model.Value);
  value.origin = model.Position.intrinsic();
  value.data = .{.location = model.Value.Location.init(&name_val.data.text, t)};
  return &value.data.location;
}

fn typeSymbol(context: *Context, name: []const u8, t: model.Type)
    !*model.Symbol {
  const ret = try context.allocator().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.@"type" = t},
  };
  return ret;
}

fn prototypeSymbol(context: *Context, name: []const u8, pt: model.Prototype)
    !*model.Symbol {
  const ret = try context.allocator().create(model.Symbol);
  ret.* = model.Symbol{
    .defined_at = model.Position.intrinsic(),
    .name = name,
    .data = .{.prototype = pt},
  };
  return ret;
}

fn typeConstructor(context: *Context, p: *Provider, name: []const u8,
                   bres: types.SigBuilderResult) !types.Constructor {
  return types.Constructor{
    .callable = try bres.createCallable(context.allocator(), .@"type"),
    .impl_index = try registerExtImpl(context, p, name, bres),
  };
}

fn prototypeConstructor(context: *Context, p: *Provider, name: []const u8,
                        bres: types.SigBuilderResult) !types.Constructor {
  return types.Constructor{
    .callable = try bres.createCallable(context.allocator(), .prototype),
    .impl_index = try registerExtImpl(context, p, name, bres),
  };
}

pub fn intrinsicModule(context: *Context) !*model.Module {
  var ret = try context.allocator().create(model.Module);
  ret.root = try context.genLiteral(model.Position.intrinsic(), .void);
  ret.symbols = try context.allocator().alloc(*model.Symbol, 6);
  var index: usize = 0;

  var ip = Intrinsics.init();

  const location_block = blk: {
    const value_header_location = try context.allocator().create(model.Value);
    value_header_location.* = .{
      .data = .{
        .block_header = .{
          .config = .{
            .syntax = .{
              .pos = model.Position.intrinsic(),
              .index = 0,
            },
            .map = &.{},
            .off_colon = null,
            .off_comment = null,
            .full_ast = null,
          },
          .swallow_depth = null,
        },
      },
      .origin = model.Position.intrinsic(),
    };
    break :blk &value_header_location.data.block_header;
  };

  const definition_block = blk: {
    const value_header_definition = try context.allocator().create(model.Value);
    value_header_definition.* = .{
      .data = .{
        .block_header = .{
          .config = .{
            .syntax = .{
              .pos = model.Position.intrinsic(),
              .index = 1,
            },
            .map = &.{},
            .off_colon = null,
            .off_comment = null,
            .full_ast = null,
          },
          .swallow_depth = null,
        },
      },
      .origin = model.Position.intrinsic(),
    };
    break :blk &value_header_definition.data.block_header;
  };

  //-------------
  // type symbols
  //-------------

  // location
  var b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 8, .{.intrinsic = .ast_node}, false);
  try b.push(try intLoc(context, "name", .{.intrinsic = .literal})); // TODO: identifier
  try b.push(try intLoc(context, "type", .{.intrinsic = .@"type"}));
  try b.push(try intLoc(
    context, "primary", .{.instantiated = &context.types.boolean}));
  try b.push(try intLoc(
    context, "varargs", .{.instantiated = &context.types.boolean}));
  try b.push(try intLoc(
    context, "varmap", .{.instantiated = &context.types.boolean}));
  try b.push(try intLoc(
    context, "mutable", .{.instantiated = &context.types.boolean}));
  try b.push(try intLoc(context, "header", (try context.types.optional(
      .{.intrinsic = .block_header})).?));
  try b.push((try intLoc(context, "default", (try context.types.optional(
      .{.intrinsic = .ast_node})).?)).withPrimary(model.Position.intrinsic()));
  context.types.constructors.location = try
    typeConstructor(context, &ip.provider, "Location", b.finish());
  ret.symbols[index] = try
    typeSymbol(context, "Location", model.Type{.intrinsic = .location});
  index += 1;

  // definition
  b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 3, .{.intrinsic = .ast_node}, false);
  try b.push(try intLoc(context, "name", .{.intrinsic = .literal})); // TODO: identifier
  try b.push(try intLoc(
    context, "root", .{.instantiated = &context.types.boolean}));
  try b.push(try intLoc(context, "item", .{.intrinsic = .ast_node}));
  context.types.constructors.definition = try
    typeConstructor(context, &ip.provider, "Definition", b.finish());
  ret.symbols[index] = try
    typeSymbol(context, "Definition", model.Type{.intrinsic = .definition});
  index += 1;

  // record
  b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 1, .{.intrinsic = .ast_node}, false);
  // TODO: allow record to extend other record (?)
  try b.push((try intLoc(context, "fields", (try context.types.concat(
    model.Type{.intrinsic = .location})).?)).withHeader(
      location_block).withPrimary(model.Position.intrinsic()));
  context.types.constructors.prototypes.record = try
    prototypeConstructor(context, &ip.provider, "Record", b.finish());
  ret.symbols[index] = try
    prototypeSymbol(context, "Record", .record);
  index += 1;

  // Raw
  b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 1, .{.intrinsic = .raw}, true);
  try b.push((try intLoc(
    context, "input", model.Type{.intrinsic = .raw})).withPrimary(
      model.Position.intrinsic()));
  context.types.constructors.raw = try
    typeConstructor(context, &ip.provider, "Raw", b.finish());
  ret.symbols[index] =
    try typeSymbol(context, "Raw", model.Type{.intrinsic = .raw});
  index += 1;

  //-------------------
  // external symbols
  //-------------------

  // declare
  b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 3, .{.intrinsic = .ast_node}, false);
  try b.push(try intLoc(context, "namespace", (try context.types.optional(
      .{.intrinsic = .@"type"})).?));
  try b.push((try intLoc(context, "public", .{.intrinsic = .ast_node})
    ).withPrimary(model.Position.intrinsic()).withHeader(definition_block));
  try b.push((try intLoc(context, "private", .{.intrinsic = .ast_node})
    ).withHeader(definition_block));
  ret.symbols[index] =
    try extFuncSymbol(context, "declare", true, b.finish(), &ip.provider);
  index += 1;

  // if
  b = try types.SigBuilder(.intrinsic).init(
    context.allocator(), 3, .{.intrinsic = .ast_node}, false);
  try b.push(try intLoc(context, "condition", .{.intrinsic = .ast_node}));
  try b.push((try intLoc(
    context, "then", .{.intrinsic = .ast_node})).withPrimary(
      model.Position.intrinsic()));
  try b.push(try intLoc(context, "else", .{.intrinsic = .ast_node}));
  ret.symbols[index]  =
    try extFuncSymbol(context, "if", false, b.finish(), &ip.provider);
  index += 1;

  return ret;
}