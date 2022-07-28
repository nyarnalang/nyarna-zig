const std = @import("std");

const model = @import("../model.zig");

const Expression = model.Expression;
const Node       = model.Node;
const Type       = model.Type;

const offset = @import("../helpers.zig").offset;

const Value = @This();

pub const Ast = struct {
  /// a capture variable defined on this block.
  pub const VarDef = struct {
    ns  : u15,
    /// always allocated in global storage.
    name: []const u8,
    pos : model.Position,
  };

  root      : *Node,
  container : ?*model.VariableContainer,
  /// slice into the interpreters' list of symbols declarations.
  /// used for checking name collisions of variables that are introduced after
  /// parsing, e.g. function parameters or captures.
  inner_syms: []model.Symbol.Definition,
  capture   : []VarDef,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// This value type is used to read in block headers within SpecialSyntax,
/// e.g. the default block configuration of function parameters.
pub const BlockHeader = struct {
  config       : ?model.BlockConfig = null,
  swallow_depth: ?u21 = null,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// a Concat value
pub const Concat = struct {
  t      : *const Type.Concat,
  content: std.ArrayList(*Value),

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Definition = struct {
  name       : *Value.TextScalar,
  content_pos: model.Position,
  content    : union(enum) {
    /// might be a keyword function, which is why content is not simply a Value.
    func: *model.Function,
    @"type": model.Type,
  },
  merge: ?model.Position = null,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// an Enum value
pub const Enum = struct {
  t    : *const Type.Enum,
  index: usize,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// a float Numeric value
pub const FloatNum = struct {
  t       : *const Type.FloatNum,
  content : f64,
  cur_unit: usize,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }

  pub fn formatWithUnit(
    self        : @This(),
    unit_index  : usize,
    max_decimals: usize,
    decimal_sep : u8,
    writer      : anytype,
  ) @TypeOf(writer).Error!void {
    const unit = self.t.suffixes[unit_index];
    var out = self.content * unit.factor;
    try std.fmt.format(writer, "{}", .{std.math.trunc(out)});
    out = @mod(std.math.fabs(out), 1);
    if (max_decimals > 0 and out > 0) {
      try writer.writeByte(decimal_sep);
      var rem_decimals = max_decimals;
      while (rem_decimals > 0 and out > 0) : (rem_decimals -= 1) {
        out *= 10;
        try std.fmt.format(writer, "{}", .{std.math.trunc(out)});
        out = @mod(out, 1);
      }
    }
    try writer.writeAll(unit.suffix);
  }

  fn format(
    self      : @This(),
    comptime _: []const u8,
    _         : std.fmt.FormatOptions,
    writer    : anytype,
  ) @TypeOf(writer).Error!void {
    if (self.t.suffixes.len > 0) {
      try self.formatWithUnit(self.cur_unit, 2, '.', writer);
    } else {
      try std.fmt.format(writer, "{}", .{self.content});
    }
  }

  pub fn formatter(self: @This()) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};

pub const FuncRef = struct {
  func: *model.Function,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const HashMap = struct {
  pub const Items = std.HashMap(*Value, *Value, Value.HashContext, 50);

  t: *const Type.HashMap,
  items: Items,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// an integer Numeric value
pub const IntNum = struct {
  t       : *const Type.IntNum,
  content : i64,
  cur_unit: usize,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }

  pub fn formatWithUnit(
    self        : *const @This(),
    unit_index  : usize,
    max_decimals: usize,
    decimal_sep : u8,
    writer      : anytype,
  ) @TypeOf(writer).Error!void {
    const unit = self.t.suffixes[unit_index];
    var trunc = @divTrunc(self.content, unit.factor);
    try std.fmt.format(writer, "{}", .{trunc});
    var rem = @rem(self.content, unit.factor);
    if (max_decimals > 0 and rem != 0) {
      try writer.writeByte(decimal_sep);
      var rem_decimals = max_decimals;
      while (rem != 0 and rem_decimals > 0) : (rem_decimals -= 1) {
        rem = rem * 10;
        trunc = @mod(@divTrunc(rem, unit.factor), 10);
        rem = @rem(rem, unit.factor);
        try writer.writeByte('0' + @intCast(u8, trunc));
      }
    }
    try writer.writeAll(unit.suffix);
  }

  fn format(
             self  : *const @This(),
    comptime _     : []const u8,
             _     : std.fmt.FormatOptions,
             writer: anytype,
  ) @TypeOf(writer).Error!void {
    if (self.t.suffixes.len > 0) {
      try self.formatWithUnit(self.cur_unit, 2, '.', writer);
    } else {
      try std.fmt.format(writer, "{}", .{self.content});
    }
  }

  pub fn formatter(self: *const @This()) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};

/// a List value
pub const List = struct {
  t: *const Type.List,
  content: std.ArrayList(*Value),

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Location = struct {
  name   : *Value.TextScalar,
  spec   : model.SpecType,
  default: ?*Expression    = null,
  primary: ?model.Position = null,
  varargs: ?model.Position = null,
  varmap : ?model.Position = null,
  borrow : ?model.Position = null,
  header : ?*BlockHeader   = null,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }

  pub fn withDefault(self: *Location, v: *Expression) *Location {
    std.debug.assert(self.default == null);
    self.default = v;
    return self;
  }

  pub fn withHeader(self: *Location, v: *BlockHeader) *Location {
    std.debug.assert(self.header == null);
    self.header = v;
    return self;
  }

  pub fn withPrimary(self: *Location, v: model.Position) *Location {
    std.debug.assert(self.primary == null);
    self.primary = v;
    return self;
  }

  pub fn withVarargs(self: *Location, v: model.Position) *Location {
    std.debug.assert(self.varargs == null);
    self.varargs = v;
    return self;
  }
};

pub const Output = struct {
  name  : *TextScalar,
  schema: ?*Schema,
  body  : *Value,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const PrototypeVal = struct {
  pt: model.Prototype,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// a Record value
pub const Record = struct {
  t     : *const Type.Record,
  fields: []*Value,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Schema = struct {
  root   : model.SpecType,
  symbols: []*model.Symbol,
  /// The backend, if it exists, is a function that takes a value of type `root`
  /// as argument and returns a concatenation of \Output.
  ///
  /// Even if the SchemaDef had multiple backends, the Schema has at most one,
  /// this being the one that was selected during compilation of the SchemaDef.
  /// No more than one backend will be compiled into a schema.
  backend: ?*model.Function,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const SchemaDef = struct {
  defs    : []*Node.Definition,
  root    : *Node,
  backends: []*Node.Definition,
  /// This is the `val` capture on the backends block, if any.
  doc_var : ?Ast.VarDef,
  /// if this SchemaDef has already been instaniated, this is its instance.
  instance: ?*Schema = null,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const SchemaExt = struct {
  defs    : []*Node.Definition,
  backends: []*Node.Definition,
  /// see SchemaDef
  doc_var : ?Ast.VarDef,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// a Sequence value
pub const Seq = struct {
  pub const Item = struct {
    content : *Value,
    lf_after: usize,
  };
  t      : *const Type.Sequence,
  content: std.ArrayList(Item),

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};


/// a Space, Literal, Raw or Textual value
pub const TextScalar = struct {
  t      : Type,
  content: []const u8,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const TypeVal = struct {
  t: Type,

  pub fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Data = union(enum) {
  ast         : Ast,
  block_header: BlockHeader,
  concat      : Concat,
  definition  : Definition,
  @"enum"     : Enum,
  float       : FloatNum,
  funcref     : FuncRef,
  hashmap     : HashMap,
  int         : IntNum,
  list        : List,
  location    : Location,
  output      : Output,
  prototype   : PrototypeVal,
  record      : Record,
  schema      : Schema,
  schema_def  : SchemaDef,
  schema_ext  : SchemaExt,
  seq         : Seq,
  text        : TextScalar,
  @"type"     : TypeVal,
  void, poison
};

const HashContext = struct {
  pub fn hash(_: HashContext, v: *Value) u64 {
    return switch (v.data) {
      .text    => |ts|  std.hash_map.hashString(ts.content),
      .int     => |int| @bitCast(u64, int.content),
      .float   => |fl|  @bitCast(u64, fl.content),
      .@"enum" => |ev|  @intCast(u64, ev.index),
      .@"type" => |tv|  model.Type.HashContext.hash(undefined, tv.t),
      else => unreachable,
    };
  }

  pub fn eql(_: HashContext, a: *Value, b: *Value) bool {
    return switch (a.data) {
      .text    => |ts|  std.hash_map.eqlString(ts.content, b.data.text.content),
      .int     => |int| int.content == b.data.int.content,
      .float   => |fl|  fl.content  == b.data.float.content,
      .@"enum" => |ev|  ev.index    == b.data.@"enum".index,
      .@"type" => |tv|
        model.Type.HashContext.eql(undefined, tv.t, b.data.@"type".t),
      else => unreachable,
    };
  }
};

origin: model.Position,
data: Data,

fn parent(it: anytype) *Value {
  const t = @typeInfo(@TypeOf(it)).Pointer.child;
  const addr = @ptrToInt(it) - switch (t) {
    Ast          => offset(Data, "ast"),
    BlockHeader  => offset(Data, "block_header"),
    Concat       => offset(Data, "concat"),
    Definition   => offset(Data, "definition"),
    Enum         => offset(Data, "enum"),
    FloatNum     => offset(Data, "float"),
    FuncRef      => offset(Data, "funcref"),
    HashMap      => offset(Data, "hashmap"),
    IntNum       => offset(Data, "int"),
    List         => offset(Data, "list"),
    Location     => offset(Data, "location"),
    Output       => offset(Data, "output"),
    PrototypeVal => offset(Data, "prototype"),
    Record       => offset(Data, "record"),
    Schema       => offset(Data, "schema"),
    SchemaDef    => offset(Data, "schema_def"),
    SchemaExt    => offset(Data, "schema_ext"),
    Seq          => offset(Data, "seq"),
    TextScalar   => offset(Data, "text"),
    TypeVal      => offset(Data, "type"),
    else => unreachable,
  };
  return @fieldParentPtr(Value, "data", @intToPtr(*Data, addr));
}