const std = @import("std");

const CycleResolution = @import("../Interpreter/CycleResolution.zig");
const ContentLevel    = @import("../Parser/ContentLevel.zig");
const nyarna          = @import("../../nyarna.zig");
const Globals         = @import("../Globals.zig");

const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;
const Types       = nyarna.Types;

const SchemaBuilder = @This();

const BackendDef = struct {
  doc_var: ?model.Value.Ast.VarDef,
  backend: *model.Node.Backend,
};

const BackendBuilder = struct {
  container: *model.VariableContainer,
  intpr    : *nyarna.Interpreter,
  doc_type : *model.Type.Record,

  funcs : std.ArrayListUnmanaged(*model.Node.Definition) = .{},
  output: std.ArrayListUnmanaged(*model.Value.Ast) = .{},

  fn merge(
    self      : *@This(),
    backend   : *model.Node.Backend,
    doc_var   : ?model.Value.Ast.VarDef,
    var_offset: u15,
  ) !void {
    // create the variable referencing the document, as specified by :<val \x>
    // on the backends block, if any.
    if (doc_var) |v| {
      const doc_sym = try self.intpr.ctx.global().create(model.Symbol);
      // because the SchemaDef and Extensions have separate block capture
      // variables, we will have multiple variables referencing the same stack
      // position. For this reason, we do not increase the num_values of the
      // container here; it is instead calculated to be the sum of all given
      // vars in all backends, so that the symbol is at the end of the container
      // as it is expected for function parameters.
      doc_sym.* = .{
        .defined_at = v.pos,
        .name       = v.name,
        .data       = .{.variable = .{
          .kind       = .given,
          .spec       = self.doc_type.typedef().predef(),
          .container  = self.container,
          .offset     = var_offset,
        }},
      };
      const ns = self.intpr.namespace(0);
      _ = try ns.tryRegister(self.intpr, doc_sym);
      defer ns.data.shrinkRetainingCapacity(ns.data.count() - 1);

      if (backend.vars) |vars| {
        _ = try self.intpr.tryInterpret(vars, .{.kind = .resolve});
      }
      for (backend.funcs) |def| {
        _ = try self.intpr.tryInterpret(def.content, .{.kind = .resolve});
      }
      if (backend.body) |body| {
        _ = try self.intpr.tryInterpret(body.root, .{.kind = .resolve});
      }
    }

    const alloc = self.intpr.allocator();
    // TODO: can we do more complex things with the body than just appending?
    if (backend.body) |body| try self.output.append(alloc, body);
    const prev_funcs = self.funcs.items;
    for (backend.funcs) |func| {
      if (func.merge != null) {
        const target_func = for (prev_funcs) |prev| {
          if (std.mem.eql(u8, prev.name.content, func.name.content)) {
            break prev;
          }
        } else {
          self.intpr.ctx.logger.UnknownMergeTarget(
            func.node().pos, func.name.content);
          return;
        };
        try mergeNode(self.intpr, target_func.content, func.content);
      } else {
        try self.funcs.append(alloc, func);
      }
    }
  }
};

loader    : nyarna.Loader,
defs      : std.ArrayListUnmanaged(*model.Node.Definition),
root      : *model.Node,
/// set if a backend name has been given. used to identify relevant backend
/// definitions.
b_name    : ?[]const u8,
backends  : std.ArrayListUnmanaged(BackendDef),

pub fn create(
  base   : *model.Value.SchemaDef,
  data   : *Globals,
  backend: ?*model.Value.TextScalar,
) !*SchemaBuilder {
  const ret = try data.backing_allocator.create(SchemaBuilder);
  try ret.loader.init(data, null, null, null, null);
  ret.defs = .{};
  ret.backends = .{};
  try ret.defs.appendSlice(ret.loader.interpreter.allocator(), base.defs);
  ret.root = base.root;
  ret.b_name = null;
  if (backend) |nv| {
    for (base.backends) |b| {
      if (std.mem.eql(u8, b.name.content, nv.content)) {
        if (try ret.pushBackend(b.content, base.doc_var)) {
          ret.b_name = nv.content;
        }
        break;
      }
    } else {
      ret.loader.logger.UnknownBackend(nv.value().origin, nv.content);
    }
  }
  return ret;
}

