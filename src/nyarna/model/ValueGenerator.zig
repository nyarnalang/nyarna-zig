const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model    = nyarna.model;
const Node     = model.Node;
const Type     = model.Type;
const Value    = model.Value;
const Position = model.Position;

const Self = @This();

dummy: u8 = 0, // needed for @fieldParentPtr to work

fn allocator(self: *const Self) std.mem.Allocator {
  return @fieldParentPtr(nyarna.Context, "values", self).global();
}

fn types(self: *const Self) *nyarna.Types {
  return @fieldParentPtr(nyarna.Context, "values", self).types();
}

fn create(self: *const Self) !*Value {
  return self.allocator().create(Value);
}

pub fn ast(
  self      : *const Self,
  root      : *Node,
  container : ?*model.VariableContainer,
  inner_syms: []model.Symbol.Definition,
  capture   : []model.Value.Ast.VarDef,
) !*Value.Ast {
  return &(try self.value(root.pos, .{.ast = .{
    .root         = root,
    .container    = container,
    .inner_syms   = inner_syms,
    .capture      = capture,
  }})).data.ast;
}

pub fn blockHeader(
  self         : *const Self,
  pos          : Position,
  config       : ?model.BlockConfig,
  swallow_depth: ?u21,
) !*Value.BlockHeader {
  return &(try self.value(pos,
    .{.block_header = .{.config = config, .swallow_depth = swallow_depth}}
  )).data.block_header;
}

pub fn concat(
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

pub fn definition(
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

pub fn @"enum"(
  self : *const Self,
  pos  : Position,
  t    : *const Type.Enum,
  index: usize,
) !*Value.Enum {
  return &(try self.value(
    pos, .{.@"enum" = .{.t = t, .index = index}})).data.@"enum";
}

pub fn float(
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

pub fn funcRef(
  self: *const Self,
  pos : Position,
  func: *model.Function,
) !*Value.FuncRef {
  return &(try self.value(
    pos, .{.funcref = .{.func = func}})).data.funcref;
}

pub fn hashMap(
  self: *const Self,
  pos : Position,
  t   : *const Type.HashMap,
) !*Value.HashMap {
  return &(try self.value(pos, .{
    .hashmap = .{.t = t, .items = Value.HashMap.Items.init(self.allocator())},
  })).data.hashmap;
}

pub fn int(
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
pub fn intrinsicLoc(
  self: *const Self,
  name: []const u8,
  t: Type,
) !*Value.Location {
  const name_val = try self.textScalar(Position.intrinsic(),
    self.types().literal(), name);
  return self.location(Position.intrinsic(), name_val, t.predef());
}

pub fn list(
  self: *const Self,
  pos : Position,
  t   : *const Type.List,
) !*Value.List {
  return &(try self.value(pos, .{
    .list = .{.t = t, .content = std.ArrayList(*Value).init(self.allocator())},
  })).data.list;
}

pub fn location(
  self: *const Self,
  pos : Position,
  name: *Value.TextScalar,
  spec: model.SpecType,
) !*Value.Location {
  return &(try self.value(
    pos, .{.location = .{.name = name, .spec = spec}})).data.location;
}

pub fn output(
  self  : *const Self,
  pos   : Position,
  name  : *Value.TextScalar,
  sch   : ?*Value.Schema,
  body  : *Value,
) !*Value.Output {
  return &(try self.value(pos, .{
    .output = .{
      .name   = name,
      .schema = sch,
      .body   = body,
    }
  })).data.output;
}

pub fn poison(self: *const Self, pos: Position) !*Value {
  return self.value(pos, .poison);
}

pub fn prototype(
  self: *const Self,
  pos : Position,
  pt  : model.Prototype,
) !*Value.PrototypeVal {
  return &(try self.value(
    pos, .{.prototype = .{.pt = pt}})).data.prototype;
}

pub fn record(
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

pub fn schema(
  self   : *const Self,
  pos    : Position,
  root   : model.SpecType,
  symbols: []*model.Symbol,
  backend: ?*model.Function,
) !*Value.Schema {
  return &(try self.value(pos, .{
    .schema = .{
      .root    = root,
      .symbols = symbols,
      .backend = backend,
    },
  })).data.schema;
}

pub fn schemaDef(
  self    : *const Self,
  pos     : Position,
  defs    : []*Node.Definition,
  root    : *Node,
  backends: []*Node.Definition,
  doc_var : ?Value.Ast.VarDef,
) !*Value.SchemaDef {
  return &(try self.value(pos, .{
    .schema_def = .{
      .defs     = defs,
      .root     = root,
      .backends = backends,
      .doc_var  = doc_var,
    },
  })).data.schema_def;
}

pub fn schemaExt(
  self    : *const Self,
  pos     : Position,
  defs    : []*Node.Definition,
  backends: []*Node.Definition,
  doc_var : ?Value.Ast.VarDef,
) !*Value.SchemaExt {
  return &(try self.value(pos, .{
    .schema_ext = .{
      .defs     = defs,
      .backends = backends,
      .doc_var  = doc_var,
    },
  })).data.schema_ext;
}

pub fn seq(
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

pub fn textScalar(
  self: *const Self,
  pos : Position,
  t   : Type,
  content: []const u8,
) !*Value.TextScalar {
  return &(try self.value(
    pos, .{.text = .{.t = t, .content = content}})).data.text;
}

pub fn @"type"(
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

pub fn value(
  self: *const Self,
  pos : Position,
  data: Value.Data,
) !*Value {
  const ret = try self.create();
  ret.* = .{.origin = pos, .data = data};
  return ret;
}

pub fn @"void"(self: *const Self, pos: Position) !*Value {
  return self.value(pos, .void);
}