const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model      = nyarna.model;
const Expression = model.Expression;
const Node       = model.Node;
const Position   = model.Position;
const Symbol     = model.Symbol;
const Type       = model.Type;
const Value      = model.Value;

const Self = @This();

allocator: std.mem.Allocator,
ctx      : nyarna.Context,

pub fn init(allocator: std.mem.Allocator, ctx: nyarna.Context) Self {
  return .{
    .allocator = allocator,
    .ctx       = ctx,
  };
}

fn create(self: Self) !*Node {
  return self.allocator.create(Node);
}

pub fn newNode(self: Self, pos: Position, content: Node.Data) !*Node {
  const ret = try self.create();
  ret.* = .{.pos = pos, .data = content};
  return ret;
}

fn copyVarDefs(self: Self, defs: []Value.Ast.VarDef) ![]Value.Ast.VarDef {
  const ret = try self.allocator.alloc(Value.Ast.VarDef, defs.len);
  // no need to copy name, it's allocated in global storage.
  for (defs) |def, i| ret[i] = def;
  return ret;
}

fn copyArr(
           self: Self,
  comptime T   : type,
  comptime fld : []const u8,
           arr : []*T,
) ![]*T {
  const items = try self.allocator.alloc(*T, arr.len);
  for (arr) |item, index| {
    items[index] = &@field((try self.copy(item.node())).data, fld);
  }
  return items;
}

fn copyPath(
  self: Self,
  path: []const Node.Assign.PathItem,
) ![]Node.Assign.PathItem {
  const items = try self.allocator.alloc(Node.Assign.PathItem, path.len);
  for (path) |item, i| switch (item) {
    .field     => |index| items[i] = .{.field = index},
    .subscript => |node|  items[i] = .{.subscript = try self.copy(node)},
  };
  return items;
}

