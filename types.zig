const std = @import("std");
const data = @import("data.zig");
const unicode = @import("load/unicode.zig");

pub const Type = union(enum) {
  pub const Signature = struct {
    pub const Parameter = struct {
      pos: data.Position,
      name: []const u8,
      ptype: Type,
      capture: enum {default, varargs},
      default: *data.Expression,
      config: ?data.BlockConfig,
      mutable: bool,
    };

    parameter: []Parameter,
    keyword: bool,
    primary: ?u21,
    varmap: ?u21,
    auto_swallow: ?struct{
      param_index: usize,
      depth: usize,
    },
    returns: Type,
  };

  pub const Intersection = struct {
    scalar: ?Type,
    types: []Type,
  };

  /// types with structural equivalence
  pub const Structural = union(enum) {
    optional: Type,
    concat: Type,
    paragraphs: struct {
      inner: []Type,
      auto: ?u21,
    },
    list: Type,
    map: struct {
      key: Type,
      value: Type,
    },
    callable: *Signature,
    intersection: *Intersection,
  };

  /// parameters of a Textual type. The set of allowed characters is logically
  /// defined as follows:
  ///
  ///  * all characters in include.chars are in the set.
  ///  * all characters with a category in include.categories that are not in
  ///    exclude are in the set.
  pub const Textual = struct {
    include: struct {
      chars: []u8,
      categories: unicode.CategorySet,
    },
    exclude: []u8,
  };

  /// parameters of a Numeric type.
  pub const Numeric = struct {
    min: i64,
    max: i64,
    decimals: u32,
  };

  /// parameters of a Float type.
  pub const Float = struct {
    pub const Precision = enum {
      half, single, double, quadruple, octuple
    };
    precision: Precision,
  };

  /// parameters of an Enum type.
  pub const Enum = struct {
    /// retains the order of the enum values.
    /// must not be modified after creation.
    values: std.StringArrayHashMapUnmanaged(u0),
  };

  /// parameters of a Record type. contains the signature of its constructor.
  /// its fields are derived from that signature.
  pub const Record = struct {
    signature: Signature,
  };

  /// unique types predefined by Nyarna
  intrinsic: enum {
    void, prototype, schema, extension,
    space, literal, raw,
    location, definition, backend
  },

  structural: *Structural,
  /// types with name equivalence that are instantiated by user code
  instantiated: *struct{
    /// position at which the type has been declared.
    at: data.Position,
    /// name of the type, if it has any.
    name: *?data.Symbol,
    /// kind and parameters of the type
    data: union(enum) {
      textual: *Textual,
      numeric: *Numeric,
      float: *Float,
      tenum: *Enum,
      record: *Record,
    },
  },
};