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
    const res = try self.data.getOrPut(intpr.allocator(), sym.name);
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
  /// The source that is being parsed. Must not be changed during an
  /// interpreter's operation.
  input: *const model.Source,
  /// Context of the ModuleLoader that owns this interpreter.
  ctx: nyarna.Context,
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer uses this to check whether a character is a command
  /// character; the namespace mapping is relevant later for the interpreter.
  /// The values are indexes into the namespaces field.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15),
  /// Used when disabling all command characters. Will be swapped with
  /// command_characters until the block disabling the command characters ends.
  stored_command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15) = .{},
  /// Internal namespaces in the source file (see 6.1).
  /// A namespace will not be deleted when it goes out of scope, so that we do
  /// not need to apply special care for delayed resolution of symrefs:
  /// If a symref cannot initially be resolved to a symbol, it will be stored
  /// with namespace index and target name. Since namespaces are never deleted,
  // it will still try to find its target symbol in the same namespace when
  /// delayed resolution is triggered.
  namespaces: std.ArrayListUnmanaged(Namespace),
  /// The local storage of the interpreter where all data will be allocated that
  /// will be discarded when the interpreter finishes. This includes primarily
  /// the AST nodes which will be interpreted into expressions during
  /// interpretation. Some AST nodes may become exported (for example, as part
  /// of a function implementation) in which case they must be copied to the
  /// global storage. This happens exactly at the time an AST node is put into
  /// an AST model.Value.
  storage: std.heap.ArenaAllocator,
  /// Array of alternative syntaxes known to the interpreter (7.12).
  /// TODO: make this user-extensible
  syntax_registry: [2]syntaxes.SpecialSyntax,
  /// convenience object to generate nodes using the interpreter's storage.
  node_gen: model.NodeGenerator,

  pub fn create(ctx: nyarna.Context,
                input: *const model.Source) !*Interpreter {
    var arena = std.heap.ArenaAllocator.init(ctx.local());
    var ret = try arena.allocator().create(Interpreter);
    ret.* = .{
      .input = input,
      .ctx = ctx,
      .storage = arena,
      .command_characters = .{},
      .namespaces = .{},
      .syntax_registry = .{syntaxes.SymbolDefs.locations(),
                           syntaxes.SymbolDefs.definitions()},
      .node_gen = undefined,
    };
    ret.node_gen = model.NodeGenerator.init(ret.allocator());
    errdefer ret.deinit();
    try ret.addNamespace('\\');
    return ret;
  }

  /// discards the internal storage for AST nodes.
  pub fn deinit(self: *Interpreter) void {
    // self.storage is inside the deallocated memory so we must copy it, else
    // we would need to run into use-after-free.
    var storage = self.storage;
    storage.deinit();
  }

  /// returns the allocator for interpreter-local storage, i.e. values that
  /// are to go out of scope when the interpreter has finished parsing a source.
  ///
  /// use Interpreter.node_gen for generating nodes that use this allocator.
  pub inline fn allocator(self: *Interpreter) std.mem.Allocator {
    return self.storage.allocator();
  }

  pub fn addNamespace(self: *Interpreter, character: u21) !void {
    const index = self.namespaces.items.len;
    if (index > std.math.maxInt(u16)) return nyarna.Error.too_many_namespaces;
    try self.command_characters.put(
      self.allocator(), character, @intCast(u15, index));
    try self.namespaces.append(self.allocator(), .{});
    // intrinsic symbols of every namespace.
    try self.importModuleSyms(self.ctx.data.intrinsics, @intCast(u15, index));
  }

  pub inline fn namespace(self: *Interpreter, ns: u15) *Namespace {
    return &self.namespaces.items[ns];
  }

  pub fn importModuleSyms(self: *Interpreter, module: *const model.Module,
                          ns_index: u15) !void {
    const ns = self.namespace(ns_index);
    for (module.symbols) |sym| _ = try ns.tryRegister(self, sym);
  }

  pub fn removeNamespace(self: *Interpreter, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  fn tryInterpretAccess(self: *Interpreter, input: *model.Node, stage: Stage)
      nyarna.Error!?*model.Expression {
    if (stage.kind == .resolve) {
      _ = try self.tryInterpret(input.data.access.subject, stage);
      return null;
    }
    switch (try chains.Resolver.init(self, stage).resolve(input)) {
      .var_chain => |vc| {
        const retr = try self.ctx.global().create(model.Expression);
        retr.* = .{
          .pos = vc.target.pos,
          .data = .{.var_retrieval = .{.variable = vc.target.variable}},
          .expected_type = vc.target.variable.t,
        };
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .access = .{.subject = retr, .path = vc.field_chain.items},
          },
          .expected_type = vc.t,
        };
        return expr;
      },
      .func_ref => |ref| {
        return try self.ctx.createValueExpr(
          if (ref.prefix != null) blk: {
            self.ctx.logger.PrefixedFunctionMustBeCalled(input.pos);
            break :blk try self.ctx.values.poison(input.pos);
          } else (try self.ctx.values.funcRef(input.pos, ref.target)).value());
      },
      .type_ref => |ref| return self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(input.pos, ref.*)).value()),
      .proto_ref => |ref| return self.ctx.createValueExpr(
        (try self.ctx.values.prototype(input.pos, ref.*)).value()),
      .expr_chain => |ec| {
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .access = .{.subject = ec.expr, .path = ec.field_chain.items},
          },
          .expected_type = ec.t,
        };
        return expr;
      },
      .failed => return null,
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(input.pos)),
    }
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
          .var_chain => |*vc| {
            ass.target = .{
              .resolved = .{
                .target = vc.target.variable,
                .path = vc.field_chain.items,
                .t = vc.t,
              },
            };
            break :innerblk &ass.target.resolved;
          },
          .func_ref, .type_ref, .proto_ref, .expr_chain => {
            self.ctx.logger.InvalidLvalue(node.pos);
            return self.ctx.createValueExpr(
              try self.ctx.values.poison(ass.node().pos));
          },
          .poison => {
            return self.ctx.createValueExpr(
              try self.ctx.values.poison(ass.node().pos));
          },
          .failed => return null,
        }
      }
    };
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

  fn tryInterpretSymref(self: *Interpreter, ref: *model.Node.ResolvedSymref)
      nyarna.Error!*model.Expression {
    switch (ref.sym.data) {
      .func => |func| return self.ctx.createValueExpr(
        (try self.ctx.values.funcRef(ref.node().pos, func)).value()),
      .variable => |*v| {
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
    if (stage.kind == .resolve) return null;
    const sig = switch (rc.target.expected_type) {
      .intrinsic  => |intr| std.debug.panic(
        "call target has unexpected type {s}", .{@tagName(intr)}),
      .structural => |strct| switch (strct.*) {
        .callable => |*c| c.sig,
        else => std.debug.panic(
          "call target has unexpected type: {s}", .{@tagName(strct.*)}),
      },
      .instantiated => |inst| std.debug.panic(
        "call target has unexpected type: {s}", .{@tagName(inst.data)}),
    };
    const is_keyword = sig.returns.is(.ast_node);
    const cur_allocator = if (is_keyword) self.allocator()
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
          if (try self.associate(arg.*, sig.parameters[i].ptype, arg_stage)) |e|
            .{.expression = e}
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
      *model.Expression, sig.parameters.len);
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
          .target = rc.target,
          .exprs = args,
        },
      },
      .expected_type = sig.returns,
    };
    if (is_keyword) {
      var eval = self.ctx.evaluator();
      const res = try eval.evaluateKeywordCall(self, &expr.data.call);
      const interpreted_res = try self.tryInterpret(res, stage);
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
          if (expr.data.value.data == .poison) return;
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
      self: *Interpreter, func: *model.Node.Funcgen, stage: Stage) !bool {
    if (!(try self.locationsCanGenVars(func.params.unresolved, stage))) {
      return false;
    }
    var locs = std.ArrayList(model.Node.Funcgen.LocRef).init(self.allocator());
    try self.collectLocations(func.params.unresolved, &locs);
    var variables =
      try self.allocator().alloc(*model.Symbol.Variable, locs.items.len);
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
            },
          },
        },
        .value => |vl| .{
          .defined_at = vl.name.value().origin,
          .name = vl.name.content,
          .data = .{.variable = .{.t = vl.tloc}},
        },
      };
      variables[index] = &sym.data.variable;
    }
    func.params = .{
      .resolved = .{
        .locations = locs.items,
        .variables = variables,
      },
    };
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
      .unresolved => if (!try self.tryInterpretFuncParams(func, stage))
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
        .ny = .{
          .variables = func.params.resolved.variables,
          .body = undefined,
        },
      },
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
        orelse return null;
      const ny = &ret.data.ny;
      ny.body = (try self.tryInterpretFuncBody(
        func, returns, stage)) orelse return null;
      return ret;
    } else {
      switch (func.params) {
        .unresolved => if (!try self.tryInterpretFuncParams(func, stage))
          return null,
        else => {},
      }
      const body_expr = (try self.tryInterpretFuncBody(func, null, stage))
        orelse return null;
      const ret = (try self.tryPregenFunc(
        func, body_expr.expected_type, stage)).?;
      ret.data.ny.body = body_expr;
      return ret;
    }
  }

  fn tryInterpretUCall(self: *Interpreter, uc: *model.Node.UnresolvedCall,
                       stage: Stage) nyarna.Error!?*model.Expression {
    if (stage.kind == .intermediate) return null;
    const call_ctx = try chains.CallContext.fromChain(self, uc.target.pos,
      try chains.Resolver.init(self, stage).resolve(uc.target));
    switch (call_ctx) {
      .known => |k| {
        var sm = try mapper.SignatureMapper.init(
          self, k.target, k.ns, k.signature);
        if (k.first_arg) |prefix| {
          if (sm.mapper.map(prefix.pos, .position, .flow)) |cursor| {
            try sm.mapper.push(cursor, prefix);
          }
        }
        for (uc.proto_args) |*arg, index| {
          const flag: mapper.Mapper.ProtoArgFlag = flag: {
            if (index < uc.first_block_arg) break :flag .flow;
            if (arg.had_explicit_block_config) break :flag .block_with_config;
            break :flag .block_no_config;
          };
          if (sm.mapper.map(arg.content.pos, arg.kind, flag)) |cursor| {
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
  fn tryInterpretURef(self: *Interpreter, us: *model.Node.UnresolvedSymref,
                      stage: Stage) nyarna.Error!?*model.Expression {
    const ns = self.namespace(us.ns);
    if (ns.data.get(us.name)) |sym| {
      const input = us.node();
      input.data = .{.resolved_symref = .{.ns = us.ns, .sym = sym}};
      return self.tryInterpret(input, stage);
    } else switch (stage.kind) {
      .intermediate, .resolve => {},
      .assumed => unreachable,
      .keyword => self.ctx.logger.CannotResolveImmediately(us.node().pos),
      .final => self.ctx.logger.UnknownSymbol(us.node().pos),
    }
    return null;
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
        var expr = (try self.tryInterpretURef(usym, stage))
          orelse if (stage.resolve) |r|
            switch (try r.probeSibling(self.allocator(), node)) {
              .unfinished_function => {
                self.ctx.logger.CantCallUnfinished(node.pos);
                return TypeResult.failed;
              },
              .unfinished_type => |t| return TypeResult{.unfinished = t},
              .known => return TypeResult.unavailable,
              .failed => {
                self.ctx.logger.UnknownSymbol(node.pos);
                return TypeResult.failed;
              },
              .variable => |v| return TypeResult{.finished = v.t},
            } else return TypeResult.unavailable;
        break try self.ctx.evaluator().evaluate(expr);
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

  fn tryGenIntersection(
      self: *Interpreter, gi: *model.Node.tg.Intersection, stage: Stage)
      nyarna.Error!?*model.Expression {
    var scalar: ?struct {
      pos: model.Position,
      t: model.Type,
    } = null;
    var builder = try types.IntersectionTypeBuilder.init(
      gi.types.len + 1, self.allocator());
    var failed_some = false;
    var poison = false;
    for (gi.types) |node| {
      var unfinished_other_inter = false;
      const inner = switch (try self.tryGetType(node, stage)) {
        .finished => |t| t,
        .unfinished => |t| blk: {
          unfinished_other_inter = t.isStructural(.intersection);
          break :blk t;
        },
        .unavailable => {
          failed_some = true;
          continue;
        },
        .failed => {
          poison = true;
          continue;
        },
      };
      const Check = struct {
        scalar: ?model.Type = null,
        append: ?[]const model.Type = null,
        failed: bool = false,
      };
      const result = switch (inner) {
        .structural => |strct| switch (strct.*) {
          .intersection => |*ci| Check{.scalar = ci.scalar, .append = ci.types},
          else => Check{.failed = true},
        },
        .intrinsic => |i| switch (i) {
          .space, .literal, .raw => Check{.scalar = inner},
          else => Check{.failed = true},
        },
        .instantiated => |inst| switch (inst.data) {
          .textual => Check{.scalar = inner},
          .numeric, .float, .tenum => Check{.scalar = .{.intrinsic = .raw}},
          .record => Check{.append = @ptrCast([*]const model.Type, &inner)[0..1]},
        },
      };
      if (result.scalar) |s| {
        if (scalar) |prev| {
          if (!s.eql(prev.t)) {
            self.ctx.logger.MultipleScalarTypesInIntersection(
              "TODO", node.pos, prev.pos);
          }
        } else scalar = .{.pos = node.pos, .t = s};
      }
      if (result.append) |append| builder.push(append);
      if (result.failed) {
        self.ctx.logger.InvalidInnerIntersectionType(
          node.pos, &[_]model.Type{inner});
      }
    }
    if (poison) {
      return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gi.node().pos));
    }
    if (failed_some) return null;
    if (scalar) |found_scalar| {
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
      .access => self.tryInterpretAccess(input, stage),
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
      .literal => |lit|
        // TODO: delay this until stage.kind == .final?
        try self.ctx.createValueExpr(
        (try self.ctx.values.textScalar(input.pos,
          .{.intrinsic = if (lit.kind == .space) .space else .literal},
          try self.ctx.global().dupe(u8, lit.content))).value()),
      .location => |*loc| self.tryInterpretLoc(loc, stage),
      .resolved_symref => |*ref| self.tryInterpretSymref(ref),
      .resolved_call => |*rc| self.tryInterpretCall(rc, stage),
      .gen_concat => |*gc| self.tryGenConcat(gc, stage),
      .gen_enum => |*ge| self.tryGenEnum(ge, stage),
      .gen_float => |*gf| self.tryGenFloat(gf, stage),
      .gen_intersection => |*gi| self.tryGenIntersection(gi, stage),
      .gen_list => |*gl| self.tryGenList(gl, stage),
      .gen_map => |*gm| self.tryGenMap(gm, stage),
      .gen_numeric => |*gn| self.tryGenNumeric(gn, stage),
      .gen_optional => |*go| self.tryGenOptional(go, stage),
      .gen_paragraphs => |*gp| self.tryGenParagraphs(gp, stage),
      .gen_record => |*gr| self.tryGenRecord(gr, stage),
      .gen_textual => |*gt| self.tryGenTextual(gt, stage),
      .unresolved_call => |*uc| self.tryInterpretUCall(uc, stage),
      .unresolved_symref => |*us| self.tryInterpretURef(us, stage),
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

  pub fn resolveSymbol(self: *Interpreter, pos: model.Position, ns: u15,
                       name: []const u8) !*model.Node {
    var syms = &self.namespaces.items[ns].data;
    var ret = try self.allocator().create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = if (syms.get(name)) |sym| .{
        .resolved_symref = .{
          .ns = ns,
          .sym = sym,
        },
      } else .{
        .unresolved_symref = .{
          .ns = ns, .name = name
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
        try self.allocator().alloc(model.Type, index + 1);
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
      .access, .assign, .funcgen, .gen_concat, .gen_enum, .gen_float,
      .gen_intersection, .gen_list, .gen_map, .gen_numeric, .gen_optional,
      .gen_paragraphs, .gen_record, .gen_textual => {
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
      .resolved_call => |*rc| {
        if (rc.target.expected_type.structural.callable.sig.returns.is(
            .ast_node)) {
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
        } else return rc.target.expected_type.structural.callable.sig.returns;
      },
      .resolved_symref => |*ref| {
        const callable = switch (ref.sym.data) {
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
            .instantiated => |it| return switch (it.data) {
              .textual, .numeric, .float, .tenum => unreachable, // TODO
              .record => |rt| rt.typedef(),
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
        std.debug.assert(!callable.sig.returns.is(.ast_node));
        return callable.typedef();
      },
      .unresolved_call, .unresolved_symref => {
        if (stage.resolve) |r| {
          switch (try r.probeSibling(self.allocator(), node)) {
            .unfinished_function => |t| return t,
            .unfinished_type, .known => return null,
            .failed => {
              node.data = .poison;
              return model.Type{.intrinsic = .poison};
            },
            .variable => |v| switch (node.data) {
              .unresolved_symref => return v.t,
              .unresolved_call => |*ucall| {
                const expr = try self.ctx.global().create(model.Expression);
                expr.* = .{
                  .pos = node.pos,
                  .data = .{.var_retrieval = .{.variable = v}},
                  .expected_type = v.t,
                };
                ucall.target.data = .{.expression = expr};
              },
              else => unreachable,
            },
          }
        } else if (stage.kind == .intermediate) return null;
        if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
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
        .numeric => unreachable, // TODO
        .float => unreachable, // TODO
        .tenum => |*e| {
          const index = e.values.getIndex(l.content) orelse {
            self.ctx.logger.UnknownEnumValue(l.node().pos);
            return self.ctx.values.poison(l.node().pos);
          };
          return (try self.ctx.values.@"enum"(l.node().pos, e, index)).value();
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
  fn interpretWithTargetScalar(
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
      .access, .assign, .definition, .funcgen, .location, .resolved_symref,
      .resolved_call, .gen_concat, .gen_enum, .gen_float, .gen_intersection,
      .gen_list, .gen_map, .gen_numeric, .gen_optional, .gen_paragraphs,
      .gen_record, .gen_textual => {
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
      .unresolved_call, .unresolved_symref => return null,
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
        node.pos, &[_]model.Type{expr.expected_type, t});
      expr.data = .{.value = try self.ctx.values.poison(expr.pos)};
      break :blk expr;
    } else null;
  }
};