pub fn copy(self: Self, node: *Node) std.mem.Allocator.Error!*Node {
  return switch (node.data) {
    .assign => |*ass| (
      try self.assign(node.pos, .{
        .target = switch (ass.target) {
          .unresolved => |unres| .{.unresolved = try self.copy(unres)},
          .resolved => |res| .{.resolved = .{
            .target = res.target,
            .path   = try self.copyPath(res.path),
            .spec   = res.spec,
            .pos    = res.pos,
          }},
        },
        .replacement = try self.copy(ass.replacement),
      })
    ).node(),
    .backend => |*ba| (
      try self.backend(node.pos,
      if (ba.vars) |vars| try self.copy(vars) else null,
        try self.copyArr(Node.Definition, "definition", ba.funcs),
        if (ba.body) |body| (
          try self.ctx.values.ast(
            try self.copy(body.root), body.container, &.{}, &.{})
        ) else null,
      )
    ).node(),
    .branches => |*br| (
      try self.branches(node.pos, .{
        .condition = try self.copy(br.condition),
        .cond_type = br.cond_type,
        .branches  = blk: {
          const arr = try self.allocator.alloc(*Node, br.branches.len);
          for (br.branches) |b, i| arr[i] = try self.copy(b);
          break :blk arr;
        },
      })
    ).node(),
    .builtingen => |*bg| (
      try self.builtinGen(
        node.pos, try self.copy(bg.params.unresolved), switch (bg.returns) {
          .node => |n| .{.node = try self.copy(n)},
          .expr => |e| .{.expr = e},
        })
    ).node(),
    .capture => |*cap| (
      try self.capture(
        node.pos, try self.copyVarDefs(cap.vars),
        try self.copy(cap.content))
    ).node(),
    .concat => |*con| {
      const items = try self.allocator.alloc(*Node, con.items.len);
      for (con.items) |item, index| items[index] = try self.copy(item);
      return (try self.concat(node.pos, .{.items = items})).node();
    },
    .definition => |*def| (
      try self.definition(node.pos, .{
        .name    = &(try self.copy(def.name.node())).data.literal,
        .content = try self.copy(def.content),
        .public  = def.public,
        .merge   = def.merge,
      })
    ).node(),
    .expression => |expr| blk: {
      switch (expr.data) {
        .value => |value| switch (value.data) {
          .ast => |*ast| {
            const syms = try self.allocator.alloc(
              model.Symbol.Definition, ast.inner_syms.len);
            for (ast.inner_syms) |sym, index| syms[index] = sym;
            const cap = try self.copyVarDefs(ast.capture);
            const copied_ast = try self.ctx.values.ast(
              try self.copy(ast.root), ast.container, syms, cap);
            const cexpr = try self.ctx.createValueExpr(copied_ast.value());
            break :blk try self.expression(cexpr);
          },
          else => {},
        },
        else => {}
      }
      break :blk try self.expression(expr);
    },
    .root_def   => unreachable, // never copied
    .@"for"     => |*f| (
      try self.@"for"(node.pos, try self.copy(f.input),
        if (f.collector) |collector| try self.copy(collector) else null,
        try self.copy(f.body),
        try self.copyVarDefs(f.captures),
        f.variables,
      )
    ).node(),
    .funcgen    => |*fg| (
      try self.funcgen(node.pos,
        if (fg.returns) |returns| try self.copy(returns) else null,
        try self.copy(fg.params.unresolved), fg.params_ns,
        try self.copy(fg.body), fg.variables)
    ).node(),
    .import  => unreachable, // not allowed inside of schemadef /extensiondef
    .literal => |*lit| (
      try self.literal(node.pos, .{
        .kind = lit.kind, .content = try self.allocator.dupe(u8, lit.content),
      })
    ).node(),
    .location => |*loc| {
      const additionals = if (loc.additionals) |src| blk: {
        const val = try self.allocator.create(Node.Location.Additionals);
        val.* = .{
          .primary = src.primary,
          .varargs = src.varargs,
          .varmap  = src.varmap,
          .borrow  = src.borrow,
          .header  = src.header,
        };
        break :blk val;
      } else null;

      return (
        try self.location(node.pos, try self.copy(loc.name),
          if (loc.@"type") |t| try self.copy(t) else null,
          if (loc.default) |d| try self.copy(d) else null, additionals)
      ).node();
    },
    .map => |*mn| return (
      try self.map(node.pos, try self.copy(mn.input),
        if (mn.func) |func| try self.copy(func) else null,
        if (mn.collector) |coll| try self.copy(coll) else null)
    ).node(),
    .match => |*mat| {
      const cases = try self.allocator.alloc(Node.Match.Case, mat.cases.len);
      for (mat.cases) |case, index| {
        const inner_syms = try self.allocator.alloc(
          model.Symbol.Definition, case.content.inner_syms.len);
        for (case.content.inner_syms) |def, inner_index| {
          inner_syms[inner_index] = .{
            .ns    = def.ns,
            .sym   = def.sym,
            .alive = def.alive,
          };
        }
        const cpt = try self.copyVarDefs(case.content.capture);
        switch (case.variable) {
          .def => |def| {
            cases[index] = .{
              .t       = try self.copy(case.t),
              .content = try self.ctx.values.ast(
                try self.copy(case.content.root), case.content.container,
                inner_syms, cpt),
              .variable = .{.def = Value.Ast.VarDef{
                .ns   = def.ns,
                .name = try self.allocator.dupe(u8, def.name),
                .pos  = def.pos,
              }},
            };
          },
          .sym => |sym| {
            cases[index] = .{
              .t       = try self.copy(case.t),
              .content = try self.ctx.values.ast(
                try self.copy(case.content.root), case.content.container,
                inner_syms, cpt),
              .variable = .{.sym = sym},
            };
          },
          .none => {
            cases[index] = .{
              .t       = try self.copy(case.t),
              .content = try self.ctx.values.ast(
                try self.copy(case.content.root), case.content.container,
                inner_syms, cpt),
              .variable = .none,
            };
          },
        }
      }
      return (
        try self.match(node.pos, try self.copy(mat.subject), cases)
      ).node();
    },
    .matcher => |*mtr| (
      try self.matcher(node.pos, &(try self.copy(mtr.body.node())).data.match,
        mtr.container, mtr.variable)
    ).node(),
    .output => |*out| (
      try self.output(node.pos, try self.copy(out.name),
        if (out.schema) |schema| try self.copy(schema) else null,
        try self.copy(out.body))
    ).node(),
    .resolved_access => |*ra| (
      try self.raccess(node.pos, try self.copy(ra.base),
        try self.copyPath(ra.path), ra.last_name_pos, ra.ns)
    ).node(),
    .resolved_call => |*rc| {
      const args = try self.allocator.alloc(*Node, rc.args.len);
      for (rc.args) |arg, index|  args[index] = try self.copy(arg);
      return (
        try self.rcall(node.pos, .{
          .target = try self.copy(rc.target),
          .args   = args,
          .sig    = rc.sig,
          .ns     = rc.ns,
        })
      ).node();
    },
    .resolved_symref => |*rs| (
      try self.rsymref(node.pos, .{
        .ns       = rs.ns,
        .sym      = rs.sym,
        .name_pos = rs.name_pos,
      })
    ).node(),
    .seq => |*s| {
      var items = try self.allocator.alloc(Node.Seq.Item, s.items.len);
      for (s.items) |item, index| items[index] = .{
        .content  = try self.copy(item.content),
        .lf_after = item.lf_after,
      };
      return (try self.seq(node.pos, .{.items = items})).node();
    },
    .unresolved_access => |*ua| (
      try self.uAccess(node.pos, .{
        .subject = try self.copy(ua.subject),
        .id      = try self.allocator.dupe(u8, ua.id),
        .id_pos  = ua.id_pos,
        .ns      = ua.ns,
      })
    ).node(),
    .unresolved_call => |*uc| {
      const proto_args = try self.allocator.alloc(
        Node.UnresolvedCall.ProtoArg, uc.proto_args.len);
      for (uc.proto_args) |arg, index| {
        proto_args[index] = .{
          .kind = switch (arg.kind) {
            .named     => |name| .{.named  = try self.allocator.dupe(u8, name)},
            .direct    => |name| .{.direct = try self.allocator.dupe(u8, name)},
            .name_expr => |nexpr| .{.name_expr = try self.copy(nexpr)},
            .primary   => .primary,
            .position  => .position,
          },
          .content = try self.copy(arg.content),
          .had_explicit_block_config = arg.had_explicit_block_config,
        };
      }
      return (
        try self.uCall(node.pos, .{
          .target = try self.copy(uc.target),
          .proto_args = proto_args,
          .first_block_arg = uc.first_block_arg,
        })
      ).node();
    },
    .unresolved_symref => |*us| (
      try self.uSymref(node.pos, .{
        .ns         = us.ns,
        .name       = try self.allocator.dupe(u8, us.name),
        .nschar_len = us.nschar_len,
      })
    ).node(),
    .varargs => |*va| {
      const ret = try self.varargs(node.pos, va.spec_pos, va.t);
      try ret.content.ensureTotalCapacityPrecise(
        self.allocator, va.content.items.len);
      for (va.content.items) |item| {
        ret.content.appendAssumeCapacity(.{
          .direct = item.direct,
          .node   = try self.copy(item.node),
        });
      }
      return ret.node();
    },
    .varmap => |*vm| {
      var ret = try self.varmap(node.pos, vm.spec_pos, vm.t);
      try ret.content.ensureTotalCapacityPrecise(
        self.allocator, vm.content.items.len);
      for (vm.content.items) |item| {
        ret.content.appendAssumeCapacity(.{
          .key = switch (item.key) {
            .node   => |n| .{.node = try self.copy(n)},
            .direct => .direct,
          },
          .value = try self.copy(item.value),
        });
      }
      return ret.node();
    },
    .vt_setter => |*vts| try self.vtSetter(vts.v, try self.copy(vts.content)),
    .gen_concat => |*tgc| (
      try self.tgConcat(node.pos, try self.copy(tgc.inner))
    ).node(),
    .gen_enum => |*tge| {
      var values = try self.allocator.alloc(Node.Varargs.Item, tge.values.len);
      for (tge.values) |val, index| {
        values[index] = .{
          .direct = val.direct,
          .node   = try self.copy(val.node),
        };
      }
      return (try self.tgEnum(node.pos, values)).node();
    },
    .gen_intersection => |*tgi| {
      var types = try self.allocator.alloc(Node.Varargs.Item, tgi.types.len);
      for (tgi.types) |t, i| {
        types[i] = .{
          .direct = t.direct,
          .node   = try self.copy(t.node),
        };
      }
      return (try self.tgIntersection(node.pos, types)).node();
    },
    .gen_list => |*tgl| (
      try self.tgList(node.pos, try self.copy(tgl.inner))
    ).node(),
    .gen_map => |*tgm| (
      try self.tgHashMap(
        node.pos, try self.copy(tgm.key), try self.copy(tgm.value))
    ).node(),
    .gen_numeric => |*tgn| (
      try self.tgNumeric(node.pos, try self.copy(tgn.backend),
        if (tgn.min) |min| try self.copy(min) else null,
        if (tgn.max) |max| try self.copy(max) else null, tgn.suffixes)
    ).node(),
    .gen_optional => |*tgo| (
      try self.tgOptional(node.pos, try self.copy(tgo.inner))
    ).node(),
    .gen_sequence => |*tgs| {
      var inner = try self.allocator.alloc(Node.Varargs.Item, tgs.inner.len);
      for (tgs.inner) |item, index| {
        inner[index] = .{
          .direct = item.direct,
          .node   = try self.copy(item.node),
        };
      }
      return (
        try self.tgSequence(node.pos,
          if (tgs.direct) |d|    try self.copy(d) else null, inner,
          if (tgs.auto)   |auto| try self.copy(auto) else null)
      ).node();
    },
    .gen_prototype => unreachable, // occurs only in system.ny
    .gen_record => |*tgr| {
      var embed = try self.allocator.alloc(Node.Varargs.Item, tgr.embed.len);
      for (tgr.embed) |item, index| {
        embed[index] = .{
          .direct = item.direct,
          .node   = try self.copy(item.node),
        };
      }
      return (
        try self.tgRecord(
          node.pos, embed,
          if (tgr.abstract) |anode| try self.copy(anode) else null,
          try self.copy(tgr.fields.unresolved))
      ).node();
    },
    .gen_textual => |*tgt| {
      var categories = try self.allocator.alloc(
        Node.Varargs.Item, tgt.categories.len);
      for (tgt.categories) |cat, index| {
        categories[index] = .{
          .direct = cat.direct,
          .node   = try self.copy(cat.node),
        };
      }
      return (
        try self.tgTextual(node.pos, categories,
          if (tgt.include_chars) |ic| try self.copy(ic) else null,
          if (tgt.exclude_chars) |ec| try self.copy(ec) else null)
      ).node();
    },
    .gen_unique => unreachable, // occurs only in system.ny
    .void      => try self.@"void"(node.pos),
    .poison    => try self.poison(node.pos),
  };
}

