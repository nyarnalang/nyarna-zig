const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const parse = @import("parse.zig");
const syntaxes = @import("syntaxes.zig");
const graph = @import("graph.zig");
const algo = @import("algo.zig");
const mapper = @import("mapper.zig");
const chains = @import("chains.zig");

pub const Errors = error {
  referred_source_unavailable,
};

/// Describes the current stage when trying to interpret nodes.
pub const Stage = struct {
  kind: enum {
    /// in intermediate stage, symbol resolutions are allowed to fail and won't
    /// generate error messages. This allows forward references e.g. in \declare
    intermediate,
    /// try to resolve unresolved functions, don't interpret anything else. This
    /// is used for late-binding function arguments inside function bodies.
    resolve,
    /// keyword stage is used for interpreting value (non-AST) arguments of
    /// keywords. Failed symbol resolution will issue an error saying that the
    /// symbol cannot be resolved *immediately* (telling the user that forward
    /// references are not possible here).
    keyword,
    /// the final stage of node resolutions, in which all context is available
    /// and thus all nodes must be interpretable. Failed symbol resolution here
    /// will issue an error saying that the symbol is unknown.
    final,
    /// this stage is used when the code assumes that interpretation cannot
    /// fail. Failure will result in an std.debug.panic.
    assumed,
  },
  /// additional resolution context that is set during cyclic resolution /
  /// fixpoint iteration in \declare and templates. This context is queried for
  /// symbol resolution if the symbol is not directly resolvable in its
  /// namespace.
  resolve: ?*graph.ResolutionContext = null,
};

pub const Namespace = struct {
  pub const Mark = usize;

  data: std.StringArrayHashMapUnmanaged(*model.Symbol) = .{},

  pub fn tryRegister(self: *Namespace, intpr: *Interpreter, sym: *model.Symbol)
      !bool {
    const res = try self.data.getOrPut(intpr.allocator, sym.name);
    if (res.found_existing) {
      intpr.ctx.logger.DuplicateSymbolName(
        sym.name, sym.defined_at, res.value_ptr.*.defined_at);
      return false;
    } else {
      res.value_ptr.* = sym;
      return true;
    }
  }

  pub fn mark(self: *Namespace) Mark {
    return self.data.count();
  }

  pub fn reset(self: *Namespace, state: Mark) void {
    self.data.shrinkRetainingCapacity(state);
  }
};