pub fn destroy(self: *SchemaBuilder) void {
  const globals = self.loader.data;
  self.loader.deinit();
  globals.backing_allocator.destroy(self);
}

fn ip(self: *SchemaBuilder) *nyarna.Interpreter {
  return self.loader.interpreter;
}

fn pushBackend(
  self: *SchemaBuilder,
  node: *model.Node,
  val : ?model.Value.Ast.VarDef,
) !bool {
  switch (node.data) {
    .backend => |*b| try self.backends.append(
      self.loader.storage.allocator(), .{
        .backend = b,
        .doc_var = val,
      }),
    .poison => return false,
    else => {
      self.loader.logger.NotABackend(node.pos);
      return false;
    }
  }
  return true;
}

fn procBackend(
  self: *SchemaBuilder,
  root: model.SpecType,
) !?*model.Function {
  if (self.b_name == null) return null;
  const ctx = self.loader.ctx();
  const ret_type = (try ctx.types().concat(ctx.types().output())).?;

  // we will generate a concat expression that contains
  // * initial assignments to all variables
  // * calls to each of the outputs specified.
  var level = ContentLevel{
    .start     = model.Cursor.unknown(),
    .command   = undefined,
    .fullast   = false,
    .sym_start = self.ip().symbols.items.len,
    .capture   = &.{},
  };

  // generate a variable container for the backend's variables, calculate
  // its final size, and append it to the interpreter.
  const container =
    try self.loader.data.storage.allocator().create(model.VariableContainer);
  container.* = .{.num_values = 0};

  var var_locs =
    std.ArrayList(model.locations.Ref).init(self.loader.storage.allocator());

  for (self.backends.items) |def| if (def.backend.vars) |vars| {
    // TODO: does this suffice to properly handle name clashes in variables?
    try self.ip().collectLocations(vars, &var_locs);
  };
  try self.ip().var_containers.append(
    self.loader.storage.allocator(), .{
      .offset    = self.ip().symbols.items.len,
      .container = container,
    });

  // the document type contains the root value and meta information.
  const doc_type = blk: {
    const name_type = self.loader.data.types.text().predef();

    var finder = Types.CallableReprFinder.init(&self.loader.data.types);
    // input name
    try finder.pushType(name_type.t);
    // document root
    try finder.pushType(root.t);

    const named =
      try self.loader.data.storage.allocator().create(model.Type.Named);
    named.* = .{
      .at   = root.pos,
      .name = null,
      .data = .{.record = .{.constructor = undefined}},
    };
    const target_type = model.Type{.named = named};

    const finder_res = try finder.finish(target_type, true);

    var sb = try Types.SigBuilder.init(
      self.loader.ctx(), 2, target_type, finder_res.needs_different_repr);
    sb.pushUnwrapped(model.Position.intrinsic(), "name", name_type);
    sb.pushUnwrapped(model.Position.intrinsic(), "root", root);
    const sb_res = sb.finish();
    named.data.record.constructor = try sb_res.createCallable(
      self.loader.data.storage.allocator(), .@"type");
    break :blk &named.data.record;
  };

  // merge the content of all given backends.
  var builder = BackendBuilder{
    .container = container,
    .intpr     = self.ip(),
    .doc_type  = doc_type,
  };
  for (self.backends.items) |bd| {
    try builder.merge(
      bd.backend, bd.doc_var, @intCast(u15, var_locs.items.len));
  }

  // create all variables in the container.
  var var_proc = try nyarna.lib.system.VarProc.init(self.ip(), 0, undefined);
  for (var_locs.items) |item| switch (item) {
    .node => |n| {
      var_proc.keyword_pos = n.node().pos;
      try level.append(self.ip(), try var_proc.node(n.node()));
    },
    .expr => |expr| {
      var_proc.keyword_pos = expr.pos;
      try level.append(self.ip(), try var_proc.expression(expr));
    },
    .value => |val| {
      var_proc.keyword_pos = val.value().origin;
      try level.append(self.ip(), try var_proc.value(val.value()));
    },
    .poison => {},
  };

  if (self.loader.logger.count == 0) {
    // count > 0 can mean that there has been a naming conflict between vars.
    // in that case we skip this assertion as it may be false; the backend func
    // will never be called anyway when there were errors.
    std.debug.assert(container.num_values == var_locs.items.len);
  }
  // add the slot for the document argument to the container.
  container.num_values += 1;

  // instantiate the functions so that they may be referred to in the output
  // expressions.
  var dres =
    try CycleResolution.create(self.ip(), builder.funcs.items, 0, null);
  try dres.execute();

  // ensure that CycleResolution doesn't put additional variables in here,
  // which it shouldn't
  if (self.loader.logger.count == 0) {
    std.debug.assert(container.num_values == var_locs.items.len + 1);
  }

  // create a function for each output, append a call to that function to the
  // level.
  var sig_builder =
    try Types.SigBuilder.init(ctx, 0, ret_type, true);
  const output_callable = try sig_builder.finish().createCallable(
    ctx.global(), .function);
  for (builder.output.items) |output| {
    const func = try ctx.global().create(model.Function);
    func.* = .{
      .callable   = output_callable,
      .name       = null,
      .defined_at = output.root.pos,
      .variables  = output.container.?,
      .data       = .{.ny = .{
        .body = try self.ip().interpretAs(output.root, ret_type.predef()),
      }},
    };
    const target =
      try ctx.values.funcRef(output.root.pos, func);
    const expr = try ctx.global().create(model.Expression);
    expr.* = .{
      .pos  = output.root.pos,
      .data = .{.call = .{
        .ns     = undefined,
        .target = try ctx.createValueExpr(target.value()),
        .exprs  = &.{},
      }},
      .expected_type = ret_type,
    };
    try level.append(self.ip(), try self.ip().node_gen.expression(expr));
  }

  const content = (try level.finalizeParagraph(self.ip())) orelse {
    self.loader.logger.EmptyBackend(self.backends.items[0].backend.node().pos);
    return null;
  };

  // build the signature of the backend function
  sig_builder = try Types.SigBuilder.init(ctx, 1, ret_type, true);
  sig_builder.pushUnwrapped(
    model.Position.intrinsic(), "doc", doc_type.typedef().predef());
  const callable =
    try sig_builder.finish().createCallable(ctx.global(), .function);

  const func = try self.loader.ctx().global().create(model.Function);
  func.* = .{
    .callable   = callable,
    .name       = null,
    .defined_at = self.backends.items[0].backend.node().pos,
    .variables  = container,
    .data = .{
      .ny = .{
        .body = try self.ip().interpretAs(content, ret_type.predef()),
      },
    },
  };
  return func;
}