pub fn assign(
  self   : Self,
  pos    : Position,
  content: Node.Assign,
) !*Node.Assign {
  return &(try self.newNode(pos, .{.assign = content})).data.assign;
}

pub fn backend(
  self : Self,
  pos  : Position,
  vars : ?*model.Node,
  funcs: []*model.Node.Definition,
  body : ?*model.Value.Ast,
) !*Node.Backend {
  return &(try self.newNode(pos, .{.backend = .{
    .vars = vars, .funcs = funcs, .body = body,
  }})).data.backend;
}

pub fn branches(
  self   : Self,
  pos    : Position,
  content: Node.Branches,
) !*Node.Branches {
  return &(try self.newNode(pos, .{.branches = content})).data.branches;
}

pub fn builtinGen(
  self   : Self,
  pos    : Position,
  params : *Node,
  returns: std.meta.fieldInfo(Node.BuiltinGen, .returns).field_type,
) !*Node.BuiltinGen {
  return &(try self.newNode(pos, .{.builtingen = .{
    .params  = .{.unresolved = params},
    .returns = returns,
  }})).data.builtingen;
}

pub fn capture(
  self   : Self,
  pos    : Position,
  vars   : []model.Value.Ast.VarDef,
  content: *Node,
) !*Node.Capture {
  return &(try self.newNode(pos, .{.capture = .{
    .vars = vars, .content = content,
  }})).data.capture;
}

