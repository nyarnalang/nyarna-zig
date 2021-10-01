const std = @import("std");
const Context = @import("interpret.zig").Context;
const data = @import("data");

/// A provider implements all external functions for a certain Nyarna module.
pub const Provider = struct {
  pub const ImplWrapper = fn(ctx: *Context, args: []*data.Value) std.mem.Allocator.Error!*data.Value;

  getImpl: fn(name: []const u8) ?ImplWrapper,

  fn Params(comptime fn_decl: std.builtin.TypeInfo.Fn) type {
    var fields: [fn_decl.args.len]std.builtin.TypeInfo.StructField = undefined;
    var buf: [2*fn_decl.args.len]u8 = undefined;
    for (fn_decl.args) |arg, index| {
      fields[index] = .{
        .name = std.fmt.bufPrint(buf[2*index..2*index+2], "{}", .{index}) catch unreachable,
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
    const decls = @typeInfo(impls).Struct.decls;
    return struct {
      const Self = @This();

      provider: Provider,

      fn getTypedValue(comptime T: type, v: *data.Value) T {
        return switch (T) {
          data.Type => v.data.typeval.t,
          else => switch (@typeInfo(T)) {
            .Optional => |opt| if (v.data == .void) null else getTypedValue(opt.child, v),
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
              data.Value => &args[index],
              else => unreachable,
            },
            else => unreachable,
          },
        };
      }

      fn getImpl(name: []const u8) ?ImplWrapper {
        inline for (decls) |decl| {
          const dummy_ns = struct {
            fn wrapper(ctx: *Context, args: []*data.Value) std.mem.Allocator.Error!*data.Value {
              var unwrapped: Params(@typeInfo(decl.data.Fn.fn_type).Fn) = undefined;
              inline for (@typeInfo(@TypeOf(unwrapped)).Struct.fields) |f, index| {
                unwrapped[index] = getTypedValue(f.field_type, args[index]);
              }
              return @call(.{}, @field(impls, decl.name), unwrapped);
            }
          };
          if (std.hash_map.eqlString(name, decl.name)) {
            return dummy_ns.wrapper;
          }
        }
        return null;
      }

      pub fn init() Self {
        return .{
          .provider = .{
            .getImpl = getImpl,
          },
        };
      }
    };
  }
};

pub const Intrinsics = Provider.Wrapper(struct {
  fn declare(nsType: ?data.Type, public: *data.Value.Concat, private: *data.Value.Concat) !*data.Value {
    unreachable;
  }
});