/// merging nodes always acts on resolved calls. this function ensures that a
/// node participating in a merge is a resolved call, and reports an error and
/// returns null if it isn't.
fn getCall(intpr: *Interpreter, node: *model.Node) !?*model.Node.ResolvedCall {
  switch (node.data) {
    .unresolved_call => {
      // there can't be a symbol that was unavailable previously, so this node
      // is guaranteed to fail on interpretation. Do that to report the error.
      const res = try intpr.interpret(node);
      std.debug.assert(res.expected_type.isNamed(.poison));
      return null;
    },
    .resolved_call => |*rc| return rc,
    .poison        => return null,
    else           => {
      intpr.ctx.logger.NodePrematurelyProcessed(
        node.pos, @tagName(node.data));
      return null;
    },
  }
}

/// returns the called symbol if it is a valid keyword for a definition.
/// else logs error and returns null.
fn sym(intpr: *Interpreter, call: *model.Node.ResolvedCall) !?*model.Symbol {
  return if (call.sig.returns.isNamed(.ast)) (
    call.target.data.resolved_symref.sym
  ) else {
    const expr = try intpr.interpret(call.target);
    if (!expr.expected_type.isNamed(.poison)) {
      intpr.ctx.logger.InvalidDefinitionValue(
        &.{expr.expected_type.at(expr.pos)});
    }
    return null;
  };
}

fn getVarargs(call: *model.Node.ResolvedCall) *model.Node.Varargs {
  return &call.args[0].data.expression.data.value.data.ast.root.data.varargs;
}

fn getVarmap(call: *model.Node.ResolvedCall) *model.Node.Varmap {
  return &call.args[0].data.expression.data.value.data.ast.root.data.varmap;
}