pub fn concat(
  self   : Self,
  pos    : Position,
  content: Node.Concat,
) !*Node.Concat {
  return &(try self.newNode(pos, .{.concat = content})).data.concat;
}

pub fn definition(
  self   : Self,
  pos    : Position,
  content: Node.Definition,
) !*Node.Definition {
  return &(try self.newNode(pos, .{.definition = content})).data.definition;
}

pub fn expression(
  self   : Self,
  content: *Expression,
) !*Node {
  return self.newNode(content.pos, .{.expression = content});
}

pub fn @"for"(
  self     : Self,
  pos      : Position,
  input    : *Node,
  collector: ?*Node,
  body     : *Node,
  captures : []Value.Ast.VarDef,
  variables: *model.VariableContainer,
) !*Node.For {
  return &(try self.newNode(pos, .{.@"for" = .{
    .input     = input,
    .collector = collector,
    .body      = body,
    .captures  = captures,
    .variables = variables,
  }})).data.@"for";
}

pub fn funcgen(
  self     : Self,
  pos      : Position,
  returns  : ?*Node,
  params   : *Node,
  params_ns: u15,
  body     : *Node,
  variables: *model.VariableContainer,
) !*Node.Funcgen {
  return &(try self.newNode(pos, .{.funcgen = .{
    .returns   = returns, .params = .{.unresolved = params},
    .params_ns = params_ns, .body = body,
    .variables = variables, .cur_returns = self.ctx.types().every(),
  }})).data.funcgen;
}

