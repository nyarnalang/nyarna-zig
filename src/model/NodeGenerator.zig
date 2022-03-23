const std = @import("std");

const model = @import("../model.zig");
const nyarna = @import("../nyarna.zig");
const Expression = @import("Expression.zig");
const Node = @import("Node.zig");
const Symbol = @import("Symbol.zig");
const Type = model.Type;
const Value = @import("Value.zig");
const Position = model.Position;

const Self = @This();

allocator: std.mem.Allocator,
types: *nyarna.types.Lattice,

pub fn init(allocator: std.mem.Allocator, types: *nyarna.types.Lattice) Self {
  return .{
    .allocator = allocator,
    .types = types,
  };
}

inline fn create(self: *Self) !*Node {
  return self.allocator.create(Node);
}

pub inline fn node(self: *Self, pos: Position, content: Node.Data) !*Node {
  const ret = try self.create();
  ret.* = .{.pos = pos, .data = content};
  return ret;
}

pub inline fn assign(
  self: *Self,
  pos: Position,
  content: Node.Assign,
) !*Node.Assign {
  return &(try self.node(pos, .{.assign = content})).data.assign;
}

pub inline fn branches(
  self: *Self,
  pos: Position,
  content: Node.Branches,
) !*Node.Branches {
  return &(try self.node(pos, .{.branches = content})).data.branches;
}

pub inline fn builtinGen(
  self: *Self,
  pos: Position,
  params: *Node,
  returns: std.meta.fieldInfo(Node.BuiltinGen, .returns).field_type,
) !*Node.BuiltinGen {
  return &(try self.node(pos, .{.builtingen = .{
    .params = .{.unresolved = params},
    .returns = returns,
  }})).data.builtingen;
}

pub inline fn concat(
  self: *Self,
  pos: Position,
  content: Node.Concat,
) !*Node.Concat {
  return &(try self.node(pos, .{.concat = content})).data.concat;
}

pub inline fn definition(
  self: *Self,
  pos: Position,
  content: Node.Definition,
) !*Node.Definition {
  return &(try self.node(pos, .{.definition = content})).data.definition;
}

pub inline fn expression(
  self: *Self,
  content: *Expression,
) !*Node {
  return self.node(content.pos, .{.expression = content});
}

pub inline fn funcgen(
  self: *Self,
  pos: Position,
  returns: ?*Node,
  params: *Node,
  params_ns: u15,
  body: *Node,
  variables: *model.VariableContainer,
  inject_this: bool,
) !*Node.Funcgen {
  return &(try self.node(pos, .{.funcgen = .{
    .returns = returns, .params = .{.unresolved = params},
    .params_ns = params_ns, .body = body, .needs_this_inject = inject_this,
    .variables = variables, .cur_returns = self.types.every(),
  }})).data.funcgen;
}

pub inline fn import(
  self: *Self,
  pos: Position,
  ns_index: u15,
  module_index: usize,
) !*Node.Import {
  return &(try self.node(
    pos, .{.import = .{
      .ns_index = ns_index, .module_index = module_index,
    }})).data.import;
}

pub inline fn literal(
  self: *Self,
  pos: Position,
  content: Node.Literal,
) !*Node.Literal {
  return &(try self.node(pos, .{.literal = content})).data.literal;
}

pub inline fn location(
  self: *Self,
  pos: Position,
  name: *Node.Literal,
  @"type": ?*Node,
  default: ?*Node,
  additionals: ?*Node.Location.Additionals,
) !*Node.Location {
  std.debug.assert(@"type" != null or default != null);
  return &(try self.node(pos, .{.location = .{
    .name = name, .@"type" = @"type", .default = default,
    .additionals = additionals,
  }})).data.location;
}

pub fn locationFromValue(
  self: *Self,
  ctx: nyarna.Context,
  value: *Value.Location,
) !*Node.Location {
  const loc_node = try self.location(value.value().origin, .{
    .name = try self.literal(
      value.name.value().origin, .{
        .kind = .text, .content = value.name.content,
      }),
    .@"type" = try self.expression(
      try ctx.createValueExpr(value.value().origin, .{
        .@"type" = .{.t = value.tloc},
      })),
    .default = if (value.default) |d|
      try self.expression(d)
    else null,
    .additionals = null
  });
  if (
    value.primary != null or value.varargs != null or value.varmap != null or
    value.mutable != null or value.header != null
  ) {
    const add = try self.allocator.create(Node.Location.Additionals);
    inline for ([_][]const u8{
        "primary", "varargs", "varmap", "mutable", "header"}) |field|
      @field(add, field) = @field(value, field);
    loc_node.additionals = add;
  }
  return loc_node;
}

pub inline fn paras(
  self: *Self,
  pos: Position,
  content: Node.Paras,
) !*Node.Paras {
  return &(try self.node(pos, .{.paras = content})).data.paras;
}

pub inline fn raccess(
  self: *Self,
  pos: Position,
  base: *Node,
  path: []const usize,
  last_name_pos: Position,
  ns: u15,
) !*Node.ResolvedAccess {
  return &(try self.node(pos, .{.resolved_access = .{
    .base = base,
    .path = path,
    .last_name_pos = last_name_pos,
    .ns = ns,
  }})).data.resolved_access;
}

pub inline fn rcall(
  self: *Self,
  pos: Position,
  content: Node.ResolvedCall,
) !*Node.ResolvedCall {
  return &(try self.node(
    pos, .{.resolved_call = content})).data.resolved_call;
}

