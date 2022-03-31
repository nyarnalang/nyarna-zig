const std = @import("std");

const model = @import("../model.zig");
const unicode = @import("../unicode.zig");
const Expression = @import("Expression.zig");
const Symbol = @import("Symbol.zig");
const offset = @import("../helpers.zig").offset;
const Position = model.Position;

const local = @This();

//----------------------------------------------------------------------------//
// available types                                                            //
//----------------------------------------------------------------------------//

/// Type of callable entities.
pub const Callable = struct {
  pub const Kind = enum {function, @"type", prototype};
  /// allocated separately to make the Structural union smaller.
  sig: *model.Signature,
  /// This determines the position of this type in the type hierarchy.
  /// For a Callable c,
  ///    c < Type iff c.kind == type
  ///    c < Prototype iff c.kind == prototype
  /// no relation to Type resp. Prototype otherwise.
  kind: Kind,
  /// representative of this type in the type lattice.
  /// the representative has no primary, varmap, or auto_swallow value, and
  /// its parameters have empty names, always default-capture, and have
  /// neither config nor default.
  ///
  /// undefined for keywords which cannot be used as Callable values and
  /// therefore never interact with the type lattice.
  repr: *Callable,

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Concatenation type with an inner type.
pub const Concat = struct {
  inner: Type,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// An Enumeration type.
pub const Enum = struct {
  constructor: *Callable,
  /// retains the order of the enum values.
  /// must not be modified after creation.
  /// the map's value is the position where the enum value has been defined.
  values: std.StringArrayHashMapUnmanaged(model.Position),

  pub inline fn pos(self: *const @This()) Position {
    return Instantiated.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Instantiated.typedef(self);
  }

  pub inline fn instantiated(self: *const @This()) *Instantiated {
    return Instantiated.parent(self);
  }
};

/// A Float type. While at most five structually different Float types can ever
/// exist, Float types have name equivalence, which is why it is not five
/// enumeration values in the Type enum.
pub const Float = struct {
  pub const Precision = enum {
    half, single, double, quadruple, octuple
  };

  constructor: *Callable,
  precision: Precision,

  pub inline fn pos(self: *@This()) Position {
    return Instantiated.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Instantiated.typedef(self);
  }

  pub inline fn instantiated(self: *const @This()) *Instantiated {
    return Instantiated.parent(self);
  }
};

/// Intersection is a virtual type that takes values of possibly a scalar type,
/// or a set of Record types.
pub const Intersection = struct {
  scalar: ?Type,
  types: []Type,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// List type with an inner type.
pub const List = struct {
  inner: Type,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Map type with a key and a value type.
pub const Map = struct {
  key: Type,
  value: Type,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// A Numeric type, which has a minimum value, a maximum value, and a defined
/// number of decimal digits. std.math.minInt(i64) and std.math.maxInt(i64)
/// serve as the implementation-defined smallest and largest possible numbers.
pub const Numeric = struct {
  constructor: *Callable,
  min: i64,
  max: i64,
  decimals: u8,

  pub inline fn pos(self: *@This()) Position {
    return Instantiated.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Instantiated.typedef(self);
  }

  pub inline fn instantiated(self: *const @This()) *Instantiated {
    return Instantiated.parent(self);
  }
};

/// Optional virtual type with an inner type.
pub const Optional = struct {
  inner: Type,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Paragraphs type, with a set of inner types, and possibly a callable
/// auto-type which will be used to implicitly wrap paragraphs that are not
/// assignable to any inner type.
pub const Paragraphs = struct {
  inner: []Type,
  /// index into inner, if set.
  auto: ?u21,

  pub inline fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// A Record type. Its fields are defined by its constructor's signature.
pub const Record = struct {
  /// Constructor signature.
  /// Serves as type of the Record when used as type value.
  constructor: *Callable,

  pub fn pos(self: *@This()) Position {
    return Instantiated.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Instantiated.typedef(self);
  }

  pub inline fn instantiated(self: *const @This()) *Instantiated {
    return Instantiated.parent(self);
  }
};

/// A Textual type.
/// The set of allowed characters is logically defined as follows:
///
///  * all characters in include.chars are in the set.
///  * all characters with a category in include.categories that are not in
///    exclude are in the set.
pub const Textual = struct {
  constructor: *Callable,
  include: struct {
    /// not changed after creation
    chars: std.hash_map.AutoHashMapUnmanaged(u21, void),
    categories: unicode.CategorySet,
  },
  /// not changed after creation
  exclude: std.hash_map.AutoHashMapUnmanaged(u21, void),

  pub inline fn pos(self: *@This()) Position {
    return Instantiated.pos(self);
  }

  pub inline fn typedef(self: *const @This()) Type {
    return Instantiated.typedef(self);
  }
};

//----------------------------------------------------------------------------//
// type kinds (name-equiv vs structure equiv)                                 //
//----------------------------------------------------------------------------//

/// A type with name equivalence. This includes unique types.
pub const Instantiated = struct {
  pub const Data = union(enum) {
    textual: Textual,
    numeric: Numeric,
    float: Float,
    tenum: Enum,
    record: Record,
    // what follows are unique intrinsic types.
    @"void", prototype, schema, extension, ast, frame_root, block_header,
    @"type", space, literal, raw, location, definition, backend, poison, every,
  };
  /// position at which the type has been declared.
  at: Position,
  /// name of the type, if it has any.
  name: ?*Symbol,
  /// kind and parameters of the type
  data: Data,

  fn parent(it: anytype) *Instantiated {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch (t) {
      Textual =>  offset(Data, "textual"),
      Numeric => offset(Data, "numeric"),
      Float => offset(Data, "float"),
      Enum => offset(Data, "tenum"),
      Record => offset(Data, "record"),
      else => unreachable
    };
    return @fieldParentPtr(Instantiated, "data", @intToPtr(*Data, addr));
  }

  /// calculates the position from a pointer to Textual, Numeric, Float,
  /// Enum, or Record
  pub fn pos(it: anytype) Position {
    return parent(it).at;
  }

  /// returns a type, given a pointer to Instantiated or any of its data types.
  pub fn typedef(it: anytype) Type {
    return .{
      .instantiated = if (@TypeOf(it) == *Instantiated) it else parent(it),
    };
  }
};

/// types with structural equivalence
pub const Structural = union(enum) {
  /// general type for anything callable, has flag for whether it's a type
  callable: Callable,
  concat: Concat,
  intersection: Intersection,
  list: List,
  map: Map,
  optional: Optional,
  paragraphs: Paragraphs,

  fn parent(it: anytype) *Structural {
    const t = @typeInfo(@TypeOf(it)).Pointer.child;
    const addr = @ptrToInt(it) - switch (t) {
      Optional => offset(Structural, "optional"),
      Concat => offset(Structural, "concat"),
      Paragraphs => offset(Structural, "paragraphs"),
      List => offset(Structural, "list"),
      Map => offset(Structural, "map"),
      Callable => offset(Structural, "callable"),
      Intersection => offset(Structural, "intersection"),
      else => unreachable
    };
    return @intToPtr(*Structural, addr);
  }

  /// calculates the position from a pointer to Textual, Numeric, Float,
  /// Enum, or Record
  fn pos(it: anytype) Position {
    return parent(it).at;
  }

  /// returns a type, given a pointer to Structural or any of its data types.
  pub fn typedef(it: anytype) Type {
    return .{.structural = if (@TypeOf(it) == *Structural) it else parent(it)};
  }
};

//----------------------------------------------------------------------------//
// the actual Type type (should be imported directly, contains everything)    //
//----------------------------------------------------------------------------//

pub const Type = union(enum) {
  pub const Callable = local.Callable;
  pub const Concat = local.Concat;
  pub const Intersection = local.Intersection;
  pub const Map = local.Map;
  pub const Optional = local.Optional;
  pub const Paragraphs = local.Paragraphs;
  pub const List = local.List;
  pub const Structural = local.Structural;

  pub const Enum = local.Enum;
  pub const Float = local.Float;
  pub const Numeric = local.Numeric;
  pub const Record = local.Record;
  pub const Textual = local.Textual;
  pub const Instantiated = local.Instantiated;

  /// types with structural equivalence.
  structural: *local.Structural,
  /// types with name equivalence that are instantiated by user code.
  instantiated: *local.Instantiated,

  pub const HashContext = struct {
    pub fn hash(_: HashContext, t: Type) u64 {
      return switch (t) {
        .structural => |s| @intCast(u64, @ptrToInt(s)),
        .instantiated => |in| @intCast(u64, @ptrToInt(in)),
      };
    }

    pub fn eql(_: HashContext, a: Type, b: Type) bool {
      return a.eql(b);
    }
  };

  pub fn isScalar(t: @This()) bool {
    return switch (t) {
      .structural => false,
      .instantiated => |it| switch (it.data) {
        .textual, .numeric, .float, .tenum, .space, .literal, .raw => true,
        else => false,
      },
    };
  }

  pub inline fn isStruc(t: Type, comptime expected: anytype) bool {
    return switch (t) {
      .structural => |strct| strct.* == expected,
      else => false,
    };
  }

  pub inline fn isInst(t: Type, comptime expected: anytype) bool {
    return switch (t) {
      .instantiated => |inst| inst.data == expected,
      else => false,
    };
  }

  pub inline fn eql(a: Type, b: Type) bool {
    return switch (a) {
      .instantiated => |ia|
        switch (b) {.instantiated => |ib| ia == ib, else => false},
      .structural => |sa|
        switch (b) {.structural => |sb| sa == sb, else => false},
    };
  }

  fn formatParameterized(
    comptime fmt: []const u8,
    opt: std.fmt.FormatOptions,
    name: []const u8,
    inners: []const Type,
    writer: anytype,
  ) @TypeOf(writer).Error!void {
    try writer.writeAll(name);
    try writer.writeByte('<');
    for (inners) |inner, index| {
      if (index > 0) {
        try writer.writeAll(", ");
      }
      try inner.format(fmt, opt, writer);
    }
    try writer.writeByte('>');
  }

  pub fn format(
    self: Type,
    comptime fmt: []const u8,
    opt: std.fmt.FormatOptions,
    writer: anytype
  ) @TypeOf(writer).Error!void {
    switch (self) {
      .structural => |struc| try switch (struc.*) {
        .optional => |op| formatParameterized(
          fmt, opt, "Optional", &[_]Type{op.inner}, writer),
        .concat => |con| formatParameterized(
          fmt, opt, "Concat", &[_]Type{con.inner}, writer),
        .paragraphs => |para| formatParameterized(
          fmt, opt, "Paragraphs", para.inner, writer),
        .list => |list| formatParameterized(
          fmt, opt, "List", &[_]Type{list.inner}, writer),
        .map => |map| formatParameterized(
          fmt, opt, "Optional", &[_]Type{map.key, map.value}, writer),
        .callable => |clb| {
          try writer.writeAll(switch (clb.kind) {
            .function => @as([]const u8, "[function] "),
            .@"type" => "[type] ",
            .prototype => "[prototype] ",
          });
          try writer.writeByte('(');
          for (clb.sig.parameters) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try param.ptype.format(fmt, opt, writer);
          }
          try writer.writeAll(") -> ");
          try clb.sig.returns.format(fmt, opt, writer);
        },
        .intersection => |inter| {
          try writer.writeByte('{');
          if (inter.scalar) |scalar| try scalar.format(fmt, opt, writer);
          for (inter.types) |inner, i| {
            if (i > 0 or inter.scalar != null) try writer.writeAll(", ");
            try inner.format(fmt, opt, writer);
          }
          try writer.writeByte('}');
          return;
        },
      },
      .instantiated => |it| {
        try writer.writeAll(if (it.name) |sym| sym.name else @tagName(it.data));
      },
    }
  }

  pub fn formatAll(
    types: []const Type,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
  ) @TypeOf(writer).Error!void {
    for (types) |t, i| {
      if (i > 0) try writer.writeAll(", ");
      try t.format(fmt, options, writer);
    }
  }

  pub inline fn formatter(self: Type) std.fmt.Formatter(format) {
    return .{.data = self};
  }

  pub inline fn formatterAll(types: []const Type)
      std.fmt.Formatter(formatAll) {
    return .{.data = types};
  }
};