pub fn import(
  self        : Self,
  pos         : Position,
  ns_index    : u15,
  module_index: usize,
) !*Node.Import {
  return &(try self.newNode(
    pos, .{.import = .{
      .ns_index = ns_index, .module_index = module_index,
    }})).data.import;
}

pub fn literal(
  self   : Self,
  pos    : Position,
  content: Node.Literal,
) !*Node.Literal {
  return &(try self.newNode(pos, .{.literal = content})).data.literal;
}

pub fn location(
  self       : Self,
  pos        : Position,
  name       : *Node,
  @"type"    : ?*Node,
  default    : ?*Node,
  additionals: ?*Node.Location.Additionals,
) !*Node.Location {
  std.debug.assert(@"type" != null or default != null);
  return &(try self.newNode(pos, .{.location = .{
    .name        = name,
    .@"type"     = @"type",
    .default     = default,
    .additionals = additionals,
  }})).data.location;
}

pub fn locationFromValue(
  self : Self,
  ctx  : nyarna.Context,
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
    value.borrow != null or value.header != null
  ) {
    const add = try self.allocator.create(Node.Location.Additionals);
    inline for ([_][]const u8{
        "primary", "varargs", "varmap", "borrow", "header"}) |field|
      @field(add, field) = @field(value, field);
    loc_node.additionals = add;
  }
  return loc_node;
}

pub fn map(
  self     : Self,
  pos      : Position,
  input    : *Node,
  func     : ?*Node,
  collector: ?*Node,
) !*Node.Map {
  return &(try self.newNode(pos, .{.map = .{
    .input = input, .func = func, .collector = collector,
  }})).data.map;
}

pub fn match(
  self   : Self,
  pos    : Position,
  subject: *Node,
  cases  : []Node.Match.Case,
) !*Node.Match {
  return &(try self.newNode(pos, .{.match = .{
    .subject = subject,
    .cases   = cases,
  }})).data.match;
}

