const std = @import("std");

const model = @import("../model.zig");
const Expression = @import("Expression.zig");
const Node = @import("Node.zig");
const Type = @import("types.zig").Type;
const offset = @import("../helpers.zig").offset;

const Value = @This();

/// a Space, Literal, Raw or Textual value
pub const TextScalar = struct {
  t: Type,
  content: []const u8,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a Numeric value
pub const Number = struct {
  t: *const Type.Numeric,
  content: i64,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }

  fn format(
    self: *const Number,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype
  ) @TypeOf(writer).Error!void {
    const one = std.math.pow(i64, 10, self.t.decimals);
    try std.fmt.format(writer, "{}", .{@divTrunc(self.content, one)});
    const rest = @mod((std.math.absInt(self.content) catch unreachable), one);
    if (rest > 0) {
      try std.fmt.format(writer, ".{}", .{rest});
    }
  }

  pub fn formatter(self: *const @This()) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};
/// a Float value
pub const FloatNumber = struct {
  pub const Content = union {
    half: f16,
    single: f32,
    double: f64,
    quadruple: f128,
  };

  t: *const Type.Float,
  content: Content,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// an Enum value
pub const Enum = struct {
  t: *const Type.Enum,
  index: usize,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a Record value
pub const Record = struct {
  t: *const Type.Record,
  fields: []*Value,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a Concat value
pub const Concat = struct {
  t: *const Type.Concat,
  content: std.ArrayList(*Value),

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a Sequence value
pub const Seq = struct {
  pub const Item = struct {
    content: *Value,
    lf_after: usize,
  };
  t: *const Type.Sequence,
  content: std.ArrayList(Item),

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a List value
pub const List = struct {
  t: *const Type.List,
  content: std.ArrayList(*Value),

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};
/// a Map value
pub const Map = struct {
  pub const Items = std.HashMap(*Value, *Value, Value.HashContext, 50);

  t: *const Type.Map,
  items: Items,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const TypeVal = struct {
  t: Type,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const PrototypeVal = struct {
  pt: model.Prototype,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const FuncRef = struct {
  func: *model.Function,

  pub inline fn value(self: *@This()) *Value {
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

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }

  pub inline fn withDefault(self: *Location, v: *Expression) *Location {
    std.debug.assert(self.default == null);
    self.default = v;
    return self;
  }

  pub inline fn withHeader(self: *Location, v: *BlockHeader) *Location {
    std.debug.assert(self.header == null);
    self.header = v;
    return self;
  }

  pub inline fn withPrimary(self: *Location, v: model.Position) *Location {
    std.debug.assert(self.primary == null);
    self.primary = v;
    return self;
  }

  pub inline fn withVarargs(self: *Location, v: model.Position) *Location {
    std.debug.assert(self.varargs == null);
    self.varargs = v;
    return self;
  }
};

pub const Definition = struct {
  name: *Value.TextScalar,
  content_pos: model.Position,
  content: union(enum) {
    /// might be a keyword function, which is why content is not simply a Value.
    func: *model.Function,
    @"type": model.Type,
  },
  root: ?model.Position = null,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Ast = struct {
  root: *Node,
  container: ?*model.VariableContainer,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

/// This value type is used to read in block headers within SpecialSyntax,
/// e.g. the default block configuration of function parameters.
pub const BlockHeader = struct {
  config: ?model.BlockConfig = null,
  swallow_depth: ?u21 = null,

  pub inline fn value(self: *@This()) *Value {
    return Value.parent(self);
  }
};

pub const Data = union(enum) {
  text        : TextScalar,
  number      : Number,
  float       : FloatNumber,
  @"enum"     : Enum,
  record      : Record,
  concat      : Concat,
  seq         : Seq,
  list        : List,
  map         : Map,
  @"type"     : TypeVal,
  prototype   : PrototypeVal,
  funcref     : FuncRef,
  location    : Location,
  definition  : Definition,
  ast         : Ast,
  block_header: BlockHeader,
  void, poison
};

const HashContext = struct {
  pub fn hash(_: HashContext, v: *Value) u64 {
    return switch (v.data) {
      .text => |ts| std.hash_map.hashString(ts.content),
      .number => |num| @bitCast(u64, num.content),
      .float => |fl| switch (fl.t.precision) {
        .half => @intCast(u64, @bitCast(u16, fl.content.half)),
        .single => @intCast(u64, @bitCast(u32, fl.content.single)),
        .double => @bitCast(u64, fl.content.double),
        .quadruple, .octuple =>
          @truncate(u64, @bitCast(u128, fl.content.quadruple)),
      },
      .@"enum" => |ev| @intCast(u64, ev.index),
      else => unreachable,
    };
  }

  pub fn eql(_: HashContext, a: *Value, b: *Value) bool {
    return switch (a.data) {
      .text => |ts| std.hash_map.eqlString(ts.content, b.data.text.content),
      .number => |num| num.content == b.data.number.content,
      .float => |fl| switch (fl.t.precision) {
        .half => fl.content.half == b.data.float.content.half,
        .single => fl.content.single == b.data.float.content.single,
        .double => fl.content.double == b.data.float.content.double,
        .quadruple, .octuple =>
          fl.content.quadruple == b.data.float.content.quadruple,
      },
      .@"enum" => |ev| ev.index == b.data.@"enum".index,
      else => unreachable,
    };
  }
};

origin: model.Position,
data: Data,

pub inline fn create(
  allocator: std.mem.Allocator,
  pos: model.Position,
  content: anytype,
) !*Value {
  var ret = try allocator.create(Value);
  ret.origin = pos;
  ret.data = switch (@TypeOf(content)) {
    TextScalar   => .{.text         = content},
    Number       => .{.number       = content},
    FloatNumber  => .{.float        = content},
    Enum         => .{.enumval      = content},
    Record       => .{.record       = content},
    Concat       => .{.concat       = content},
    Seq          => .{.seq          = content},
    List         => .{.list         = content},
    Map          => .{.map          = content},
    TypeVal      => .{.@"type"      = content},
    PrototypeVal => .{.prototype    = content},
    FuncRef      => .{.funcref      = content},
    Definition   => .{.definition   = content},
    Ast          => .{.ast          = content},
    BlockHeader  => .{.block_header = content},
    else         => content
  };
  return ret;
}

fn parent(it: anytype) *Value {
  const t = @typeInfo(@TypeOf(it)).Pointer.child;
  const addr = @ptrToInt(it) - switch (t) {
    TextScalar   => offset(Data, "text"),
    Number       => offset(Data, "number"),
    FloatNumber  => offset(Data, "float"),
    Enum         => offset(Data, "enum"),
    Record       => offset(Data, "record"),
    Concat       => offset(Data, "concat"),
    Seq          => offset(Data, "seq"),
    List         => offset(Data, "list"),
    Map          => offset(Data, "map"),
    TypeVal      => offset(Data, "type"),
    PrototypeVal => offset(Data, "prototype"),
    FuncRef      => offset(Data, "funcref"),
    Location     => offset(Data, "location"),
    Definition   => offset(Data, "definition"),
    Ast          => offset(Data, "ast"),
    BlockHeader  => offset(Data, "block_header"),
    else => unreachable
  };
  return @fieldParentPtr(Value, "data", @intToPtr(*Data, addr));
}