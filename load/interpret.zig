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

  fn reportResolveFailures(
      self: *Interpreter, node: *model.Node, immediate: bool) void {
    switch (node.data) {
      .resolved_call, .literal, .resolved_symref, .expression, .poisonNode,
      .voidNode => {},
      .access => |*acc| self.reportResolveFailures(acc.subject, immediate),
      .assignment => |*ass| {
        switch (ass.target) {
          .unresolved => |unres| self.reportResolveFailures(unres, immediate),
          .resolved => {},
        }
        self.reportResolveFailures(ass.replacement, immediate);
      },
      .unresolved_call => |*uc| {
        self.reportResolveFailures(uc.target, immediate);
        for (uc.proto_args) |*arg|
          self.reportResolveFailures(arg.content, immediate);
      },

      .branches => |*br| {
        self.reportResolveFailures(br.condition, immediate);
        for (br.branches) |branch|
          self.reportResolveFailures(branch, immediate);
      },
      .concatenation => |*con| {
        for (con.content) |item| self.reportResolveFailures(item, immediate);
      },
      .paragraphs => |*para| {
        for (para.items) |*item|
          self.reportResolveFailures(item.content, immediate);
      },
      .unresolved_symref => if (immediate)
        self.loader.logger.CannotResolveImmediately(node.pos)
      else
        self.loader.logger.UnknownSymbol(node.pos),
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
      self: *Interpreter, input: *model.Node, report_failure: bool,
      ctx: ?*graph.ResolutionContext) nyarna.Error!?*model.Expression {
    switch (input.data) {
      .access => {
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
              self.loader.logger.PrefixedFunctionMustBeCalled(input.pos);
              expr.fillPoison(input.pos);
            } else {
              self.fillLiteral(input.pos, expr, .{
                .funcref = .{
                  .func = ref.target
                },
              });
            }
            return expr;
          },
          .type_ref => |ref| {
            const expr = try self.createPublic(model.Expression);
            self.fillLiteral(input.pos, expr, .{
              .@"type" = .{
                .t = ref.*,
              },
            });
            return expr;
          },
          .proto_ref => |ref| {
            const expr = try self.createPublic(model.Expression);
            self.fillLiteral(input.pos, expr, .{
              .prototype = .{
                .pt = ref.*,
              },
            });
            return expr;
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
            return expr;
          },
          .failed => return null,
          .poison => {
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(input.pos);
            return expr;
          },
        }
      },
      .assignment => |*ass| {
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
                self.loader.logger.InvalidLvalue(node.pos);
                const expr = try self.createPublic(model.Expression);
                expr.fillPoison(input.pos);
                return expr;
              },
              .poison => {
                const expr = try self.createPublic(model.Expression);
                expr.fillPoison(input.pos);
                return expr;
              },
              .failed => return null,
            }
          }
        };
        const target_expr = (try self.associate(ass.replacement, target.t))
            orelse {
          if (report_failure)
            self.reportResolveFailures(ass.replacement, false);
          return null;
        };
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
        return expr;
      },
      .branches, .concatenation, .paragraphs => {
        const ret_type = (try self.probeType(input, ctx)) orelse {
          if (report_failure) self.reportResolveFailures(input, false);
          return null;
        };
        return self.interpretWithTargetType(input, ret_type, true);
      },
      .resolved_symref => |ref| {
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
          .@"type" => |*t| self.fillLiteral(input.pos, expr, .{
            .@"type" = .{
              .t = t.*
            },
          }),
          .prototype => |pt| self.fillLiteral(input.pos, expr, .{
            .prototype = .{
              .pt = pt,
            },
          }),
        }
        return expr;
      },
      .resolved_call => |*rc| {
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
        const allocator = if (is_keyword) &self.storage.allocator
                          else &self.loader.context.storage.allocator;
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
              self.reportResolveFailures(arg, true);
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(input.pos);
            return expr;
          } else {
            if (report_failure) {
              for (failed_to_interpret.items) |arg|
                self.reportResolveFailures(arg, false);
            }
            return null;
          }
        }

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
          const interpreted_res =
            try self.tryInterpret(res, report_failure, ctx);
          // a call to a keyword can never return a node that cannot be
          // interpreted.
          std.debug.assert(interpreted_res != null);
          return interpreted_res;
        } else {
          return expr;
        }
      },
      .expression => |expr| return expr,
      .voidNode => {
        const expr = try self.storage.allocator.create(model.Expression);
        expr.fillVoid(input.pos);
        return expr;
      },
      .poisonNode => {
        const expr = try self.storage.allocator.create(model.Expression);
        expr.fillPoison(input.pos);
        return expr;
      },
      .literal => |lit| {
        return try self.genPublicLiteral(input.pos, .{
          .text = .{
            .t = model.Type{
              .intrinsic = if (lit.kind == .space) .space else .literal},
            .content = try std.mem.dupe(
              &self.loader.context.storage.allocator, u8, lit.content),
          },
        });
      },
      .unresolved_symref, .unresolved_call => {
        if (report_failure) self.reportResolveFailures(input, false);
        return null;
      },
    }
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
              self.loader.logger.PrefixedFunctionMustBeCalled(
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
        if (try self.tryInterpret(node, false, ctx)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        } else return null;
      },
      .branches => |br| return try self.probeNodeList(br.branches, ctx),
      .concatenation => |con| {
        var inner =
          (try self.probeNodeList(con.content, ctx)) orelse return null;
        if (!inner.is(.poison))
          inner = (try self.types().concat(inner)) orelse {
            self.loader.logger.InvalidInnerConcatType(
              node.pos, &[_]model.Type{inner});
            std.debug.panic("here", .{});
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
              self.types().constructors.prototypes.record.callable.typedef(),
            .concat =>
              self.types().constructors.prototypes.concat.callable.typedef(),
            .list =>
              self.types().constructors.prototypes.list.callable.typedef(),
            else => model.Type{.intrinsic = .prototype},
          }),
        };
        // references to keywords must not be used as standalone values.
        std.debug.assert(!callable.sig.returns.is(.ast_node));
        return callable.typedef();
      },
      .unresolved_call => return null,
      .resolved_call => |rc| {
        if (rc.target.expected_type.structural.callable.sig.returns.is(
            .ast_node)) {
          // call to keywords must be interpretable at this point.
          if (try self.tryInterpret(node, true, ctx)) |expr| {
            node.data = .{.expression = expr};
            return expr.expected_type;
          } else {
            node.data = .poisonNode;
            return model.Type{.intrinsic = .poison};
          }
        } else return rc.target.expected_type.structural.callable.sig.returns;
      },
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
              .content = try std.mem.dupe(
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
              .content = try std.mem.dupe(
                &self.loader.context.storage.allocator, u8, l.content),
            },
          }),
        else =>
          self.fillLiteral(l.pos(), e, .{
          .text = .{
            .t = .{.intrinsic = if (l.kind == .text) .literal else .space},
            .content = try std.mem.dupe(
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
      nyarna.Error!?*model.Expression {
    switch (input.data) {
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| {
        const expr = try self.createPublic(model.Expression);
        try self.createTextLiteral(l, t, expr);
        expr.expected_type = t;
        return expr;
      },
      .access, .assignment, .resolved_symref, .resolved_call =>
        return self.tryInterpret(input, false, null),
      .branches => |br| {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse return null;
          if (!actual_type.is(.poison) and
              !self.types().lesserEqual(actual_type, t)) {
            actual_type = .{.intrinsic = .poison};
            self.loader.logger.ExpectedExprOfTypeXGotY(
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
          if (try self.interpretWithTargetType(
              br.condition, model.Type{.intrinsic = .literal}, false)) |expr|
            break :cblk expr
          else return null;
        };

        var failed_some = false;
        for (br.branches) |*node| {
          if (node.*.data != .expression) {
            if (try self.interpretWithTargetType(node.*, t, probed)) |expr| {
              const expr_node = try self.storage.allocator.create(model.Node);
              expr_node.* = .{
                .data = .{.expression = expr},
                .pos = node.*.pos,
              };
              node.* = expr_node;
            } else failed_some = true;
          }
        }
        if (failed_some) return null;
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
        return expr;
      },
      .concatenation => |con| {
        if (!probed) {
          var actual_type =
            (try self.probeType(input, null)) orelse return null;
          if (!actual_type.is(.poison) and
              !self.types().lesserEqual(actual_type, t)) {
            actual_type = .{.intrinsic = .poison};
            self.loader.logger.ExpectedExprOfTypeXGotY(
              input.pos, &[_]model.Type{t, actual_type});
          }
          if (actual_type.is(.poison)) {
            const expr = try self.createPublic(model.Expression);
            expr.fillPoison(input.pos);
            return expr;
          }
        }
        var failed_some = false;
        for (con.content) |*node| {
          if (node.*.data != .expression) {
            if (try self.interpretWithTargetType(node.*, t, probed)) |expr| {
              const expr_node = try self.storage.allocator.create(model.Node);
              expr_node.* = .{
                .data = .{.expression = expr},
                .pos = node.*.pos,
              };
              node.* = expr_node;
            } else failed_some = true;
          }
        }
        if (failed_some) return null;
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
        return expr;
      },
      .paragraphs => unreachable,
      .unresolved_symref, .unresolved_call, .expression => return null,
      .voidNode => {
        const expr = try self.createPublic(model.Expression);
        expr.fillVoid(input.pos);
        return expr;
      },
      .poisonNode => {
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
  pub fn associate(self: *Interpreter, node: *model.Node, t: model.Type)
      !?*model.Expression {
    return if (try self.interpretWithTargetType(node, t, false)) |expr| blk: {
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
    } else null;
  }

};