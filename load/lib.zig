const std = @import("std");
const Interpreter = @import("interpret.zig").Interpreter;
const Loader = @import("load.zig").Loader;
const data = @import("../data.zig");
const types = @import("../types.zig");

// TODO: dummy, refactor!
pub const RuntimeContext = struct {
  storage: std.heap.ArenaAllocator,
};

/// A provider implements all external functions for a certain Nyarna module.
pub const Provider = struct {
  pub const KeywordWrapper = fn(
    ctx: *Interpreter, pos: data.Position,
    args: []*data.Value) std.mem.Allocator.Error!*data.Node;
  /// TODO: proper context type for runtime fns
  pub const BuiltinWrapper = fn(
    ctx: *RuntimeContext, pos: data.Position,
    args: []*data.Value) std.mem.Allocator.Error!*data.Value;

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

      fn getTypedValue(comptime T: type, v: *data.Value) T {
        return switch (T) {
          data.Type => v.data.typeval.t,
          else => switch (@typeInfo(T)) {
            .Optional => |opt| if (v.data == .void) null
                               else getTypedValue(opt.child, v),
            .Pointer => |ptr| switch (ptr.child) {
              data.Value.TextScalar => &v.data.text,
              data.Value.Number => &v.data.number,
              data.Value.FloatNumber => &v.data.float,
              data.Value.Enum => &v.data.enumval,
              data.Value.Record => &v.data.record,
              data.Value.List => &v.data.list,
              data.Value.Map => &v.data.map,
              data.Value.TypeVal => &v.data.typeval,
              data.Value.FuncRef => &v.data.funcref,
              data.Value.BlockHeader => &v.data.block_header,
              data.Value => |cval| getTypedValue(T, &cval),
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
          fn wrapper(ctx: FirstArg, pos: data.Position,
                     args: []*data.Value) std.mem.Allocator.Error!*Ret {
            var unwrapped: Params(@typeInfo(decl.data.Fn.fn_type).Fn) =
              undefined;
            inline for (@typeInfo(@TypeOf(unwrapped)).Struct.fields)
                |f, index| {
              unwrapped[index] = switch (index) {
                0 => ctx,
                1 => pos,
                else => getTypedValue(f.field_type, args[index - 2]),
              };
            }
            return @call(.{}, @field(impls, decl.name), unwrapped);
          }
        };
      }

      fn ImplWrapper(comptime keyword: bool, comptime F: type) type {
        const FirstArg = if (keyword) *Interpreter else *RuntimeContext;
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
                  if (keyword) data.Node else data.Value).wrapper;
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
  fn location(context: *Interpreter, pos: data.Position,
              name: []const u8, t: ?data.Type, primary: *data.Value.Enum,
              varargs: *data.Value.Enum, varmap: *data.Value.Enum,
              mutable: *data.Value.Enum, header: ?*data.Value.BlockHeader,
              default: ?*data.Value.Ast) !*data.Node {
    var expr = if (default) |node| blk: {
      var val = try context.interpret(node.root);
      if (t) |given_type| {
        if (!context.loader.types.lesserEqual(val.expected_type, given_type)
            and !val.expected_type.is(.poison)) {
          context.loader.logger.ExpectedExprOfTypeXGotY(
            val.pos, given_type, val.expected_type);
          return data.Node.poison(&context.storage.allocator, pos);
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
        context.loader.logger.IncompatibleFlag("varmap",
          varmap.value().origin, varargs.value().origin);
        return data.Node.poison(&context.storage.allocator, pos);
      } else if (mutable.index == 1) {
        context.loader.logger.IncompatibleFlag("varmap",
          varmap.value().origin, mutable.value().origin);
        return data.Node.poison(&context.storage.allocator, pos);
      }
    } else if (varargs.index == 1) if (mutable.index == 1) {
      context.loader.logger.IncompatibleFlag("mutable",
        mutable.value().origin, varargs.value().origin);
      return data.Node.poison(&context.storage.allocator, pos);
    };

    var lit_expr = try context.createPublic(data.Expression);
    return data.Node.valueNode(&context.storage.allocator, lit_expr, pos, .{
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

  fn definition(context: *Interpreter, pos: data.Position, name: []const u8,
                root: *data.Value.Enum, node: *data.Value.Ast) !*data.Node {
    var lit_expr = try context.createPublic(data.Expression);
    return data.Node.valueNode(&context.storage.allocator, lit_expr, pos, .{
      .definition = .{
        .name = name,
        .content = node,
        .root = if (root.index == 1) root.value().origin else null,
      },
    });
  }

  fn declare(_: *RuntimeContext, _: data.Position,
             _: ?data.Type, _: *data.Value.Concat,
             _: *data.Value.Concat) !*data.Value {
    unreachable;
  }
});

fn extFunc(context: *Loader, name: []const u8, sig: *data.Type.Signature,
           p: *Provider) !data.Symbol.ExtFunc {
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
  return data.Symbol.ExtFunc{
    .signature = sig,
    .impl_index = impl_index,
  };
}

fn extFuncSymbol(context: *Loader, name: []const u8, sig: *data.Type.Signature,
                 p: *Provider) !*data.Symbol {
  const ret = try context.storage.allocator.create(data.Symbol);
  ret.defined_at = data.Position.intrinsic();
  ret.name = name;
  ret.data = .{
    .ext_func = try extFunc(context, name, sig, p),
  };
  return ret;
}

pub fn intrinsicModule(context: *Loader) !*data.Module {
  var ret = try context.storage.allocator.create(data.Module);
  ret.root = try context.storage.allocator.create(data.Expression);
  ret.root.* = data.Expression.literal(data.Position.intrinsic(), .void);
  ret.symbols = try context.storage.allocator.alloc(*data.Symbol, 1);
  var index = @as(usize, 0);

  var ip = Intrinsics.init();

  //-------------------
  // type constructors
  //-------------------

  // location
  var b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 8, .{.intrinsic = .ast_node});
  try b.push(&data.Value.Location.simple(
    "name", .{.intrinsic = .literal}, null)); // TODO: identifier
  try b.push(&data.Value.Location.simple(
    "type", .{.intrinsic = .non_callable_type}, null));
  try b.push(&data.Value.Location.simple(
    "primary", .{.instantiated = &context.types.boolean}, null));
  try b.push(&data.Value.Location.simple(
    "varargs", .{.instantiated = &context.types.boolean}, null));
  try b.push(&data.Value.Location.simple(
    "varmap", .{.instantiated = &context.types.boolean}, null));
  try b.push(&data.Value.Location.simple(
    "mutable", .{.instantiated = &context.types.boolean}, null));
  try b.push(&data.Value.Location.simple(
    "header", (try context.types.optional(.{.intrinsic = .block_header})).?,
    null));
  try b.push(&data.Value.Location.primary(
    "default", (try context.types.optional(.{.intrinsic = .ast_node})).?,
    null));
  context.types.type_constructors[0] =
    try extFunc(context, "location", b.finish(), &ip.provider);

  // definition
  b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 3, .{.intrinsic = .ast_node});
  try b.push(&data.Value.Location.simple(
    "name", .{.intrinsic = .literal}, null)); // TODO: identifier
  try b.push(&data.Value.Location.simple(
    "root", .{.instantiated = &context.types.boolean}, null));
  try b.push(&data.Value.Location.simple(
    "item", .{.intrinsic = .ast_node}, null));
  context.types.type_constructors[1] =
    try extFunc(context, "definition", b.finish(), &ip.provider);

  //-------------------
  // external symbols
  //-------------------

  b = try types.SigBuilder(.intrinsic).init(
    &context.storage.allocator, 3, .{.intrinsic = .void});
  var definition_concat =
    (try context.types.concat(.{.intrinsic = .definition})).?;
  try b.push(&data.Value.Location.simple(
    "type", (try context.types.optional(.{.intrinsic = .non_callable_type})).?,
    null));
  try b.push(&data.Value.Location.primary("public", definition_concat, null));
  try b.push(&data.Value.Location.simple("private", definition_concat, null));
  ret.symbols[index] =
    try extFuncSymbol(context, "declare", b.finish(), &ip.provider);

  return ret;
}