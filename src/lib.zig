const std = @import("std");
const nyarna = @import("nyarna.zig");
const interpret = @import("interpret.zig");
const Interpreter = interpret.Interpreter;
const Context = nyarna.Context;
const Evaluator = @import("runtime.zig").Evaluator;
const model = nyarna.model;
const types = nyarna.types;
const algo = @import("interpret/algo.zig");
const unicode = @import("unicode.zig");

pub const system = @import("lib/system.zig");
pub const constructors = @import("lib/constructors.zig");

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

      fn SingleWrapper(
        comptime FirstArg: type,
        comptime decl: std.builtin.TypeInfo.Declaration,
        comptime Ret: type,
      ) type {
        return struct {
          fn wrapper(
            ctx: FirstArg,
            pos: model.Position,
            stack_frame: [*]model.StackItem,
          ) nyarna.Error!*Ret {
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
              if (
                @typeInfo(decl.data.Fn.fn_type).Fn.args[0].arg_type.? !=
                FirstArg
              ) continue;
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

pub fn registerExtImpl(
  ctx: Context,
  p: *const Provider,
  name: []const u8,
  bres: types.SigBuilderResult,
) !?usize {
  return if (bres.sig.isKeyword()) blk: {
    const impl = p.getKeyword(name) orelse return null;
    try ctx.data.keyword_registry.append(ctx.global(), impl);
    break :blk ctx.data.keyword_registry.items.len - 1;
  } else blk: {
    const impl = p.getBuiltin(name) orelse return null;
    try ctx.data.builtin_registry.append(ctx.global(), impl);
    break :blk ctx.data.builtin_registry.items.len - 1;
  };
}

fn registerGenericImpl(
  ctx: Context,
  p: *const Provider,
  name: []const u8,
) !usize {
  const impl = p.getBuiltin(name) orelse
    std.debug.panic("don't know generic builtin: {s}\n", .{name});
  try ctx.data.builtin_registry.append(ctx.global(), impl);
  return ctx.data.builtin_registry.items.len - 1;
}

pub fn extFunc(
  ctx: Context,
  name: *model.Symbol,
  bres: types.SigBuilderResult,
  ns_dependent: bool,
  p: *const Provider,
) !?*model.Function {
  const index =
    (try registerExtImpl(ctx, p, name.name, bres)) orelse return null;
  const container = try ctx.global().create(model.VariableContainer);
  container.* = .{
    .num_values = @intCast(u15, bres.sig.parameters.len),
  };
  const ret = try ctx.global().create(model.Function);
  ret.* = .{
    .callable = try bres.createCallable(ctx.global(), .function),
    .defined_at = model.Position.intrinsic(),
    .data = .{
      .ext = .{
        .ns_dependent = ns_dependent,
        .impl_index = index,
      },
    },
    .name = name,
    .variables = container,
  };
  return ret;
}

pub fn extFuncSymbol(
  ctx: Context,
  name: []const u8,
  ns_dependent: bool,
  bres: types.SigBuilderResult,
  p: *const Provider,
) !?*model.Symbol {
  const ret = try ctx.global().create(model.Symbol);
  ret.defined_at = model.Position.intrinsic();
  ret.name = name;
  ret.data = .{.func = (try extFunc(ctx, ret, bres, ns_dependent, p)) orelse {
    ctx.global().destroy(ret);
    return null;
  }};
  return ret;
}

fn typeConstructor(
  ctx: Context,
  p: *Provider,
  name: []const u8,
  bres: types.SigBuilderResult,
) !types.Constructor {
  return types.Constructor{
    .callable = try bres.createCallable(ctx.global(), .@"type"),
    .impl_index = try registerExtImpl(ctx, p, name, bres),
  };
}


// pub fn intrinsicModule(ctx: Context) !*model.Module {
//   var ret = try ctx.global().create(model.Module);
//   ret.root = try ctx.createValueExpr(
//     try ctx.values.void(model.Position.intrinsic()));
//   ret.symbols = try ctx.global().alloc(*model.Symbol, 22);
//   var index: usize = 0;

//   var ip = system.Impl.init();

//   const loc_syntax = // zig 0.9.0 crashes when inlining this
//     model.BlockConfig.SyntaxDef{.pos = model.Position.intrinsic(), .index = 0};
//   const location_block = try ctx.values.blockHeader(
//     model.Position.intrinsic(), model.BlockConfig{
//       .syntax = loc_syntax,
//       .map = &.{},
//       .off_colon = null,
//       .off_comment = null,
//       .full_ast = null,
//     }, null);

//   const def_syntax = // zig 0.9.0 crashes when inlining this
//     model.BlockConfig.SyntaxDef{.pos = model.Position.intrinsic(), .index = 1};
//   const definition_block = try ctx.values.blockHeader(
//     model.Position.intrinsic(), model.BlockConfig{
//       .syntax = def_syntax,
//       .map = &.{},
//       .off_colon = null,
//       .off_comment = null,
//       .full_ast = null,
//     }, null);
//   const t = ctx.types();

//   //-------------
//   // type symbols
//   //-------------

//   // Raw
//   var b = try types.SigBuilder.init(ctx, 1, t.raw(), true);
//   try b.push((try ctx.values.intLocation(
//     "input", t.raw())).withPrimary(
//       model.Position.intrinsic()));
//   ctx.types().constructors.raw = try
//     typeConstructor(ctx, &ip.provider, "constrRaw", b.finish());
//   ret.symbols[index] = try typeSymbol(ctx, "Raw", t.raw());
//   index += 1;

//   // Location
//   b = try types.SigBuilder.init(ctx, 8, t.ast(), false);
//   try b.push(try ctx.values.intLocation("name", t.literal())); // TODO: identifier
//   try b.push(try ctx.values.intLocation("type", t.@"type"()));
//   try b.push(try ctx.values.intLocation(
//     "primary", ctx.types().getBoolean().typedef()));
//   try b.push(try ctx.values.intLocation(
//     "varargs", ctx.types().getBoolean().typedef()));
//   try b.push(try ctx.values.intLocation(
//     "varmap", ctx.types().getBoolean().typedef()));
//   try b.push(try ctx.values.intLocation(
//     "mutable", ctx.types().getBoolean().typedef()));
//   try b.push(try ctx.values.intLocation("header", (try ctx.types().optional(
//       t.blockHeader())).?));
//   try b.push((try ctx.values.intLocation(
//     "default", (try ctx.types().optional(
//       t.ast())).?)).withPrimary(model.Position.intrinsic()));
//   ctx.types().constructors.location = try
//     typeConstructor(ctx, &ip.provider, "constrLocation", b.finish());
//   ret.symbols[index] =
//     try typeSymbol(ctx, "Location", t.location());
//   index += 1;

//   // Definition
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation("name", t.literal())); // TODO: identifier
//   try b.push(try ctx.values.intLocation(
//     "root", ctx.types().getBoolean().typedef()));
//   try b.push(try ctx.values.intLocation("item", t.ast()));
//   ctx.types().constructors.definition = try
//     typeConstructor(ctx, &ip.provider, "constrDefinition", b.finish());
//   ret.symbols[index] = try
//     typeSymbol(ctx, "Definition", t.definition());
//   index += 1;

//   // Boolean
//   ret.symbols[index] = ctx.types().boolean.name.?;
//   index += 1;

//   // Integer
//   ret.symbols[index] = ctx.types().integer.name.?;
//   index += 1;

//   // instantiated scalars
//   ctx.types().constructors.generic.textual =
//     try registerGenericImpl(ctx, &ip.provider, "constrTextual");
//   ctx.types().constructors.generic.numeric =
//     try registerGenericImpl(ctx, &ip.provider, "constrNumeric");
//   ctx.types().constructors.generic.float =
//     try registerGenericImpl(ctx, &ip.provider, "constrFloat");
//   ctx.types().constructors.generic.@"enum" =
//     try registerGenericImpl(ctx, &ip.provider, "constrEnum");

//   //------------------
//   // prototype symbols
//   //------------------

//   // Optional
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push((try ctx.values.intLocation("inner", t.ast()
//     )).withPrimary(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.optional = try
//     prototypeConstructor(ctx, &ip.provider, "Optional", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Optional", .optional);
//   index += 1;

//   // Concat
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push((try ctx.values.intLocation("inner", t.ast()
//     )).withPrimary(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.concat = try
//     prototypeConstructor(ctx, &ip.provider, "Concat", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Concat", .concat);
//   index += 1;

//   // List
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push((try ctx.values.intLocation("inner", t.ast()
//     )).withPrimary(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.list = try
//     prototypeConstructor(ctx, &ip.provider, "List", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "List", .list);
//   index += 1;

//   // Paragraphs
//   b = try types.SigBuilder.init(ctx, 2, t.ast(), false);
//   try b.push((try ctx.values.intLocation("inners", (try ctx.types().list(
//     t.ast())).?)).withVarargs(model.Position.intrinsic()
//     ).withPrimary(model.Position.intrinsic()));
//   try b.push(try ctx.values.intLocation("auto", (try ctx.types().optional(
//     t.ast())).?));
//   ctx.types().constructors.prototypes.paragraphs = try
//     prototypeConstructor(ctx, &ip.provider, "Paragraphs", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Paragraphs", .paragraphs);
//   index += 1;

//   // Map
//   b = try types.SigBuilder.init(ctx, 2, t.ast(), false);
//   try b.push(try ctx.values.intLocation("key", t.ast()));
//   try b.push(try ctx.values.intLocation("value", t.ast()));
//   ctx.types().constructors.prototypes.map = try
//     prototypeConstructor(ctx, &ip.provider, "Map", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Map", .map);
//   index += 1;

//   // Record
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   // TODO: allow record to extend other record (?)
//   try b.push((try ctx.values.intLocation("fields",
//     (try ctx.types().optional(t.ast())).?
//     )).withHeader(location_block).withPrimary(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.record = try
//     prototypeConstructor(ctx, &ip.provider, "Record", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Record", .record);
//   index += 1;

//   // Intersection
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push((try ctx.values.intLocation("types", (try ctx.types().list(
//     t.ast())).?)).withVarargs(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.intersection = try
//     prototypeConstructor(ctx, &ip.provider, "Intersection", b.finish());
//   ret.symbols[index] =
//     try prototypeSymbol(ctx, "Intersection", .intersection);
//   index += 1;

//   // Textual
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation("cats", t.ast()));
//   try b.push(try ctx.values.intLocation("include", t.ast()));
//   try b.push(try ctx.values.intLocation("exclude", t.ast()));
//   ctx.types().constructors.prototypes.textual = try
//     prototypeConstructor(ctx, &ip.provider, "Textual", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Textual", .textual);
//   index += 1;

//   // Numeric
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation(
//     "min", (try ctx.types().optional(t.ast())).?));
//   try b.push(try ctx.values.intLocation(
//     "max", (try ctx.types().optional(t.ast())).?));
//   try b.push(try ctx.values.intLocation(
//     "decimals", (try ctx.types().optional(t.ast())).?));
//   ctx.types().constructors.prototypes.numeric = try
//     prototypeConstructor(ctx, &ip.provider, "Numeric", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Numeric", .numeric);
//   index += 1;

//   // Float
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push(try ctx.values.intLocation("precision", t.ast()));
//   ctx.types().constructors.prototypes.float = try
//     prototypeConstructor(ctx, &ip.provider, "Float", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Float", .float);
//   index += 1;

//   // Enum
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push((try ctx.values.intLocation("values", (try ctx.types().list(
//     t.raw())).?)).withVarargs(model.Position.intrinsic()));
//   ctx.types().constructors.prototypes.@"enum" = try
//     prototypeConstructor(ctx, &ip.provider, "Enum", b.finish());
//   ret.symbols[index] = try prototypeSymbol(ctx, "Enum", .@"enum");
//   index += 1;

//   //-------------------
//   // external symbols
//   //-------------------

//   // declare
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation("namespace", (try ctx.types().optional(
//       t.@"type"())).?));
//   try b.push((try ctx.values.intLocation(
//     "public", (try ctx.types().optional(t.ast())).?
//   )).withPrimary(model.Position.intrinsic()).withHeader(definition_block));
//   try b.push((try ctx.values.intLocation(
//     "private", (try ctx.types().optional(t.ast())).?
//   )).withHeader(definition_block));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "declare", true, b.finish(), &ip.provider);
//   index += 1;

//   // if
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation(
//     "condition",  t.ast()));
//   try b.push((try ctx.values.intLocation(
//     "then", (try ctx.types().optional(t.ast())).?
//   )).withPrimary(model.Position.intrinsic()));
//   try b.push(try ctx.values.intLocation(
//     "else", (try ctx.types().optional(t.ast())).?));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "if", false, b.finish(), &ip.provider);
//   index += 1;

//   // func
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation("return",
//     (try ctx.types().optional(t.ast())).?));
//   try b.push((try ctx.values.intLocation(
//     "params", (try ctx.types().optional(t.ast())).?
//   )).withPrimary(model.Position.intrinsic()).withHeader(location_block));
//   try b.push(
//     (try ctx.values.intLocation("body", t.frameRoot())));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "func", true, b.finish(), &ip.provider);
//   index += 1;

//   // method
//   b = try types.SigBuilder.init(ctx, 3, t.ast(), false);
//   try b.push(try ctx.values.intLocation("return",
//     (try ctx.types().optional(t.ast())).?));
//   try b.push((try ctx.values.intLocation(
//     "params", (try ctx.types().optional(t.ast())).?
//   )).withPrimary(model.Position.intrinsic()).withHeader(location_block));
//   try b.push(
//     (try ctx.values.intLocation("body", t.frameRoot())));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "method", true, b.finish(), &ip.provider);
//   index += 1;

//   // import
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push(try ctx.values.intLocation("locator", t.ast()));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "import", true, b.finish(), &ip.provider);
//   index += 1;

//   // var
//   b = try types.SigBuilder.init(ctx, 1, t.ast(), false);
//   try b.push(
//     (try ctx.values.intLocation("defs", t.ast())).withHeader(
//       location_block).withPrimary(model.Position.intrinsic()));
//   ret.symbols[index] =
//     try extFuncSymbol(ctx, "var", true, b.finish(), &ip.provider);
//   index += 1;

//   std.debug.assert(index == ret.symbols.len);

//   return ret;
// }