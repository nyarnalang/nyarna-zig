const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model    = nyarna.model;
const Node     = model.Node;
const Type     = model.Type;
const Value    = model.Value;
const Position = model.Position;

const Self = @This();

dummy: u8 = 0, // needed for @fieldParentPtr to work

inline fn allocator(self: *const Self) std.mem.Allocator {
  return @fieldParentPtr(nyarna.Context, "values", self).global();
}

inline fn types(self: *const Self) *nyarna.Types {
  return @fieldParentPtr(nyarna.Context, "values", self).types();
}

inline fn create(self: *const Self) !*Value {
  return self.allocator().create(Value);
}

pub inline fn value(
  self: *const Self,
  pos : Position,
  data: Value.Data,
) !*Value {
  const ret = try self.create();
  ret.* = .{.origin = pos, .data = data};
  return ret;
}

pub inline fn ast(
  self      : *const Self,
  root      : *Node,
  container : ?*model.VariableContainer,
  inner_syms: []model.Symbol.Definition,
  capture   : ?*Node.Capture,
) !*Value.Ast {
  return &(try self.value(root.pos, .{.ast = .{
    .root         = root,
    .container    = container,
    .inner_syms   = inner_syms,
    .capture      = capture,
  }})).data.ast;
}

pub inline fn blockHeader(
  self         : *const Self,
  pos          : Position,
  config       : ?model.BlockConfig,
  swallow_depth: ?u21,
) !*Value.BlockHeader {
  return &(try self.value(pos,
    .{.block_header = .{.config = config, .swallow_depth = swallow_depth}}
  )).data.block_header;
}

pub inline fn concat(
  self: *const Self,
  pos : Position,
  t   : *const Type.Concat,
) !*Value.Concat {
  return &(try self.value(pos, .{
    .concat = .{
      .t = t,
      .content = std.ArrayList(*Value).init(self.allocator()),
    },
  })).data.concat;
}

pub inline fn definition(
  self       : *const Self,
  pos        : Position,
  name       : *Value.TextScalar,
  content    : std.meta.fieldInfo(Value.Definition, .content).field_type,
  content_pos: Position,
) !*Value.Definition {
  return &(try self.value(pos, .{.definition = .{
    .name = name, .content = content, .content_pos = content_pos,
  }})).data.definition;
}

pub inline fn @"enum"(
  self : *const Self,
  pos  : Position,
  t    : *const Type.Enum,
  index: usize,
) !*Value.Enum {
  return &(try self.value(
    pos, .{.@"enum" = .{.t = t, .index = index}})).data.@"enum";
}

pub inline fn float(
  self   : *const Self,
  pos    : Position,
  t      : *const Type.FloatNum,
  content: f64,
  unit   : usize,
) !*Value.FloatNum {
  return &(try self.value(
    pos, .{.float = .{.t = t, .content = content, .cur_unit = unit}}
  )).data.float;
}

pub inline fn funcRef(
  self: *const Self,
  pos : Position,
  func: *model.Function,
) !*Value.FuncRef {
  return &(try self.value(
    pos, .{.funcref = .{.func = func}})).data.funcref;
}

pub inline fn int(
  self   : *const Self,
  pos    : Position,
  t      : *const Type.IntNum,
  content: i64,
  unit   : usize,
) !*Value.IntNum {
  return &(try self.value(
    pos, .{.int = .{.t = t, .content = content, .cur_unit = unit}})).data.int;
}

/// Generates an intrinsic location (contained positions are <intrinsic>).
/// The given name must live at least as long as the Context.
pub inline fn intrinsicLoc(
  self: *const Self,
  name: []const u8,
  t: Type,
) !*Value.Location {
  const name_val = try self.textScalar(Position.intrinsic(),
    self.types().literal(), name);
  return self.location(Position.intrinsic(), name_val, t.predef());
}

pub inline fn list(
  self: *const Self,
  pos : Position,
  t   : *const Type.List,
) !*Value.List {
  return &(try self.value(pos, .{
    .list = .{.t = t, .content = std.ArrayList(*Value).init(self.allocator())},
  })).data.list;
}

pub inline fn location(
  self: *const Self,
  pos : Position,
  name: *Value.TextScalar,
  spec: model.SpecType,
) !*Value.Location {
  return &(try self.value(
    pos, .{.location = .{.name = name, .spec = spec}})).data.location;
}

pub inline fn map(
  self: *const Self,
  pos: Position,
  t: *const Type.Map,
) !*Value.Map {
  return &(try self.value(pos, .{
    .map = .{.t = t, .items = Value.Map.Items.init(self.allocator())},
  })).data.map;
}

pub inline fn schemaDef(
  self: *const Self,
  pos : Position,
  defs: []*model.Node.Definition,
  root : *model.Node,
) !*Value.SchemaDef {
  return &(try self.value(pos, .{
    .schema_def = .{
      .defs = defs,
      .root = root,
    },
  })).data.schema_def;
}

pub inline fn schema(
  self   : *const Self,
  pos    : Position,
  root   : model.SpecType,
  symbols: []*model.Symbol,
) !*Value.Schema {
  return &(try self.value(pos, .{
    .schema = .{
      .root    = root,
      .symbols = symbols,
    },
  })).data.schema;
}

pub inline fn seq(
  self: *const Self,
  pos : Position,
  t   : *const Type.Sequence,
) !*Value.Seq {
  return &(try self.value(pos, .{
    .seq = .{
      .t = t, .content = std.ArrayList(Value.Seq.Item).init(self.allocator()),
    },
  })).data.seq;
}

pub inline fn prototype(
  self: *const Self,
  pos : Position,
  pt  : model.Prototype,
) !*Value.PrototypeVal {
  return &(try self.value(
    pos, .{.prototype = .{.pt = pt}})).data.prototype;
}

pub inline fn record(
  self: *const Self,
  pos : Position,
  t   : *const Type.Record,
) !*Value.Record {
  const fields =
    try self.allocator().alloc(*Value, t.constructor.sig.parameters.len);
  errdefer self.allocator().free(fields);
  return &(try self.value(
    pos, .{.record = .{.t = t, .fields = fields}})).data.record;
}

pub inline fn textScalar(
  self: *const Self,
  pos : Position,
  t   : Type,
  content: []const u8,
) !*Value.TextScalar {
  return &(try self.value(
    pos, .{.text = .{.t = t, .content = content}})).data.text;
}

pub inline fn @"type"(
  self: *const Self,
  pos : Position,
  t   : Type,
) !*Value.TypeVal {
  const ctx = @fieldParentPtr(nyarna.Context, "values", self);
  if (try ctx.types().instanceFuncsOf(t)) |instf| {
    try instf.genConstructor(ctx.*);
  }
  return &(try self.value(
    pos, .{.@"type" = .{.t = t}})).data.@"type";
}

pub inline fn @"void"(self: *const Self, pos: Position) !*Value {
  return self.value(pos, .void);
}

pub inline fn poison(self: *const Self, pos: Position) !*Value {
  return self.value(pos, .poison);
}