const std = @import("std");

const model   = @import("../model.zig");
const unicode = @import("../unicode.zig");

const Expression = model.Expression;
const Position   = model.Position;
const Symbol     = model.Symbol;
const Value      = model.Value;


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
  /// its parameters have names "p1", "p2" etc, always default-capture, and have
  /// neither config nor default.
  ///
  /// undefined for keywords which cannot be used as Callable values and
  /// therefore never interact with the type lattice.
  repr: *Callable,
  /// list of Location values that represent this callable's parameters.
  locations: []*Value,

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Concatenation type with an inner type.
pub const Concat = struct {
  inner: Type,

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// An Enumeration type.
pub const Enum = struct {
  /// retains the order of the enum values.
  /// must not be modified after creation.
  /// the map's value is the position where the enum value has been defined.
  values: std.array_hash_map.String(model.Position),

  pub fn pos(self: *const @This()) Position {
    return Named.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Named.typedef(self);
  }

  pub fn named(self: *const @This()) *Named {
    return Named.parent(self);
  }
};

/// A Numeric type with float backend.
/// has a minimum value and a maximum value.
pub const FloatNum = struct {
  pub const Unit = struct {
    suffix: []const u8,
    factor: f64,
  };

  min: f64,
  max: f64,
  suffixes: []Unit,

  pub fn pos(self: *@This()) Position {
    return Named.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Named.typedef(self);
  }

  pub fn named(self: *const @This()) *Named {
    return Named.parent(self);
  }
};

/// Intersection is a virtual type that takes values of possibly a scalar type,
/// or a set of Record types.
pub const Intersection = struct {
  scalar: ?Type,
  types: []Type,

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// A Numeric type with integer backend.
/// has a minimum value and a maximum value.
pub const IntNum = struct {
  pub const Unit = struct {
    suffix: []const u8,
    factor: i64,
  };

  min: i64,
  max: i64,
  suffixes: []Unit,

  pub fn pos(self: *@This()) Position {
    return Named.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Named.typedef(self);
  }

  pub fn named(self: *const @This()) *Named {
    return Named.parent(self);
  }
};

/// List type with an inner type.
pub const List = struct {
  inner: Type,

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// HashMap type with a key and a value type.
pub const HashMap = struct {
  key  : model.Type,
  value: model.Type,

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Optional virtual type with an inner type.
pub const Optional = struct {
  inner: Type,

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }
};

/// Sequence type for paragraphs.
pub const Sequence = struct {
  /// the direct type is the single scalar or concat type in this Sequence.
  /// there may be at most one such type.
  direct: ?Type,
  /// all other types are records.
  inner: []*Record,
  /// non-null if this sequence has an auto type
  auto: ?struct {
    /// index into inner that identifiers the auto type
    index: u21,
    /// representant type that has the same direct and inner, but no auto.
    /// this will be used for type calculations.
    repr: *Sequence,
  },

  pub fn pos(self: *@This()) Position {
    return Structural.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Structural.typedef(self);
  }

  pub fn repr(self: *const @This()) Type {
    return if (self.auto) |auto| auto.repr.typedef() else self.typedef();
  }
};

/// A Record type. Its fields are defined by its constructor's signature.
pub const Record = struct {
  /// an Record embedded in this one.
  pub const Embed = struct {
    t          : *Record,
    /// first field declared directly by the embedded record (not its embeds).
    first_field: usize,
  };

  /// Constructor signature.
  /// Serves as type of the Record when used as type value.
  constructor: *Callable,
  embeds     : []Embed,
  /// first field in the constructor that belongs to this record.
  first_own  : usize,
  abstract   : bool,

  pub fn pos(self: *@This()) Position {
    return Named.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Named.typedef(self);
  }

  pub fn named(self: *const @This()) *Named {
    return Named.parent(self);
  }
};

/// A Textual type.
/// The set of allowed characters is logically defined as follows:
///
///  * all characters in include.chars are in the set.
///  * all characters with a category in include.categories that are not in
///    exclude are in the set.
pub const Textual = struct {
  include: struct {
    /// not changed after creation
    chars: std.hash_map.AutoHashMapUnmanaged(u21, void),
    categories: unicode.CategorySet,
  },
  /// not changed after creation
  exclude: std.hash_map.AutoHashMapUnmanaged(u21, void),

  pub fn pos(self: *@This()) Position {
    return Named.pos(self);
  }

  pub fn typedef(self: *const @This()) Type {
    return Named.typedef(self);
  }

  pub fn includes(self: Textual, cp: u21) bool {
    const included =
      self.include.categories.contains(unicode.category(cp))
      and self.exclude.get(cp) == null;
    return included or self.include.chars.get(cp) != null;
  }
};

//----------------------------------------------------------------------------//
// type kinds (name-equiv vs structure equiv)                                 //
//----------------------------------------------------------------------------//

/// A type with name equivalence. This includes unique types.
pub const Named = struct {
  pub const Data = union(enum) {
    textual: Textual,
    @"enum": Enum,
    float  : FloatNum,
    int    : IntNum,
    record : Record,
    // what follows are unique intrinsic types.
    ast, block_header, definition, every, frame_root, literal, location, output,
    poison, prototype, schema, schema_def, schema_ext, space, @"type", @"void",
  };
  /// position at which the type has been declared.
  at: Position,
  /// name of the type, if it has any.
  name: ?*Symbol,
  /// kind and parameters of the type
  data: Data,

  fn parent(it: anytype) *Named {
    const t = @typeInfo(@TypeOf(it)).pointer.child;
    const data: *Data = switch (t) {
      Textual  => @alignCast(@fieldParentPtr("textual", @constCast(it))),
      Enum     => @alignCast(@fieldParentPtr("enum", @constCast(it))),
      FloatNum => @alignCast(@fieldParentPtr("float", @constCast(it))),
      IntNum   => @alignCast(@fieldParentPtr("int", @constCast(it))),
      Record   => @alignCast(@fieldParentPtr("record", @constCast(it))),
      else => unreachable
    };
    return @fieldParentPtr("data", data);
  }

  /// calculates the position of Textual, Numeric, Enum, or Record
  pub fn pos(it: anytype) Position {
    return parent(it).at;
  }

  /// returns a type, given a pointer to Named or any of its data types.
  pub fn typedef(it: anytype) Type {
    return .{
      .named = if (@TypeOf(it) == *Named) it else parent(it),
    };
  }
};

/// types with structural equivalence
pub const Structural = union(enum) {
  /// general type for anything callable, has flag for whether it's a type
  callable    : Callable,
  concat      : Concat,
  intersection: Intersection,
  list        : List,
  hashmap     : HashMap,
  optional    : Optional,
  sequence    : Sequence,

  fn parent(it: anytype) *Structural {
    const t = @typeInfo(@TypeOf(it)).pointer.child;
    return switch (t) {
      Callable     => @alignCast(@fieldParentPtr("callable", @constCast(it))),
      Concat       => @alignCast(@fieldParentPtr("concat", @constCast(it))),
      HashMap      => @alignCast(@fieldParentPtr("hashmap", @constCast(it))),
      Intersection =>
        @alignCast(@fieldParentPtr("intersection", @constCast(it))),
      List         => @alignCast(@fieldParentPtr("list", @constCast(it))),
      Optional     => @alignCast(@fieldParentPtr("optional", @constCast(it))),
      Sequence     => @alignCast(@fieldParentPtr("sequence", @constCast(it))),
      else => unreachable
    };
  }

  /// calculates the position from a pointer to one of the inner types
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
  pub const Callable     = local.Callable;
  pub const Concat       = local.Concat;
  pub const HashMap      = local.HashMap;
  pub const Intersection = local.Intersection;
  pub const List         = local.List;
  pub const Optional     = local.Optional;
  pub const Sequence     = local.Sequence;
  pub const Structural   = local.Structural;

  pub const Enum     = local.Enum;
  pub const FloatNum = local.FloatNum;
  pub const IntNum   = local.IntNum;
  pub const Record   = local.Record;
  pub const Textual  = local.Textual;
  pub const Named    = local.Named;

  /// types with structural equivalence.
  structural: *local.Structural,
  /// types with name equivalence that are named by user code.
  named: *local.Named,

  pub const HashContext = struct {
    pub fn hash(_: HashContext, t: Type) u64 {
      return switch (t) {
        .structural => |s| @as(u64, @intCast(@intFromPtr(s))),
        .named => |in| @as(u64, @intCast(@intFromPtr(in))),
      };
    }

    pub fn eql(_: HashContext, a: Type, b: Type) bool {
      return a.eql(b);
    }
  };

  pub fn isScalar(t: @This()) bool {
    return switch (t) {
      .structural => false,
      .named => |it| switch (it.data) {
        .textual, .int, .float, .@"enum", .space, .literal => true,
        else => false,
      },
    };
  }

  pub fn isStruc(t: Type, comptime expected: anytype) bool {
    return switch (t) {
      .structural => |strct| strct.* == expected,
      else => false,
    };
  }

  pub fn isNamed(t: Type, comptime expected: anytype) bool {
    return switch (t) {
      .named => |named| named.data == expected,
      else => false,
    };
  }

  pub fn eql(a: Type, b: Type) bool {
    return switch (a) {
      .named => |ia|
        switch (b) {.named => |ib| ia == ib, else => false},
      .structural => |sa|
        switch (b) {.structural => |sb| sa == sb, else => false},
    };
  }

  fn listTypes(
    data  : anytype,
    index : *usize,
    writer: *std.Io.Writer
  ) std.Io.Writer.Error!void {
    switch (comptime @typeInfo(@TypeOf(data))) {
      .optional => if (data) |value| {
        try listTypes(value, index, writer);
      },
      .@"struct" => |strct| {
        inline for (strct.field_names) |name| {
          try listTypes(@field(data, name), index, writer);
        }
      },
      .@"union" => { // Type
        if (index.* > 0) try writer.writeAll(", ");
        try data.format(writer);
        index.* += 1;
      },
      .pointer => |ptr| if (ptr.size == .one) {
        try listTypes(data.typedef(), index, writer);
      } else {
        for (data) |item| try listTypes(item, index, writer);
      },
      else => std.debug.panic("Invalid input for listing types: {s}",
        .{@tagName(@typeInfo(@TypeOf(data)))}),
    }
  }

  fn formatParameterized(
    name  : []const u8,
    inners: anytype,
    writer: *std.Io.Writer,
  ) std.Io.Writer.Error!void {
    try writer.writeAll(name);
    try writer.writeByte('<');
    var index: usize = 0;
    try listTypes(inners, &index, writer);
    try writer.writeByte('>');
  }

  pub fn format(
    self  : Type,
    writer: *std.Io.Writer
  ) std.Io.Writer.Error!void {
    switch (self) {
      .structural => |struc| try switch (struc.*) {
        .optional => |op| formatParameterized(
          "Optional", op.inner, writer),
        .concat => |con| formatParameterized(
          "Concat", con.inner, writer),
        .sequence => |seq| formatParameterized(
          "Sequence", .{seq.direct, seq.inner}, writer),
        .list => |list| formatParameterized(
          "List", list.inner, writer),
        .hashmap => |map| formatParameterized(
          "HashMap", .{map.key, map.value}, writer),
        .callable => |clb| {
          try writer.writeAll(switch (clb.kind) {
            .function => @as([]const u8, "[function] "),
            .@"type" => "[type] ",
            .prototype => "[prototype] ",
          });
          try writer.writeByte('(');
          for (clb.sig.parameters, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try param.spec.t.format(writer);
          }
          try writer.writeAll(") -> ");
          try clb.sig.returns.format(writer);
        },
        .intersection => |inter| {
          try writer.writeByte('{');
          var index: usize = 0;
          try listTypes(.{inter.scalar, inter.types}, &index, writer);
          try writer.writeByte('}');
          return;
        },
      },
      .named => |it| {
        try writer.writeAll(if (it.name) |sym| sym.name else @tagName(it.data));
      },
    }
  }

  pub fn formatAll(
    types : []const Type,
    writer: *std.Io.Writer,
  ) std.Io.Writer.Error!void {
    for (types, 0..) |t, i| {
      if (i > 0) try writer.writeAll(", ");
      try t.format(writer);
    }
  }

  pub fn formatter(self: Type) std.fmt.Alt(Type, format) {
    return .{.data = self};
  }

  pub fn formatterAll(types: []const Type)
      std.fmt.Alt([]const Type, formatAll) {
    return .{.data = types};
  }

  /// creates a SpecType at intrinsic position, for target types that are
  /// specified by the language itself.
  pub fn predef(self: Type) model.SpecType {
    return self.at(model.Position.intrinsic());
  }

  pub fn at(self: Type, pos: model.Position) model.SpecType {
    return .{.t = self, .pos = pos};
  }
};