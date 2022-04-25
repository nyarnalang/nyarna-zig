const std = @import("std");
const nyarna = @import("nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const parse = @import("parse.zig");
const syntaxes = @import("parse/syntaxes.zig");
const graph = @import("interpret/graph.zig");
const algo = @import("interpret/algo.zig");
const mapper = @import("parse/mapper.zig");
const chains = @import("interpret/chains.zig");
const unicode = @import("unicode.zig");

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

/// An internal namespace that contains a set of symbols with unique names.
/// This data type is optimized for quick symbol name lookup. In contrast, a
/// module's external namespace is a simple list not supporting name lookup
/// directly since it is only ever imported into internal namespaces, where
/// symbols will be looked up.
pub const Namespace = struct {
  pub const Mark = usize;

  data: std.StringArrayHashMapUnmanaged(*model.Symbol) = .{},

  pub fn tryRegister(
    self: *Namespace,
    intpr: *Interpreter,
    sym: *model.Symbol,
  ) !bool {
    const res = try self.data.getOrPut(intpr.allocator, sym.name);
    // if the symbol exists, check if the existing symbol is intrinsic.
    // if so, the new symbol overrides a magic symbol used in system.ny which is
    // allowed.
    if (res.found_existing and !res.value_ptr.*.defined_at.isIntrinsic()) {
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
  /// the implementation of builtin functions for this module, if any.
  builtin_provider: ?*const lib.Provider,
  /// the content of the current file, as specified by \library, \standalone or
  /// \fragment.
  specified_content: union(enum) {
    library: model.Position,
    standalone: struct {
      pos: model.Position,
      root_type: model.Type,
      // TODO: schema (?)
    },
    fragment: struct {
      pos: model.Position,
      root_type: model.Type,
    },
    unspecified,
  } = .unspecified,

  /// creates an interpreter.
  pub fn create(
    ctx: nyarna.Context,
    allocator: std.mem.Allocator,
    source: *model.Source,
    public_ns: *std.ArrayListUnmanaged(*model.Symbol),
    provider: ?*const lib.Provider,
  ) !*Interpreter {
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
      .builtin_provider = provider,
    };
    ret.node_gen = model.NodeGenerator.init(allocator, ctx.types());
    try ret.addNamespace('\\');
    const container = try ctx.global().create(model.VariableContainer);
    container.* = .{.num_values = 0};
    try ret.var_containers.append(ret.allocator, .{
      .offset = 0, .container = container,
    });
    return ret;
  }

  pub fn addNamespace(self: *Interpreter, character: u21) !void {
    const index = self.namespaces.items.len;
    if (index > std.math.maxInt(u15)) return nyarna.Error.too_many_namespaces;
    try self.command_characters.put(
      self.allocator, character, @intCast(u15, index));
    try self.namespaces.append(self.allocator, .{});
    const ns = self.namespace(@intCast(u15, index));
    // intrinsic symbols of every namespace.
    for (self.ctx.data.generic_symbols.items) |sym| {
      _ = try ns.tryRegister(self, sym);
    }
  }

  pub inline fn namespace(self: *Interpreter, ns: u15) *Namespace {
    return &self.namespaces.items[ns];
  }

  pub inline fn type_namespace(self: *Interpreter, t: model.Type) !*Namespace {
    const entry = try self.type_namespaces.getOrPutValue(
      self.allocator, t, Namespace{});
    return entry.value_ptr;
  }

  /// imports all symbols in the external namespace of the given module into the
  /// internal namespace given by ns_index.
  pub fn importModuleSyms(
    self: *Interpreter,
    module: *const model.Module,
    ns_index: u15,
  ) !void {
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

  fn tryInterpretAss(
    self: *Interpreter,
    ass: *model.Node.Assign,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
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
                    .spec = v.spec,
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
              return try self.ctx.createValueExpr(
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
                    .spec = v.spec,
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
      (try self.associate(ass.replacement, target.spec, stage))
        orelse return null;
    const expr = try self.ctx.global().create(model.Expression);
    const path = try self.ctx.global().dupe(usize, target.path);
    expr.* = .{
      .pos = ass.node().pos,
      .data = .{
        .assignment = .{
          .target = target.target,
          .path = path,
          .rexpr = target_expr,
        },
      },
      .expected_type = self.ctx.types().void(),
    };
    return expr;
  }

  /// probes the given node for its scalar type (if any), and then interprets
  /// it using that type, so that any literal nodes will become expression of
  /// that type.
  fn tryProbeAndInterpret(
    self: *Interpreter,
    input: *model.Node,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    const scalar_type = (try self.probeForScalarType(input, stage))
      orelse return null;
    return self.interpretWithTargetScalar(input, scalar_type.predef(), stage);
  }

  fn tryInterpretSymref(
    self: *Interpreter,
    ref: *model.Node.ResolvedSymref,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) return null;
    switch (ref.sym.data) {
      .func => |func| {
        if (func.sig().isKeyword()) {
          self.ctx.logger.KeywordMustBeCalled(ref.node().pos);
          return self.ctx.createValueExpr(
            try self.ctx.values.poison(ref.node().pos));
        }
        return self.ctx.createValueExpr(
          (try self.ctx.values.funcRef(ref.node().pos, func)).value());
      },
      .variable => |*v| {
        if (v.spec.t.isNamed(.every)) return null;
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = ref.node().pos,
          .data = .{
            .var_retrieval = .{
              .variable = v
            },
          },
          .expected_type = v.spec.t,
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

  fn tryInterpretCall(
    self: *Interpreter,
    rc: *model.Node.ResolvedCall,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      _ = try chains.Resolver.init(self, stage).resolve(rc.target);
      for (rc.args) |arg, index| {
        if (try self.tryInterpret(arg, stage)) |expr| {
          expr.expected_type = rc.sig.parameters[index].spec.t;
          arg.data = .{.expression = expr};
        }
      }
      return null;
    }
    const is_keyword = rc.sig.returns.isNamed(.ast);
    const target: ?*model.Expression = if (is_keyword) null else (
      try self.tryInterpret(rc.target, stage)
    ) orelse return null;

    const cur_allocator =
      if (is_keyword) self.allocator else self.ctx.global();
    var args_failed_to_interpret = false;
    const arg_stage = Stage{
      .kind = if (is_keyword) .keyword else stage.kind,
      .resolve = stage.resolve,
    };
    // in-place modification of args requires that the arg nodes have been
    // created by the current document. The only way a node from another
    // document can be referenced in the current document is through
    // compile-time functions. Therefore, we always copy call nodes that
    // originate from calls of compile-time functions.
    for (rc.args) |*arg, i| {
      if (arg.*.data != .expression) {
        arg.*.data = if (
          try self.associate(arg.*, rc.sig.parameters[i].spec, arg_stage)
        ) |e| .{.expression = e}
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
      if (args[i].expected_type.isNamed(.poison)) seen_poison = true;
    }

    if (target) |rt_target| {
      const expr = try cur_allocator.create(model.Expression);
      expr.* = .{
        .pos = rc.node().pos,
        .data = .{
          .call = .{
            .ns = rc.ns,
            .target = rt_target,
            .exprs = args,
          },
        },
        .expected_type = rc.sig.returns,
      };
      return expr;
    } else {
      var eval = self.ctx.evaluator();
      const res = try eval.evaluateKeywordCall(
        self, rc.node().pos, rc.ns, rc.target.data.resolved_symref.sym, args);
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
    }
  }

  fn tryInterpretLoc(
    self: *Interpreter,
    loc: *model.Node.Location,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      if (loc.@"type") |node| {
        if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
        }
      }
      if (loc.default) |node| _ = try self.tryInterpret(node, stage);
      return null;
    }
    var incomplete = false;
    var t = if (loc.@"type") |node| blk: {
      var expr = (try self.associate(
        node, self.ctx.types().@"type"().predef(), stage))
      orelse {
        incomplete = true;
        break :blk null;
      };
      break :blk expr;
    } else null;

    var default: ?*model.Expression = null;
    if (loc.default) |node| {
      const res: ?*model.Expression = if (t) |texpr| switch (texpr.data) {
        .value => |val| switch (val.data) {
          .@"type" => |tv|
            try self.associate(node, tv.t.at(texpr.pos), stage),
          else => try self.tryInterpret(node, stage),
        },
        else => try self.tryInterpret(node, stage),
      } else try self.tryInterpret(node, stage);
      if (res) |rexpr| default = rexpr else incomplete = true;
    }

    if (incomplete) return null;

    const name = (
      try self.associate(loc.name, self.ctx.types().literal().predef(), stage)
    ) orelse return null;

    const ret = try self.ctx.global().create(model.Expression);
    ret.* = .{
      .pos = loc.node().pos,
      .expected_type = self.ctx.types().location(),
      .data = .{.location = .{
        .name = name,
        .@"type" = t,
        .default = default,
        .additionals = loc.additionals,
      }},
    };
    return ret;
  }

  fn tryInterpretDef(
    self: *Interpreter,
    def: *model.Node.Definition,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      _ = try self.tryInterpret(def.content, stage);
      return null;
    }
    const expr = (try self.tryInterpret(def.content, stage))
      orelse return null;
    const value = try self.ctx.evaluator().evaluate(expr);
    const content:
      std.meta.fieldInfo(model.Value.Definition, .content).field_type =
      switch (value.data) {
        .funcref => |f| .{.func = f.func},
        .@"type" => |tv| .{.@"type" = tv.t},
        else => {
          if (value.data != .poison) {
            self.ctx.logger.InvalidDefinitionValue(
              &.{try self.ctx.types().valueSpecType(value)});
          }
          return try self.ctx.createValueExpr(
            try self.ctx.values.poison(def.node().pos));
        }
      };
    const name = try self.ctx.values.textScalar(
      def.name.node().pos, self.ctx.types().literal(),
      try self.ctx.global().dupe(u8, def.name.content));

    const def_val = try self.ctx.values.definition(
      def.node().pos, name, content, def.node().pos);
    def_val.root = def.root;
    return try self.ctx.createValueExpr(def_val.value());
  }

  pub fn tryInterpretImport(
    self: *Interpreter,
    import: *model.Node.Import,
  ) parse.Error!?*model.Expression {
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

  fn ensureResolved(
    self: *Interpreter,
    node: *model.Node,
    stage: Stage,
  ) nyarna.Error!?*model.Node {
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

  fn tryInterpretRAccess(
    self: *Interpreter,
    racc: *model.Node.ResolvedAccess,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
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

  fn locationsCanGenVars(
    self: *Interpreter,
    node: *model.Node,
    stage: Stage,
  ) nyarna.Error!bool {
    switch (node.data) {
      .location => |*loc| {
        if (
          try self.associate(
            loc.name, self.ctx.types().literal().predef(), stage)
        ) |nexpr| {
          loc.name.data = .{.expression = nexpr};
        } else return false;
        if (loc.@"type") |tnode| {
          if (
            try self.associate(
              tnode, self.ctx.types().@"type"().predef(), stage)
          ) |texpr| {
            tnode.data = .{.expression = texpr};
            return true;
          } else return false;
        } else {
          return (try self.probeType(loc.default.?, stage, false)) != null;
        }
      },
      .concat => |*con| {
        for (con.items) |item|
          if (!(try self.locationsCanGenVars(item, stage)))
            return false;
        return true;
      },
      else => if (
        try self.associate(node,
          (try self.ctx.types().concat(self.ctx.types().location())).?.predef(),
          stage)
      ) |expr| {
        node.data = .{.expression = expr};
        return true;
      } else return false,
    }
  }

  fn collectLocations(
    self: *Interpreter,
    node: *model.Node,
    collector: *std.ArrayList(model.locations.Ref),
  ) nyarna.Error!void {
    switch (node.data) {
      .location => |*loc| try collector.append(.{.node = loc}),
      .concat => |*con|
        for (con.items) |item| try self.collectLocations(item, collector),
      .void, .poison => {},
      else => {
        const value = try self.ctx.evaluator().evaluate(node.data.expression);
        switch (value.data) {
          .concat => |*con| {
            for (con.content.items) |item|
              try collector.append(.{.value = &item.data.location});
          },
          .poison => {},
          else => unreachable,
        }
      },
    }
  }

  pub fn tryInterpretLocationsList(
    self: *Interpreter,
    list: *model.locations.List(void),
    stage: Stage,
  ) !bool {
    switch (list.*) {
      .unresolved => |uc| {
        if (!(try self.locationsCanGenVars(uc, stage))) {
          return false;
        }
        var locs = std.ArrayList(model.locations.Ref).init(self.allocator);
        try self.collectLocations(uc, &locs);
        list.* = .{.resolved = .{.locations = locs.items}};
      },
      else => {},
    }
    return true;
  }

  /// Tries to change func.params.unresolved to func.params.resolved.
  /// returns true if that transition was successful. A return value of false
  /// implies that there is at least one yet unresolved reference in the params.
  ///
  /// On success, this function also resolves all unresolved references to the
  /// variables in the function's body.
  pub fn tryInterpretFuncParams(
    self: *Interpreter,
    func: *model.Node.Funcgen,
    stage: Stage,
  ) !bool {
    if (!(try self.locationsCanGenVars(func.params.unresolved, stage))) {
      return false;
    }
    var locs = std.ArrayList(model.locations.Ref).init(self.allocator);
    try self.collectLocations(func.params.unresolved, &locs);
    var variables =
      try self.allocator.alloc(*model.Symbol.Variable, locs.items.len);
    var next: usize = 0;
    for (locs.items) |*loc, index| {
      var name: *model.Value.TextScalar = undefined;
      var loc_type: model.SpecType = undefined;
      var borrowed: bool = undefined;
      switch (loc.*) {
        .node => |nl| {
          switch (
            (try self.ctx.evaluator().evaluate(nl.name.data.expression)).data
          ) {
            .text => |*txt| name = txt,
            .poison => {
              loc.* = .poison;
              continue;
            },
            else => unreachable,
          }
          if (nl.@"type") |lt| (
            switch (lt.data.expression.data.value.data) {
              .@"type" => |vt| loc_type = vt.t.at(lt.pos),
              .poison => loc_type = self.ctx.types().poison().predef(),
              else => unreachable,
            }
          ) else {
            const probed = (try self.probeType(nl.default.?, stage, false)).?;
            loc_type = probed.at(nl.default.?.pos);
          }
          borrowed = if (nl.additionals) |a| a.borrow != null else false;
        },
        .expr => |expr| switch (expr.data) {
          .location => |*lexpr| {
            switch ((try self.ctx.evaluator().evaluate(lexpr.name)).data) {
              .text => |*txt| name = txt,
              .poison => {
                loc.* = .poison;
                continue;
              },
              else => unreachable,
            }
            if (lexpr.@"type") |texpr| switch (
              (try self.ctx.evaluator().evaluate(texpr)).data
            ) {
              .@"type" => |tv| loc_type = tv.t.at(texpr.pos),
              .poison  => loc_type = self.ctx.types().poison().predef(),
              else => unreachable,
            } else {
              loc_type = lexpr.default.?.expected_type.at(lexpr.default.?.pos);
            }
            borrowed = if (lexpr.additionals) |a| a.borrow != null else false;
          },
          else => switch ((try self.ctx.evaluator().evaluate(expr)).data) {
            .location => |*lval| {
              loc.* = .{.value = lval};
              name = lval.name;
              loc_type = lval.spec;
              borrowed = lval.borrow != null;
            },
            .poison => {
              loc.* = .poison;
              continue;
            },
            else => unreachable,
          },
        },
        .value => |lval| {
          name = lval.name;
          loc_type = lval.spec;
          borrowed = lval.borrow != null;
        },
        .poison => continue,
      }
      const sym = try self.ctx.global().create(model.Symbol);
      sym.* = .{
        .defined_at = name.value().origin,
        .name = name.content,
        .data = .{
          .variable = .{
            .spec = loc_type,
            .container = func.variables,
            .offset = func.variables.num_values + @intCast(u15, index),
            .assignable = false,
            .borrowed = borrowed,
          },
        },
        .parent_type = null,
      };
      variables[next] = &sym.data.variable;
      next += 1;
    }
    variables = variables[0..next];
    func.params = .{
      .resolved = .{.locations = locs.items},
    };
    func.variables.num_values += @intCast(u15, variables.len);

    // resolve references to arguments inside body.
    const ns = &self.namespaces.items[func.params_ns];
    const mark = ns.mark();
    defer ns.reset(mark);
    for (variables) |v| _ = try ns.tryRegister(self, v.sym());
    _ = try self.tryInterpret(func.body, .{.kind = .resolve});
    return true;
  }

  pub fn processLocations(
    self: *Interpreter,
    locs: *[]model.locations.Ref,
    stage: Stage,
  ) nyarna.Error!?types.CallableReprFinder {
    var finder = types.CallableReprFinder.init(self.ctx.types());
    var index: usize = 0;
    locsLoop: while (index < locs.len) {
      const loc = &locs.*[index];
      const lval = valueLoop: while (true) switch (loc.*) {
        .node => |nl| {
          const expr = (try self.tryInterpretLoc(nl, stage)) orelse return null;
          loc.* = .{.expr = expr};
        },
        .expr => |expr| switch (
          (try self.ctx.evaluator().evaluate(expr)).data
        ) {
          .location => |*locv| {
            loc.* = .{.value = locv};
            break :valueLoop locv;
          },
          .poison => {
            loc.* = .poison;
            continue :locsLoop;
          },
          else => unreachable,
        },
        .value => |lval| break :valueLoop lval,
        .poison => continue :locsLoop,
      } else unreachable;
      try finder.push(lval);
      index += 1;
    }
    return finder;
  }

  pub fn tryPregenFunc(
    self: *Interpreter,
    func: *model.Node.Funcgen,
    ret_type: model.Type,
    stage: Stage,
  ) nyarna.Error!?*model.Function {
    switch (func.params) {
      .unresolved =>
        if (!try self.tryInterpretFuncParams(func, stage)) return null,
      .resolved => {},
      .pregen => |pregen| return pregen,
    }
    const params = &func.params.resolved;
    var finder = (try self.processLocations(&params.locations, stage))
      orelse return null;
    const finder_res = try finder.finish(ret_type, false);
    var builder = try types.SigBuilder.init(self.ctx, params.locations.len,
      ret_type, finder_res.needs_different_repr);
    for (params.locations) |loc| try builder.push(loc.value);
    const builder_res = builder.finish();

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

  pub fn tryInterpretFuncBody(
    self: *Interpreter,
    func: *model.Node.Funcgen,
    expected_type: ?model.SpecType,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    switch (func.body.data) {
      .expression => |expr| return expr,
      else => {},
    }

    const res = (if (expected_type) |spec|
      (try self.associate(func.body, spec, stage))
    else try self.tryInterpret(func.body, stage))
    orelse return null;
    func.body.data = .{.expression = res};
    return res;
  }

  pub fn tryInterpretFunc(
    self: *Interpreter,
    func: *model.Node.Funcgen,
    stage: Stage,
  ) nyarna.Error!?*model.Function {
    if (stage.kind == .resolve) {
      switch (func.params) {
        .unresolved => |node| _ = try self.tryInterpret(node, stage),
        .resolved => |*res| for (res.locations) |*lref| switch (lref.*) {
          .node => |lnode| _ = try self.tryInterpretLoc(lnode, stage),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      _ = try self.tryInterpret(func.body, stage);
      return null;
    }
    if (func.returns) |rnode| {
      const ret_val = try self.ctx.evaluator().evaluate(
        (try self.associate(rnode, self.ctx.types().@"type"().predef(),
          .{.kind = .final, .resolve = stage.resolve})).?);
      const returns = if (ret_val.data == .poison)
        self.ctx.types().poison().predef()
      else ret_val.data.@"type".t.at(ret_val.origin);
      const ret = (try self.tryPregenFunc(func, returns.t, stage))
        orelse {
          // just for discovering potential dependencies during \declare
          // resolution.
          _ = try self.tryInterpretFuncBody(func, returns, stage);
          return null;
        };
      const ny = &ret.data.ny;
      ny.body = (try self.tryInterpretFuncBody(func, returns, stage))
        orelse return null;
      return ret;
    } else {
      var failed_parts = false;
      switch (func.params) {
        .unresolved => {
          if (!try self.tryInterpretFuncParams(func, stage)) {
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

  /// never creates an Expression because builtins may only occur as node in a
  /// definition, where they are handled directly. Returns true iff all
  /// components have been resolved. Issues error if called in .keyword or
  /// .final stage because that implies it is used outside of a definition.
  pub fn tryInterpretBuiltin(
    self: *Interpreter,
    bg: *model.Node.BuiltinGen,
    stage: Stage,
  ) nyarna.Error!bool {
    if (stage.kind == .resolve) {
      switch (bg.params) {
        .unresolved => |node| _ = try self.tryInterpret(node, stage),
        .resolved => |*res| for (res.locations) |*lref| switch (lref.*) {
          .node => |lnode| _ = try self.tryInterpretLoc(lnode, stage),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      switch (bg.returns) {
        .node => |rnode| if (try self.tryInterpret(rnode, stage)) |expr| {
          bg.returns = .{.expr = expr};
        },
        .expr => {},
      }
      return false;
    }

    switch (bg.returns) {
      .expr => {},
      .node => |rnode| {
        const expr = (
          try self.associate(rnode, self.ctx.types().@"type"().predef(), stage)
        ) orelse return false;
        bg.returns = .{.expr = expr};
      }
    }

    if (!(try self.tryInterpretLocationsList(&bg.params, stage))) return false;
    switch(stage.kind) {
      .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(bg.node().pos),
      else => {}
    }
    return true;
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

  fn tryInterpretUCall(
    self: *Interpreter,
    uc: *model.Node.UnresolvedCall,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    switch (stage.kind) {
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
        if (expr.expected_type.isNamed(.poison)) seen_poison = true;
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
    self: *Interpreter,
    vs: *model.Node.VarTypeSetter,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (try self.tryInterpret(vs.content, stage)) |expr| {
      vs.v.spec = expr.expected_type.at(expr.pos);
      return expr;
    } else return null;
  }

  const TypeResult = union(enum) {
    finished  : model.Type,
    unfinished: model.Type,
    expression: *model.Expression,
    unavailable, failed,
  };

  fn tryGetType(
    self: *Interpreter,
    node: *model.Node,
    stage: Stage,
  ) !TypeResult {
    switch (node.data) {
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
            .variable => |v| {
              if (
                self.ctx.types().lesserEqual(
                  v.spec.t, self.ctx.types().@"type"())
              ) {
                const expr = try self.ctx.global().create(model.Expression);
                expr.* = .{
                  .pos = node.pos,
                  .expected_type = self.ctx.types().@"type"(),
                  .data = .{.var_retrieval = .{
                    .variable = v,
                  }},
                };
                return TypeResult{.expression = expr};
              } else {
                self.ctx.logger.ExpectedExprOfTypeXGotY(&.{
                  v.spec, self.ctx.types().@"type"().predef(),
                });
                return TypeResult.failed;
              }
            },
          }
        } else if (
          try self.associate(node, self.ctx.types().@"type"().predef(), stage)
        ) |expr| {
          return TypeResult{.expression = expr};
        } else return TypeResult.unavailable;
      },
      .expression => |expr| return TypeResult{.expression = expr},
      else => if (
        try self.associate(node, self.ctx.types().@"type"().predef(), stage)
      ) |expr| {
        return TypeResult{.expression = expr};
      } else return TypeResult.unavailable,
    }
  }

  /// try to generate a structural type with one inner type.
  fn tryGenUnary(
    self: *Interpreter,
    comptime name: []const u8,
    comptime register_name: []const u8,
    comptime error_name: []const u8,
    input: anytype,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    const inner = switch (try self.tryGetType(input.inner, stage)) {
      .finished => |t| t,
      .unfinished => |t| t,
      .expression => |expr| blk: {
        switch (expr.data) {
          .value => |val| switch (val.data) {
            .@"type" => |*tv| break :blk tv.t,
            .poison => return try self.ctx.createValueExpr(
              try self.ctx.values.poison(input.node().pos)),
            else => unreachable,
          },
          else => {
            const ret = try self.ctx.global().create(model.Expression);
            ret.* = .{
              .pos = input.node().pos,
              .expected_type = self.ctx.types().@"type"(),
              .data = @unionInit(model.Expression.Data, "tg_" ++ name, .{
                .inner = expr,
              }),
            };
            return ret;
          }
        }
      },
      .unavailable => return null,
      .failed => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(input.node().pos)),
    };
    const ret: *model.Value = if (input.generated) |target| blk: {
      target.* = @unionInit(model.Type.Structural, name, .{.inner = inner});
      if (try @field(self.ctx.types(), register_name)(
          &@field(target.*, name))) {
        const t = model.Type{.structural = target};
        break :blk (try self.ctx.values.@"type"(input.node().pos, t)).value();
      } else {
        @field(self.ctx.logger, error_name)(
          &[_]model.SpecType{inner.at(input.inner.pos)});
        break :blk try self.ctx.values.poison(input.node().pos);
      }
    } else try self.ctx.unaryTypeVal(
      name, input.node().pos, inner, input.inner.pos, error_name);
    return try self.ctx.createValueExpr(ret);
  }

  fn tryGenConcat(
    self: *Interpreter,
    gc: *model.Node.tg.Concat,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    return self.tryGenUnary(
      "concat", "registerConcat", "InvalidInnerConcatType", gc, stage);
  }

  fn tryGenEnum(
    self: *Interpreter,
    ge: *model.Node.tg.Enum,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    var result = try self.tryProcessVarargs(
      ge.values, self.ctx.types().system.identifier, stage);

    var builder = try types.EnumBuilder.init(self.ctx, ge.node().pos);

    for (ge.values) |item| {
      if (item.direct) {
        switch (item.node.data.expression.data.value.data) {
          .poison => {},
          .list => |*list| for (list.content.items) |child| {
            try builder.add(child.data.text.content, child.origin);
          },
          else => unreachable,
        }
      } else {
        const expr = (
          try self.associate(
            item.node, self.ctx.types().literal().predef(), stage)
        ) orelse {
          if (result.kind != .poison) result.kind = .failed;
          continue;
        };
        const value = try self.ctx.evaluator().evaluate(expr);
        switch (value.data) {
          .poison => result.kind = .poison,
          .text => |*text| try builder.add(text.content, value.origin),
          else => unreachable,
        }
        expr.data = .{.value = value};
        item.node.data = .{.expression = expr};
      }
    }
    switch (result.kind) {
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(ge.node().pos)),
      .failed => return null,
      .success => {
        const t = builder.finish().typedef();
        return try self.ctx.createValueExpr(
          (try self.ctx.values.@"type"(ge.node().pos, t)).value());
      },
    }
  }

  fn tryGenFloat(
    self: *Interpreter,
    gf: *model.Node.tg.Float,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    _ = self; _ = gf; _ = stage; unreachable;
  }

  const IntersectionChecker = struct {
    const Result = struct {
      scalar: ?model.Type = null,
      append: ?[]const model.Type = null,
      failed: bool = false,
    };

    intpr: *Interpreter,
    builder: *types.IntersectionBuilder,
    scalar: ?model.SpecType = null,

    fn push(self: *@This(), t: model.Type, pos: model.Position) !void {
      const result: Result = switch (t) {
        .structural => |strct| switch (strct.*) {
          .intersection => |*ci| Result{
            .scalar = ci.scalar, .append = ci.types,
          },
          else => Result{.failed = true},
        },
        .named => |named| switch (named.data) {
          .textual, .space, .literal => Result{.scalar = t},
          .int, .float, .@"enum" =>
            Result{.scalar = self.intpr.ctx.types().text()},
          .record => Result{.append = @ptrCast([*]const model.Type, &t)[0..1]},
          else => Result{.failed = true},
        },
      };
      if (result.scalar) |s| {
        if (self.scalar) |prev| {
          if (!s.eql(prev.t)) {
            const t_fmt = s.formatter();
            const repr =
              try std.fmt.allocPrint(self.intpr.allocator, "{}", .{t_fmt});
            defer self.intpr.allocator.free(repr);
            self.intpr.ctx.logger.MultipleScalarTypes(&.{
              s.at(pos), prev,
            });
          }
        } else self.scalar = s.at(pos);
      }
      if (result.append) |append| self.builder.push(append);
      if (result.failed) {
        self.intpr.ctx.logger.InvalidInnerIntersectionType(&.{t.at(pos)});
      }
    }
  };

  const VarargsProcessResult = struct {
    const Kind = enum{success, failed, poison};
    kind: Kind,
    /// the maximum number of value that can be produced. Sum of the number of
    /// children in direct items that can be interpreted, plus number of
    /// non-direct items.
    max: usize,
  };

  fn tryProcessVarargs(
    self: *Interpreter,
    items: []model.Node.Varargs.Item,
    inner_type: model.Type,
    stage: Stage,
  ) nyarna.Error!VarargsProcessResult {
    const list_type = (try self.ctx.types().list(inner_type)).?;
    var failed_some = false;
    var poison = false;
    var count: usize = 0;
    for (items) |item| {
      if (item.direct) {
        const expr = (
          try self.associate(item.node, list_type.predef(), stage)
        ) orelse {
          failed_some = true;
          continue;
        };
        const value = try self.ctx.evaluator().evaluate(expr);
        switch (value.data) {
          .poison => poison = true,
          .list => |*list| count += list.content.items.len,
          else => unreachable,
        }
        expr.data = .{.value = value};
        item.node.data = .{.expression = expr};
      } else count += 1;
    }
    return VarargsProcessResult{
      .max = count,
      .kind = if (poison) VarargsProcessResult.Kind.poison
              else if (failed_some) VarargsProcessResult.Kind.failed
              else .success,
    };
  }

  fn tryGenIntersection(
    self: *Interpreter,
    gi: *model.Node.tg.Intersection,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      for (gi.types) |item| _ = try self.tryInterpret(item.node, stage);
      return null;
    }

    var result =
      try self.tryProcessVarargs(gi.types, self.ctx.types().@"type"(), stage);

    var builder = try types.IntersectionBuilder.init(
      result.max + 1, self.allocator);
    var checker = IntersectionChecker{.builder = &builder, .intpr = self};

    for (gi.types) |item| {
      if (item.direct) {
        const val = item.node.data.expression.data.value;
        switch (val.data) {
          .list => |*list| {
            for (list.content.items) |list_item| {
              try checker.push(list_item.data.@"type".t, list_item.origin);
            }
          },
          .poison => result.kind = .poison,
          else => unreachable,
        }
      } else {
        const inner = switch (try self.tryGetType(item.node, stage)) {
          .finished => |t| t,
          .unfinished => |t| t,
          .expression => |expr| switch (
            (try self.ctx.evaluator().evaluate(expr)).data
          ) {
            .@"type" => |tv| tv.t,
            .poison => {
              if (result.kind != .poison) result.kind = .failed;
              continue;
            },
            else => unreachable,
          },
          .unavailable => {
            if (result.kind != .poison) result.kind = .failed;
            continue;
          },
          .failed => {
            result.kind = .poison;
            continue;
          },
        };
        try checker.push(inner, item.node.pos);
      }
    }
    switch (result.kind) {
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gi.node().pos)),
      .failed => return null,
      .success => {
        if (checker.scalar) |*found_scalar| {
          builder.push(@ptrCast([*]const model.Type, &found_scalar.t)[0..1]);
        }
        const t = try builder.finish(self.ctx.types());
        return try self.ctx.createValueExpr(
          (try self.ctx.values.@"type"(gi.node().pos, t)).value());
      }
    }
  }

  fn tryGenList(
    self: *Interpreter,
    gl: *model.Node.tg.List,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    return self.tryGenUnary(
      "list", "registerList", "InvalidInnerListType", gl, stage);
  }

  fn tryGenMap(
    self: *Interpreter,
    gm: *model.Node.tg.Map,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    _ = self; _ = gm; _ = stage; unreachable;
  }

  fn doGenNumeric(
    self: *Interpreter,
    builder: anytype,
    gn: *model.Node.tg.Numeric,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    var seen_poison = false;
    var seen_unfinished = false;
    for ([_]?*model.Node{gn.min, gn.max}) |e, index| if (e) |item| {
      if (
        try self.associate(
          item, self.ctx.types().literal().predef(), stage)
      ) |expr| {
        item.data = .{.expression = expr};
        const value = try self.ctx.evaluator().evaluate(expr);
        switch (value.data) {
          .poison => seen_poison = true,
          .text => |*txt| switch (parse.LiteralNumber.from(txt.content)) {
            .invalid => {
              self.ctx.logger.InvalidNumber(expr.pos, txt.content);
              seen_poison = true;
            },
            .too_large => {
              self.ctx.logger.NumberTooLarge(expr.pos, txt.content);
              seen_poison = true;
            },
            .success => |parsed| switch (index) {
              0 => builder.min(parsed, expr.pos),
              1 => builder.max(parsed, expr.pos),
              else => unreachable,
            },
          },
          else => unreachable,
        }
      } else seen_unfinished = true;
    };
    if (seen_unfinished) {
      builder.abort();
      return null;
    }
    const ret: ?@TypeOf(builder.ret) = if (seen_poison) blk: {
      builder.abort();
      break :blk null;
    } else builder.finish();
    if (ret) |numeric| {
      return try self.ctx.createValueExpr((try self.ctx.values.@"type"(
        gn.node().pos, numeric.typedef())).value());
    } else return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gn.node().pos));
  }

  fn tryGenNumeric(
    self: *Interpreter,
    gn: *model.Node.tg.Numeric,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    // bootstrapping for system.ny
    const needs_local_impl_enum =
      std.mem.eql(u8, ".std.system", gn.node().pos.source.locator.repr);
    if (needs_local_impl_enum and stage.kind == .resolve) {
      if (stage.resolve) |resolver| {
        _ = try resolver.establishLink(self, "NumericImpl");
        _ = try self.tryInterpret(gn.backend, stage);
        if (gn.min) |min| _ = try self.tryInterpret(min, stage);
        if (gn.max) |max| _ = try self.tryInterpret(max, stage);
      }
      return null;
    }

    var is_int = if (needs_local_impl_enum) blk: {
      const val = try self.ctx.evaluator().evaluate(
        try self.interpret(gn.backend));
      switch (val.data) {
        .text => |*txt| {
          if (std.mem.eql(u8, txt.content, "int")) break :blk true;
          if (std.mem.eql(u8, txt.content, "float")) break :blk false;
          self.ctx.logger.UnknownSymbol(val.origin, txt.content);
          return try self.ctx.createValueExpr(
            try self.ctx.values.poison(gn.node().pos));
        },
        .poison => return try self.ctx.createValueExpr(
          try self.ctx.values.poison(gn.node().pos)),
        else => unreachable,
      }
    } else if (
      try self.associate(
        gn.backend, self.ctx.types().system.numeric_impl.predef(), stage)
    ) |backend| switch ((try self.ctx.evaluator().evaluate(backend)).data) {
      .@"enum" => |*backend_val| switch (backend_val.index) {
        0 => true,
        1 => false,
        else => unreachable,
      },
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gn.node().pos)),
      else => unreachable,
    } else return null;

    if (is_int) {
      var ib = try types.IntNumBuilder.init(self.ctx, gn.node().pos);
      return try self.doGenNumeric(&ib, gn, stage);
    } else {
      var fb = try types.FloatNumBuilder.init(self.ctx, gn.node().pos);
      return try self.doGenNumeric(&fb, gn, stage);
    }
  }

  fn tryGenOptional(
    self: *Interpreter,
    go: *model.Node.tg.Optional,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    return self.tryGenUnary(
      "optional", "registerOptional", "InvalidInnerOptionalType", go, stage);
  }

  fn ensureIsType(
    self: *Interpreter,
    expr: *model.Expression,
  ) bool {
    if (
      switch (expr.expected_type) {
        .named => |named| switch (named.data) {
          .poison => return false,
          .@"type" => true,
          else => false,
        },
        .structural => |struc| switch (struc.*) {
          .callable => |*call| call.kind == .type,
          else => false,
        },
      }
    ) return true else {
      self.ctx.logger.ExpectedExprOfTypeXGotY(&.{
        expr.expected_type.at(expr.pos), self.ctx.types().@"type"().predef()
      });
      expr.data = .poison;
      expr.expected_type = self.ctx.types().poison();
      return false;
    }
  }

  fn tryGenSequence(
    self: *Interpreter,
    gs: *model.Node.tg.Sequence,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    var failed_some = false;
    var seen_poison = false;
    for ([_]?*model.Node{gs.direct, gs.auto}) |cur| {
      if (cur) |node| {
        const expr = switch (try self.tryGetType(node, stage)) {
          .finished, .unfinished => |t| try self.ctx.createValueExpr(
            (try self.ctx.values.@"type"(node.pos, t)).value()),
          .expression => |expr| expr,
          .unavailable => {
            failed_some = true;
            continue;
          },
          .failed => {
            seen_poison = true;
            node.data = .poison;
            continue;
          }
        };
        if (!self.ensureIsType(expr)) seen_poison = true;
        node.data = .{.expression = expr};
      }
    }
    const list_type = (try self.ctx.types().list(self.ctx.types().@"type"())).?;
    for (gs.inner) |item| {
      const expr = if (item.direct) blk: {
        if (
          try self.associate(item.node, list_type.predef(), stage)
        ) |expr| break :blk expr;
        failed_some = true;
        continue;
      } else blk: {
        const inner = switch (try self.tryGetType(item.node, stage)) {
          .finished, .unfinished => |t| try self.ctx.createValueExpr(
            (try self.ctx.values.@"type"(item.node.pos, t)).value()),
          .expression => |expr| expr,
          .unavailable => {
            failed_some = true;
            continue;
          },
          .failed => {
            seen_poison = true;
            continue;
          }
        };
        if (!self.ensureIsType(inner)) seen_poison = true;
        break :blk inner;
      };
      item.node.data = .{.expression = expr};
    }

    if (failed_some) return null;
    if (seen_poison) {
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = gs.node().pos,
        .data = .poison,
        .expected_type = self.ctx.types().poison(),
      };
      return expr;
    }
    if (gs.generated) |gen| {
      var builder = types.SequenceBuilder.init(
        self.ctx.types(), self.allocator, true);
      if (gs.direct) |input| {
        const value = try self.ctx.evaluator().evaluate(input.data.expression);
        switch (value.data) {
          .poison => {},
          .@"type" => |tv| {
            const st = tv.t.at(value.origin);
            const res = try builder.push(st, true);
            res.report(st, self.ctx.logger);
          },
          else => unreachable,
        }
      }
      for (gs.inner) |item| {
        const value =
          try self.ctx.evaluator().evaluate(item.node.data.expression);
        switch (value.data) {
          .poison => {},
          .list => |*lst| {
            std.debug.assert(item.direct);
            for (lst.content.items) |inner| {
              const t = inner.data.@"type".t.at(inner.origin);
              const res = try builder.push(t, false);
              res.report(t, self.ctx.logger);
            }
          },
          .@"type" => |tv| {
            std.debug.assert(!item.direct);
            const st = tv.t.at(value.origin);
            const res = try builder.push(st, false);
            res.report(st, self.ctx.logger);
          },
          else => unreachable,
        }
      }
      const auto_t: ?model.SpecType = if (gs.auto) |auto| blk: {
        const value = try self.ctx.evaluator().evaluate(auto.data.expression);
        switch (value.data) {
          .poison => break :blk null,
          .@"type" => |tv| break :blk tv.t.at(auto.pos),
          else => unreachable,
        }
      } else null;
      gen.* =  .{.sequence = undefined};
      const res = try builder.finish(auto_t, &gen.sequence);
      res.report(auto_t, self.ctx.logger);
      return try self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(gs.node().pos, res.t)).value());
    } else {
      var inner = std.ArrayList(model.Expression.Varargs.Item).init(
        self.ctx.global());
      for (gs.inner) |item| {
        try inner.append(
          .{.direct = item.direct, .expr = item.node.data.expression});
      }
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = gs.node().pos,
        .expected_type = self.ctx.types().@"type"(),
        .data = .{.tg_sequence = .{
          .direct = if (gs.direct) |direct| direct.data.expression else null,
          .inner = inner.items,
          .auto = if (gs.auto) |auto| auto.data.expression else null,
        }},
      };
      return expr;
    }
  }

  fn tryGenPrototype(
    self: *Interpreter,
    gp: *model.Node.tg.Prototype,
    stage: Stage,
  ) nyarna.Error!bool {
    if (stage.kind == .resolve) {
      switch (gp.params) {
        .unresolved => |node| _ = try self.tryInterpret(node, stage),
        .resolved => |*res| for (res.locations) |*lref| switch (lref.*) {
          .node => |lnode| _ = try self.tryInterpretLoc(lnode, stage),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      if (gp.constructor) |c| if (try self.tryInterpret(c, stage)) |expr| {
        c.data = .{.expression = expr};
      };
      if (gp.funcs) |funcs| _ = try self.tryInterpret(funcs, stage);
      return false;
    }

    if (!(try self.tryInterpretLocationsList(&gp.params, stage))) return false;
    switch(stage.kind) {
      .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(gp.node().pos),
      else => {}
    }
    return true;
  }

  fn tryGenRecord(
    self: *Interpreter,
    gr: *model.Node.tg.Record,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      switch (gr.fields) {
        .unresolved => |node| _ = try self.tryInterpret(node, stage),
        .resolved => |*res| for (res.locations) |*lref| switch (lref.*) {
          .node => |lnode| _ = try self.tryInterpretLoc(lnode, stage),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      return null;
    }
    var failed_parts = false;
    while (!failed_parts) switch (gr.fields) {
      .unresolved => {
        if (!try self.tryInterpretLocationsList(&gr.fields, stage)) {
          failed_parts = true;
        }
      },
      .resolved => |*res| {
        var finder = (try self.processLocations(&res.locations, stage))
          orelse return null;
        const target = &(gr.generated orelse blk: {
          const named = try self.ctx.global().create(model.Type.Named);
          named.* = .{
            .at = gr.node().pos,
            .name = null,
            .data = .{.record = .{.constructor = undefined}},
          };
          gr.generated = named;
          break :blk named;
        }).data.record;
        const target_type = model.Type{.named = target.named()};
        const finder_res = try finder.finish(target_type, true);
        std.debug.assert(finder_res.found.* == null);
        var b = try types.SigBuilder.init(self.ctx, res.locations.len,
          target_type, finder_res.needs_different_repr);
        for (res.locations) |*loc| switch (loc.*) {
          .node => unreachable,
          .expr => |expr| switch (
            (try self.ctx.evaluator().evaluate(expr)).data
          ) {
            .location => |*lval| {
              loc.* = .{.value = lval};
              try b.push(lval);
            },
            .poison => {},
            else => unreachable,
          },
          .value => |lval| try b.push(lval),
          .poison => {},
        };
        const builder_res = b.finish();
        target.constructor =
          try builder_res.createCallable(self.ctx.global(), .@"type");
        gr.fields = .pregen;
      },
      .pregen => {
        return try self.ctx.createValueExpr(
          (try self.ctx.values.@"type"(gr.node().pos, .{
            .named = gr.generated.?,
          })).value());
      }
    };
    return null;
  }

  fn putIntoCategories(
    val: *model.Value,
    cats: *unicode.CategorySet
  ) bool {
    switch (val.data) {
      .@"enum" => |*e| switch (e.index) {
        0 => cats.include(.Lu),
        1 => cats.include(.Ll),
        2 => cats.include(.Lt),
        3 => cats.include(.Lm),
        4 => cats.include(.Lo),
        5 => cats.includeSet(unicode.Lut),
        6 => cats.includeSet(unicode.LC),
        7 => cats.includeSet(unicode.L),
        8 => cats.include(.Mn),
        9 => cats.include(.Mc),
        10 => cats.include(.Me),
        11 => cats.include(.Nd),
        12 => cats.include(.Nl),
        13 => cats.include(.No),
        14 => cats.includeSet(unicode.M),
        15 => cats.include(.Pc),
        16 => cats.include(.Pd),
        17 => cats.include(.Ps),
        18 => cats.include(.Pe),
        19 => cats.include(.Pi),
        20 => cats.include(.Pf),
        21 => cats.include(.Po),
        22 => cats.includeSet(unicode.P),
        23 => cats.include(.Sm),
        24 => cats.include(.Sc),
        25 => cats.include(.Sk),
        26 => cats.include(.So),
        27 => cats.includeSet(unicode.S),
        28 => cats.includeSet(unicode.MPS),
        29 => cats.include(.Zs),
        30 => cats.include(.Zl),
        31 => cats.include(.Zp),
        32 => cats.include(.Cc),
        33 => cats.include(.Cf),
        34 => cats.include(.Co),
        35 => cats.include(.Cn),
        else => unreachable,
      },
      .poison => return false,
      else => unreachable,
    }
    return true;
  }

  fn tryGenTextual(
    self: *Interpreter,
    gt: *model.Node.tg.Textual,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    // bootstrapping for system.ny
    const needs_local_category_enum =
      std.mem.eql(u8, ".std.system", gt.node().pos.source.locator.repr);
    if (needs_local_category_enum and stage.kind == .resolve) {
      if (stage.resolve) |resolver| {
        _ = try resolver.establishLink(self, "UnicodeCategory");
        for (gt.categories) |cat| _ = try self.tryInterpret(cat.node, stage);
        if (gt.exclude_chars) |ec| _ = try self.tryInterpret(ec, stage);
        if (gt.include_chars) |ic| _ = try self.tryInterpret(ic, stage);
      }
      return null;
    }

    var seen_poison = false;
    var failed_some = false;
    var categories = unicode.CategorySet.empty();

    var unicode_category = if (needs_local_category_enum) blk: {
      if (
        self.namespaces.items[0].data.get("UnicodeCategory")
      ) |sym| {
        switch (sym.data) {
          .@"type" => |t| switch (t) {
            .named => |named| switch (named.data) {
              .@"enum" => |e| {
                if (e.values.count() == 36) break :blk t;
                self.ctx.logger.WrongNumberOfEnumValues(sym.defined_at, "36");
              },
              else =>
                self.ctx.logger.WrongType(sym.defined_at, "should be Enum"),
            },
            else => self.ctx.logger.WrongType(sym.defined_at, "should be Enum"),
          },
          else =>
            self.ctx.logger.ShouldBeType(sym.defined_at, "UnicodeCategory"),
        }
      } else self.ctx.logger.MissingType(gt.node().pos, "UnicodeCategory");
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gt.node().pos));
    } else self.ctx.types().system.unicode_category;

    for (gt.categories) |item| {
      if (item.direct) {
        const expr = (
          try self.associate(item.node,
            (try self.ctx.types().list(unicode_category)).?.predef(), stage)
        ) orelse {
          failed_some = true;
          continue;
        };
        item.node.data = .{.expression = expr};
        const val = try self.ctx.evaluator().evaluate(expr);
        switch (val.data) {
          .list => |*list| for (list.content.items) |inner| {
            if (!putIntoCategories(inner, &categories)) seen_poison = true;
          },
          .poison => seen_poison = true,
          else => unreachable,
        }
      } else {
        const expr = (
          try self.associate(item.node, unicode_category.predef(), stage)
        ) orelse {
          failed_some = true;
          continue;
        };
        item.node.data = .{.expression = expr};
        const val = try self.ctx.evaluator().evaluate(expr);
        if (!putIntoCategories(val, &categories)) seen_poison = true;
      }
    }

    var chars = [2]std.hash_map.AutoHashMapUnmanaged(u21, void){.{}, .{}};
    for ([_]?*model.Node{gt.include_chars, gt.exclude_chars}) |item, index| {
      if (item) |node| {
        if (
          try self.associate(node, self.ctx.types().literal().predef(), stage)
        ) |expr| {
          node.data = .{.expression = expr};
          const val = try self.ctx.evaluator().evaluate(expr);
          switch (val.data) {
            .text => |*txt| {
              var iter = std.unicode.Utf8Iterator{.bytes = txt.content, .i = 0};
              while (iter.nextCodepoint()) |code_point| {
                try chars[index].put(self.ctx.global(), code_point, .{});
              }
            },
            .poison => seen_poison = true,
            else => unreachable,
          }
        } else failed_some = true;
      }
    }

    if (failed_some) {
      for (chars) |*map| map.clearAndFree(self.ctx.global());
      return null;
    }
    if (seen_poison) {
      for (chars) |*map| map.clearAndFree(self.ctx.global());
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gt.node().pos));
    }

    if (categories.content == 0 and chars[0].count() == 0) {
      categories = unicode.CategorySet.all();
    }

    const named = try self.ctx.global().create(model.Type.Named);
    named.* = .{
      .at = gt.node().pos,
      .name = null,
      .data = .{.textual = .{
        .include = .{
          .chars = chars[0],
          .categories = categories,
        },
        .exclude = chars[1],
      }},
    };

    return try self.ctx.createValueExpr((try self.ctx.values.@"type"(
      named.at, model.Type{.named = named})).value());
  }

  fn tryGenUnique(
    self: *Interpreter,
    gu: *model.Node.tg.Unique,
    stage: Stage,
  ) void {
    switch (stage.kind) {
      .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(gu.node().pos),
      else => {}
    }
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
  pub fn tryInterpret(
    self: *Interpreter,
    input: *model.Node,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    return switch (input.data) {
      .assign => |*ass| self.tryInterpretAss(ass, stage),
      .branches => |*branches| if (stage.kind == .resolve) {
        _ = try self.tryInterpret(branches.condition, stage);
        for (branches.branches) |branch| {
          _ = try self.tryInterpret(branch, stage);
        }
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .builtingen => |*bg| {
        _ = try self.tryInterpretBuiltin(bg, stage);
        return null;
      },
      .concat => |*concat| if (stage.kind == .resolve) {
        for (concat.items) |item| _ = try self.tryInterpret(item, stage);
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .seq => |*seq| if (stage.kind == .resolve) {
        for (seq.items) |p| _ = try self.tryInterpret(p.content, stage);
        return null;
      } else self.tryProbeAndInterpret(input, stage),
      .definition => |*def| self.tryInterpretDef(def, stage),
      .expression => |expr| {
        if (stage.kind == .resolve) switch (expr.data) {
          .value => |value| switch (value.data) {
            .ast => |*ast| _ = try self.tryInterpret(ast.root, stage),
            else => {},
          },
          else => {},
        };
        return expr;
      },
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
          (try self.ctx.values.textScalar(
             input.pos, if (lit.kind == .space) self.ctx.types().space()
                        else self.ctx.types().literal(),
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
      .gen_sequence      => |*gp| self.tryGenSequence(gp, stage),
      .gen_prototype     => |*gp| {
        _ = try self.tryGenPrototype(gp, stage);
        return null;
      },
      .gen_record        => |*gr| self.tryGenRecord(gr, stage),
      .gen_textual       => |*gt| self.tryGenTextual(gt, stage),
      .gen_unique        => |*gu| {
        self.tryGenUnique(gu, stage);
        return null;
      },
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
          .expected_type =
            if (input.data == .void) self.ctx.types().void()
            else self.ctx.types().poison(),
        };
        return expr;
      },
    };
  }

  pub fn interpret(
    self : *Interpreter,
    input: *model.Node,
  ) nyarna.Error!*model.Expression {
    return if (try self.tryInterpret(input, .{.kind = .final})) |expr| expr
    else try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos));
  }

  pub fn interpretAs(
    self : *Interpreter,
    input: *model.Node,
    item : model.SpecType,
  ) nyarna.Error!*model.Expression {
    return if (try self.associate(input, item, .{.kind = .final})) |expr| expr
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
  fn probeNodeList(
    self: *Interpreter,
    nodes: []*model.Node,
    stage: Stage,
    sloppy: bool,
  ) !?model.Type {
    std.debug.assert(stage.kind != .resolve);
    var sup: model.Type = self.ctx.types().every();
    var already_poison = false;
    var seen_unfinished = false;
    for (nodes) |node, i| {
      const t = (try self.probeType(node, stage, sloppy)) orelse {
        seen_unfinished = true;
        continue;
      };
      if (t.isNamed(.poison)) {
        already_poison = true;
        continue;
      }
      const new = try self.ctx.types().sup(sup, t);
      if (new.isNamed(.poison)) {
        already_poison = true;
        var found = false;
        for (nodes[0..i]) |prev| {
          const prev_t = (try self.probeType(node, stage, sloppy)) orelse {
            seen_unfinished = true;
            continue;
          };
          if (prev_t.isNamed(.poison)) continue;
          if ((try self.ctx.types().sup(t, prev_t)).isNamed(.poison)) {
            found = true;
            self.ctx.logger.IncompatibleTypes(&.{
              t.at(node.pos), prev_t.at(prev.pos),
            });
            break;
          }
        }
        if (!found) {
          const pos = nodes[0].pos.span(nodes[i - 1].pos);
          self.ctx.logger.IncompatibleTypes(&.{t.at(node.pos), sup.at(pos)});
        }
      } else sup = new;
    }
    if (already_poison) {
      // we could not set nodes to .poison directly before, so that we could
      // issue correct error messages. but we do it now so that the issues will
      // not be reported again.
      sup = self.ctx.types().every();
      for (nodes) |node| {
        const t = (try self.probeType(node, stage, sloppy)) orelse continue;
        const new = try self.ctx.types().sup(sup, t);
        if (new.isNamed(.poison)) node.data = .poison else sup = new;
      }
    }

    return if (seen_unfinished) null
    else if (already_poison) self.ctx.types().poison()
    else sup;
  }

  /// Calculate the supremum of all scalar types in the given node's types.
  /// considered are direct scalar types, as well as scalar types in
  /// concatenations, optionals and paragraphs.
  ///
  /// returns null only in the event of unfinished nodes.
  fn probeForScalarType(
    self: *Interpreter,
    input: *model.Node,
    stage: Stage,
  ) !?model.Type {
    std.debug.assert(stage.kind != .resolve);
    const t = (try self.probeType(input, stage, true)) orelse return null;
    return types.containedScalar(t) orelse self.ctx.types().every();
  }

  fn typeFromSymbol(self: *Interpreter, sym: *model.Symbol) !model.Type {
    const callable = switch (sym.data) {
      .func => |f| f.callable,
      .variable => |v| return v.spec.t,
      .@"type" => |t| return try self.ctx.types().typeType(t),
      .prototype => |pt| return switch (pt) {
        .record =>
          self.ctx.types().constructors.prototypes.record.callable.?.typedef(),
        .concat =>
          self.ctx.types().constructors.prototypes.concat.callable.?.typedef(),
        .list =>
          self.ctx.types().constructors.prototypes.list.callable.?.typedef(),
        else => self.ctx.types().prototype(),
      },
      .poison => return self.ctx.types().poison(),
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
  pub fn probeType(
    self: *Interpreter,
    node: *model.Node,
    stage: Stage,
    sloppy: bool,
  ) nyarna.Error!?model.Type {
    switch (node.data) {
      .gen_concat, .gen_enum, .gen_float, .gen_intersection, .gen_list,
      .gen_map, .gen_numeric, .gen_optional, .gen_sequence, .gen_record,
      .gen_textual, .gen_unique => if (sloppy) return self.ctx.types().@"type"()
        else if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null,
      .assign, .builtingen, .import, .funcgen, .vt_setter => {
        if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
      .branches => |br|
        return try self.probeNodeList(br.branches, stage, sloppy),
      .concat => |con| {
        var inner =
          (try self.probeNodeList(con.items, stage, sloppy)) orelse return null;
        if (!inner.isNamed(.poison)) {
          inner = (try self.ctx.types().concat(inner)) orelse blk: {
            self.ctx.logger.InvalidInnerConcatType(&.{inner.at(node.pos)});
            break :blk self.ctx.types().poison();
          };
        }
        if (inner.isNamed(.poison)) {
          node.data = .poison;
        }
        return inner;
      },
      .definition => return self.ctx.types().definition(),
      .expression => |e| return e.expected_type,
      .gen_prototype => return self.ctx.types().prototype(),
      .literal => |l| if (l.kind == .space) return self.ctx.types().space()
                      else return self.ctx.types().literal(),
      .location => return self.ctx.types().location(),
      .seq => |*seq| {
        var builder = nyarna.types.SequenceBuilder.init(
          self.ctx.types(), self.allocator, false);
        var seen_unfinished = false;
        for (seq.items) |*item| {
          if (try self.probeType(item.content, stage, sloppy)) |t| {
            const st = t.at(item.content.pos);
            const res = try builder.push(st, false);
            if (res != .success) {
              item.content.data = .poison;
              res.report(st, self.ctx.logger);
            }
          } else seen_unfinished = true;
        }
        return
          if (seen_unfinished) null else (try builder.finish(null, null)).t;
      },
      .resolved_access => |*ra| {
        var t = (try self.probeType(ra.base, stage, sloppy)).?;
        for (ra.path) |index| t = types.descend(t, index);
        return t;
      },
      .resolved_call => |*rc| {
        if (rc.sig.returns.isNamed(.ast)) {
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
          return try self.probeType(node, stage, sloppy);
        } else return rc.sig.returns;
      },
      .resolved_symref => |*ref| return try self.typeFromSymbol(ref.sym),
      .unresolved_access, .unresolved_call, .unresolved_symref => {
        return switch (try chains.Resolver.init(self, stage).resolve(node)) {
          .runtime_chain => |*rc| rc.t,
          .sym_ref => |*sr| try self.typeFromSymbol(sr.sym),
          .failed, .function_returning => null,
          .poison => blk: {
            node.data = .poison;
            break :blk self.ctx.types().poison();
          },
        };
      },
      .varargs => |*varargs| return varargs.t,
      .void => return self.ctx.types().void(),
      .poison => return self.ctx.types().poison(),
    }
  }

  pub inline fn genValueNode(
    self: *Interpreter,
    content: *model.Value,
  ) !*model.Node {
    return try self.node_gen.expression(try self.ctx.createValueExpr(content));
  }

  fn createTextLiteral(
    self: *Interpreter,
    l: *model.Node.Literal,
    spec: model.SpecType,
  ) nyarna.Error!*model.Value {
    switch (spec.t) {
      .structural => |struc| return switch (struc.*) {
        .optional => |*op|
          try self.createTextLiteral(l, op.inner.at(spec.pos)),
        .concat => |*con|
          try self.createTextLiteral(l, con.inner.at(spec.pos)),
        .sequence => |*seq| blk: {
          if (seq.direct) |direct| {
            if (types.containedScalar(direct)) |scalar| {
              break :blk try self.createTextLiteral(l, scalar.at(spec.pos));
            }
          }
          const lt = self.ctx.types().litType(l);
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            &.{lt.at(l.node().pos), spec});
          break :blk self.ctx.values.poison(l.node().pos);
        },
        .list, .map, .callable => blk: {
          const lt = self.ctx.types().litType(l);
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            &.{lt.at(l.node().pos), spec});
          break :blk try self.ctx.values.poison(l.node().pos);
        },
        .intersection => |*inter| if (inter.scalar) |scalar| {
          return try self.createTextLiteral(l, scalar.at(spec.pos));
        } else {
          const lt = self.ctx.types().litType(l);
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            &.{lt.at(l.node().pos), spec});
          return try self.ctx.values.poison(l.node().pos);
        }
      },
      .named => |ti| switch (ti.data) {
        .textual => |*txt| return if (
          try self.ctx.textFromString(
            l.node().pos, try self.ctx.global().dupe(u8, l.content), txt)
        ) |scalar| scalar.value() else try self.ctx.values.poison(l.node().pos),
        .int => |*n| {
          return if (
            try self.ctx.intFromText(l.node().pos, l.content, n)
          ) |nv| nv.value()
          else try self.ctx.values.poison(l.node().pos);
        },
        .float => |*fl| return if (
          try self.ctx.floatFromText(l.node().pos, l.content, fl)
        ) |float| float.value() else try self.ctx.values.poison(l.node().pos),
        .@"enum" => |*e| {
          return if (try self.ctx.enumFrom(l.node().pos, l.content, e)) |ev|
            ev.value() else try self.ctx.values.poison(l.node().pos);
        },
        .record => {
          const lt = self.ctx.types().litType(l);
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            &.{lt.at(l.node().pos), spec});
          return self.ctx.values.poison(l.node().pos);
        },
        .space => if (l.kind == .space) {
          return (try self.ctx.values.textScalar(
            l.node().pos, spec.t, try self.ctx.global().dupe(u8, l.content))
          ).value();
        } else {
          const lt = self.ctx.types().literal();
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            &.{lt.at(l.node().pos), spec});
          return self.ctx.values.poison(l.node().pos);
        },
        .literal => return (try self.ctx.values.textScalar(
          l.node().pos, spec.t, try self.ctx.global().dupe(u8, l.content)
        )).value(),
        else => return (try self.ctx.values.textScalar(
          l.node().pos,
          if (l.kind == .text) self.ctx.types().literal()
          else self.ctx.types().space(),
          try self.ctx.global().dupe(u8, l.content)
        )).value(),
      },
    }
  }

  fn probeCheckOrPoison(
    self: *Interpreter,
    input: *model.Node,
    t: model.Type,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve);
    var actual_type = (
      try self.probeType(input, stage, false)
    ) orelse return null;
    if (
      !actual_type == .poison and
      !self.ctx.types().lesserEqual(actual_type, t)
    ) {
      actual_type = .poison;
      self.ctx.logger.ExpectedExprOfTypeXGotY(
        input.pos, &[_]model.Type{t, actual_type});
    }
    return if (actual_type == .poison)
      try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos))
    else null;
  }

  /// removes any .space type from concats and paragraphs within t and t itself
  fn typeWithoutSpace(
    self: *Interpreter,
    t: model.Type,
  ) std.mem.Allocator.Error!model.Type {
    return switch (t) {
      .structural => |struc| switch (struc.*) {
        .concat   => |*con|
          (try self.ctx.types().concat(try self.typeWithoutSpace(con.inner))).?,
        .optional => |*opt| (
          try self.ctx.types().optional(try self.typeWithoutSpace(opt.inner))
        ).?,
        .sequence => |*seq| blk: {
          if (seq.direct) |direct| {
            const dws = try self.typeWithoutSpace(direct);
            if (dws.eql(direct)) break :blk t;
            return try self.ctx.types().calcSequence(dws, seq.inner);
          }
          break :blk t;
        },
        else => return t,
      },
      .named => t,
    };
  }

  fn mixIfCompatible(
    self: *Interpreter,
    target: *model.Type,
    add: model.Type,
    exprs: []*model.Expression,
    index: usize,
  ) !bool {
    if (add.isNamed(.poison)) return false;
    const new = try self.ctx.types().sup(target.*, add);
    if (new.isNamed(.poison)) {
      for (exprs[0..index]) |prev| {
        const mixed =
          try self.ctx.types().sup(prev.expected_type, add);
        if (mixed.isNamed(.poison)) {
          const expr = exprs[index];
          self.ctx.logger.IncompatibleTypes(&.{
            expr.expected_type.at(expr.pos), prev.expected_type.at(prev.pos),
          });
          return false;
        }
      }
      unreachable;
    }
    target.* = new;
    return true;
  }

  /// Same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals. The target type *must* be a
  /// scalar type or .void, in which case .space literals will be removed.
  pub fn interpretWithTargetScalar(
    self: *Interpreter,
    input: *model.Node,
    spec: model.SpecType,
    stage: Stage,
  ) nyarna.Error!?*model.Expression {
    std.debug.assert(stage.kind != .resolve);
    std.debug.assert(switch (spec.t) {
      .structural => false,
      .named => |named| switch (named.data) {
        .textual, .int, .float, .@"enum", .literal, .space, .every, .void =>
          true,
        else => false,
      },
    });
    switch (input.data) {
      .assign, .builtingen, .definition, .funcgen, .import, .location,
      .resolved_access, .resolved_symref, .resolved_call, .gen_concat,
      .gen_enum, .gen_float, .gen_intersection, .gen_list, .gen_map,
      .gen_numeric, .gen_optional, .gen_sequence, .gen_prototype, .gen_record,
      .gen_textual, .gen_unique, .unresolved_access, .unresolved_call,
      .unresolved_symref, .varargs => {
        if (try self.tryInterpret(input, stage)) |expr| {
          if (types.containedScalar(expr.expected_type)) |scalar_type| {
            if (self.ctx.types().lesserEqual(scalar_type, spec.t)) return expr;
            if (expr.expected_type.isNamed(.space) and spec.t.isNamed(.void)) {
              const target_type =
                try self.typeWithoutSpace(expr.expected_type);
              const conv = try self.ctx.global().create(model.Expression);
              conv.* = .{
                .pos = expr.pos,
                .expected_type = target_type,
                .data = .{.conversion = .{
                  .inner = expr,
                  .target_type = target_type,
                }},
              };
              return conv;
            }
            self.ctx.logger.ScalarTypesMismatch(
              &.{scalar_type.at(input.pos), spec});
            expr.data = .{.value = try self.ctx.values.poison(input.pos)};
          }
          return expr;
        }
        return null;
      },
      .branches => |br| {
        const condition = cblk: {
          if (br.cond_type) |ct| {
            if (
              try self.interpretWithTargetScalar(
                br.condition, ct.predef(), stage)
            ) |expr| break :cblk expr
            else return null;
          } else {
            const expr = (
              try self.tryInterpret(br.condition, stage)
            ) orelse return null;
            if (expr.expected_type.isNamed(.@"enum")) {
              break :cblk expr;
            } else if (!expr.expected_type.isNamed(.poison)) {
              self.ctx.logger.CannotBranchOn(
                &.{expr.expected_type.at(br.condition.pos)});
            }
            return try
              self.ctx.createValueExpr(try self.ctx.values.poison(input.pos));
          }
        };
        var seen_unfinished = false;
        for (br.branches) |item| {
          if (try self.interpretWithTargetScalar(item, spec, stage)) |expr| {
            item.data = .{.expression = expr};
          } else seen_unfinished = true;
        }
        if (seen_unfinished) return null;
        const exprs =
          try self.ctx.global().alloc(*model.Expression, br.branches.len);
        var actual_type = self.ctx.types().every();
        var seen_poison = false;
        for (br.branches) |item, i| {
          exprs[i] = item.data.expression;
          if (
            !(try self.mixIfCompatible(
              &actual_type, exprs[i].expected_type, exprs, i))
          ) seen_poison = true;
        }
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = if (seen_poison) .poison else .{
            .branches = .{.condition = condition, .branches = exprs}
          },
          .expected_type =
            if (seen_poison) self.ctx.types().poison() else actual_type,
        };
        return expr;
      },
      .concat => |con| {
        // force non-concatenable scalars to coerce to Raw
        const inner_scalar = switch (spec.t) {
          .named => |named| switch (named.data) {
            .@"enum", .int, .float => self.ctx.types().text().at(spec.pos),
            else => spec,
          },
          .structural => unreachable,
        };

        var failed_some = false;
        for (con.items) |item| {
          if (
            try self.interpretWithTargetScalar(item, inner_scalar, stage)
          ) |expr| {
            item.data = .{.expression = expr};
          } else failed_some = true;
        }
        if (failed_some) return null;
        const exprs = try self.ctx.global().alloc(
          *model.Expression, con.items.len);
        var inner_type = self.ctx.types().every();
        var seen_sequence = false;
        var seen_poison = false;
        for (con.items) |item, i| {
          const expr = item.data.expression;
          exprs[i] = expr;
          if (
            switch (expr.expected_type) {
              .structural => |struc| switch (struc.*) {
                .sequence => |*sec| blk: {
                  seen_sequence = true;
                  var already_poison = false;
                  if (sec.direct) |direct| {
                    if (
                      !(try self.mixIfCompatible(&inner_type, direct, exprs, i))
                    ) {
                      seen_poison = true;
                      already_poison = true;
                    }
                  }
                  if (!already_poison) for (sec.inner) |inner| {
                    if (
                      !(try self.mixIfCompatible(
                        &inner_type, inner.typedef(), exprs, i))
                    ) {
                      seen_poison = true;
                      already_poison = true;
                      break;
                    }
                  };
                  if (!already_poison) {
                    if (
                      !(try self.mixIfCompatible(
                        &inner_type, self.ctx.types().space(), exprs, i))
                    ) {
                      seen_poison = true;
                    }
                  }
                  break :blk false;
                },
                else => true,
              },
              else => true,
            }
          ) {
            if (
              !(try self.mixIfCompatible(
                &inner_type, expr.expected_type, exprs, i))
            ) seen_poison = true;
          }
        }
        const expr = try self.ctx.global().create(model.Expression);
        const expr_type =
          if (seen_poison) null else try self.ctx.types().concat(inner_type);
        if (expr_type) |target_type| {
          if (seen_sequence) {
            for (exprs) |*item| {
              if (item.*.expected_type.isStruc(.sequence)) {
                const conv = try self.ctx.global().create(model.Expression);
                conv.* = .{
                  .pos = item.*.pos,
                  .data = .{.conversion = .{
                    .inner = item.*,
                    .target_type = target_type,
                  }},
                  .expected_type = target_type,
                };
                item.* = conv;
              }
            }
          }
          expr.* = .{
            .pos = input.pos,
            .data = .{.concatenation = exprs},
            .expected_type = target_type,
          };
          return expr;
        } else {
          if (!seen_poison) {
            self.ctx.logger.InvalidInnerConcatType(
              &.{inner_type.at(input.pos)});
          }
          expr.* = .{
            .pos = input.pos,
            .data = .poison,
            .expected_type = self.ctx.types().poison(),
          };
          return expr;
        }
      },
      .expression => |expr| return expr,
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| {
        if (spec.t.isNamed(.void)) return try self.ctx.createValueExpr(
          try self.ctx.values.void(input.pos));
        const expr = try self.ctx.global().create(model.Expression);
        expr.pos = input.pos;
        expr.data = .{.value = try self.createTextLiteral(l, spec)};
        expr.expected_type = spec.t;
        return expr;
      },
      .seq => |*seq| {
        var seen_unfinished = false;
        for (seq.items) |item| {
          const res = try self.probeType(item.content, stage, false);
          if (res == null) seen_unfinished = true;
        }
        if (seen_unfinished) return null;
        var builder = types.SequenceBuilder.init(
          self.ctx.types(), self.allocator, false);
        const res = try self.ctx.global().alloc(
          model.Expression.Paragraph, seq.items.len);
        var next: usize = 0;
        for (seq.items) |item| {
          var para_type = (try self.probeType(item.content, stage, false)).?;
          var stype = spec;
          if (types.containedScalar(para_type)) |contained| {
            if (contained.isNamed(.space)) {
              stype = self.ctx.types().@"void"().at(spec.pos);
              para_type = try self.typeWithoutSpace(para_type);
            }
          }
          const pst = para_type.at(item.content.pos);
          const bres = try builder.push(pst, false);
          if (bres == .success) {
            res[next] = .{
              .content = (try self.interpretWithTargetScalar(
                item.content, stype, stage)).?,
              .lf_after = item.lf_after,
            };
            next += 1;
          } else {
            bres.report(pst, self.ctx.logger);
          }
        }
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.sequence = res[0..next]},
          .expected_type = (try builder.finish(null, null)).t,
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
    self : *Interpreter,
    node : *model.Node,
    item : model.SpecType,
    stage: Stage,
  ) !?*model.Expression {
    const scalar_type = types.containedScalar(item.t) orelse
      (try self.probeForScalarType(node, stage)) orelse return null;

    return if (
      try self.interpretWithTargetScalar(node, scalar_type.predef(), stage)
    ) |expr| blk: {
      if (expr.expected_type.isNamed(.poison)) break :blk expr;
      if (self.ctx.types().lesserEqual(expr.expected_type, item.t)) {
        expr.expected_type = item.t;
        break :blk expr;
      }
      if (self.ctx.types().convertible(expr.expected_type, item.t)) {
        const conv = try self.ctx.global().create(model.Expression);
        conv.* = .{
          .pos = expr.pos,
          .data = .{.conversion = .{
            .inner = expr,
            .target_type = item.t,
          }},
          .expected_type = item.t,
        };
        break :blk conv;
      } else {
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{expr.expected_type.at(node.pos), item});
        expr.data = .{.value = try self.ctx.values.poison(expr.pos)};
        expr.expected_type = self.ctx.types().poison();
        break :blk expr;
      }
    } else null;
  }
};