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

pub const Errors = error {
  referred_source_unavailable,
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
      std.debug.print("adding symbol {s}\n", .{name});
      try ns.put(self.allocator(), name, sym);
    }
  }

  pub fn removeNamespace(self: *Interpreter, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  fn reportResolveFailures(
      self: *Interpreter, node: *model.Node, immediate: bool) void {
    switch (node.data) {
      .access => |*acc| self.reportResolveFailures(acc.subject, immediate),
      .assign => |*ass| {
        switch (ass.target) {
          .unresolved => |unres| self.reportResolveFailures(unres, immediate),
          .resolved => {},
        }
        self.reportResolveFailures(ass.replacement, immediate);
      },
      .branches => |*br| {
        self.reportResolveFailures(br.condition, immediate);
        for (br.branches) |branch|
          self.reportResolveFailures(branch, immediate);
      },
      .concat => |*con| {
        for (con.items) |item| self.reportResolveFailures(item, immediate);
      },
      .definition => |*def| self.reportResolveFailures(def.content, immediate),
      .expression, .literal, .resolved_call, .resolved_symref,.void, .poison =>
        {},
      .funcgen => |*fgen| {
        self.reportResolveFailures(fgen.params.unresolved, immediate);
        if (fgen.returns) |ret| self.reportResolveFailures(ret, immediate);
        self.reportResolveFailures(fgen.body, immediate);
      },
      .location => |*loc| {
        if (loc.@"type") |t| self.reportResolveFailures(t, immediate);
        if (loc.@"default") |d| self.reportResolveFailures(d, immediate);
      },
      .paras => |*para| {
        for (para.items) |*item|
          self.reportResolveFailures(item.content, immediate);
      },
      .typegen => |*tg| switch (tg.content) {
        .optional => |*opt| self.reportResolveFailures(opt.inner, immediate),
        .concat => |*con| self.reportResolveFailures(con.inner, immediate),
        .list => |*lst| self.reportResolveFailures(lst.inner, immediate),
        .paragraphs => |*para|
          for (para.inners) |item| self.reportResolveFailures(item, immediate),
        .map => |*map| {
          self.reportResolveFailures(map.key, immediate);
          self.reportResolveFailures(map.value, immediate);
        },
        .record => |*rct| for (rct.fields) |field|
          self.reportResolveFailures(field.node(), immediate),
        .intersection => |*inter| {
          for (inter.types) |t| self.reportResolveFailures(t, immediate);
        },
        .textual => unreachable,
        .numeric => |*num| {
          if (num.min) |min| self.reportResolveFailures(min, immediate);
          if (num.max) |max| self.reportResolveFailures(max, immediate);
          if (num.decimals) |dec| self.reportResolveFailures(dec, immediate);
        },
        .float => |*fl| self.reportResolveFailures(fl.precision, immediate),
        .@"enum" => |*en|
          for (en.values) |v| self.reportResolveFailures(v, immediate),
      },
      .unresolved_call => |*uc| {
        self.reportResolveFailures(uc.target, immediate);
        for (uc.proto_args) |*arg|
          self.reportResolveFailures(arg.content, immediate);
      },
      .unresolved_symref => if (immediate)
        self.ctx.logger.CannotResolveImmediately(node.pos)
      else
        self.ctx.logger.UnknownSymbol(node.pos),
    }
  }

  fn tryInterpretAccess(
      self: *Interpreter, input: *model.Node, report_failure: bool,
      ctx: ?*graph.ResolutionContext) nyarna.Error!?*model.Expression {
    switch (try self.resolveChain(input, report_failure, ctx)) {
      .var_chain => |vc| {
        const retr =
          try self.createPublic(model.Expression);
        retr.* = .{
          .pos = vc.target.pos,
          .data = .{
            .var_retrieval = .{
              .variable = vc.target.variable
            },
          },
          .expected_type = vc.target.variable.t,
        };
        const expr =
          try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .access = .{
              .subject = retr,
              .path = vc.field_chain.items
            },
          },
          .expected_type = vc.t,
        };
        return expr;
      },
      .func_ref => |ref| {
        const expr =
          try self.createPublic(model.Expression);
        if (ref.prefix != null) {
          self.ctx.logger.PrefixedFunctionMustBeCalled(input.pos);
          expr.fillPoison(input.pos);
        } else {
          self.ctx.assignValue(expr, input.pos, .{
            .funcref = .{
              .func = ref.target
            },
          });
        }
        return expr;
      },
      .type_ref => |ref| return self.ctx.createValueExpr(input.pos, .{
        .@"type" = .{
          .t = ref.*,
        },
      }),
      .proto_ref => |ref| return self.ctx.createValueExpr(input.pos, .{
        .prototype = .{
          .pt = ref.*,
        },
      }),
      .expr_chain => |ec| {
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .access = .{
              .subject = ec.expr,
              .path = ec.field_chain.items,
            },
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

  fn tryInterpretAss(self: *Interpreter, ass: *model.Node.Assign,
                     report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
    const target = switch (ass.target) {
      .resolved => |*val| val,
      .unresolved => |node| innerblk: {
        switch (try self.resolveChain(node, report_failure, ctx)) {
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
    const target_expr = (try self.associate(ass.replacement, target.t, ctx))
        orelse {
      if (report_failure)
        self.reportResolveFailures(ass.replacement, false);
      return null;
    };
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

  fn tryProbeAndInterpret(self: *Interpreter, input: *model.Node,
                          report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
    const ret_type = (try self.probeType(input, ctx)) orelse {
      if (report_failure) self.reportResolveFailures(input, false);
      return null;
    };
    return self.interpretWithTargetType(input, ret_type, true, ctx);
  }

  fn tryInterpretSymref(self: *Interpreter, ref: *model.Node.ResolvedSymref)
      nyarna.Error!*model.Expression {
    const expr = try self.createPublic(model.Expression);
    switch (ref.sym.data) {
      .ext_func, .ny_func => self.ctx.assignValue(expr, ref.node().pos, .{
        .funcref = .{
          .func = ref.sym,
        },
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
                      report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
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
    var failed_to_interpret = std.ArrayListUnmanaged(*model.Node){};
    var args_failed_to_interpret = false;
    // in-place modification of args requires that the arg nodes have been
    // created by the current document. The only way a node from another
    // document can be referenced in the current document is through
    // compile-time functions. Therefore, we always copy call nodes that
    // originate from calls of compile-time functions.
    for (rc.args) |*arg, i| {
      if (arg.*.data != .expression) {
        arg.*.data =
          if (try self.associate(arg.*, sig.parameters[i].ptype, ctx)) |e| .{
            .expression = e,
          } else {
            args_failed_to_interpret = true;
            if (is_keyword) try
              failed_to_interpret.append(self.allocator(), arg.*);
            continue;
          };
      }
    }

    if (args_failed_to_interpret) {
      if (is_keyword) {
        for (failed_to_interpret.items) |arg|
          self.reportResolveFailures(arg, true);
        const expr = try self.createPublic(model.Expression);
        expr.fillPoison(rc.node().pos);
        return expr;
      } else {
        if (report_failure) {
          for (failed_to_interpret.items) |arg|
            self.reportResolveFailures(arg, false);
        }
        return null;
      }
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
      const interpreted_res =
        try self.tryInterpret(res, report_failure, ctx);
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

  fn tryInterpretLoc(self: *Interpreter, loc: *model.Node.Location,
                     report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
    var incomplete = false;
    var poison = false;
    var t = if (loc.@"type") |node| blk: {
      var expr = (try self.associate(
        node, model.Type{.intrinsic = .@"type"}, ctx))
      orelse {
        incomplete = true;
        break :blk null;
      };
      if (expr.expected_type.is(.poison)) {
        poison = true;
        break :blk null;
      }
      var eval = self.ctx.evaluator();
      var val = try eval.evaluate(expr);
      break :blk val.data.@"type".t;
    } else null;

    var expr = if (loc.default) |node| blk: {
      var val = (try self.tryInterpret(node, report_failure, ctx)) orelse {
        incomplete = true;
        break :blk null;
      };
      if (val.expected_type.is(.poison)) {
        poison = true;
        break :blk null;
      }
      if (t) |given_type| {
        if (!self.ctx.types().lesserEqual(val.expected_type, given_type)
            and !val.expected_type.is(.poison)) {
          self.ctx.logger.ExpectedExprOfTypeXGotY(
            val.pos, &[_]model.Type{given_type, val.expected_type});
          poison = true;
          break :blk null;
        }
      }
      break :blk val;
    } else null;
    if (!poison and !incomplete and t == null and expr == null) {
      self.ctx.logger.MissingSymbolType(loc.node().pos);
      poison = true;
    }
    if (loc.additionals) |add| {
      if (add.varmap) |varmap| {
        if (add.varargs) |varargs| {
          self.ctx.logger.IncompatibleFlag("varmap", varmap, varargs);
          poison = true;
        } else if (add.mutable) |mutable| {
          self.ctx.logger.IncompatibleFlag("varmap", varmap, mutable);
          poison = true;
        }
      } else if (add.varargs) |varargs| if (add.mutable) |mutable| {
        self.ctx.logger.IncompatibleFlag("mutable", mutable, varargs);
        poison = true;
      };
    }

    if (poison) {
      const pe = try self.allocator().create(model.Expression);
      pe.fillPoison(loc.node().pos);
      return pe;
    }
    if (incomplete) return null;
    const ltype = if (t) |given_type| given_type else expr.?.expected_type;

    const name = try self.createPublic(model.Value);
    name.* = .{
      .origin = loc.name.node().pos,
      .data = .{
        .text = .{
          .t = model.Type{.intrinsic = .literal},
          .content =
            try self.ctx.global().dupe(u8, loc.name.content),
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
                     report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
    const expr = (try self.tryInterpret(def.content, report_failure, ctx))
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

  fn locationsCanGenVars(
      self: *Interpreter, node: *model.Node, report_failure: bool,
      ctx: ?*graph.ResolutionContext) nyarna.Error!bool {
    switch (node.data) {
      .location => |*loc| {
        if (loc.@"type") |tnode| {
          if (try self.tryInterpret(tnode, report_failure, ctx)) |texpr| {
            tnode.data = .{.expression = texpr};
            return true;
          } else return false;
        } else {
          return (try self.probeType(loc.default.?, ctx)) != null;
        }
      },
      .concat => |*con| {
        for (con.items) |item|
          if (!(try self.locationsCanGenVars(item, report_failure, ctx)))
            return false;
        return true;
      },
      else => if (try self.tryInterpret(node, report_failure, ctx)) |expr| {
        node.data = .{.expression = expr};
        return true;
      } else return false,
    }
  }

  fn collectLocations(self: *Interpreter, node: *model.Node,
                      collector: *std.ArrayList(*model.Node.Location))
      nyarna.Error!void {
    switch (node.data) {
      .location => |*loc| {
        if (loc.@"type") |tnode| {
          const expr =
            (try self.associate(tnode, .{.intrinsic = .@"type"}, null)).?;
          if (expr.data.literal.value.data == .poison) return;
        } else if ((try self.probeType(loc.default.?, null)).?.is(.poison))
          return;
        try collector.append(loc);
      },
      .concat => |*con|
        for (con.items) |item| try self.collectLocations(item, collector),
      .void, .poison => {},
      else => {
        const expr = (try self.associate(
          node, (try self.ctx.types().concat(.{.intrinsic = .location})).?, null
        )).?;
        const value = try self.ctx.evaluator().evaluate(expr);
        switch (value.data) {
          .concat => |*con| {
            for (con.content.items) |item|
              try collector.append(try self.node_gen.locationFromValue(
                self.ctx, &item.data.location));
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
  pub fn tryInterpretFuncParams(self: *Interpreter, func: *model.Node.Funcgen,
                                report_failure: bool,
                                ctx: ?*graph.ResolutionContext) !bool {
    if (!(try self.locationsCanGenVars(
        func.params.unresolved, report_failure, ctx)))
      return false;
    var locs = std.ArrayList(*model.Node.Location).init(self.allocator());
    try self.collectLocations(func.params.unresolved, &locs);
    var variables =
      try self.allocator().alloc(*model.Symbol.Variable, locs.items.len);
    for (locs.items) |loc, index| {
      const sym = try self.ctx.global().create(model.Symbol);
      sym.* = .{
        .defined_at = loc.name.node().pos,
        .name = try self.ctx.global().dupe(u8, loc.name.content),
        .data = .{
          .variable = .{
            .t = if (loc.@"type") |lt|
              lt.data.expression.data.literal.value.data.@"type".t
            else (try self.probeType(loc.default.?, ctx)).?,
          },
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

  fn tryInterpretFunc(self: *Interpreter, func: *model.Node.Funcgen,
                      report_failure: bool, ctx: ?*graph.ResolutionContext)
      nyarna.Error!?*model.Expression {
    if (func.params == .unresolved)
      if (!try self.tryInterpretFuncParams(func, report_failure, ctx))
        return null;
    // TODO: add symbols to namespace. interpret body. remove symbols from ns.
    unreachable;
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
      self: *Interpreter, input: *model.Node, report_failure: bool,
      ctx: ?*graph.ResolutionContext) nyarna.Error!?*model.Expression {
    return switch (input.data) {
      .access => self.tryInterpretAccess(input, report_failure, ctx),
      .assign => |*ass| self.tryInterpretAss(ass, report_failure, ctx),
      .branches, .concat, .paras =>
        self.tryProbeAndInterpret(input, report_failure, ctx),
      .definition => |*def| self.tryInterpretDef(def, report_failure, ctx),
      .expression => |expr| expr,
      .funcgen => |*func| self.tryInterpretFunc(func, report_failure, ctx),
      .literal => |lit| try self.ctx.createValueExpr(input.pos, .{
        .text = .{
          .t = model.Type{
            .intrinsic = if (lit.kind == .space) .space else .literal},
          .content = try self.ctx.global().dupe(u8, lit.content),
        },
      }),
      .location => |*loc| self.tryInterpretLoc(loc, report_failure, ctx),
      .resolved_symref => |*ref| self.tryInterpretSymref(ref),
      .resolved_call => |*rc| self.tryInterpretCall(rc, report_failure, ctx),
      .typegen => unreachable, // TODO
      .unresolved_symref, .unresolved_call => blk: {
        if (report_failure) self.reportResolveFailures(input, false);
        break :blk null;
      },
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
    if (try self.tryInterpret(input, true, null)) |expr| return expr
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
      /// must be ExtFunc or NyFunc
      target: *model.Symbol,
      signature: *const model.Type.Signature,
      /// set if targt is a function reference in the namespace of a type,
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

  /// resolves an accessor chain of *model.Node. iff force_fail is true, failure
  /// to resolve the base symbol will be reported as error and .poison will be
  /// returned; else no error will be reported and .failed will be returned.
  pub fn resolveChain(
      self: *Interpreter, chain: *model.Node, force_fail: bool,
      ctx: ?*graph.ResolutionContext)nyarna.Error!ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, force_fail, ctx);
        switch (inner) {
          .var_chain => |_| {
            // TODO: find field in value's type, update value's type and the
            // field_chain, return it.
            unreachable;
          },
          .func_ref => |ref| {
            if (ref.prefix != null) {
              self.ctx.logger.PrefixedFunctionMustBeCalled(
                value.subject.pos);
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
        .ext_func => |*ef| ChainResolution{
          .func_ref = .{
            .ns = rs.ns,
            .target = rs.sym,
            .signature = ef.sig(),
            .prefix = null,
          },
        },
        .ny_func => |*nf| ChainResolution{
          .func_ref = .{
            .ns = rs.ns,
            .target = rs.sym,
            .signature = nf.sig(),
            .prefix = null,
          },
        },
        .@"type" => |*t| ChainResolution{
          .type_ref = t,
        },
        .prototype => |*pv| ChainResolution{
          .proto_ref = pv,
        },
        .variable => |*v| ChainResolution{
          .var_chain = .{
            .target = .{
              .variable = v,
              .pos = chain.pos,
            },
            .field_chain = .{},
            .t = v.t,
          },
        },
      },
      else =>
        return if (try self.tryInterpret(chain, force_fail, ctx)) |_| {
          // TODO: resolve accessor chain in context of expression's type and
          // return expr_chain
          unreachable;
        } else @as(ChainResolution, if (force_fail) .poison else .failed)
    }
  }

  /// Calculate the supremum of the given nodes' types and return it.
  ///
  /// Substructures will be interpreted as necessary (see doc on probeType).
  /// If some substructure cannot be interpreted, null is returned.
  fn probeNodeList(self: *Interpreter, nodes: []*model.Node,
                   ctx: ?*graph.ResolutionContext) !?model.Type {
    var sup = model.Type{.intrinsic = .every};
    var already_poison = false;
    var seen_unfinished = false;
    var first_incompatible: ?usize = null;
    for (nodes) |node, i| {
      const t = (try self.probeType(node, ctx)) orelse {
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
    return if (first_incompatible) |index| blk: {
      const type_arr =
        try self.allocator().alloc(model.Type, index + 1);
      type_arr[0] = (try self.probeType(nodes[index], ctx)).?;
      var j = @as(usize, 0);
      while (j < index) : (j += 1) {
        type_arr[j + 1] = (try self.probeType(nodes[j], ctx)).?;
      }
      self.ctx.logger.IncompatibleTypes(nodes[index].pos, type_arr);
      break :blk model.Type{.intrinsic = .poison};
    } else if (already_poison) model.Type{.intrinsic = .poison}
    else if (seen_unfinished) null else sup;
  }

  /// Calculate the supremum of all scalar types in the given node's types.
  /// considered are direct scalar types, as well as scalar types in
  /// concatenations, optionals and paragraphs.
  ///
  /// returns null only in the event of unfinished nodes.
  fn probeNodesForScalarType(self: *Interpreter, nodes: []*model.Node,
                             ctx: ?*graph.ResolutionContext) !?model.Type {
    var sup = model.Type{.intrinsic = .every};
    var seen_unfinished = false;
    for (nodes) |node| {
      const t = (try self.probeType(node, ctx)) orelse {
        seen_unfinished = true;
        break;
      };
      sup = try self.ctx.types().sup(sup, self.containedScalar(t) or continue);
    }
    return if (seen_unfinished) null else sup;
  }

  /// Returns the given node's type, if it can be calculated. If the node or its
  /// substructures cannot be interpreted, null is returned.
  ///
  /// This will modify the given node by interpreting all substructures that
  /// are guaranteed not to be type-dependent on context. This means that all
  /// nodes are evaluated except for literal nodes, paragraphs, concatenations
  /// transitively.
  ///
  /// Semantic errors that are discovered during probing will be logged and lead
  /// to poison being returned.
  pub fn probeType(self: *Interpreter, node: *model.Node,
                   ctx: ?*graph.ResolutionContext) nyarna.Error!?model.Type {
    switch (node.data) {
      .access, .assign, .funcgen, .typegen => {
        if (try self.tryInterpret(node, false, ctx)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
      .branches => |br| return try self.probeNodeList(br.branches, ctx),
      .concat => |con| {
        var inner =
          (try self.probeNodeList(con.items, ctx)) orelse return null;
        if (!inner.is(.poison))
          inner = (try self.ctx.types().concat(inner)) orelse {
            self.ctx.logger.InvalidInnerConcatType(
              node.pos, &[_]model.Type{inner});
            std.debug.panic("here", .{});
            node.data = .poisonNode;
            return model.Type{.intrinsic = .poison};
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
          try builder.push((try self.probeType(item.content, ctx)) orelse {
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
          if (try self.tryInterpret(node, true, ctx)) |expr| {
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
          .ext_func => |ef| ef.callable,
          .ny_func => |nf| nf.callable,
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
      .unresolved_call, .unresolved_symref => return null,
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

  /// Same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals.
  ///
  /// Give probed==true if t resulted from probing input. probed==false will
  /// calculate the actual type of inner structures and check them for
  /// compatibility with t.
  fn interpretWithTargetType(
      self: *Interpreter, input: *model.Node, t: model.Type, probed: bool,
      ctx: ?*graph.ResolutionContext) nyarna.Error!?*model.Expression {
    switch (input.data) {
      .access, .assign, .definition, .funcgen, .location, .resolved_symref,
      .resolved_call, .typegen =>
        return self.tryInterpret(input, false, ctx),
      .branches => |br| {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse return null;
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
        }
        const condition = cblk: {
          // TODO: use intrinsic Boolean type here
          if (try self.interpretWithTargetType(br.condition,
              model.Type{.intrinsic = .literal}, false, ctx)) |expr|
            break :cblk expr
          else return null;
        };

        var failed_some = false;
        for (br.branches) |*node| {
          if (node.*.data != .expression) {
            if (try self.interpretWithTargetType(node.*, t, probed, ctx))
                |expr| {
              const expr_node = try self.allocator().create(model.Node);
              expr_node.* = .{
                .data = .{.expression = expr},
                .pos = node.*.pos,
              };
              node.* = expr_node;
            } else failed_some = true;
          }
        }
        if (failed_some) return null;
        const exprs = try self.ctx.global().alloc(
          *model.Expression, br.branches.len);
        for (br.branches) |item, i|
          exprs[i] = item.data.expression;
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .branches = .{
              .condition = condition,
              .branches = exprs,
            },
          },
          .expected_type = t,
        };
        return expr;
      },
      .concat => |con| {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse return null;
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
        }
        var failed_some = false;
        for (con.items) |*node| {
          if (node.*.data != .expression) {
            if (try self.interpretWithTargetType(node.*, t, probed, ctx))
                |expr| {
              const expr_node = try self.allocator().create(model.Node);
              expr_node.* = .{
                .data = .{.expression = expr},
                .pos = node.*.pos,
              };
              node.* = expr_node;
            } else failed_some = true;
          }
        }
        if (failed_some) return null;
        const exprs = try self.ctx.global().alloc(
          *model.Expression, con.items.len);
        // TODO: properly handle paragraph types
        for (con.items) |item, i|
          exprs[i] = item.data.expression;
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .concatenation = exprs,
          },
          .expected_type = t,
        };
        return expr;
      },
      .expression, .unresolved_call, .unresolved_symref => return null,
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| {
        const expr = try self.createPublic(model.Expression);
        try self.createTextLiteral(l, t, expr);
        expr.expected_type = t;
        return expr;
      },
      .paras => unreachable, // TODO
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
  pub fn associate(self: *Interpreter, node: *model.Node, t: model.Type,
      ctx: ?*graph.ResolutionContext) !?*model.Expression {
    return if (try self.interpretWithTargetType(node, t, false, ctx)) |expr|
      blk: {
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

};