pub fn matcher(
  self     : Self,
  pos      : Position,
  body     : *Node.Match,
  container: *model.VariableContainer,
  variable : *Symbol.Variable,
) !*Node.Matcher {
  return &(try self.newNode(pos, .{.matcher = .{
    .body        = body,
    .container   = container,
    .variable    = variable,
    .cur_returns = self.ctx.types().every(),
  }})).data.matcher;
}

pub fn output(
  self  : Self,
  pos   : Position,
  name  : *Node,
  schema: ?*Node,
  body  : *Node,
) !*Node.Output {
  return &(try self.newNode(pos, .{.output = .{
    .name = name, .schema = schema, .body = body,
  }})).data.output;
}

pub fn raccess(
  self         : Self,
  pos          : Position,
  base         : *Node,
  path         : []const Node.Assign.PathItem,
  last_name_pos: Position,
  ns: u15,
) !*Node.ResolvedAccess {
  return &(try self.newNode(pos, .{.resolved_access = .{
    .base           = base,
    .path           = path,
    .last_name_pos  = last_name_pos,
    .ns             = ns,
  }})).data.resolved_access;
}

pub fn rcall(
  self   : Self,
  pos    : Position,
  content: Node.ResolvedCall,
) !*Node.ResolvedCall {
  return &(try self.newNode(
    pos, .{.resolved_call = content})).data.resolved_call;
}

pub fn rsymref(
  self   : Self,
  pos    : Position,
  content: Node.ResolvedSymref,
) !*Node.ResolvedSymref {
  return &(try self.newNode(
    pos, .{.resolved_symref = content})).data.resolved_symref;
}

pub fn rootDef(
  self  : Self,
  pos   : Position,
  kind  : std.meta.fieldInfo(Node.RootDef, .kind).field_type,
  root  : ?*Node,
  params: ?*Node,
) !*Node.RootDef {
  return &(try self.newNode(
    pos, .{.root_def = .{
      .kind   = kind,
      .root   = root,
      .params = params,
    }}
  )).data.root_def;
}

pub fn seq(
  self   : Self,
  pos    : Position,
  content: Node.Seq,
) !*Node.Seq {
  return &(try self.newNode(pos, .{.seq = content})).data.seq;
}

pub fn tgConcat(
  self : Self,
  pos  : Position,
  inner: *Node,
) !*Node.tg.Concat {
  return &(try self.newNode(
    pos, .{.gen_concat = .{.inner = inner}})).data.gen_concat;
}

pub fn tgEnum(
  self  : Self,
  pos   : Position,
  values: []Node.Varargs.Item,
) !*Node.tg.Enum {
  return &(try self.newNode(
    pos, .{.gen_enum = .{.values = values}})).data.gen_enum;
}

pub fn tgHashMap(
  self : Self,
  pos  : Position,
  key  : *Node,
  value: *Node,
) !*Node.tg.HashMap {
  return &(try self.newNode(
    pos, .{.gen_map = .{.key = key, .value = value}})).data.gen_map;
}

pub fn tgIntersection(
  self : Self,
  pos  : Position,
  types: []Node.Varargs.Item
) !*Node.tg.Intersection {
  return &(try self.newNode(
    pos, .{.gen_intersection = .{.types = types}})).data.gen_intersection;
}

pub fn tgList(
  self : Self,
  pos  : Position,
  inner: *Node,
) !*Node.tg.List {
  return &(try self.newNode(
    pos, .{.gen_list = .{.inner = inner}})).data.gen_list;
}

pub fn tgNumeric(
  self    : Self,
  pos     : Position,
  nbackend: *Node,
  min     : ?*Node,
  max     : ?*Node,
  suffixes: *Value.HashMap,
) !*Node.tg.Numeric {
  return &(try self.newNode(
    pos, .{.gen_numeric = .{
      .backend  = nbackend,
      .min      = min,
      .max      = max,
      .suffixes = suffixes,
    }},
  )).data.gen_numeric;
}

