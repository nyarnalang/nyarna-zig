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

pub const Errors = error {
  referred_source_unavailable,
};

/// Describes the current stage when trying to interpret nodes.
pub const Stage = struct {
  kind: enum {
    /// in the initial stage, symbol resolutions are allowed to fail and won't
    /// generate error messages. This allows forward references e.g. in \declare
    initial,
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
  /// Internal namespaces in the source file (see 6.1).
  /// A namespace will not be deleted when it goes out of scope, so that we do
  /// not need to apply special care for delayed resolution of symrefs:
  /// If a symref cannot initially be resolved to a symbol, it will be stored
  /// with namespace index and target name. Since namespaces are never deleted,
  // it will still try to find its target symbol in the same namespace when
  /// delayed resolution is triggered.
  namespaces:
    std.ArrayListUnmanaged(std.StringArrayHashMapUnmanaged(*model.Symbol)),
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
  /// The type that is currently assembled during inference on type definitions
  /// inside \declare. If set, prototype invocations may create incomplete types
  /// as long as they can push the incomplete parts here.
  currently_built_type: ?*algo.DeclaredType = null,
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

  /// create an object in the public (Loader-wide) storage.
  pub inline fn createPublic(self: *Interpreter, comptime T: type) !*T {
    return self.ctx.global().create(T);
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
    //const ns = &self.namespaces.items[index]; TODO: do we need this?
    // intrinsic symbols of every namespace.
    try self.importModuleSyms(self.ctx.data.intrinsics, index);
  }

  pub fn importModuleSyms(self: *Interpreter, module: *const model.Module,
                          ns_index: usize) !void {
    const ns = &self.namespaces.items[ns_index];
    for (module.symbols) |sym| {
      const name = sym.name;
      try ns.put(self.allocator(), name, sym);
    }
  }

  pub fn removeNamespace(self: *Interpreter, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  fn tryInterpretAccess(self: *Interpreter, input: *model.Node, stage: Stage)
      nyarna.Error!?*model.Expression {
    switch (try self.resolveChain(input, stage)) {
      .var_chain => |vc| {
        const retr = try self.createPublic(model.Expression);
        retr.* = .{
          .pos = vc.target.pos,
          .data = .{.var_retrieval = .{.variable = vc.target.variable}},
          .expected_type = vc.target.variable.t,
        };
        const expr = try self.createPublic(model.Expression);
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
        const expr = try self.createPublic(model.Expression);
        if (ref.prefix != null) {
          self.ctx.logger.PrefixedFunctionMustBeCalled(input.pos);
          expr.fillPoison(input.pos);
        } else {
          self.ctx.assignValue(expr, input.pos, .{
            .funcref = .{.func = ref.target},
          });
        }
        return expr;
      },
      .type_ref => |ref| return self.ctx.createValueExpr(input.pos, .{
        .@"type" = .{.t = ref.*},
      }),
      .proto_ref => |ref| return self.ctx.createValueExpr(input.pos, .{
        .prototype = .{.pt = ref.*},
      }),
      .expr_chain => |ec| {
        const expr = try self.createPublic(model.Expression);
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
      .poison => {
        const expr = try self.createPublic(model.Expression);
        expr.fillPoison(input.pos);
        return expr;
      },
    }
  }

  fn tryInterpretAss(self: *Interpreter, ass: *model.Node.Assign, stage: Stage)
      nyarna.Error!?*model.Expression {
    const target = switch (ass.target) {
      .resolved => |*val| val,
      .unresolved => |node| innerblk: {
        switch (try self.resolveChain(node, stage)) {
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
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(ass.node().pos);
            return expr;
          },
          .poison => {
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(ass.node().pos);
            return expr;
          },
          .failed => return null,
        }
      }
    };
    const target_expr =
      (try self.associate(ass.replacement, target.t, stage))
        orelse return null;
    const expr = try self.createPublic(model.Expression);
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
    const expr = try self.createPublic(model.Expression);
    switch (ref.sym.data) {
      .func => |func| self.ctx.assignValue(expr, ref.node().pos, .{
        .funcref = .{.func = func},
      }),
      .variable => |*v| {
        expr.* = .{
          .pos = ref.node().pos,
          .data = .{
            .var_retrieval = .{
              .variable = v
            },
          },
          .expected_type = v.t,
        };
      },
      .@"type" => |*t| self.ctx.assignValue(expr, ref.node().pos, .{
        .@"type" = .{
          .t = t.*
        },
      }),
      .prototype => |pt| self.ctx.assignValue(expr, ref.node().pos, .{
        .prototype = .{
          .pt = pt,
        },
      }),
    }
    return expr;
  }

  fn tryInterpretCall(self: *Interpreter, rc: *model.Node.ResolvedCall,
                      stage: Stage) nyarna.Error!?*model.Expression {
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
      if (is_keyword) {
        const expr = try self.createPublic(model.Expression);
        expr.fillPoison(rc.node().pos);
        return expr;
      } else return null;
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

    const name = try self.createPublic(model.Value);
    name.* = .{
      .origin = loc.name.node().pos,
      .data = .{
        .text = .{
          .t = model.Type{.intrinsic = .literal},
          .content = try self.ctx.global().dupe(u8, loc.name.content),
        },
      },
    };

    return self.ctx.createValueExpr(loc.node().pos, .{
      .location = .{
        .name = &name.data.text,
        .tloc = ltype,
        .default = expr,
        .primary = if (loc.additionals) |add| add.primary else null,
        .varargs = if (loc.additionals) |add| add.varargs else null,
        .varmap  = if (loc.additionals) |add| add.varmap else null,
        .mutable = if (loc.additionals) |add| add.mutable else null,
        .header = if (loc.additionals) |add| add.header else null,
      },
    });
  }

  fn tryInterpretDef(self: *Interpreter, def: *model.Node.Definition,
                     stage: Stage) nyarna.Error!?*model.Expression {
    const expr = (try self.tryInterpret(def.content, stage))
      orelse return null;
    if (!self.ctx.types().lesserEqual(
        expr.expected_type, model.Type{.intrinsic = .@"type"}) and
        !expr.expected_type.isStructural(.callable)) {
      self.ctx.logger.InvalidDefinitionValue(
        expr.pos, &.{expr.expected_type});
      const pe = try self.allocator().create(model.Expression);
      pe.fillPoison(def.node().pos);
      return pe;
    }
    var eval = self.ctx.evaluator();
    var name = try self.createPublic(model.Value);
    name.* = .{
      .origin = def.name.node().pos,
      .data = .{
        .text = .{
          .t = model.Type{.intrinsic = .literal},
          .content =
            try self.ctx.global().dupe(u8, def.name.content),
        },
      },
    };
    return self.ctx.createValueExpr(def.node().pos, .{
      .definition = .{
        .name = &name.data.text,
        .content = try eval.evaluate(expr),
        .root = def.root
      },
    });
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
          if (expr.data.literal.value.data == .poison) return;
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
                lt.data.expression.data.literal.value.data.@"type".t
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
    return true;
  }

  pub fn tryInterpretFunc(
      self: *Interpreter, func: *model.Node.Funcgen, stage: Stage)
      nyarna.Error!?*model.Function {
    if (func.params == .unresolved)
      if (!try self.tryInterpretFuncParams(func, stage))
        return null;
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

    var num_added_symbols: usize = 0;
    const ns = &self.namespaces.items[func.params_ns];
    for (params.variables) |v| {
      const res = try ns.getOrPut(self.allocator(), v.sym().name);
      if (res.found_existing) {
        self.ctx.logger.DuplicateSymbolName(
          v.sym().name, v.sym().defined_at, res.value_ptr.*.defined_at);
      } else {
        res.value_ptr.* = v.sym();
        num_added_symbols += 1;
      }
    }
    defer ns.shrinkRetainingCapacity(ns.count() - num_added_symbols);

    const body_expr =
      (try self.tryInterpret(func.body, stage)) orelse return null;
    const ret_type = if (func.returns) |rnode| blk: {
      const ret_val = try self.ctx.evaluator().evaluate(
        (try self.associate(rnode, .{.intrinsic = .@"type"},
          .{.kind = .assumed, .resolve = stage.resolve})).?);
      if (ret_val.data == .poison) break :blk model.Type{.intrinsic = .poison};
      break :blk ret_val.data.@"type".t;
    } else body_expr.expected_type;

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
          .body = body_expr,
        },
      },
    };
    return ret;
  }

  fn tryInterpretUCall(self: *Interpreter, uc: *model.Node.UnresolvedCall,
                       stage: Stage) nyarna.Error!?*model.Expression {
    if (stage.kind == .initial) return null;
    const call_ctx = try self.chainResToContext(uc.target.pos,
      try self.resolveChain(uc.target, stage));
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
        return try self.tryInterpret(input, stage);
      },
      .unknown => return null,
      .poison => {
        const expr = try self.allocator().create(model.Expression);
        expr.fillPoison(uc.node().pos);
        return expr;
      }
    }
  }
  fn tryInterpretURef(self: *Interpreter, us: *model.Node.UnresolvedSymref,
                      stage: Stage) nyarna.Error!?*model.Expression {
    if (stage.kind == .initial) return null;
    const ns = us.ns;
    const syms = &self.namespaces.items[ns];
    if (syms.get(us.name)) |sym| {
      const input = us.node();
      input.data = .{.resolved_symref = .{.ns = ns, .sym = sym}};
      return self.tryInterpret(input, stage);
    } else switch (stage.kind) {
      .initial, .assumed => unreachable,
      .keyword => self.ctx.logger.CannotResolveImmediately(us.node().pos),
      .final => self.ctx.logger.UnknownSymbol(us.node().pos),
    }
    return null;
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
      .branches, .concat, .paras =>
        self.tryProbeAndInterpret(input, stage),
      .definition => |*def| self.tryInterpretDef(def, stage),
      .expression => |expr| expr,
      .funcgen => |*func| blk: {
        const val = (try self.tryInterpretFunc(func, stage))
          orelse break :blk null;
        break :blk try self.ctx.createValueExpr(input.pos, .{
          .funcref = .{.func = val},
        });
      },
      .literal => |lit| try self.ctx.createValueExpr(input.pos, .{
        .text = .{
          .t = model.Type{
            .intrinsic = if (lit.kind == .space) .space else .literal},
          .content = try self.ctx.global().dupe(u8, lit.content),
        },
      }),
      .location => |*loc| self.tryInterpretLoc(loc, stage),
      .resolved_symref => |*ref| self.tryInterpretSymref(ref),
      .resolved_call => |*rc| self.tryInterpretCall(rc, stage),
      .typegen => unreachable, // TODO
      .unresolved_call => |*uc| self.tryInterpretUCall(uc, stage),
      .unresolved_symref => |*us| self.tryInterpretURef(us, stage),
      .void => blk: {
        const expr = try self.allocator().create(model.Expression);
        expr.fillVoid(input.pos);
        break :blk expr;
      },
      .poison => blk: {
        const expr = try self.allocator().create(model.Expression);
        expr.fillPoison(input.pos);
        break :blk expr;
      },
    };
  }

  pub fn interpret(self: *Interpreter, input: *model.Node)
      nyarna.Error!*model.Expression {
    if (try self.tryInterpret(input, .{.kind = .final})) |expr|
      return expr
    else {
      const ret = try self.createPublic(model.Expression);
      ret.fillPoison(input.pos);
      return ret;
    }
  }

  pub fn resolveSymbol(self: *Interpreter, pos: model.Position, ns: u15,
                       name: []const u8) !*model.Node {
    var syms = &self.namespaces.items[ns];
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

  /// Result of resolving an accessor chain.
  pub const ChainResolution = union(enum) {
    /// chain starts at a variable reference and descends into its fields.
    var_chain: struct {
      /// the target variable that is to be indexed.
      target: struct {
        variable: *model.Symbol.Variable,
        pos: model.Position,
      },
      /// chain into the fields of a variable. Each item is the index of a
      /// nested field.
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      t: model.Type,
    },
    /// last chain item was resolved to a function.
    func_ref: struct {
      ns: u15,
      target: *model.Function,
      /// set if target is a function reference in the namespace of a type,
      /// which has been accessed via an expression of that type. That is only
      /// allowed in the context of a call. The caller of resolveChain is to
      /// enforce this.
      prefix: ?*model.Expression = null,
    },
    /// last chain item was resolved to a type. Value is a pointer into a
    /// model.Symbol.
    type_ref: *model.Type,
    /// last chain item was resolved to a prototype. Value is a pointer into a
    /// model.Symbol.
    proto_ref: *model.Prototype,
    /// chain starts at an expression and descends into the returned value.
    expr_chain: struct {
      expr: *model.Expression,
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      t: model.Type,
    },
    /// the resolution failed because an identifier in the chain could not be
    /// resolved – this is not necessarily an error since the chain may be
    /// successfully resolved later.
    failed,
    /// this will be set if the chain is guaranteed to be faulty.
    poison,
  };

  /// resolves an accessor chain of *model.Node. iff stage.kind != .initial,
  /// failure to resolve the base symbol will be reported as error and
  /// .poison will be returned; else .failed will be returned.
  pub fn resolveChain(self: *Interpreter, chain: *model.Node, stage: Stage)
      nyarna.Error!ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, stage);
        switch (inner) {
          .var_chain => |_| {
            // TODO: find field in value's type, update value's type and the
            // field_chain, return it.
            unreachable;
          },
          .func_ref => |ref| {
            if (ref.prefix != null) {
              self.ctx.logger.PrefixedFunctionMustBeCalled(value.subject.pos);
              return .poison;
            }
            // TODO: transform function reference to variable ref, then search
            // in that expression's type for the symbol.
            unreachable;
          },
          .type_ref => |_| {
            // TODO: search in the namespace of the type for the given name.
            unreachable;
          },
          .proto_ref => |_| {
            // TODO: decide whether prototypes have a namespace
            unreachable;
          },
          .expr_chain => |_| {
            // TODO: same as var_chain basically
            unreachable;
          },
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .resolved_symref => |rs| return switch(rs.sym.data) {
        .func => |func| ChainResolution{
          .func_ref = .{
            .ns = rs.ns,
            .target = func,
            .prefix = null,
          },
        },
        .@"type" => |*t| ChainResolution{.type_ref = t},
        .prototype => |*pv| ChainResolution{.proto_ref = pv},
        .variable => |*v| ChainResolution{
          .var_chain = .{
            .target = .{.variable = v, .pos = chain.pos},
            .field_chain = .{},
            .t = v.t,
          },
        },
      },
      else =>
        return if (try self.tryInterpret(chain, stage)) |expr| ChainResolution{
          .expr_chain = .{
            .expr = expr,
            .t = expr.expected_type,
          },
        } else
          @as(ChainResolution, if (stage.kind != .initial) .poison else .failed)
    }
  }

  /// Calculate the supremum of the given nodes' types and return it.
  ///
  /// Substructures will be interpreted as necessary (see doc on probeType).
  /// If some substructure cannot be interpreted, null is returned.
  fn probeNodeList(self: *Interpreter, nodes: []*model.Node,
                   stage: Stage) !?model.Type {
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
  /// to poison being returned if stage.kind != .initial.
  pub fn probeType(self: *Interpreter, node: *model.Node, stage: Stage)
      nyarna.Error!?model.Type {
    switch (node.data) {
      .access, .assign, .funcgen, .typegen => {
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
      .resolved_call => |rc| {
        if (rc.target.expected_type.structural.callable.sig.returns.is(
            .ast_node)) {
          // call to keywords must be interpretable at this point.
          if (try self.tryInterpret(
              node, .{.kind = .keyword, .resolve = stage.resolve})) |expr| {
            node.data = .{.expression = expr};
            return expr.expected_type;
          } else {
            node.data = .poison;
            return model.Type{.intrinsic = .poison};
          }
        } else return rc.target.expected_type.structural.callable.sig.returns;
      },
      .resolved_symref => |ref| {
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
        };
        // references to keywords must not be used as standalone values.
        std.debug.assert(!callable.sig.returns.is(.ast_node));
        return callable.typedef();
      },
      .unresolved_call, .unresolved_symref => {
        if (stage.kind == .initial) return null;
        if (try self.tryInterpret(node, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
      .void => return model.Type{.intrinsic = .void},
      .poison => return model.Type{.intrinsic = .poison},
    }
  }

  pub inline fn genValueNode(self: *Interpreter, pos: model.Position,
                             content: model.Value.Data) !*model.Node {
    const expr = try self.ctx.createValueExpr(pos, content);
    var ret = try self.allocator().create(model.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .expression = expr,
      },
    };
    return ret;
  }

  fn createTextLiteral(self: *Interpreter, l: *model.Node.Literal,
                       t: model.Type, e: *model.Expression) nyarna.Error!void {
    switch (t) {
      .intrinsic => |it| switch (it) {
        .space => if (l.kind == .space)
          self.ctx.assignValue(e, l.node().pos, .{
            .text = .{
              .t = t,
              .content =
                try self.ctx.global().dupe(u8, l.content),
            },
          }) else {
            self.ctx.logger.ExpectedExprOfTypeXGotY(
              l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
            e.fillPoison(l.node().pos);
          },
        .literal, .raw =>
          self.ctx.assignValue(e, l.node().pos, .{
            .text = .{
              .t = t,
              .content =
                try self.ctx.global().dupe(u8, l.content),
            },
          }),
        else =>
          self.ctx.assignValue(e, l.node().pos, .{
          .text = .{
            .t = .{.intrinsic = if (l.kind == .text) .literal else .space},
            .content =
              try self.ctx.global().dupe(u8, l.content),
          },
        }),
      },
      .structural => |struc| switch (struc.*) {
        .optional => |*op| try self.createTextLiteral(l, op.inner, e),
        .concat => |*con| try self.createTextLiteral(l, con.inner, e),
        .paragraphs => unreachable,
        .list => |*list| try self.createTextLiteral(l, list.inner, e), // TODO
        .map, .callable => {
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
          e.fillPoison(l.node().pos);
        },
        .intersection => |*inter|
          if (inter.scalar) |scalar| {
            try self.createTextLiteral(l, scalar, e);
          } else {
            self.ctx.logger.ExpectedExprOfTypeXGotY(
              l.node().pos, &[_]model.Type{t, .{.intrinsic = .literal}});
            e.fillPoison(l.node().pos);
          }
      },
      .instantiated => |ti| switch (ti.data) {
        .textual => unreachable, // TODO
        .numeric => unreachable, // TODO
        .float => unreachable, // TODO
        .tenum => unreachable, // TODO
        .record => {
          self.ctx.logger.ExpectedExprOfTypeXGotY(l.node().pos,
            &[_]model.Type{
              t, .{.intrinsic = if (l.kind == .text) .literal else .space},
            });
          e.fillPoison(l.node().pos);
        },
      },
    }
  }

  fn probeCheckOrPoison(self: *Interpreter, input: *model.Node, t: model.Type,
                        stage: Stage) nyarna.Error!?*model.Expressio {
    var actual_type = (try self.probeType(input, stage)) orelse return null;
    if (!actual_type.is(.poison) and
        !self.ctx.types().lesserEqual(actual_type, t)) {
      actual_type = .{.intrinsic = .poison};
      self.ctx.logger.ExpectedExprOfTypeXGotY(
        input.pos, &[_]model.Type{t, actual_type});
    }
    if (actual_type.is(.poison)) {
      const expr = try self.createPublic(model.Expression);
      expr.fillPoison(input.pos);
      return expr;
    }
    return null;
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
    const expr = try self.ctx.global().create(model.Expression);
    expr.fillPoison(pos);
    return expr;
  }

  /// Same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals. The target type *must* be a
  /// scalar type.
  fn interpretWithTargetScalar(
      self: *Interpreter, input: *model.Node, t: model.Type, stage: Stage)
      nyarna.Error!?*model.Expression {
    std.debug.assert(switch (t) {
      .intrinsic => |intr|
        intr == .literal or intr == .space or intr == .raw or intr == .every,
      .structural => false,
      .instantiated => |inst| inst.data == .textual or inst.data == .numeric or
        inst.data == .float or inst.data == .tenum,
    });
    switch (input.data) {
      .access, .assign, .definition, .funcgen, .location, .resolved_symref,
      .resolved_call, .typegen => {
        if (try self.tryInterpret(input, stage)) |expr| {
          if (types.containedScalar(expr.expected_type)) |scalar_type| {
            if (self.ctx.types().lesserEqual(scalar_type, t)) return expr;
            // TODO: conversion
            self.ctx.logger.ScalarTypesMismatch(
              input.pos, &[_]model.Type{t, scalar_type});
            expr.fillPoison(input.pos);
          }
          return expr;
        }
        return null;
      },
      .branches => |br| {
        const condition = cblk: {
          // TODO: use intrinsic Boolean type here / the type used for braching
          if (try self.interpretWithTargetScalar(br.condition,
              model.Type{.intrinsic = .literal}, stage)) |expr|
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
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.branches = .{.condition = condition, .branches = exprs}},
          .expected_type = try self.ctx.types().sup(actual_type, t),
        };
        return expr;
      },
      .concat => |con| {
        const actual_type =
          (try self.probeNodeList(con.items, stage)) orelse return null;
        if (try self.poisonIfNotCompat(input.pos, actual_type, t)) |expr| {
          return expr;
        }
        const exprs = try self.ctx.global().alloc(
          *model.Expression, con.items.len);
        // TODO: properly handle paragraph types
        for (con.items) |item, i| {
          exprs[i] = (try self.interpretWithTargetScalar(item, t, stage)).?;
        }
        const expr = try self.createPublic(model.Expression);
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
        const expr = try self.createPublic(model.Expression);
        try self.createTextLiteral(l, t, expr);
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
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{.paragraphs = res},
          .expected_type = try self.ctx.types().sup(probed, t),
        };
        return expr;
      },
      .void => {
        const expr = try self.createPublic(model.Expression);
        expr.fillVoid(input.pos);
        return expr;
      },
      .poison => {
        const expr = try self.createPublic(model.Expression);
        expr.fillPoison(input.pos);
        return expr;
      }
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
      expr.fillPoison(node.pos);
      break :blk expr;
    } else null;
  }

  pub const CallContext = union(enum) {
    known: struct {
      target: *model.Expression,
      ns: u15,
      signature: *const model.Type.Signature,
      first_arg: ?*model.Node,
    },
    unknown, poison,
  };

  pub fn chainResToContext(self: *Interpreter, pos: model.Position,
                           res: ChainResolution) !CallContext {
    switch (res) {
      .var_chain => |_| {
        unreachable; // TODO
      },
      .func_ref => |fr| {
        const target_expr = try self.ctx.createValueExpr(
          pos, .{.funcref = .{.func = fr.target}});
        return CallContext{
          .known = .{
            .target = target_expr,
            .ns = fr.ns,
            .signature = fr.target.sig(),
            .first_arg = if (fr.prefix) |prefix|
              try self.node_gen.expression(prefix) else null,
          },
        };
      },
      .expr_chain => |ec| {
        const target_expr = if (ec.field_chain.items.len == 0)
          ec.expr
        else blk: {
          const acc = try self.ctx.global().create(model.Expression);
          acc.* = .{
            .pos = pos,
            .data = .{
              .access = .{.subject = ec.expr, .path = ec.field_chain.items},
            },
            .expected_type = ec.t,
          };
          break :blk acc;
        };
        const sig = switch (target_expr.expected_type) {
          .structural => |strct| switch (strct.*) {
            .callable => |callable| @as(?*model.Type.Signature, callable.sig),
            else => null
          },
          else => null
        } orelse {
          self.ctx.logger.CantBeCalled(pos);
          return .poison;
        };
        return CallContext{
          .known = .{
            .target = target_expr,
            .ns = undefined, // cannot be a function depending on this
            .signature = sig,
            .first_arg = null,
          },
        };
      },
      .type_ref => |_| {
        unreachable; // TODO
      },
      .proto_ref => |pref| {
        const target_expr = try self.ctx.createValueExpr(
          pos, .{.prototype = .{.pt = pref.*}});
        return CallContext{
          .known = .{
            .target = target_expr,
            .ns = undefined,
            .signature = self.ctx.types().prototypeConstructor(
              pref.*).callable.sig,
            .first_arg = null,
          },
        };
      },
      .failed => return .unknown,
      .poison => return .poison,
    }
  }
};