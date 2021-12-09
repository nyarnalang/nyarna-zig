const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const ModuleLoader = @import("load.zig").ModuleLoader;
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
  /// The loader that owns this interpreter.
  loader: *ModuleLoader,
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
  /// The namespace on which the currently evaluated keyword has been called.
  currently_called_ns: u15 = undefined,

  pub fn init(loader: *ModuleLoader, input: *const model.Source) !Interpreter {
    var ret = Interpreter{
      .input = input,
      .loader = loader,
      .storage = std.heap.ArenaAllocator.init(loader.context.allocator),
      .command_characters = .{},
      .namespaces = .{},
      .syntax_registry = .{syntaxes.SymbolDefs.locations(),
                           syntaxes.SymbolDefs.definitions()},
    };
    errdefer ret.deinit();
    try ret.addNamespace('\\');
    return ret;
  }

  /// discards the internal storage for AST nodes.
  pub fn deinit(self: *Interpreter) void {
    self.storage.deinit();
  }

  /// create an object in the public (Loader-wide) storage.
  pub inline fn createPublic(self: *Interpreter, comptime T: type) !*T {
    return self.loader.context.storage.allocator.create(T);
  }

  pub inline fn types(self: *Interpreter) *nyarna.types.Lattice {
    return &self.loader.context.types;
  }

  pub fn addNamespace(self: *Interpreter, character: u21) !void {
    const index = self.namespaces.items.len;
    if (index > std.math.maxInt(u16)) return nyarna.Error.too_many_namespaces;
    try self.command_characters.put(
      &self.storage.allocator, character, @intCast(u15, index));
    try self.namespaces.append(&self.storage.allocator, .{});
    //const ns = &self.namespaces.items[index]; TODO: do we need this?
    // intrinsic symbols of every namespace.
    try self.importModuleSyms(self.loader.context.intrinsics, index);
  }

  pub fn importModuleSyms(self: *Interpreter, module: *const model.Module,
                          ns_index: usize) !void {
    const ns = &self.namespaces.items[ns_index];
    for (module.symbols) |sym| {
      const name = sym.name;
      std.debug.print("adding symbol {s}\n", .{name});
      try ns.put(&self.storage.allocator, name, sym);
    }
  }

  pub fn removeNamespace(self: *Interpreter, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  fn reportImmediateResolveFailures(
      self: *Interpreter, node: *model.Node) void {
    switch (node.data) {
      .resolved_call, .literal, .resolved_symref, .expression, .poisonNode,
      .voidNode => {},
      .access => |*acc| self.reportImmediateResolveFailures(acc.subject),
      .assignment => |*ass| {
        switch (ass.target) {
          .unresolved => |unres| self.reportImmediateResolveFailures(unres),
          .resolved => {},
        }
        self.reportImmediateResolveFailures(ass.replacement);
      },
      .unresolved_call => |*uc| {
        self.reportImmediateResolveFailures(uc.target);
        for (uc.proto_args) |*arg|
          self.reportImmediateResolveFailures(arg.content);
      },

      .branches => |*br| {
        self.reportImmediateResolveFailures(br.condition);
        for (br.branches) |branch| self.reportImmediateResolveFailures(branch);
      },
      .concatenation => |*con| {
        for (con.content) |item| self.reportImmediateResolveFailures(item);
      },
      .paragraphs => |*para| {
        for (para.items) |*item|
          self.reportImmediateResolveFailures(item.content);
      },
      .unresolved_symref => {
        self.loader.logger.CannotResolveImmediately(node.pos);
      }
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
  pub fn tryInterpret(self: *Interpreter, input: *model.Node,
                      report_failure: bool,
                      ctx: ?*graph.ResolutionContext) nyarna.Error!*model.Node {
    return switch (input.data) {
      .access => blk: {
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
            input.data = .{.expression = expr};
          },
          .func_ref => |ref| {
            const expr =
              try self.createPublic(model.Expression);
            if (ref.prefix != null) {
              self.loader.logger.PrefixedFunctionMustBeCalled(input.pos);
              expr.fillPoison(input.pos);
            } else {
              self.fillLiteral(input.pos, expr, .{
                .funcref = .{
                  .func = ref.target
                },
              });
            }
            input.data = .{.expression = expr};
          },
          .type_ref => |ref| {
            const expr = try self.createPublic(model.Expression);
            self.fillLiteral(input.pos, expr, .{
              .typeval = .{
                .t = ref.*,
              },
            });
            input.data = .{.expression = expr};
          },
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
            input.data = .{.expression = expr};
          },
          .failed => {},
          .poison => {
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(input.pos);
            input.data = .{.expression = expr};
          },
        }
        break :blk input;
      },
      .assignment => |*ass| blk: {
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
              .func_ref, .type_ref, .expr_chain => {
                self.loader.logger.InvalidLvalue(node.pos);
                return try model.Node.poison(&self.storage.allocator, node.pos);
              },
              .poison =>
                return try model.Node.poison(&self.storage.allocator, node.pos),
              .failed =>
                break :blk input,
            }
          }
        };
        const target_expr = (try self.associate(ass.replacement, target.t))
          orelse break :blk input;
        const expr = try self.createPublic(model.Expression);
        const path = try std.mem.dupe(&self.loader.context.storage.allocator,
          usize, target.path);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .assignment = .{
              .target = target.target,
              .path = path,
              .expr = target_expr,
            },
          },
          .expected_type = model.Type{.intrinsic = .void},
        };
        input.data = .{.expression = expr};
        break :blk input;
      },
      .branches, .concatenation, .paragraphs => blk: {
        const ret_type =
          (try self.probeType(input, ctx)) orelse break :blk input;
        break :blk self.interpretWithTargetType(input, ret_type, true);
      },
      .resolved_symref => |ref| blk: {
        const expr = try self.createPublic(model.Expression);
        switch (ref.sym.data) {
          .ext_func, .ny_func => self.fillLiteral(input.pos, expr, .{
            .funcref = .{
              .func = ref.sym,
            },
          }),
          .variable => |*v| {
            expr.* = .{
              .pos = input.pos,
              .data = .{
                .var_retrieval = .{
                  .variable = v
                },
              },
              .expected_type = v.t,
            };
          },
          .ny_type => |*t| self.fillLiteral(input.pos, expr, .{
            .typeval = .{
              .t = t.*
            },
          }),
        }
        input.data = .{.expression = expr};
        break :blk input;
      },
      .resolved_call => |*rc| blk: {
        const sig = switch (rc.target.expected_type.structural.*) {
          .callable => |*c| c.sig,
          else => unreachable
        };
        const is_keyword = sig.returns.is(.ast_node);
        const allocator = if (is_keyword) &self.storage.allocator
                          else &self.loader.context.storage.allocator;
        var failed_to_interpret = std.ArrayListUnmanaged(*model.Node){};
        var args_failed_to_interpret = false;
        for (rc.args) |*arg, i| {
          if (arg.*.data != .expression) {
            arg.*.data =
              if (try self.associate(arg.*, sig.parameters[i].ptype)) |e| .{
                .expression = e,
              } else {
                args_failed_to_interpret = true;
                if (is_keyword) try
                  failed_to_interpret.append(&self.storage.allocator, arg.*);
                continue;
              };
          }
        }

        if (args_failed_to_interpret) {
          if (is_keyword) {
            for (failed_to_interpret.items) |arg|
              self.reportImmediateResolveFailures(arg);
            input.data = .poisonNode;
          }
        } else {
          const args = try allocator.alloc(
            *model.Expression, sig.parameters.len);
          var seen_poison = false;
          for (rc.args) |arg, i| {
            args[i] = arg.data.expression;
            if (args[i].expected_type.is(.poison)) seen_poison = true;
          }
          const expr = try allocator.create(model.Expression);
          expr.* = .{
            .pos = input.pos,
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
            var eval = nyarna.Evaluator{.context = self.loader.context};
            const res = try eval.evaluateKeywordCall(self, &expr.data.call);
            return self.tryInterpret(res, report_failure, ctx);
          } else {
            input.data = .{.expression = expr};
          }
        }
        break :blk input;
      },
      .expression => input,
      .voidNode => blk: {
        const expr = try self.storage.allocator.create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .void,
          .expected_type = .{.intrinsic = .void},
        };
        break :blk input;
      },
      .literal, .unresolved_symref, .unresolved_call, .poisonNode => input,
    };
  }

  pub fn interpret(self: *Interpreter, input: *model.Node)
      nyarna.Error!*model.Expression {
    const res = try self.tryInterpret(input, true, null);
    return switch (res.data) {
      .expression => |expr| expr,
      else => blk: {
        const ret = try self.createPublic(model.Expression);
        ret.fillPoison(input.pos);
        break :blk ret;
      }
    };
  }

  pub fn resolveSymbol(self: *Interpreter, pos: model.Position, ns: u15,
                       name: []const u8) !*model.Node {
    var syms = &self.namespaces.items[ns];
    var ret = try self.storage.allocator.create(model.Node);
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
    /// last chain item was resolved to a type. Type is a pointer into a
    /// model.Symbol.
    type_ref: *model.Type,
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
              // TODO: report error based on the name of target_expr
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
          .expr_chain => |_| {
            // TODO: same as var_chain basically
            unreachable;
          },
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .unresolved_symref => return .failed,
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
        .ny_type => |*t| ChainResolution{
          .type_ref = t,
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
      else => {
        const res = try self.tryInterpret(chain, force_fail, ctx);
        return switch (res.data) {
          .expression => |_| {
            // TODO: resolve accessor chain in context of expression's type and
            // return expr_chain
            unreachable;
          },
          else => @as(ChainResolution, if (force_fail) .poison else .failed),
        };
      }
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
      sup = try self.types().sup(sup, t);
      if (first_incompatible == null and sup.is(.poison)) {
        first_incompatible = i;
      }
    }
    return if (first_incompatible) |index| blk: {
      const type_arr =
        try self.storage.allocator.alloc(model.Type, index + 1);
      type_arr[0] = (try self.probeType(nodes[index], ctx)).?;
      var j = @as(usize, 0);
      while (j < index) : (j += 1) {
        type_arr[j + 1] = (try self.probeType(nodes[j], ctx)).?;
      }
      self.loader.logger.IncompatibleTypes(nodes[index].pos, type_arr);
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
      sup = try self.types().sup(sup, self.containedScalar(t) or continue);
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
      .literal => |l| return model.Type{.intrinsic =
        if (l.kind == .space) .space else .literal},
      .access, .assignment => {
        const interpreted = try self.tryInterpret(node, false, ctx);
        return switch (interpreted.data) {
          .expression => |expr| expr.expected_type,
          else => null
        };
      },
      .branches => |br| return try self.probeNodeList(br.branches, ctx),
      .concatenation => |con| {
        var inner =
          (try self.probeNodeList(con.content, ctx)) orelse return null;
        if (!inner.is(.poison))
          inner = (try self.types().concat(inner)) orelse {
            self.loader.logger.InvalidInnerConcatType(
              node.pos, &[_]model.Type{inner});
            node.data = .poisonNode;
            return model.Type{.intrinsic = .poison};
          };
        if (inner.is(.poison)) {
          node.data = .poisonNode;
        }
        return inner;
      },
      .paragraphs => |*para| {
        var builder =
          nyarna.types.ParagraphTypeBuilder.init(self.types(), false);
        var seen_unfinished = false;
        for (para.items) |*item|
          try builder.push((try self.probeType(item.content, ctx)) orelse {
            seen_unfinished = true;
            continue;
          });
        return if (seen_unfinished) null else
          (try builder.finish()).resulting_type;
      },
      .unresolved_symref => return null,
      .resolved_symref => |ref| switch (ref.sym.data) {
        .ext_func => |ef| return ef.callable.typedef(),
        .ny_func => |nf| return nf.callable.typedef(),
        .variable => |v| return v.t,
        .ny_type => |t| switch (t) {
          .intrinsic => |it| return switch (it) {
            .location, .definition => unreachable, // TODO
            else => model.Type{.intrinsic = .non_callable_type},
          },
          .structural => |st| return switch (st.*) {
            .concat, .paragraphs, .list, .map => unreachable, // TODO
            else => model.Type{.intrinsic = .non_callable_type},
          },
          .instantiated => |it| return switch (it.data) {
            .textual, .numeric, .float, .tenum => unreachable, // TODO
            .record => |rt| rt.typedef(),
          },
        },
      },
      .unresolved_call => return null,
      .resolved_call => |rc|
        return rc.target.expected_type.structural.callable.sig.returns,
      .expression => |e| return e.expected_type,
      .poisonNode => return model.Type{.intrinsic = .poison},
      .voidNode => return model.Type{.intrinsic = .void},
    }
  }

  pub inline fn fillLiteral(
      self: *Interpreter, at: model.Position, e: *model.Expression,
      content: model.Value.Data) void {
    self.loader.context.fillLiteral(at, e, content);
  }

  pub inline fn genPublicLiteral(self: *Interpreter, at: model.Position,
                                 content: model.Value.Data) !*model.Expression {
    return self.loader.context.genLiteral(at, content);
  }

  pub inline fn genValueNode(self: *Interpreter, pos: model.Position,
                             content: model.Value.Data) !*model.Node {
    const expr = try self.genPublicLiteral(pos, content);
    var ret = try self.storage.allocator.create(model.Node);
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
          self.fillLiteral(l.pos(), e, .{
            .text = .{
              .t = t,
              .value = try std.mem.dupe(
                &self.loader.context.storage.allocator, u8, l.content),
            },
          }) else {
            self.loader.logger.ExpectedExprOfTypeXGotY(
              l.pos(), &[_]model.Type{t, .{.intrinsic = .literal}});
            e.fillPoison(l.pos());
          },
        .literal, .raw =>
          self.fillLiteral(l.pos(), e, .{
            .text = .{
              .t = t,
              .value = try std.mem.dupe(
                &self.loader.context.storage.allocator, u8, l.content),
            },
          }),
        else =>
          self.fillLiteral(l.pos(), e, .{
          .text = .{
            .t = .{.intrinsic = if (l.kind == .text) .literal else .space},
            .value = try std.mem.dupe(
              &self.loader.context.storage.allocator, u8, l.content),
          },
        }),
      },
      .structural => |struc| switch (struc.*) {
        .optional => |*op| try self.createTextLiteral(l, op.inner, e),
        .concat => |*con| try self.createTextLiteral(l, con.inner, e),
        .paragraphs => unreachable,
        .list => |*list| try self.createTextLiteral(l, list.inner, e), // TODO
        .map, .callable => {
          self.loader.logger.ExpectedExprOfTypeXGotY(
            l.pos(), &[_]model.Type{t, .{.intrinsic = .literal}});
          e.fillPoison(l.pos());
        },
        .intersection => |*inter|
          if (inter.scalar) |scalar| {
            try self.createTextLiteral(l, scalar, e);
          } else {
            self.loader.logger.ExpectedExprOfTypeXGotY(
              l.pos(), &[_]model.Type{t, .{.intrinsic = .literal}});
            e.fillPoison(l.pos());
          }
      },
      .instantiated => |ti| switch (ti.data) {
        .textual => unreachable, // TODO
        .numeric => unreachable, // TODO
        .float => unreachable, // TODO
        .tenum => unreachable, // TODO
        .record => {
          self.loader.logger.ExpectedExprOfTypeXGotY(l.pos(),
            &[_]model.Type{
              t, .{.intrinsic = if (l.kind == .text) .literal else .space},
            });
          e.fillPoison(l.pos());
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
      self: *Interpreter, input: *model.Node, t: model.Type, probed: bool)
      nyarna.Error!*model.Node {
    return switch (input.data) {
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| blk: {
        const e = try self.createPublic(model.Expression);
        try self.createTextLiteral(l, t, e);
        e.expected_type = t;
        input.data = .{.expression = e};
        break :blk input;
      },
      .access, .assignment, .resolved_symref, .resolved_call =>
        self.tryInterpret(input, false, null),
      .branches => |br| blk: {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse break :blk input;
          if (!actual_type.is(.poison) and
              !self.types().lesserEqual(actual_type, t)) {
            actual_type = .{.intrinsic = .poison};
            self.loader.logger.ExpectedExprOfTypeXGotY(
              input.pos, &[_]model.Type{t, actual_type});
          }
          if (actual_type.is(.poison)) {
            input.data = .poisonNode;
            break :blk input;
          }
        }
        const condition = cblk: {
          // TODO: use intrinsic Boolean type here
          const res = try self.interpretWithTargetType(
            br.condition, model.Type{.intrinsic = .literal}, false);
          switch (res.data) {
            .expression => |expr| break :cblk expr,
            else => break :blk input,
          }
        };

        var failed_some = false;
        for (br.branches) |*node| {
          node.* = try self.interpretWithTargetType(node.*, t, probed);
          if (node.*.data != .expression) failed_some = true;
        }
        if (failed_some) break :blk input;
        const exprs = try self.loader.context.storage.allocator.alloc(
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
        input.data = .{.expression = expr};
        break :blk input;
      },
      .concatenation => |con| blk: {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse break :blk input;
          if (!actual_type.is(.poison) and
              !self.types().lesserEqual(actual_type, t)) {
            actual_type = .{.intrinsic = .poison};
            self.loader.logger.ExpectedExprOfTypeXGotY(
              input.pos, &[_]model.Type{t, actual_type});
          }
          if (actual_type.is(.poison)) {
            input.data = .poisonNode;
            break :blk input;
          }
        }
        var failed_some = false;
        for (con.content) |*node| {
          node.* = try self.interpretWithTargetType(node.*, t, probed);
          if (node.*.data != .expression) failed_some = true;
        }
        if (failed_some) break :blk input;
        const exprs = try self.loader.context.storage.allocator.alloc(
          *model.Expression, con.content.len);
        // TODO: properly handle paragraph types
        for (con.content) |item, i|
          exprs[i] = item.data.expression;
        const expr = try self.createPublic(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .{
            .concatenation = exprs,
          },
          .expected_type = t,
        };
        input.data = .{.expression = expr};
        break :blk input;
      },
      .paragraphs => unreachable,
      .unresolved_symref, .unresolved_call, .expression => input,
      .voidNode => blk: {
        const e = try self.createPublic(model.Expression);
        e.fillVoid(input.pos);
        input.data = .{.expression = e};
        break :blk input;
      },
      .poisonNode => blk: {
        const e = try self.createPublic(model.Expression);
        e.fillPoison(input.pos);
        input.data = .{.expression = e};
        break :blk input;
      }
    };
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
  pub fn associate(self: *Interpreter, node: *model.Node, t: model.Type)
      !?*model.Expression {
    return switch ((try self.interpretWithTargetType(node, t, false)).data) {
      .expression => |expr| blk: {
        if (expr.expected_type.is(.poison)) break :blk expr;
        if (self.types().lesserEqual(expr.expected_type, t)) {
          expr.expected_type = t;
          break :blk expr;
        }
        // TODO: semantic conversions here
        self.loader.logger.ExpectedExprOfTypeXGotY(
          node.pos, &[_]model.Type{t, expr.expected_type});
        expr.fillPoison(node.pos);
        break :blk expr;
      },
      else => null
    };
  }

};