pub inline fn rsymref(
  self: *Self,
  pos: Position,
  content: Node.ResolvedSymref,
) !*Node.ResolvedSymref {
  return &(try self.node(
    pos, .{.resolved_symref = content})).data.resolved_symref;
}

pub inline fn tgConcat(
  self: *Self,
  pos: Position,
  inner: *Node,
) !*Node.tg.Concat {
  return &(try self.node(
    pos, .{.gen_concat = .{.inner = inner}})).data.gen_concat;
}

pub inline fn tgEnum(
  self: *Self,
  pos: Position,
  values: []Node.Varargs.Item,
) !*Node.tg.Enum {
  return &(try self.node(
    pos, .{.gen_enum = .{.values = values}})).data.gen_enum;
}

pub inline fn tgFloat(
  self: *Self,
  pos: Position,
  precision: *Node,
) !*Node.tg.Float {
  return &(try self.node(
    pos, .{.gen_float = .{.precision = precision}})).data.gen_float;
}

pub inline fn tgIntersection(
  self: *Self,
  pos: Position,
  types: []Node.Varargs.Item
) !*Node.tg.Intersection {
  return &(try self.node(
    pos, .{.gen_intersection = .{.types = types}})).data.gen_intersection;
}

pub inline fn tgList(
  self: *Self,
  pos: Position,
  inner: *Node,
) !*Node.tg.List {
  return &(try self.node(
    pos, .{.gen_list = .{.inner = inner}})).data.gen_list;
}

pub inline fn tgMap(
  self: *Self,
  pos: Position,
  key: *Node,
  value: *Node,
) !*Node.tg.Map {
  return &(try self.node(
    pos, .{.gen_map = .{.key = key, .value = value}})).data.gen_map;
}

pub inline fn tgNumeric(
  self: *Self,
  pos: Position,
  min: ?*Node, max: ?*Node,
  decimals: ?*Node,
) !*Node.tg.Numeric {
  return &(try self.node(
    pos, .{.gen_numeric = .{
      .min = min,
      .max = max,
      .decimals = decimals,
    }},
  )).data.gen_numeric;
}

pub inline fn tgOptional(
  self: *Self,
  pos: Position,
  inner: *Node,
) !*Node.tg.Optional {
  return &(try self.node(
    pos, .{.gen_optional = .{.inner = inner}})).data.gen_optional;
}

pub inline fn tgParagraphs(
  self: *Self,
  pos: Position,
  inners: []Node.Varargs.Item,
  auto: ?*Node,
) !*Node.tg.Paragraphs {
  return &(try self.node(
    pos, .{.gen_paragraphs = .{.inners = inners, .auto = auto}}
  )).data.gen_paragraphs;
}

pub inline fn tgPrototype(
  self: *Self,
  pos: Position,
  params: *Node,
  funcs: ?*Node,
) !*Node.tg.Prototype {
  return &(try self.node(
    pos, .{.gen_prototype = .{
      .params = .{.unresolved = params},
      .funcs = funcs,
    }}
  )).data.gen_prototype;
}

pub inline fn tgRecord(
  self: *Self,
  pos: Position,
  fields: *Node,
) !*Node.tg.Record {
  return &(try self.node(pos, .{.gen_record = .{
    .fields = .{.unresolved = fields},
  }})).data.gen_record;
}

pub inline fn tgTextual(
  self: *Self,
  pos: Position,
  categories: []*Node,
  include_chars: *Node,
  exclude_chars: *Node,
) !*Node.tg.Textual {
  return &(try self.node(
    pos, .{.gen_textual = .{
      .categories = categories,
      .include_chars = include_chars,
      .exclude_chars = exclude_chars,
    }})).data.gen_textual;
}

pub inline fn tgUnique(
  self: *Self,
  pos: Position,
  params: ?*Node,
) !*Node.tg.Unique {
  return &(try self.node(
    pos, .{.gen_unique = .{.constr_params = params}})).data.gen_unique;
}

pub inline fn uAccess(
  self: *Self,
  pos: Position,
  content: Node.UnresolvedAccess,
) !*Node.UnresolvedAccess {
  return &(try self.node(
    pos, .{.unresolved_access = content})).data.unresolved_access;
}

pub inline fn uCall(
  self: *Self,
  pos: Position,
  content: Node.UnresolvedCall,
) !*Node.UnresolvedCall {
  return &(try self.node(
    pos, .{.unresolved_call = content})).data.unresolved_call;
}

pub inline fn uSymref(
  self: *Self,
  pos: Position,
  content: Node.UnresolvedSymref,
) !*Node.UnresolvedSymref {
  return &(try self.node(
    pos, .{.unresolved_symref = content})).data.unresolved_symref;
}

pub inline fn varargs(self: *Self, pos: Position, t: Type) !*Node.Varargs {
  return &(try self.node(
    pos, .{.varargs = .{.t = t}})).data.varargs;
}

pub inline fn vtSetter(self: *Self, v: *Symbol.Variable, n: *Node) !*Node {
  return try self.node(n.pos, .{.vt_setter = .{
    .v = v, .content = n,
  }});
}

pub inline fn poison(self: *Self, pos: Position) !*Node {
  return self.node(pos, .poison);
}

pub inline fn @"void"(self: *Self, pos: Position) !*Node {
  return self.node(pos, .void);
}