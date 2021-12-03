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
          model.Type => v.data.typeval.t,
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
              model.Value.TypeVal => &v.data.typeval,
              model.Value.FuncRef => &v.data.funcref,
              model.Value.Location => &v.data.location,
              model.Value.Definition => &v.data.definition,
              model.Value.Ast => &v.data.ast,
              model.Value.BlockHeader => &v.data.block_header,
              model.Value => |cval| getTypedValue(T, &cval),
              else => unreachable,
            },
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
  fn location(intpr: *Interpreter, pos: model.Position,
              name: []const u8, t: ?model.Type, primary: *model.Value.Enum,
              varargs: *model.Value.Enum, varmap: *model.Value.Enum,
              mutable: *model.Value.Enum, header: ?*model.Value.BlockHeader,
              default: ?*model.Value.Ast) nyarna.Error!*model.Node {
    var expr = if (default) |node| blk: {
      var val = try intpr.interpret(node.root);
      if (t) |given_type| {
        if (!intpr.types().lesserEqual(val.expected_type, given_type)
            and !val.expected_type.is(.poison)) {
          intpr.loader.logger.ExpectedExprOfTypeXGotY(
            val.pos, &[_]model.Type{given_type, val.expected_type});
          return model.Node.poison(&intpr.storage.allocator, pos);
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
        return model.Node.poison(&intpr.storage.allocator, pos);
      } else if (mutable.index == 1) {
        intpr.loader.logger.IncompatibleFlag("varmap",
          varmap.value().origin, mutable.value().origin);
        return model.Node.poison(&intpr.storage.allocator, pos);
      }
    } else if (varargs.index == 1) if (mutable.index == 1) {
      intpr.loader.logger.IncompatibleFlag("mutable",
        mutable.value().origin, varargs.value().origin);
      return model.Node.poison(&intpr.storage.allocator, pos);
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

  fn definition(intpr: *Interpreter, pos: model.Position, name: []const u8,
                root: *model.Value.Enum, node: *model.Value.Ast) !*model.Node {
    return intpr.genValueNode(pos, .{
      .definition = .{
        .name = name,
        .content = node,
        .root = if (root.index == 1) root.value().origin else null,
      },
    });
  }

  fn declare(intpr: *Interpreter, pos: model.Position,
             _: ?model.Type, public: *model.Value.Concat,
             private: *model.Value.Concat) nyarna.Error!*model.Node {
    var defs = try intpr.storage.allocator.alloc(*model.Value.Definition,
      public.items.items.len + private.items.items.len);
    for (public.items.items) |item, i| defs[i] = &item.data.definition;
    for (private.items.items) |item, i|
      defs[public.items.items.len + i] = &item.data.definition;
    var res = try algo.DeclareResolution.create(intpr, defs);
    try res.execute();
    return model.Node.genVoid(&intpr.storage.allocator, pos);
  }

  fn @"if"(intpr: *Interpreter, pos: model.Position,
           condition: *model.Value.Ast, then: *model.Value.Ast,
           @"else": *model.Value.Ast) !*model.Node {
    const nodes = try intpr.storage.allocator.alloc(*model.Node, 2);
    nodes[1] = then.root;
    nodes[0] = @"else".root;

    const ret = try intpr.storage.allocator.create(model.Node);
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

fn extFunc(context: *Context, name: []const u8, sig: *model.Type.Signature,
           is_type: bool, p: *Provider) !model.Symbol.ExtFunc {
  const impl_index = if (sig.isKeyword()) blk: {
    const impl = p.getKeyword(name) orelse {
      std.debug.print("don't know keyword: {s}\n", .{name});
      unreachable;
    };
    try context.keyword_registry.append(&context.storage.allocator, impl);
    break :blk context.keyword_registry.items.len - 1;
  } else blk: {
    const impl = p.getBuiltin(name) orelse {
      std.debug.print("don't know keyword: {s}\n", .{name});
      unreachable;
    };
    try context.builtin_registry.append(&context.storage.allocator, impl);
    break :blk context.builtin_registry.items.len - 1;
  };
  const callable = try context.storage.allocator.create(model.Type.Structural);
  callable.* = .{
    .callable = .{
      .sig = sig,
      .is_type = is_type,
    },
  };
  return model.Symbol.ExtFunc{
    .callable = &callable.callable,
    .impl_index = impl_index,
    .cur_frame = null,
  };
}

fn extFuncSymbol(context: *Context, name: []const u8,
                 sig: *model.Type.Signature, p: *Provider) !*model.Symbol {
  const ret = try context.storage.allocator.create(model.Symbol);
  ret.defined_at = model.Position.intrinsic();
  ret.name = name;
  ret.data = .{
    .ext_func = try extFunc(context, name, sig, false, p),
  };
  return ret;
}

pub inline fn intLoc(context: *Context, content: model.Value.Location)
    !*model.Value.Location {
  const value = try context.storage.allocator.create(model.Value);
  value.origin = model.Position.intrinsic();
  value.data = .{
    .location = content
  };
  return &value.data.location;
}

pub fn intrinsicModule(context: *Context) !*model.Module {
  var ret = try context.storage.allocator.create(model.Module);
  ret.root = try context.genLiteral(model.Position.intrinsic(), .void);
  ret.symbols = try context.storage.allocator.alloc(*model.Symbol, 2);
  var index = @as(usize, 0);

  var ip = Intrinsics.init();

  //-------------------
  // type constructors
  //-------------------

  // location
  var b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 8, .{.intrinsic = .ast_node});
  try b.push(try intLoc(context, model.Value.Location.simple(
    "name", .{.intrinsic = .literal}, null))); // TODO: identifier
  try b.push(try intLoc(context, model.Value.Location.simple(
    "type", .{.intrinsic = .non_callable_type}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "primary", .{.instantiated = &context.types.boolean}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "varargs", .{.instantiated = &context.types.boolean}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "varmap", .{.instantiated = &context.types.boolean}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "mutable", .{.instantiated = &context.types.boolean}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "header", (try context.types.optional(
      .{.intrinsic = .block_header})).?, null)));
  try b.push(try intLoc(context, model.Value.Location.primary(
    "default", (try context.types.optional(
      .{.intrinsic = .ast_node})).?, null)));
  context.types.type_constructors[0] =
    try extFunc(context, "location", b.finish(), true, &ip.provider);

  // definition
  b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 3, .{.intrinsic = .ast_node});
  try b.push(try intLoc(context, model.Value.Location.simple(
    "name", .{.intrinsic = .literal}, null))); // TODO: identifier
  try b.push(try intLoc(context, model.Value.Location.simple(
    "root", .{.instantiated = &context.types.boolean}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "item", .{.intrinsic = .ast_node}, null)));
  context.types.type_constructors[1] =
    try extFunc(context, "definition", b.finish(), true, &ip.provider);

  //-------------------
  // external symbols
  //-------------------

  // declare
  b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 3, .{.intrinsic = .ast_node});
  var definition_concat =
    (try context.types.concat(.{.intrinsic = .definition})).?;
  try b.push(try intLoc(context, model.Value.Location.simple(
    "namespace", (try context.types.optional(
      .{.intrinsic = .non_callable_type})).?, null)));
  try b.push(try intLoc(context, model.Value.Location.primary(
    "public", definition_concat, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "private", definition_concat, null)));
  ret.symbols[index] =
    try extFuncSymbol(context, "declare", b.finish(), &ip.provider);
  index += 1;

  // if
  b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 3, .{.intrinsic = .ast_node});
  try b.push(try intLoc(context, model.Value.Location.simple(
    "condition", .{.intrinsic = .ast_node}, null)));
  try b.push(try intLoc(context, model.Value.Location.primary(
    "then", .{.intrinsic = .ast_node}, null)));
  try b.push(try intLoc(context, model.Value.Location.simple(
    "else", .{.intrinsic = .ast_node}, null)));
  ret.symbols[index]  =
    try extFuncSymbol(context, "if", b.finish(), &ip.provider);
  index += 1;

  return ret;
}