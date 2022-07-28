const std = @import("std");

const CycleResolution = @import("Interpreter/CycleResolution.zig");
const nyarna            = @import("../nyarna.zig");
const unicode           = @import("unicode.zig");

const Context     = nyarna.Context;
const Evaluator   = nyarna.Evaluator;
const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

pub const system       = @import("lib/system.zig");
pub const constructors = @import("lib/constructors.zig");

const last = @import("helpers.zig").last;

/// A provider implements all external functions for a certain Nyarna module.
pub const Provider = struct {
  pub const KeywordWrapper = fn(
    ctx        : *Interpreter,
    pos        : model.Position,
    stack_frame: [*]model.StackItem,
  ) nyarna.Error!*model.Node;
  pub const BuiltinWrapper = fn(
    ctx        : *Evaluator,
    pos        : model.Position,
    stack_frame: [*]model.StackItem,
  ) nyarna.Error!*model.Value;

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
        .layout   = .Auto,
        .fields   = &fields,
        .decls    = &[_]std.builtin.TypeInfo.Declaration{},
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

      fn getTypedValue(
        comptime T    : type,
                 v    : *model.Value,
                 intpr: anytype,
      ) T {
        return switch (T) {
          model.Type => v.data.@"type".t,
          else => switch (@typeInfo(T)) {
            .Int      => @intCast(T, v.data.int.content),
            .Float    => @floatCast(T, v.data.float.content),
            .Optional => |opt| if (v.data == .void) null
                               else getTypedValue(opt.child, v, intpr),
            .Pointer  => |ptr| switch (ptr.child) {
              model.Node              => blk: {
                reportCaptures(intpr, &v.data.ast, 0);
                break :blk v.data.ast.root;
              },
              model.Node.Varmap       => blk: {
                reportCaptures(intpr, &v.data.ast, 0);
                break :blk &v.data.ast.root.data.varmap;
              },
              model.Value             => v,
              model.Value.Ast         => &v.data.ast,
              model.Value.BlockHeader => &v.data.block_header,
              model.Value.Concat      => &v.data.concat,
              model.Value.Definition  => &v.data.definition,
              model.Value.Enum        => &v.data.@"enum",
              model.Value.FloatNum    => &v.data.float,
              model.Value.FuncRef     => &v.data.funcref,
              model.Value.IntNum      => &v.data.int,
              model.Value.List        => &v.data.list,
              model.Value.Location    => &v.data.location,
              model.Value.HashMap     => &v.data.hashmap,
              model.Value.Record      => &v.data.record,
              model.Value.Seq         => &v.data.seq,
              model.Value.SchemaDef   => &v.data.schema_def,
              model.Value.TextScalar  => &v.data.text,
              model.Value.TypeVal     => &v.data.@"type",
              u8 =>
                if (ptr.is_const and ptr.size == .Slice)
                  v.data.text.content
                else std.debug.panic(
                  "invalid native parameter type: {s}", .{@typeName(T)}),
              else => std.debug.panic(
                "invalid native parameter type: {s}", .{@typeName(T)}),
            },
            else   => unreachable,
          },
        };
      }

      fn SingleWrapper(
        comptime FirstArg: type,
        comptime decl    : std.builtin.TypeInfo.Declaration,
        comptime Ret     : type,
      ) type {
        return struct {
          fn wrapper(
            ctx: FirstArg,
            pos: model.Position,
            stack_frame: [*]model.StackItem,
          ) nyarna.Error!*Ret {
            var unwrapped: Params(@typeInfo(decl.data.Fn.fn_type).Fn) =
              undefined;
            inline for (
              @typeInfo(@TypeOf(unwrapped)).Struct.fields
            ) |f, index| {
              unwrapped[index] = switch (index) {
                0 => ctx,
                1 => pos,
                else =>
                  getTypedValue(
                    f.field_type, stack_frame[index - 2].value, ctx),
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
  ctx : Context,
  p   : *const Provider,
  name: []const u8,
  is_keyword: bool,
) !?usize {
  return if (is_keyword) blk: {
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
  ctx : Context,
  p   : *const Provider,
  name: []const u8,
) !usize {
  const impl = p.getBuiltin(name) orelse (
    std.debug.panic("don't know generic builtin: {s}\n", .{name})
  );
  try ctx.data.builtin_registry.append(ctx.global(), impl);
  return ctx.data.builtin_registry.items.len - 1;
}

pub fn extFunc(
  ctx         : Context,
  impl_name   : []const u8,
  bres        : nyarna.Types.SigBuilderResult,
  ns_dependent: bool,
  p           : *const Provider,
) !?*model.Function {
  const index = (
    try registerExtImpl(ctx, p, impl_name, bres.sig.isKeyword())
  ) orelse return null;
  const container = try ctx.global().create(model.VariableContainer);
  container.* = .{
    .num_values = @intCast(u15, bres.sig.parameters.len),
  };
  const ret = try ctx.global().create(model.Function);
  ret.* = .{
    .callable   = try bres.createCallable(ctx.global(), .function),
    .defined_at = model.Position.intrinsic(),
    .data       = .{.ext = .{
      .ns_dependent = ns_dependent,
      .impl_index   = index,
    }},
    .name      = null,
    .variables = container,
  };
  return ret;
}

pub fn reportCaptures(
  intpr: *Interpreter,
  ast: *model.Value.Ast,
  allowed: usize,
) void {
  if (ast.capture.len > allowed) {
    intpr.ctx.logger.UnexpectedCaptureVars(
      ast.capture[allowed].pos.span(last(ast.capture).pos));
  }
}