/// The Interpreter is part of the process to read in a single file or stream.
/// It provides both the functionality of interpretation, i.e. transformation
/// of AST nodes to expressions, and context data for the lexer and parser.
///
/// The interpreter implements a push-interface, i.e. nodes are pushed into it
/// for interpretation by the parser. The parser decides when nodes ought to be
/// interpreted.
///
/// The interpreter is a parameter to keyword implementations, which are allowed
/// to leverage its facilities for the implementation of static semantics.
pub const Interpreter = struct {
  /// does not need reference to actual variable; only used to shrink the
  /// variable's namespace when leaving the level where the variable was
  /// defined.
  const ActiveVariable = struct {
    ns: u15,
  };
  pub const ActiveVarContainer = struct {
    /// into Interpreter.variables. At this offset, the first variable (if any)
    /// of the container is found.
    offset: usize,
    /// unfinished. required to link newly created variables to it.
    container: *model.VariableContainer,
  };

  /// The source that is being parsed. Must not be changed during an
  /// interpreter's operation.
  input: *const model.Source,
  /// Context of the ModuleLoader that owns this interpreter.
  ctx: nyarna.Context,
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer uses this to check whether a character is a command
  /// character; the namespace mapping is relevant later for the interpreter.
  /// The values are indexes into the namespaces field.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15) = .{},
  /// Used when disabling all command characters. Will be swapped with
  /// command_characters until the block disabling the command characters ends.
  stored_command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15) = .{},
  /// Internal namespaces in the source file [6.1].
  /// A namespace will not be deleted when it goes out of scope, so that we do
  /// not need to apply special care for delayed resolution of symrefs:
  /// If a symref cannot initially be resolved to a symbol, it will be stored
  /// with namespace index and target name. Since namespaces are never deleted,
  // it will still try to find its target symbol in the same namespace when
  /// delayed resolution is triggered.
  namespaces: std.ArrayListUnmanaged(Namespace) = .{},
  /// Type namespaces [6.2].
  /// The namespace of a type is added to this hashmap when the first symbol in
  /// that namespace is established. This hashmap is used to lookup any
  /// references to symbols in a type's namespace in the current source file.
  type_namespaces: std.HashMapUnmanaged(model.Type, Namespace,
    model.Type.HashContext, std.hash_map.default_max_load_percentage) = .{},
  /// The public namespace of the current module, into which public symbols are
  /// published.
  public_namespace: *std.ArrayListUnmanaged(*model.Symbol),
  /// Allocator for data private to the interpreter (use ctx.global() for other
  /// data).This includes primarily the AST nodes generated from the parser.
  /// anything allocated here *must* be copied when referred by an external
  /// entity, such as a Value or an Expression.
  allocator: std.mem.Allocator,
  /// Array of alternative syntaxes known to the interpreter [7.12].
  /// TODO: make this user-extensible
  syntax_registry: [2]syntaxes.SpecialSyntax,
  /// convenience object to generate nodes using the interpreter's storage.
  node_gen: model.NodeGenerator,
  /// variables declared in the source code. At any time, this list contains all
  /// variables that are currently established in a namespace.
  variables: std.ArrayListUnmanaged(ActiveVariable),
  /// length equals the current list of open levels whose block configuration
  /// includes `varhead`.
  var_containers: std.ArrayListUnmanaged(ActiveVarContainer),

  /// creates an interpreter.
  pub fn create(
      ctx: nyarna.Context, allocator: std.mem.Allocator, source: *model.Source,
      public_ns: *std.ArrayListUnmanaged(*model.Symbol)) !*Interpreter {
    var ret = try allocator.create(Interpreter);
    ret.* = .{
      .input = source,
      .ctx = ctx,
      .allocator = allocator,
      .syntax_registry = .{syntaxes.SymbolDefs.locations(),
                           syntaxes.SymbolDefs.definitions()},
      .node_gen = undefined,
      .public_namespace = public_ns,
      .variables = .{},
      .var_containers = .{},
    };
    ret.node_gen = model.NodeGenerator.init(allocator);
    try ret.addNamespace('\\');
    const container = try ctx.global().create(model.VariableContainer);
    container.* = .{
      .num_values = 0,
    };
    try ret.var_containers.append(ret.allocator, .{
      .offset = 0, .container = container,
    });
    return ret;
  }

  pub fn addNamespace(self: *Interpreter, character: u21) !void {
    const index = self.namespaces.items.len;
    if (index > std.math.maxInt(u16)) return nyarna.Error.too_many_namespaces;
    try self.command_characters.put(
      self.allocator, character, @intCast(u15, index));
    try self.namespaces.append(self.allocator, .{});
    // intrinsic symbols of every namespace.
    try self.importModuleSyms(self.ctx.data.intrinsics, @intCast(u15, index));
  }

  pub inline fn namespace(self: *Interpreter, ns: u15) *Namespace {
    return &self.namespaces.items[ns];
  }

  pub inline fn type_namespace(self: *Interpreter, t: model.Type) !*Namespace {
    const entry = try self.type_namespaces.getOrPutValue(
      self.allocator, t, Namespace{});
    return entry.value_ptr;
  }

  pub fn importModuleSyms(self: *Interpreter, module: *const model.Module,
                          ns_index: u15) !void {
    const ns = self.namespace(ns_index);
    for (module.symbols) |sym| {
      if (sym.parent_type) |ptype| {
        _ = try (try self.type_namespace(ptype)).tryRegister(self, sym);
      } else _ = try ns.tryRegister(self, sym);
    }
  }

  pub fn removeNamespace(self: *Interpreter, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  fn tryInterpretChainEnd(
    self: *Interpreter,
    node: *model.Node,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    switch (try chains.Resolver.init(self, stage).resolve(node)) {
      .runtime_chain => |*rc| {
        if (rc.preliminary) return null;
        if (rc.indexes.items.len == 0) {
          return self.tryInterpret(rc.base, stage);
        } else {
          std.debug.assert(rc.base != node);
          node.data = .{.resolved_access = .{
            .base = rc.base,
            .path = rc.indexes.items,
            .last_name_pos = rc.last_name_pos,
            .ns = rc.ns,
          }};
          return self.tryInterpretRAccess(&node.data.resolved_access, stage);
        }
      },
      .sym_ref => |ref| {
        if (ref.preliminary or stage.kind == .resolve) return null;
        const value = if (ref.prefix != null) blk: {
          self.ctx.logger.PrefixedSymbolMustBeCalled(node.pos);
          break :blk try self.ctx.values.poison(node.pos);
        } else switch (ref.sym.data) {
          .func => |func|
            (try self.ctx.values.funcRef(node.pos, func)).value(),
          .@"type" => |t|
            (try self.ctx.values.@"type"(node.pos, t)).value(),
          .prototype => |pt|
            (try self.ctx.values.prototype(node.pos, pt)).value(),
          .variable, .poison => unreachable,
        };
        return try self.ctx.createValueExpr(value);
      },
      .failed, .function_returning => return null,
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(node.pos)),
    }
  }

  fn tryInterpretUAccess(
    self: *Interpreter,
    uacc: *model.Node.UnresolvedAccess,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    const input = uacc.node();
    if (stage.kind == .resolve) {
      _ = try self.tryInterpret(uacc.subject, stage);
      return null;
    }
    return try self.tryInterpretChainEnd(input, stage);
  }

  fn tryInterpretURef(
    self: *Interpreter,
    uref: *model.Node.UnresolvedSymref,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    return try self.tryInterpretChainEnd(uref.node(), stage);
  }

  fn tryInterpretAss(self: *Interpreter, ass: *model.Node.Assign, stage: Stage)
      nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      switch (ass.target) {
        .unresolved => |ures| _ = try self.tryInterpret(ures, stage),
        .resolved => {},
      }
      _ = try self.tryInterpret(ass.replacement, stage);
      return null;
    }
    const target = switch (ass.target) {
      .resolved => |*val| val,
      .unresolved => |node| innerblk: {
        switch (try chains.Resolver.init(self, stage).resolve(node)) {
          .runtime_chain => |*rc| switch (rc.base.data) {
            .resolved_symref => |*rsym| switch (rsym.sym.data) {
              .variable => |*v| {
                ass.target = .{
                  .resolved = .{
                    .target = v,
                    .path = rc.indexes.items,
                    .t = v.t,
                    .pos = node.pos,
                  },
                };
                break :innerblk &ass.target.resolved;
              },
              else => {
                self.ctx.logger.InvalidLvalue(node.pos);
                return self.ctx.createValueExpr(
                  try self.ctx.values.poison(ass.node().pos));
              }
            },
            .unresolved_call, .unresolved_symref => return null,
            else => {
              self.ctx.logger.InvalidLvalue(node.pos);
              return self.ctx.createValueExpr(
                try self.ctx.values.poison(ass.node().pos));
            },
          },
          .sym_ref => |*sr| {
            switch (sr.sym.data) {
              .variable => |*v| {
                ass.target = .{
                  .resolved = .{
                    .target = v,
                    .path = &.{},
                    .t = v.t,
                    .pos = node.pos,
                  },
                };
                break :innerblk &ass.target.resolved;
              },
              else => {},
            }
            self.ctx.logger.InvalidLvalue(node.pos);
            return self.ctx.createValueExpr(
              try self.ctx.values.poison(ass.node().pos));
          },
          .poison => {
            return self.ctx.createValueExpr(
              try self.ctx.values.poison(ass.node().pos));
          },
          .failed, .function_returning => return null,
        }
      }
    };
    if (!target.target.assignable) {
      const sym = target.target.sym();
      self.ctx.logger.CannotAssignToConst(
        sym.name, target.pos, sym.defined_at);
      return self.ctx.createValueExpr(
        try self.ctx.values.poison(ass.node().pos));
    }
    const target_expr =
      (try self.associate(ass.replacement, target.t, stage))
        orelse return null;
    const expr = try self.ctx.global().create(model.Expression);
    const path = try self.ctx.global().dupe(usize, target.path);
    expr.* = .{
      .pos = ass.node().pos,
      .data = .{
        .assignment = .{
          .target = target.target,
          .path = path,
          .expr = target_expr,
        },
      },
      .expected_type = model.Type{.intrinsic = .void},
    };
    return expr;
  }

  fn tryProbeAndInterpret(self: *Interpreter, input: *model.Node, stage: Stage)
      nyarna.Error!?*model.Expression {
    const scalar_type = (try self.probeForScalarType(input, stage))
      orelse return null;
    return self.interpretWithTargetScalar(input, scalar_type, stage);
  }

  fn tryInterpretSymref(
    self: *Interpreter,
    ref: *model.Node.ResolvedSymref,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) return null;
    switch (ref.sym.data) {
      .func => |func| return self.ctx.createValueExpr(
        (try self.ctx.values.funcRef(ref.node().pos, func)).value()),
      .variable => |*v| {
        if (v.t.is(.every)) return null;
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = ref.node().pos,
          .data = .{
            .var_retrieval = .{
              .variable = v
            },
          },
          .expected_type = v.t,
        };
        return expr;
      },
      .@"type" => |t| return self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(ref.node().pos, t)).value()),
      .prototype => |pt| return self.ctx.createValueExpr(
        (try self.ctx.values.prototype(ref.node().pos, pt)).value()),
      .poison => return self.ctx.createValueExpr(
        try self.ctx.values.poison(ref.node().pos)),
    }
  }

  fn tryInterpretCall(self: *Interpreter, rc: *model.Node.ResolvedCall,
                      stage: Stage) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      _ = try chains.Resolver.init(self, stage).resolve(rc.target);
      for (rc.args) |arg| {
        if (try self.tryInterpret(arg, stage)) |expr| {
          arg.data = .{.expression = expr};
        }
      }
      return null;
    }
    const target = (try self.tryInterpret(rc.target, stage)) orelse
      return null;
    const is_keyword = rc.sig.returns.is(.ast_node);
    const cur_allocator = if (is_keyword) self.allocator
                          else self.ctx.global();
    var args_failed_to_interpret = false;
    const arg_stage = Stage{.kind = if (is_keyword) .keyword else stage.kind,
                            .resolve = stage.resolve};
    // in-place modification of args requires that the arg nodes have been
    // created by the current document. The only way a node from another
    // document can be referenced in the current document is through
    // compile-time functions. Therefore, we always copy call nodes that
    // originate from calls of compile-time functions.
    for (rc.args) |*arg, i| {
      if (arg.*.data != .expression) {
        arg.*.data =
          if (try self.associate(arg.*, rc.sig.parameters[i].ptype,
                                 arg_stage)) |e| .{.expression = e}
          else {
            args_failed_to_interpret = true;
            continue;
          };
      }
    }

    if (args_failed_to_interpret) {
      return if (is_keyword) try self.ctx.createValueExpr(
        try self.ctx.values.poison(rc.node().pos)) else null;
    }

    const args = try cur_allocator.alloc(
      *model.Expression, rc.sig.parameters.len);
    var seen_poison = false;
    for (rc.args) |arg, i| {
      args[i] = arg.data.expression;
      if (args[i].expected_type.is(.poison)) seen_poison = true;
    }
    const expr = try cur_allocator.create(model.Expression);
    expr.* = .{
      .pos = rc.node().pos,
      .data = .{
        .call = .{
          .ns = rc.ns,
          .target = target,
          .exprs = args,
        },
      },
      .expected_type = rc.sig.returns,
    };
    if (is_keyword) {
      var eval = self.ctx.evaluator();
      const res = try eval.evaluateKeywordCall(self, &expr.data.call);
      // if this is an import, the parser must handle it.
      const interpreted_res = if (res.data == .import) null else
        try self.tryInterpret(res, stage);
      if (interpreted_res == null) {
        // it would be nicer to actually replace the original node with `res`
        // but that would make the tryInterpret API more complicated so we just
        // update the original node instead.
        rc.node().* = res.*;
      }
      return interpreted_res;
    } else {
      return expr;
    }
  }

  fn tryInterpretLoc(
      self: *Interpreter, loc: *model.Node.Location, stage: Stage)
      nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve); // TODO
    var incomplete = false;
    var t = if (loc.@"type") |node| blk: {
      var expr = (try self.associate(
        node, model.Type{.intrinsic = .@"type"}, stage))
      orelse {
        incomplete = true;
        break :blk null;
      };
      if (expr.expected_type.is(.poison)) {
        break :blk model.Type{.intrinsic = .poison};
      }
      var eval = self.ctx.evaluator();
      var val = try eval.evaluate(expr);
      break :blk val.data.@"type".t;
    } else null;

    var expr = if (loc.default) |node|
      (if (t) |texpl| try self.associate(node, texpl, stage)
       else try self.tryInterpret(node, stage))
      orelse blk: {
        incomplete = true;
        break :blk null;
      }
    else null;

    if (!incomplete and t == null and expr == null) {
      self.ctx.logger.MissingSymbolType(loc.node().pos);
      t = model.Type{.intrinsic = .poison};
    }
    if (loc.additionals) |add| {
      if (add.varmap) |varmap| {
        if (add.varargs) |varargs| {
          self.ctx.logger.IncompatibleFlag("varmap", varmap, varargs);
          add.varmap = null;
        } else if (add.mutable) |mutable| {
          self.ctx.logger.IncompatibleFlag("varmap", varmap, mutable);
          add.varmap = null;
        }
      } else if (add.varargs) |varargs| if (add.mutable) |mutable| {
        self.ctx.logger.IncompatibleFlag("mutable", mutable, varargs);
        add.mutable = null;
      };
      // TODO: check whether given flags are allowed for types.
    }

    if (incomplete) return null;
    const ltype = if (t) |given_type| given_type else expr.?.expected_type;

    const name = try self.ctx.values.textScalar(
      loc.name.node().pos, .{.intrinsic = .literal},
      try self.ctx.global().dupe(u8, loc.name.content));
    const loc_val = try self.ctx.values.location(loc.node().pos, name, ltype);
    loc_val.default = expr;
    loc_val.primary = if (loc.additionals) |add| add.primary else null;
    loc_val.varargs = if (loc.additionals) |add| add.varargs else null;
    loc_val.varmap  = if (loc.additionals) |add| add.varmap  else null;
    loc_val.mutable = if (loc.additionals) |add| add.mutable else null;
    loc_val.header  = if (loc.additionals) |add| add.header  else null;
    return try self.ctx.createValueExpr(loc_val.value());
  }

  fn tryInterpretDef(self: *Interpreter, def: *model.Node.Definition,
                     stage: Stage) nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve); // TODO
    const expr = (try self.tryInterpret(def.content, stage))
      orelse return null;
    if (!self.ctx.types().lesserEqual(
        expr.expected_type, model.Type{.intrinsic = .@"type"}) and
        !expr.expected_type.isStructural(.callable)) {
      self.ctx.logger.InvalidDefinitionValue(
        expr.pos, &.{expr.expected_type});
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(def.node().pos));
    }
    var eval = self.ctx.evaluator();
    const name = try self.ctx.values.textScalar(
      def.name.node().pos, .{.intrinsic = .literal},
      try self.ctx.global().dupe(u8, def.name.content));
    const def_val = try self.ctx.values.definition(
      def.node().pos, name, try eval.evaluate(expr));
    def_val.root = def.root;
    return try self.ctx.createValueExpr(def_val.value());
  }

  pub fn tryInterpretImport(self: *Interpreter, import: *model.Node.Import)
      parse.Error!?*model.Expression {
    const me = &self.ctx.data.known_modules.values()[import.module_index];
    switch (me) {
      .loaded => |module| {
        self.importModuleSyms(module, import.ns_index);
        return module.root;
      },
      .require_params => |ml| {
        me.* = .{.require_module = ml};
        return parse.UnwindReason.referred_module_unavailable;
      },
      .require_module => {
        // cannot happen. if the module is further down the dependency chain
        // than the current one is, then it would have had priority before ours
        // after .require_module has been set.
        unreachable;
      }
    }
  }


  fn ensureResolved(self: *Interpreter, node: *model.Node, stage: Stage)
      nyarna.Error!?*model.Node {
    switch (node.data) {
      .unresolved_call, .unresolved_symref => {
        if (stage.kind == .final or stage.kind == .keyword) {
          const res = try chains.Resolver.init(self, stage).resolve(node);
          switch (res) {
            .runtime_chain => |*rc| {
              std.debug.assert(rc.indexes.items.len == 0);
              return rc.base;
            },
            .func_ref => |*fref| {
              std.debug.assert(fref.prefix == null);
              const expr = try self.ctx.createValueExpr(
                (try self.ctx.values.funcRef(node.pos, fref.target)).value());
              node.data = .{.expression = expr};
              return node;
            },
            .type_ref => |tref| {
              const expr = try self.ctx.createValueExpr(
                (try self.ctx.values.@"type"(node.pos, tref.*)).value());
              node.data = .{.expression = expr};
              return node;
            },
            .proto_ref => |pref| {
              const expr = try self.ctx.createValueExpr(
                (try self.ctx.value.prototype(node.pos, pref.*)).value());
              node.data = .{.expression = expr};
              return node;
            },
            .failed => return null,
            .poison => {
              node.data = .poison;
              return node;
            }
          }
        } else return null;
      },
      else => return node,
    }
  }

  fn tryInterpretRAccess(self: *Interpreter, racc: *model.Node.ResolvedAccess,
      stage: Stage) nyarna.Error!?*model.Expression {
    std.debug.assert(racc.base != racc.node());
    const base = (try self.tryInterpret(racc.base, stage)) orelse return null;
    var t = base.expected_type;
    for (racc.path) |index| t = types.descend(t, index);
    std.debug.assert(racc.path.len > 0);
    const expr = try self.ctx.global().create(model.Expression);
    expr.* = .{
      .pos = racc.node().pos,
      .data = .{.access = .{
        .subject = base,
        .path = try self.ctx.global().dupe(usize, racc.path),
      }},
      .expected_type = t,
    };
    return expr;
  }

  fn locationsCanGenVars(self: *Interpreter, node: *model.Node, stage: Stage)
      nyarna.Error!bool {
    switch (node.data) {
      .location => |*loc| {
        if (loc.@"type") |tnode| {
          if (try self.tryInterpret(tnode, stage)) |texpr| {
            tnode.data = .{.expression = texpr};
            return true;
          } else return false;
        } else {
          return (try self.probeType(loc.default.?, stage)) != null;
        }
      },
      .concat => |*con| {
        for (con.items) |item|
          if (!(try self.locationsCanGenVars(item, stage)))
            return false;
        return true;
      },
      else => if (try self.tryInterpret(node, stage)) |expr| {
        node.data = .{.expression = expr};
        return true;
      } else return false,
    }
  }

  fn collectLocations(self: *Interpreter, node: *model.Node,
                      collector: *std.ArrayList(model.Node.Funcgen.LocRef))
      nyarna.Error!void {
    switch (node.data) {
      .location => |*loc| {
        if (loc.@"type") |tnode| {
          const expr = (try self.associate(
            tnode, .{.intrinsic = .@"type"}, .{.kind = .assumed})).?;
          if (expr.expected_type.is(.poison)) return;
          tnode.data = .{.expression = expr};
        } else if ((try self.probeType(
            loc.default.?, .{.kind = .assumed})).?.is(.poison)) return;
        try collector.append(.{.node = loc});
      },
      .concat => |*con|
        for (con.items) |item| try self.collectLocations(item, collector),
      .void, .poison => {},
      else => {
        const expr = (try self.associate(
          node, (try self.ctx.types().concat(.{.intrinsic = .location})).?,
          .{.kind = .assumed})).?;
        const value = try self.ctx.evaluator().evaluate(expr);
        switch (value.data) {
          .concat => |*con| {
            for (con.content.items) |item|
              try collector.append(.{.value =  &item.data.location});
          },
          .poison => {},
          else => unreachable,
        }
      },
    }
  }

  /// Tries to change func.params.unresolved to func.params.resolved.
  /// returns true if that transition was successful. A return value of false
  /// implies that there is at least one yet unresolved reference in the params.
  ///
  /// On success, this function also resolves all unresolved references to the
  /// variables in the function's body.
  pub fn tryInterpretFuncParams(
      self: *Interpreter, func: *model.Node.Funcgen, stage: Stage,
      this_type: ?model.Type) !bool {
    if (!(try self.locationsCanGenVars(func.params.unresolved, stage))) {
      return false;
    }
    // refuse params creation if this is a \method and the \this type is not yet
    // available.
    if (func.needs_this_inject and this_type == null and
        stage.kind == .intermediate) return false;
    var locs = std.ArrayList(model.Node.Funcgen.LocRef).init(self.allocator);
    if (func.needs_this_inject) {
      if (this_type) |t| {
        try locs.append(.{.value = try self.ctx.values.location(
          func.node().pos, self.ctx.thisName(), t)});
      } else {
        self.ctx.logger.MethodOutsideDeclare(func.node().pos);
      }
    }
    try self.collectLocations(func.params.unresolved, &locs);
    var variables =
      try self.allocator.alloc(*model.Symbol.Variable, locs.items.len);
    for (locs.items) |loc, index| {
      const sym = try self.ctx.global().create(model.Symbol);
      sym.* = switch (loc) {
        .node => |nl| .{
          .defined_at = nl.name.node().pos,
          .name = try self.ctx.global().dupe(u8, nl.name.content),
          .data = .{
            .variable = .{
              .t = if (nl.@"type") |lt|
                lt.data.expression.data.value.data.@"type".t
              else (try self.probeType(nl.default.?, stage)).?,
              .container = func.variables,
              .offset = func.variables.num_values + @intCast(u15, index),
              .assignable = false,
            },
          },
          .parent_type = null,
        },
        .value => |vl| .{
          .defined_at = vl.name.value().origin,
          .name = vl.name.content,
          .data = .{.variable = .{
            .t = vl.tloc,
            .container = func.variables,
            .offset = func.variables.num_values + @intCast(u15, index),
            .assignable = false,
          }},
          .parent_type = null,
        },
      };
      variables[index] = &sym.data.variable;
      func.variables.num_values += 1;
    }
    func.params = .{
      .resolved = .{.locations = locs.items},
    };
    func.variables.num_values += @intCast(u15, locs.items.len);

    // resolve references to arguments inside body.
    const ns = &self.namespaces.items[func.params_ns];
    const mark = ns.mark();
    defer ns.reset(mark);
    for (variables) |v| _ = try ns.tryRegister(self, v.sym());
    _ = try self.tryInterpret(func.body, .{.kind = .resolve});
    return true;
  }

  pub fn tryPregenFunc(
      self: *Interpreter, func: *model.Node.Funcgen, ret_type: model.Type,
      stage: Stage) nyarna.Error!?*model.Function {
    switch (func.params) {
      .unresolved => if (!try self.tryInterpretFuncParams(func, stage, null))
        return null,
      .resolved => {},
      .pregen => |pregen| return pregen,
    }
    const params = &func.params.resolved;

    var finder = types.CallableReprFinder.init(self.ctx.types());
    var index: usize = 0;
    while (index < params.locations.len) {
      const loc = params.locations[index];
      const lval = switch (loc) {
        .node => |nl| blk: {
          const expr = (try self.tryInterpretLoc(nl, stage)) orelse return null;
          const val = try self.ctx.evaluator().evaluate(expr);
          if (val.data == .poison) {
            std.mem.copy(model.Node.Funcgen.LocRef,
              params.locations[index..params.locations.len-1],
              params.locations[index+1..params.locations.len]);
            params.locations =
              params.locations[0..params.locations.len - 1];
            continue;
          }
          params.locations[index] = .{.value = &val.data.location};
          break :blk &val.data.location;
        },
        .value => |vl| vl,
      };
      try finder.push(lval);
      index += 1;
    }

    const finder_res = try finder.finish(ret_type, false);
    var b = try types.SigBuilder.init(self.ctx, params.locations.len,
      ret_type, finder_res.needs_different_repr);
    for (params.locations) |loc| try b.push(loc.value);
    const builder_res = b.finish();

    const ret = try self.ctx.global().create(model.Function);
    ret.* = .{
      .callable = try builder_res.createCallable(self.ctx.global(), .function),
      .name = null,
      .defined_at = func.node().pos,
      .data = .{
        .ny = .{.body = undefined},
      },
      .variables = func.variables,
    };
    func.params = .{.pregen = ret};
    return ret;
  }

  pub fn tryInterpretFuncBody(self: *Interpreter, func: *model.Node.Funcgen,
                              expected_type: ?model.Type, stage: Stage)
      nyarna.Error!?*model.Expression {
    switch (func.body.data) {
      .expression => |expr| return expr,
      else => {},
    }

    const res = (if (expected_type) |t|
      (try self.associate(func.body, t, stage))
    else try self.tryInterpret(func.body, stage))
    orelse return null;
    func.body.data = .{.expression = res};
    return res;
  }

  pub fn tryInterpretFunc(
      self: *Interpreter, func: *model.Node.Funcgen, stage: Stage)
      nyarna.Error!?*model.Function {
    std.debug.assert(stage.kind != .resolve); // TODO
    if (func.returns) |rnode| {
      const ret_val = try self.ctx.evaluator().evaluate(
        (try self.associate(rnode, .{.intrinsic = .@"type"},
          .{.kind = .assumed, .resolve = stage.resolve})).?);
      const returns = if (ret_val.data == .poison)
        model.Type{.intrinsic = .poison}
      else ret_val.data.@"type".t;
      const ret = (try self.tryPregenFunc(func, returns, stage))
        orelse {
          // just for discovering potential dependencies during \declare
          // resolution.
          _ = try self.tryInterpretFuncBody(func, returns, stage);
          return null;
        };
      const ny = &ret.data.ny;
      ny.body = (try self.tryInterpretFuncBody(
        func, returns, stage)) orelse return null;
      return ret;
    } else {
      var failed_parts = false;
      switch (func.params) {
        .unresolved => {
          if (!try self.tryInterpretFuncParams(func, stage, null)) {
            failed_parts = true;
          }
        },
        else => {},
      }
      const body_expr = (try self.tryInterpretFuncBody(func, null, stage))
        orelse return null;
      if (failed_parts) return null;
      const ret = (try self.tryPregenFunc(
        func, body_expr.expected_type, stage)).?;
      ret.data.ny.body = body_expr;
      return ret;
    }
  }

  pub fn interpretCallToChain(
    self: *Interpreter,
    uc: *model.Node.UnresolvedCall,
    chain_res: chains.Resolution,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    const call_ctx =
      try chains.CallContext.fromChain(self, uc.target, chain_res);
    switch (call_ctx) {
      .known => |k| {
        var sm = try mapper.SignatureMapper.init(
          self, k.target, k.ns, k.signature);
        if (k.first_arg) |prefix| {
          if (try sm.mapper.map(prefix.pos, .position, .flow)) |cursor| {
            try sm.mapper.push(cursor, prefix);
          }
        }
        for (uc.proto_args) |*arg, index| {
          const flag: mapper.Mapper.ProtoArgFlag = flag: {
            if (index < uc.first_block_arg) break :flag .flow;
            if (arg.had_explicit_block_config) break :flag .block_with_config;
            break :flag .block_no_config;
          };
          if (try sm.mapper.map(arg.content.pos, arg.kind, flag)) |cursor| {
            if (flag == .block_no_config and sm.mapper.config(cursor) != null) {
              self.ctx.logger.BlockNeedsConfig(arg.content.pos);
            }
            try sm.mapper.push(cursor, arg.content);
          }
        }
        const input = uc.node();
        const res = try sm.mapper.finalize(input.pos);
        input.* = res.*;
        return if (stage.kind == .resolve) null
        else try self.tryInterpret(input, stage);
      },
      .unknown => return null,
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(uc.node().pos)),
    }
  }

  fn tryInterpretUCall(self: *Interpreter, uc: *model.Node.UnresolvedCall,
                       stage: Stage) nyarna.Error!?*model.Expression {
    switch (stage.kind) {
      .intermediate => return null,
      .resolve => {
        _ = try chains.Resolver.init(self, stage).resolve(uc.target);
        for (uc.proto_args) |arg| {
          if (try self.tryInterpret(arg.content, stage)) |expr| {
            arg.content.data = .{.expression = expr};
          }
        }
        return null;
      },
      else => return self.interpretCallToChain(
      uc, try chains.Resolver.init(self, stage).resolve(uc.target), stage),
    }
  }

  fn tryInterpretVarargs(
    self: *Interpreter,
    va: *model.Node.Varargs,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    var seen_poison = false;
    var seen_unfinished = false;
    for (va.content.items) |item| {
      if (try self.tryInterpret(item.node, stage)) |expr| {
        if (expr.expected_type.is(.poison)) seen_poison = true;
        item.node.data = .{.expression = expr};
      } else seen_unfinished = true;
    }
    if (seen_unfinished) {
      return if (stage.kind == .keyword or stage.kind == .final)
        try self.ctx.createValueExpr(
          try self.ctx.values.poison(va.node().pos))
      else null;
    } else if (seen_poison) {
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(va.node().pos));
    }
    const items = try self.ctx.global().alloc(
      model.Expression.Varargs.Item, va.content.items.len);
    for (va.content.items) |item, index| {
      items[index] =
        .{.direct = item.direct, .expr = item.node.data.expression};
    }

    const vexpr = try self.ctx.global().create(model.Expression);
    vexpr.* = .{
      .pos = va.node().pos,
      .expected_type = va.t,
      .data = .{.varargs = .{
        .items = items,
      }},
    };
    return vexpr;
  }

  fn tryInterpretVarTypeSetter(
      self: *Interpreter, vs: *model.Node.VarTypeSetter, stage: Stage)
      nyarna.Error!?*model.Expression {
    if (try self.tryInterpret(vs.content, stage)) |expr| {
      vs.v.t = expr.expected_type;
      return expr;
    } else return null;
  }

  const TypeResult = union(enum) {
    finished: model.Type,
    unfinished: model.Type,
    unavailable, failed,
  };

  fn tryGetType(self: *Interpreter, node: *model.Node, stage: Stage)
      !TypeResult {
    const val = while (true) switch (node.data) {
      .unresolved_symref => |*usym| {
        if (stage.resolve) |r| {
          switch (try r.resolveSymbol(self, usym)) {
            .unfinished_function => {
              self.ctx.logger.CantCallUnfinished(node.pos);
              return TypeResult.failed;
            },
            .unfinished_type => |t| return TypeResult{.unfinished = t},
            .unknown => if (stage.kind == .keyword or stage.kind == .final) {
              self.ctx.logger.UnknownSymbol(node.pos, usym.name);
              return TypeResult.failed;
            } else return TypeResult.unavailable,
            .poison => return TypeResult.failed,
            .variable => |v| return TypeResult{.finished = v.t},
          }
        } else return TypeResult.unavailable;
      },
      .expression => |expr| break try self.ctx.evaluator().evaluate(expr),
      else => {
        const expr = (try self.tryInterpret(node, stage)) orelse
          return TypeResult.unavailable;
        break try self.ctx.evaluator().evaluate(expr);
      },
    } else unreachable;
    return if (val.data == .poison) TypeResult.failed else
      TypeResult{.finished = val.data.@"type".t};
  }

  /// try to generate a structural type with one inner type.
  fn tryGenUnary(self: *Interpreter, comptime name: []const u8,
                 comptime register_name: []const u8,
                 comptime error_name: []const u8, input: anytype, stage: Stage)
      nyarna.Error!?*model.Expression {
    const inner = switch (try self.tryGetType(input.inner, stage)) {
      .finished => |t| t,
      .unfinished => |t| t,
      .unavailable => return null,
      .failed => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(input.node().pos)),
    };
    const ret: ?model.Type = if (input.generated) |target| blk: {
      target.* = @unionInit(model.Type.Structural, name, .{.inner = inner});
      if (try @field(self.ctx.types(), register_name)(
          &@field(target.*, name))) {
        break :blk .{.structural = target};
      } else {
        @field(self.ctx.logger, error_name)(
          input.inner.pos, &[_]model.Type{inner});
        break :blk null;
      }
    } else blk: {
      const t = (try self.ctx.types().concat(inner)) orelse break :blk null;
      if (t.isStructural(@field(model.Type.Structural, name))) break :blk t
      else {
        @field(self.ctx.logger, error_name)(
          input.inner.pos, &[_]model.Type{inner});
        break :blk null;
      }
    };
    return try self.ctx.createValueExpr(
      if (ret) |t| (try self.ctx.values.@"type"(input.node().pos, t)).value()
      else try self.ctx.values.poison(input.node().pos));
  }

  fn tryGenConcat(self: *Interpreter, gc: *model.Node.tg.Concat, stage: Stage)
      nyarna.Error!?*model.Expression {
    return self.tryGenUnary(
      "concat", "registerConcat", "InvalidInnerConcatType", gc, stage);
  }

  fn tryGenEnum(self: *Interpreter, ge: *model.Node.tg.Enum, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = ge; _ = stage; unreachable;
  }

  fn tryGenFloat(self: *Interpreter, gf: *model.Node.tg.Float, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gf; _ = stage; unreachable;
  }

  const IntersectionChecker = struct {
    const Result = struct {
      scalar: ?model.Type = null,
      append: ?[]const model.Type = null,
      failed: bool = false,
    };

    intpr: *Interpreter,
    builder: *types.IntersectionTypeBuilder,
    scalar: ?struct {
      pos: model.Position,
      t: model.Type,
    } = null,

    fn push(self: *@This(), t: model.Type, pos: model.Position) void {
      const result: Result = switch (t) {
        .structural => |strct| switch (strct.*) {
          .intersection => |*ci| Result{
            .scalar = ci.scalar, .append = ci.types,
          },
          else => Result{.failed = true},
        },
        .intrinsic => |i| switch (i) {
          .space, .literal, .raw => Result{.scalar = t},
          else => Result{.failed = true},
        },
        .instantiated => |inst| switch (inst.data) {
          .textual => Result{.scalar = t},
          .numeric, .float, .tenum => Result{.scalar = .{.intrinsic = .raw}},
          .record => Result{.append = @ptrCast([*]const model.Type, &t)[0..1]},
        },
      };
      if (result.scalar) |s| {
        if (self.scalar) |prev| {
          if (!s.eql(prev.t)) {
            self.intpr.ctx.logger.MultipleScalarTypesInIntersection(
              "TODO", pos, prev.pos);
          }
        } else self.scalar = .{.pos = pos, .t = s};
      }
      if (result.append) |append| self.builder.push(append);
      if (result.failed) {
        self.intpr.ctx.logger.InvalidInnerIntersectionType(
          pos, &[_]model.Type{t});
      }
    }
  };

  fn tryGenIntersection(
      self: *Interpreter, gi: *model.Node.tg.Intersection, stage: Stage)
      nyarna.Error!?*model.Expression {
    var failed_some = false;
    var poison = false;
    var type_count: usize = 0;
    for (gi.types) |item| {
      if (item.direct) {
        if (try self.tryInterpret(item.node, stage)) |expr| {
          const val = try self.ctx.evaluator().evaluate(expr);
          switch (val.data) {
            .poison => poison = true,
            .list => |*list| type_count += list.content.items.len,
            else => unreachable,
          }
          item.node.data = .{.expression = try self.ctx.createValueExpr(val)};
        }
      } else type_count += 1;
    }

    var builder = try types.IntersectionTypeBuilder.init(
      type_count + 1, self.allocator);
    var checker = IntersectionChecker{.builder = &builder, .intpr = self};

    for (gi.types) |item| {
      if (item.direct) {
        const val = item.node.data.expression.data.value;
        switch (val.data) {
          .list => |*list| {
            for (list.content.items) |list_item| {
              checker.push(list_item.data.@"type".t, list_item.origin);
            }
          },
          .poison => {},
          else => unreachable,
        }
      } else {
        const inner = switch (try self.tryGetType(item.node, stage)) {
          .finished => |t| t,
          .unfinished => |t| t,
          .unavailable => {
            failed_some = true;
            continue;
          },
          .failed => {
            poison = true;
            continue;
          },
        };
        checker.push(inner, item.node.pos);
      }
    }
    if (poison) {
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gi.node().pos));
    }
    if (failed_some) return null;
    if (checker.scalar) |found_scalar| {
      builder.push(@ptrCast([*]const model.Type, &found_scalar.t)[0..1]);
    }
    const t = try builder.finish(self.ctx.types());
    return try self.ctx.createValueExpr(
      (try self.ctx.values.@"type"(gi.node().pos, t)).value());
  }

  fn tryGenList(self: *Interpreter, gl: *model.Node.tg.List, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gl; _ = stage; unreachable;
  }

  fn tryGenMap(self: *Interpreter, gm: *model.Node.tg.Map, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gm; _ = stage; unreachable;
  }

  fn tryGenNumeric(self: *Interpreter, gn: *model.Node.tg.Numeric, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gn; _ = stage; unreachable;
  }

  fn tryGenOptional(
      self: *Interpreter, go: *model.Node.tg.Optional, stage: Stage)
      nyarna.Error!?*model.Expression {
    return self.tryGenUnary(
      "optional", "registerOptional", "InvalidInnerOptionalType", go, stage);
  }

  fn tryGenParagraphs(
      self: *Interpreter, gp: *model.Node.tg.Paragraphs, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gp; _ = stage; unreachable;
  }

  fn tryGenRecord(self: *Interpreter, gr: *model.Node.tg.Record, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gr; _ = stage; unreachable;
  }

  fn tryGenTextual(self: *Interpreter, gt: *model.Node.tg.Textual, stage: Stage)
      nyarna.Error!?*model.Expression {
    _ = self; _ = gt; _ = stage; unreachable;
  }

  /// Tries to interpret the given node. Consumes the `input` node.
  /// The node returned will be
  ///
  ///  * equal to the input node on failure
  ///  * an expression node containing the result of the interpretation
  ///
  /// If a keyword call is encountered, that call will be evaluated and its
  /// result will be processed again via tryInterpret.
  ///
  /// if report_failure is set, emits errors to the handler if this or a child
  /// node cannot be interpreted.
  pub fn tryInterpret(self: *Interpreter, input: *model.Node, stage: Stage)
      nyarna.Error!?*model.Expression {
    return switch (input.data) {
      .assign => |*ass| self.tryInterpretAss(ass, stage),
      .branches => |*branches| if (stage.kind == .resolve) {
        _ = try self.tryInterpret(branches.condition, stage);
        for (branches.branches) |branch| {
          _ = try self.tryInterpret(branch, stage);
        }
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .concat => |*concat| if (stage.kind == .resolve) {
        for (concat.items) |item| _ = try self.tryInterpret(item, stage);
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .paras => |*paras| if (stage.kind == .resolve) {
        for (paras.items) |p| _ = try self.tryInterpret(p.content, stage);
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .definition => |*def| self.tryInterpretDef(def, stage),
      .expression => |expr| expr,
      .funcgen => |*func| blk: {
        const val = (try self.tryInterpretFunc(func, stage))
          orelse break :blk null;
        break :blk try self.ctx.createValueExpr(
          (try self.ctx.values.funcRef(input.pos, val)).value());
      },
      .import => unreachable, // this must always be handled directly
                              // by the parser.
      .literal => |lit| return switch (stage.kind) {
        .keyword, .final => try self.ctx.createValueExpr(
          (try self.ctx.values.textScalar(input.pos,
            .{.intrinsic = if (lit.kind == .space) .space else .literal},
           try self.ctx.global().dupe(u8, lit.content))).value()),
        else => null,
      },
      .location          => |*lo| self.tryInterpretLoc(lo, stage),
      .resolved_access   => |*ra| self.tryInterpretRAccess(ra, stage),
      .resolved_symref   => |*rs| self.tryInterpretSymref(rs, stage),
      .resolved_call     => |*rc| self.tryInterpretCall(rc, stage),
      .gen_concat        => |*gc| self.tryGenConcat(gc, stage),
      .gen_enum          => |*ge| self.tryGenEnum(ge, stage),
      .gen_float         => |*gf| self.tryGenFloat(gf, stage),
      .gen_intersection  => |*gi| self.tryGenIntersection(gi, stage),
      .gen_list          => |*gl| self.tryGenList(gl, stage),
      .gen_map           => |*gm| self.tryGenMap(gm, stage),
      .gen_numeric       => |*gn| self.tryGenNumeric(gn, stage),
      .gen_optional      => |*go| self.tryGenOptional(go, stage),
      .gen_paragraphs    => |*gp| self.tryGenParagraphs(gp, stage),
      .gen_record        => |*gr| self.tryGenRecord(gr, stage),
      .gen_textual       => |*gt| self.tryGenTextual(gt, stage),
      .unresolved_access => |*ua| self.tryInterpretUAccess(ua, stage),
      .unresolved_call   => |*uc| self.tryInterpretUCall(uc, stage),
      .unresolved_symref => |*us| self.tryInterpretURef(us, stage),
      .varargs           => |*va| self.tryInterpretVarargs(va, stage),
      .vt_setter         => |*vs| self.tryInterpretVarTypeSetter(vs, stage),
      .void, .poison => {
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = if (input.data == .void) .void else .poison,
          .expected_type = .{
            .intrinsic = if (input.data == .void) .void else .poison,
          },
        };
        return expr;
      },
    };
  }

  pub fn interpret(self: *Interpreter, input: *model.Node)
      nyarna.Error!*model.Expression {
    return if (try self.tryInterpret(input, .{.kind = .final})) |expr| expr
    else try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos));
  }

  pub fn resolveSymbol(
    self: *Interpreter,
    pos: model.Position,
    ns: u15,
    nschar_len: u3,
    name: []const u8,
  ) !*model.Node {
    var syms = &self.namespaces.items[ns].data;
    var ret = try self.allocator.create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = if (syms.get(name)) |sym| .{
        .resolved_symref = .{
          .ns = ns,
          .sym = sym,
          .name_pos = pos.trimFrontChar(nschar_len),
        },
      } else .{
        .unresolved_symref = .{
          .ns = ns, .name = name, .nschar_len = nschar_len,
        }
      },
    };
    return ret;
  }

  /// Calculate the supremum of the given nodes' types and return it.
  ///
  /// Substructures will be interpreted as necessary (see doc on probeType).
  /// If some substructure cannot be interpreted, null is returned.
  fn probeNodeList(self: *Interpreter, nodes: []*model.Node,
                   stage: Stage) !?model.Type {
    std.debug.assert(stage.kind != .resolve);
    var sup = model.Type{.intrinsic = .every};
    var already_poison = false;
    var seen_unfinished = false;
    var first_incompatible: ?usize = null;
    for (nodes) |node, i| {
      const t = (try self.probeType(node, stage)) orelse {
        seen_unfinished = true;
        continue;
      };
      if (t.is(.poison)) {
        already_poison = true;
        continue;
      }
      sup = try self.ctx.types().sup(sup, t);
      if (first_incompatible == null and sup.is(.poison)) {
        first_incompatible = i;
      }
    }
    return if (seen_unfinished) null else if (first_incompatible) |index| blk: {
      const type_arr =
        try self.allocator.alloc(model.Type, index + 1);
      type_arr[0] = (try self.probeType(nodes[index], stage)).?;
      var j = @as(usize, 0);
      while (j < index) : (j += 1) {
        type_arr[j + 1] = (try self.probeType(nodes[j], stage)).?;
      }
      self.ctx.logger.IncompatibleTypes(nodes[index].pos, type_arr);
      break :blk model.Type{.intrinsic = .poison};
    } else if (already_poison) model.Type{.intrinsic = .poison} else sup;
  }

  /// Calculate the supremum of all scalar types in the given node's types.
  /// considered are direct scalar types, as well as scalar types in
  /// concatenations, optionals and paragraphs.
  ///
  /// returns null only in the event of unfinished nodes.
  fn probeForScalarType(self: *Interpreter, input: *model.Node,
                        stage: Stage) !?model.Type {
    std.debug.assert(stage.kind != .resolve);
    const t = (try self.probeType(input, stage)) orelse return null;
    return types.containedScalar(t) orelse .{.intrinsic = .every};
  }

  fn typeFromSymbol(self: *Interpreter, sym: *model.Symbol) model.Type {
    const callable = switch (sym.data) {
      .func => |f| f.callable,
      .variable => |v| return v.t,
      .@"type" => |t| switch (t) {
        .intrinsic => |it| return switch (it) {
          .location, .definition => unreachable, // TODO
          else => model.Type{.intrinsic = .@"type"},
        },
        .structural => |st| return switch (st.*) {
          .concat, .paragraphs, .list, .map => unreachable, // TODO
          else => model.Type{.intrinsic = .@"type"},
        },
        .instantiated => |it| switch (it.data) {
          .textual, .float, .tenum => unreachable, // TODO
          .numeric => |nm| return nm.typedef(),
          .record => |rt| return rt.typedef(),
        },
      },
      .prototype => |pt| return @as(?model.Type, switch (pt) {
        .record =>
          self.ctx.types().constructors.prototypes.record.callable.typedef(),
        .concat =>
          self.ctx.types().constructors.prototypes.concat.callable.typedef(),
        .list =>
          self.ctx.types().constructors.prototypes.list.callable.typedef(),
        else => model.Type{.intrinsic = .prototype},
      }),
      .poison => return model.Type{.intrinsic = .poison},
    };
    // references to keywords must not be used as standalone values.
    std.debug.assert(!callable.sig.isKeyword());
    return callable.typedef();
  }

  /// Returns the given node's type, if it can be calculated. If the node or its
  /// substructures cannot be fully interpreted, null is returned.
  ///
  /// This will modify the given node by interpreting all substructures that
  /// are guaranteed not to be type-dependent on context. This means that all
  /// nodes are evaluated except for literal nodes, paragraphs, concatenations
  /// transitively.
  ///
  /// Semantic errors that are discovered during probing will be logged and lead
  /// to poison being returned if stage.kind != .intermediate.
  pub fn probeType(self: *Interpreter, node: *model.Node, stage: Stage)
      nyarna.Error!?model.Type {
    std.debug.assert(stage.kind != .resolve);
    switch (node.data) {
      .assign, .import, .funcgen, .gen_concat, .gen_enum, .gen_float,
      .gen_intersection, .gen_list, .gen_map, .gen_numeric, .gen_optional,
      .gen_paragraphs, .gen_record, .gen_textual, .vt_setter => {
        if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
      .branches => |br| return try self.probeNodeList(br.branches, stage),
      .concat => |con| {
        var inner =
          (try self.probeNodeList(con.items, stage)) orelse return null;
        if (!inner.is(.poison))
          inner = (try self.ctx.types().concat(inner)) orelse blk: {
            self.ctx.logger.InvalidInnerConcatType(
              node.pos, &[_]model.Type{inner});
            break :blk .{.intrinsic = .poison};
          };
        if (inner.is(.poison)) {
          node.data = .poison;
        }
        return inner;
      },
      .definition => return model.Type{.intrinsic = .definition},
      .expression => |e| return e.expected_type,
      .literal => |l| return model.Type{.intrinsic =
        if (l.kind == .space) .space else .literal},
      .location => return model.Type{.intrinsic = .location},
      .paras => |*para| {
        var builder =
          nyarna.types.ParagraphTypeBuilder.init(self.ctx.types(), false);
        var seen_unfinished = false;
        for (para.items) |*item|
          try builder.push((try self.probeType(item.content, stage)) orelse {
            seen_unfinished = true;
            continue;
          });
        return if (seen_unfinished) null else
          (try builder.finish()).resulting_type;
      },
      .resolved_access => |*ra| {
        var t = (try self.probeType(ra.base, stage)).?;
        for (ra.path) |index| t = types.descend(t, index);
        return t;
      },
      .resolved_call => |*rc| {
        if (rc.sig.returns.is(.ast_node)) {
          // this is a keyword call. tryInterpretCall will attempt to
          // execute it.
          if (try self.tryInterpretCall(rc, stage)) |expr| {
            node.data = .{.expression = expr};
            return expr.expected_type;
          }
          // tryInterpretCall *will* have either called the keyword or
          // generated poison. The keyword may have returned an unresolvable
          // node, on which we recurse.
          std.debug.assert(node.data != .resolved_call);
          return try self.probeType(node, stage);
        } else return rc.sig.returns;
      },
      .resolved_symref => |*ref| return self.typeFromSymbol(ref.sym),
      .unresolved_access, .unresolved_call, .unresolved_symref => {
        return switch (try chains.Resolver.init(self, stage).resolve(node)) {
          .runtime_chain => |*rc| rc.t,
          .sym_ref => |*sr| self.typeFromSymbol(sr.sym),
          .failed, .function_returning => null,
          .poison => blk: {
            node.data = .poison;
            break :blk model.Type{.intrinsic = .poison};
          },
        };
      },
      .varargs => |*varargs| return varargs.t,
      .void => return model.Type{.intrinsic = .void},
      .poison => return model.Type{.intrinsic = .poison},
    }
  }

  pub inline fn genValueNode(self: *Interpreter, content: *model.Value)
      !*model.Node {
    return try self.node_gen.expression(try self.ctx.createValueExpr(content));
  }

  fn createTextLiteral(self: *Interpreter, l: *model.Node.Literal,
                       t: model.Type) nyarna.Error!*model.Value {
    switch (t) {
      .intrinsic => |it| switch (it) {
        .space => if (l.kind == .space) return (try self.ctx.values.textScalar(
          l.node().pos, t, try self.ctx.global().dupe(u8, l.content))).value()
        else {
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
          return self.ctx.values.poison(l.node().pos);
        },
        .literal, .raw => return (try self.ctx.values.textScalar(
          l.node().pos, t, try self.ctx.global().dupe(u8, l.content))).value(),
        else => return (try self.ctx.values.textScalar(
          l.node().pos,
          .{.intrinsic = if (l.kind == .text) .literal else .space},
          try self.ctx.global().dupe(u8, l.content))).value(),
      },
      .structural => |struc| return switch (struc.*) {
        .optional => |*op| try self.createTextLiteral(l, op.inner),
        .concat => |*con| try self.createTextLiteral(l, con.inner),
        .paragraphs => unreachable,
        .list => |*list| try self.createTextLiteral(l, list.inner), // TODO
        .map, .callable => blk: {
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
          break :blk try self.ctx.values.poison(l.node().pos);
        },
        .intersection => |*inter| if (inter.scalar) |scalar| {
          return try self.createTextLiteral(l, scalar);
        } else {
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
          return try self.ctx.values.poison(l.node().pos);
        }
      },
      .instantiated => |ti| switch (ti.data) {
        .textual => unreachable, // TODO
        .numeric => |*n| {
          return if (try self.ctx.numberFrom(l.node().pos, l.content, n)) |nv|
            nv.value() else try self.ctx.values.poison(l.node().pos);
        },
        .float => unreachable, // TODO
        .tenum => |*e| {
          return if (try self.ctx.enumFrom(l.node().pos, l.content, e)) |ev|
            ev.value() else try self.ctx.values.poison(l.node().pos);
        },
        .record => {
          self.ctx.logger.ExpectedExprOfTypeXGotY(l.node().pos,
            &[_]model.Type{
              t, .{.intrinsic = if (l.kind == .text) .literal else .space},
            });
          return self.ctx.values.poison(l.node().pos);
        },
      },
    }
  }

  fn probeCheckOrPoison(self: *Interpreter, input: *model.Node, t: model.Type,
                        stage: Stage) nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve);
    var actual_type = (try self.probeType(input, stage)) orelse return null;
    if (!actual_type.is(.poison) and
        !self.ctx.types().lesserEqual(actual_type, t)) {
      actual_type = .{.intrinsic = .poison};
      self.ctx.logger.ExpectedExprOfTypeXGotY(
        input.pos, &[_]model.Type{t, actual_type});
    }
    return if (actual_type.is(.poison))
      try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos))
    else null;
  }

  fn poisonIfNotCompat(
      self: *Interpreter, pos: model.Position, actual: model.Type,
      scalar: model.Type) !?*model.Expression {
    if (!actual.is(.poison)) {
      if (types.containedScalar(actual)) |contained| {
        // TODO: conversion
        if (self.ctx.types().lesserEqual(contained, scalar)) return null;
      } else return null;
    }
    return try self.ctx.createValueExpr(try self.ctx.values.poison(pos));
  }

  /// Same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals. The target type *must* be a
  /// scalar type.
  pub fn interpretWithTargetScalar(
      self: *Interpreter, input: *model.Node, t: model.Type, stage: Stage)
      nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve);
    std.debug.assert(switch (t) {
      .intrinsic => |intr|
        intr == .literal or intr == .space or intr == .raw or intr == .every,
      .structural => false,
      .instantiated => |inst| inst.data == .textual or inst.data == .numeric or
        inst.data == .float or inst.data == .tenum,
    });
    switch (input.data) {
      .assign, .definition, .funcgen, .import, .location, .resolved_access,
      .resolved_symref, .resolved_call, .gen_concat, .gen_enum, .gen_float,
      .gen_intersection, .gen_list, .gen_map, .gen_numeric, .gen_optional,
      .gen_paragraphs, .gen_record, .gen_textual,
      .unresolved_access, .unresolved_call, .unresolved_symref, .varargs => {
        if (try self.tryInterpret(input, stage)) |expr| {
          if (types.containedScalar(expr.expected_type)) |scalar_type| {
            if (self.ctx.types().lesserEqual(scalar_type, t)) return expr;
            // TODO: conversion
            self.ctx.logger.ScalarTypesMismatch(
              input.pos, &[_]model.Type{t, scalar_type});
            expr.data = .{.value = try self.ctx.values.poison(input.pos)};
          }
          return expr;
        }
        return null;
      },
      .branches => |br| {
        const condition = cblk: {
          // TODO: support non-boolean branching
          if (try self.interpretWithTargetScalar(br.condition,
              self.ctx.types().getBoolean().typedef(), stage)) |expr|
            break :cblk expr
          else return null;
        };
        const actual_type =
          (try self.probeNodeList(br.branches, stage)) orelse return null;
        if (try self.poisonIfNotCompat(input.pos, actual_type, t)) |expr| {
          return expr;
        }
        const exprs =
          try self.ctx.global().alloc(*model.Expression, br.branches.len);
        for (br.branches) |item, i| {
          exprs[i] = (try self.interpretWithTargetScalar(item, t, stage)).?;
        }
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.branches = .{.condition = condition, .branches = exprs}},
          .expected_type = try self.ctx.types().sup(actual_type, t),
        };
        return expr;
      },
      .concat => |con| {
        const inner =
          (try self.probeNodeList(con.items, stage)) orelse return null;
        const actual_type = (try self.ctx.types().concat(inner))
          orelse {
            self.ctx.logger.InvalidInnerConcatType(
              input.pos, &[_]model.Type{inner});
            return try self.ctx.createValueExpr(
              try self.ctx.values.poison(input.pos));
          };
        if (try self.poisonIfNotCompat(input.pos, actual_type, t)) |expr| {
          return expr;
        }
        // TODO: properly handle paragraph types
        var failed_some = false;
        for (con.items) |item| {
          if (try self.interpretWithTargetScalar(item, t, stage)) |expr| {
            item.data = .{.expression = expr};
          } else failed_some = true;
        }
        if (failed_some) return null;
        const exprs = try self.ctx.global().alloc(
          *model.Expression, con.items.len);
        for (con.items) |item, i| exprs[i] = item.data.expression;
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.concatenation = exprs},
          .expected_type = try self.ctx.types().sup(actual_type, t),
        };
        return expr;
      },
      .expression => |expr| return expr,
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| {
        const expr = try self.ctx.global().create(model.Expression);
        expr.pos = input.pos;
        expr.data = .{.value = try self.createTextLiteral(l, t)};
        expr.expected_type = t;
        return expr;
      },
      .paras => |paras| {
        const probed = (try self.probeType(input, stage)) orelse return null;
        if (try self.poisonIfNotCompat(input.pos, probed, t)) |expr| {
          return expr;
        }
        const res = try self.ctx.global().alloc(
          model.Expression.Paragraph, paras.items.len);
        for (paras.items) |item, i| {
          res[i] = .{
            .content =
              (try self.interpretWithTargetScalar(item.content, t, stage)).?,
            .lf_after = item.lf_after,
          };
        }
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.paragraphs = res},
          .expected_type = try self.ctx.types().sup(probed, t),
        };
        return expr;
      },
      // cannot happen, because the vt_setter defines a type, nothing can force
      // a type on the vt_setter.
      .vt_setter => unreachable,
      .void => return try self.ctx.createValueExpr(
        try self.ctx.values.void(input.pos)),
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(input.pos)),
    }
  }

  /// associates the given node with the given data type, returning an
  /// expression. association takes care of:
  ///  * interpreting the node
  ///  * checking whether the resulting expression is compatible with t –
  ///    if not, generate a poison expression
  ///  * checking whether the resulting expression needs to be converted to
  ///    conform to the given type, and if yes, wraps the expression in a
  ///    conversion.
  /// null is returned if the association cannot be made currently because of
  /// unresolved symbols.
  pub fn associate(
      self: *Interpreter, node: *model.Node, t: model.Type, stage: Stage)
      !?*model.Expression {
    const scalar_type = types.containedScalar(t) orelse
      (try self.probeForScalarType(node, stage)) orelse return null;

    return if (try self.interpretWithTargetScalar(node, scalar_type, stage))
        |expr| blk: {
      if (expr.expected_type.is(.poison)) break :blk expr;
      if (self.ctx.types().lesserEqual(expr.expected_type, t)) {
        expr.expected_type = t;
        break :blk expr;
      }
      // TODO: semantic conversions here
      self.ctx.logger.ExpectedExprOfTypeXGotY(
        node.pos, &[_]model.Type{t, expr.expected_type});
      expr.data = .{.value = try self.ctx.values.poison(expr.pos)};
      break :blk expr;
    } else null;
  }
};