fn getOptional(call: *model.Node.ResolvedCall, index: usize) **model.Value {
  return &call.args[index].data.expression.data.value;
}

fn mergeOptionals(
  intpr: *Interpreter,
  left : **model.Value,
  right: *model.Value,
  name : []const u8,
) void {
  if (right.data == .void) return;
  std.debug.assert(right.data == .ast);
  switch (left.*.data) {
    .void => left.* = right,
    .ast  => intpr.ctx.logger.DuplicateParameterArgument(
      name, right.origin, left.*.origin),
    else => unreachable,
  }
}

fn mergeNode(
  intpr : *Interpreter,
  target: *model.Node,
  ext   : *model.Node,
) !void {
  const tCall = (try getCall(intpr, target)) orelse {
    if (try getCall(intpr, ext)) |eCall| _ = try sym(intpr, eCall);
    return;
  };
  const eCall = (try getCall(intpr, ext)) orelse {
    _ = try sym(intpr, tCall);
    return;
  };
  const tSym = (try sym(intpr, tCall)) orelse {
    _ = try sym(intpr, eCall);
    return;
  };
  const eSym = (try sym(intpr, eCall)) orelse return;

  if (tSym != eSym) {
    intpr.ctx.logger.MergeSubjectsIncompatible(
      eSym.name, ext.pos, target.pos);
    return;
  }


  switch (tSym.data) {
    .func => |f| {
      const index = f.data.ext.impl_index;
      if (index == intpr.ctx.data.system_keywords.matcher) {
        try getVarmap(tCall).content.appendSlice(
          intpr.ctx.global(), getVarmap(eCall).content.items);
        return;
      }
    },
    .prototype => |pt| switch (pt) {
      .intersection => {
        try getVarargs(tCall).content.appendSlice(
          intpr.ctx.global(), getVarargs(eCall).content.items);
        return;
      },
      .sequence => {
        try getVarargs(tCall).content.appendSlice(
          intpr.ctx.global(), getVarargs(eCall).content.items);
        mergeOptionals(
          intpr, getOptional(tCall, 1), getOptional(eCall, 1).*, "direct");
        mergeOptionals(
          intpr, getOptional(tCall, 2), getOptional(eCall, 2).*, "auto");
        return;
      },
      .record                  => {}, // TODO: extend records (?)
      else                     => {},
    },
    else => {},
  }
  intpr.ctx.logger.CannotMergeThisDefinitionKind(ext.pos);
}

pub fn pushExt(
  self: *SchemaBuilder,
  ext : *model.Value.SchemaExt,
) !void {
  const prev_defs = self.defs.items;
  for (ext.defs) |def| {
    if (def.merge != null) {
      const target_def = for (prev_defs) |prev| {
        if (std.mem.eql(u8, prev.name.content, def.name.content)) {
          break prev;
        }
      } else {
        self.loader.logger.UnknownMergeTarget(def.node().pos, def.name.content);
        return;
      };
      try mergeNode(self.ip(), target_def.content, def.content);
    } else {
      try self.defs.append(self.ip().allocator(), def);
    }
  }
  if (self.b_name) |name| for (ext.backends) |b| {
    if (std.mem.eql(u8, b.name.content, name)) {
      _ = try self.pushBackend(b.content, ext.doc_var);
      break;
    }
  };
}

pub fn finalize(
  self: *SchemaBuilder,
  pos : model.Position,
) !?*model.Value.Schema {
  defer self.destroy();
  defer if (self.loader.logger.count > 0) {
    self.loader.data.seen_error = true;
  };
  var dres = try CycleResolution.create(self.ip(), self.defs.items, 0, null);
  try dres.execute();
  const expr = try self.ip().interpretAs(
    self.root, self.loader.ctx().types().@"type"().predef());
  switch ((try self.loader.ctx().evaluator().evaluate(expr)).data) {
    .@"type" => |*tv| {
      return try self.loader.ctx().values.schema(
        pos, tv.t.at(tv.value().origin), self.loader.public_syms.items,
        try self.procBackend(tv.t.at(tv.value().origin)));
    },
    .poison => return null,
    else => unreachable,
  }
}