pub fn tgOptional(
  self : Self,
  pos  : Position,
  inner: *Node,
) !*Node.tg.Optional {
  return &(try self.newNode(
    pos, .{.gen_optional = .{.inner = inner}})).data.gen_optional;
}

pub fn tgSequence(
  self  : Self,
  pos   : Position,
  direct: ?*Node,
  inner : []Node.Varargs.Item,
  auto  : ?*Node,
) !*Node.tg.Sequence {
  return &(try self.newNode(
    pos, .{.gen_sequence = .{
      .direct = direct,.inner = inner, .auto = auto,
    }},
  )).data.gen_sequence;
}

pub fn tgPrototype(
  self       : Self,
  pos        : Position,
  params     : *Node,
  constructor: ?*Node,
  funcs      : ?*Node,
) !*Node.tg.Prototype {
  return &(try self.newNode(
    pos, .{.gen_prototype = .{
      .params      = .{.unresolved = params},
      .constructor = constructor,
      .funcs       = funcs,
    }}
  )).data.gen_prototype;
}

pub fn tgRecord(
  self    : Self,
  pos     : Position,
  embed   : []Node.Varargs.Item,
  abstract: ?*Node,
  fields  : *Node,
) !*Node.tg.Record {
  return &(try self.newNode(pos, .{.gen_record = .{
    .embed    = embed,
    .abstract = abstract,
    .fields   = .{.unresolved = fields},
  }})).data.gen_record;
}

pub fn tgTextual(
  self         : Self,
  pos          : Position,
  categories   : []Node.Varargs.Item,
  include_chars: ?*Node,
  exclude_chars: ?*Node,
) !*Node.tg.Textual {
  return &(try self.newNode(
    pos, .{.gen_textual = .{
      .categories    = categories,
      .include_chars = include_chars,
      .exclude_chars = exclude_chars,
    }})).data.gen_textual;
}

pub fn tgUnique(
  self  : Self,
  pos   : Position,
  params: ?*Node,
) !*Node.tg.Unique {
  return &(try self.newNode(
    pos, .{.gen_unique = .{.constr_params = params}})).data.gen_unique;
}

pub fn uAccess(
  self   : Self,
  pos    : Position,
  content: Node.UnresolvedAccess,
) !*Node.UnresolvedAccess {
  return &(try self.newNode(
    pos, .{.unresolved_access = content})).data.unresolved_access;
}

pub fn uCall(
  self   : Self,
  pos    : Position,
  content: Node.UnresolvedCall,
) !*Node.UnresolvedCall {
  return &(try self.newNode(
    pos, .{.unresolved_call = content})).data.unresolved_call;
}

pub fn uSymref(
  self   : Self,
  pos    : Position,
  content: Node.UnresolvedSymref,
) !*Node.UnresolvedSymref {
  return &(try self.newNode(
    pos, .{.unresolved_symref = content})).data.unresolved_symref;
}

pub fn varargs(
  self    : Self,
  pos     : Position,
  spec_pos: Position,
  t       : *Type.List,
) !*Node.Varargs {
  return &(try self.newNode(
    pos, .{.varargs = .{.t = t, .spec_pos = spec_pos}})).data.varargs;
}

pub fn varmap(
  self    : Self,
  pos     : Position,
  spec_pos: Position,
  t       : *Type.HashMap,
) !*Node.Varmap {
  return &(try self.newNode(
    pos, .{.varmap = .{.t = t, .spec_pos = spec_pos}})).data.varmap;
}

pub fn vtSetter(self: Self, v: *Symbol.Variable, n: *Node) !*Node {
  return try self.newNode(n.pos, .{.vt_setter = .{
    .v = v, .content = n,
  }});
}

pub fn poison(self: Self, pos: Position) !*Node {
  return self.newNode(pos, .poison);
}

pub fn @"void"(self: Self, pos: Position) !*Node {
  return self.newNode(pos, .void);
}