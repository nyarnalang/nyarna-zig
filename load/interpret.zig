const std = @import("std");
const nyarna = @import("../nyarna.zig");
const data = nyarna.data;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const ModuleLoader = @import("load.zig").ModuleLoader;
const parse = @import("parse.zig");
const syntaxes = @import("syntaxes.zig");


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
  input: *const data.Source,
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
    std.ArrayListUnmanaged(std.StringArrayHashMapUnmanaged(*data.Symbol)),
  /// The local storage of the interpreter where all data will be allocated that
  /// will be discarded when the interpreter finishes. This includes primarily
  /// the AST nodes which will be interpreted into expressions during
  /// interpretation. Some AST nodes may become exported (for example, as part
  /// of a function implementation) in which case they must be copied to the
  /// global storage. This happens exactly at the time an AST node is put into
  /// an AST data.Value.
  storage: std.heap.ArenaAllocator,
  /// Array of alternative syntaxes known to the interpreter (7.12).
  /// TODO: make this user-extensible
  syntax_registry: [2]syntaxes.SpecialSyntax,

  pub fn init(loader: *ModuleLoader, input: *const data.Source) !Interpreter {
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

  pub fn importModuleSyms(self: *Interpreter, module: *const data.Module,
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
  pub fn tryInterpret(self: *Interpreter, input: *data.Node,
                      report_failure: bool) nyarna.Error!*data.Node {
    return switch (input.data) {
      .access => blk: {
        switch (try self.resolveChain(input, report_failure)) {
          .var_chain => |vc| {
            const retr =
              try self.createPublic(data.Expression);
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
              try self.createPublic(data.Expression);
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
              try self.createPublic(data.Expression);
            if (ref.prefix != null) {
              self.loader.logger.PrefixedFunctionMustBeCalled(input.pos);
              expr.* = data.Expression.poison(input.pos);
            } else {
              expr.* = data.Expression.literal(input.pos, .{
                .funcref = .{
                  .func = ref.target
                },
              });
            }
            input.data = .{.expression = expr};
          },
          .type_ref => |ref| {
            const expr =
              try self.createPublic(data.Expression);
            expr.* = data.Expression.literal(input.pos, .{
              .typeval = .{
                .t = ref.*,
              },
            });
            input.data = .{.expression = expr};
          },
          .expr_chain => |ec| {
            const expr =
              try self.createPublic(data.Expression);
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
            const expr = try self.createPublic(data.Expression);
            expr.* = data.Expression.poison(input.pos);
            input.data = .{.expression = expr};
          },
        }
        break :blk input;
      },
      .assignment => |*ass| blk: {
        const target = switch (ass.target) {
          .resolved => |*val| val,
          .unresolved => |node| innerblk: {
            switch (try self.resolveChain(node, report_failure)) {
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
                return try data.Node.poison(&self.storage.allocator, node.pos);
              },
              .poison =>
                return try data.Node.poison(&self.storage.allocator, node.pos),
              .failed =>
                break :blk input,
            }
          }
        };
        const target_expr = (try self.associate(ass.replacement, target.t))
          orelse break :blk input;
        const expr = try self.createPublic(data.Expression);
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
          .expected_type = data.Type{.intrinsic = .void},
        };
        input.data = .{.expression = expr};
        break :blk input;
      },
      .concatenation => |con| blk: {
        var failed_some = false;
        var inner_type = data.Type{.intrinsic = .every};
        var first_incompatible: ?usize = null;
        for (con.content) |*item, i| {
          item.* = try self.tryInterpret(item.*, report_failure);
          switch (item.*.data) {
            .expression => |expr| {
              inner_type = try self.types().sup(inner_type, expr.expected_type);
              if (first_incompatible == null and inner_type.is(.poison))
                first_incompatible = i;
            },
            else => failed_some = true,
          }
        }
        if (failed_some) break :blk input;
        const expr = try self.createPublic(data.Expression);
        if (first_incompatible) |index| {
          const type_arr =
            try self.storage.allocator.alloc(data.Type, index + 1);
          type_arr[0] = con.content[index].data.expression.expected_type;
          var j = @as(usize, 0);
          while (j < index) : (j += 1) {
            type_arr[j + 1] =
              con.content[j].data.expression.expected_type;
          }
          self.loader.logger.IncompatibleTypes(expr.pos, type_arr);
          expr.* = data.Expression.poison(input.pos);
        } else if (try self.types().concat(inner_type)) |expr_type| {
          const exprs = try self.loader.context.storage.allocator.alloc(
            *data.Expression, con.content.len);
          // TODO: properly handle paragraph types
          for (con.content) |item, i| exprs[i] = item.data.expression;
          expr.* = .{
            .pos = input.pos,
            .data = .{
              .concatenation = exprs,
            },
            .expected_type = expr_type,
          };
        } else {
          self.loader.logger.InvalidInnerConcatType(
            input.pos, &[_]data.Type{inner_type});
          expr.* = data.Expression.poison(input.pos);
        }
        input.data = .{.expression = expr};
        break :blk input;
      },
      // TODO: paragraphs (needs type lattice)
      .resolved_symref => |ref| blk: {
        const expr = try self.createPublic(data.Expression);
        switch (ref.data) {
          .ext_func, .ny_func => expr.* = data.Expression.literal(input.pos, .{
            .funcref = .{
              .func = ref
            },
          }),
          .variable => |*v| {
            expr.pos = input.pos;
            expr.data = .{
              .var_retrieval = .{
                .variable = v
              },
            };
            expr.expected_type = v.t;
          },
          .ny_type => |*t| expr.* = data.Expression.literal(input.pos, .{
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
          .callable_type => |*ct| ct.sig,
          else => unreachable
        };
        const is_keyword = sig.returns.is(.ast_node);
        const allocator = if (is_keyword) &self.storage.allocator
                          else &self.loader.context.storage.allocator;
        var args_failed_to_interpret = false;
        for (rc.args) |*arg| {
          arg.* = try self.tryInterpret(arg.*, report_failure or is_keyword);
          if (arg.*.data != .expression) args_failed_to_interpret = true;
        }

        if (args_failed_to_interpret) {
          if (is_keyword) {
            self.loader.logger.KeywordArgsNotAvailable(input.pos);
            input.data = .poisonNode;
          }
        } else {
          const args = try allocator.alloc(
            *data.Expression, sig.parameters.len);
          var seen_poison = false;
          for (rc.args) |arg, i| {
            args[i] = arg.data.expression;
            if (args[i].expected_type.is(.poison)) seen_poison = true;
          }
          const expr = try allocator.create(data.Expression);
          expr.data = .{
            .call = .{
              .target = rc.target,
              .exprs = args,
            },
          };
          if (is_keyword) {
            var eval = nyarna.Evaluator{.context = self.loader.context};
            const res = try eval.evaluateKeywordCall(self, &expr.data.call);
            return self.tryInterpret(res, report_failure);
          } else {
            input.data = .{.expression = expr};
          }
        }
        break :blk input;
      },
      .expression => input,
      .voidNode => blk: {
        const expr = try self.storage.allocator.create(data.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .void,
          .expected_type = .{.intrinsic = .void},
        };
        break :blk input;
      },
      else => input
    };
  }

  pub fn interpret(self: *Interpreter, input: *data.Node)
      nyarna.Error!*data.Expression {
    const res = try self.tryInterpret(input, true);
    return switch (res.data) {
      .expression => |expr| expr,
      else => blk: {
        const ret = try self.createPublic(data.Expression);
        ret.* = data.Expression.poison(input.pos);
        break :blk ret;
      }
    };
  }

  pub fn resolveSymbol(self: *Interpreter, pos: data.Position, ns: u15,
                       name: []const u8) !*data.Node {
    var ret = try self.storage.allocator.create(data.Node);
    ret.pos = pos;

    var syms = &self.namespaces.items[ns];
    ret.data = .{
      .resolved_symref = syms.get(name) orelse {
        ret.data = .{
          .unresolved_symref = .{
            .ns = ns, .name = name
          }
        };
        return ret;
      }
    };
    return ret;
  }

  /// Result of resolving an accessor chain.
  pub const ChainResolution = union(enum) {
    /// chain starts at a variable reference and descends into its fields.
    var_chain: struct {
      /// the target variable that is to be indexed.
      target: struct {
        variable: *data.Symbol.Variable,
        pos: data.Position,
      },
      /// chain into the fields of a variable. Each item is the index of a nested
      /// field.
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      t: data.Type,
    },
    /// last chain item was resolved to a function.
    func_ref: struct {
      /// must be ExtFunc or NyFunc
      target: *data.Symbol,
      signature: *const data.Type.Signature,
      /// set if targt is a function reference in the namespace of a type,
      /// which has been accessed via an expression of that type. That is only
      /// allowed in the context of a call. The caller of resolveChain is to
      /// enforce this.
      prefix: ?*data.Expression = null,
    },
    /// last chain item was resolved to a type. Type is a pointer into a
    /// data.Symbol.
    type_ref: *data.Type,
    /// chain starts at an expression and descends into the returned value.
    expr_chain: struct {
      expr: *data.Expression,
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      t: data.Type,
    },
    /// the resolution failed because an identifier in the chain could not be
    /// resolved – this is not necessarily an error since the chain may be
    /// successfully resolved later.
    failed,
    /// this will be set if the chain is guaranteed to be faulty.
    poison,
  };

  /// resolves an accessor chain of *data.Node. iff force_fail is true, failure
  /// to resolve the base symbol will be reported as error and .poison will be
  /// returned; else no error will be reported and .failed will be returned.
  pub fn resolveChain(self: *Interpreter, chain: *data.Node, force_fail: bool)
      nyarna.Error!ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, force_fail);
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
      .resolved_symref => |sym| return switch(sym.data) {
        .ext_func => |*ef| ChainResolution{
          .func_ref = .{
            .target = sym,
            .signature = ef.sig(),
            .prefix = null,
          },
        },
        .ny_func => |*nf| ChainResolution{
          .func_ref = .{
            .target = sym,
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
        const res = try self.tryInterpret(chain, force_fail);
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

  /// returns the given node's type, if it can be calculated.
  ///
  /// this will modify the given node by interpreting all substructures that
  /// are guaranteed not to be type-dependent on context. This means that all
  /// nodes are evaluated except for literal nodes, paragraphs, concatenations
  /// transitively.
  fn probeType(self: *Interpreter, node: *data.Node) !?data.Type {
    return switch (node.data) {
      .literal => |l| .{.intrinsic =
        if (l.kind == .space) .space else .literal},
      .access, .assignment =>
        if (try self.tryInterpret(node, false)) |expr| blk: {
          node.data = .{
            .expression = expr
          };
          break :blk expr.expected_type;
        } else null,
      .concatenation => |con| blk: {
        var t = .{.intrinsic = .every};
        for (con.content) |item| {
          t = try self.types.sup(
            t, try self.probeType(item) orelse break :blk null);
        }
        break :blk t;
      },
      .paragraphs => unreachable, // TODO
      .unresolved_symref => null,
      .resolved_symref => |ref| switch (ref.data) {
        .ext_func => |_| unreachable,
        .ny_func => |_| unreachable,
        .variable => |_| unreachable,
        .ny_type => |t| switch (t) {
          .intrinsic => |it| switch (it) {
            .location, .definition => unreachable, // TODO
            else => .{.intrinsic = .non_callable_type},
          },
          .structural => |st| switch (st) {
            .concat, .paragraphs, .list, .map => unreachable, // TODO
            else => .{.intrinsic = .non_callable_type},
          },
          .instantiated => |it| switch (it.data) {
            .textual, .numeric, .float, .tenum => unreachable, // TODO
            .record => |rt| .{.structural = .{.callable_type = &rt.signature}},
          },
        },
      },
      .unresolved_call => null,
      .resolved_call => |rc|
        rc.target.expected_type.structural.callable.returns,
      .expression => |e| e.expected_type,
      .voidNode => .{.intrinsic = .void},
    };
  }

  fn createLiteralExpr(self: *Interpreter, l: *data.Node.Literal, t: data.Type,
                       e: *data.Expression) nyarna.Error!void {
    e.* = switch (t) {
      .intrinsic => |it| switch (it) {
        .space => if (l.kind == .space) data.Expression.literal(l.pos(), .{
          .text = .{
            .t = t,
            .value = try std.mem.dupe(
              &self.loader.context.storage.allocator, u8, l.content),
          },
        }) else blk: {
          self.loader.logger.ExpectedExprOfTypeXGotY(
            l.pos(), &[_]data.Type{t, .{.intrinsic = .literal}});
          break :blk data.Expression.poison(l.pos());
        },
        .literal, .raw => data.Expression.literal(l.pos(), .{
          .text = .{
            .t = t,
            .value = try std.mem.dupe(
              &self.loader.context.storage.allocator, u8, l.content),
          },
        }),
        else => data.Expression.literal(l.pos(), .{
          .text = .{
            .t = .{.intrinsic = if (l.kind == .text) .literal else .space},
            .value = try std.mem.dupe(
              &self.loader.context.storage.allocator, u8, l.content),
          },
        }),
      },
      .structural => |struc| switch (struc.*) {
        .optional => |*op| {
          try self.createLiteralExpr(l, op.inner, e);
          return;
        },
        .concat => |*con| {
          try self.createLiteralExpr(l, con.inner, e);
          return;
        },
        .paragraphs => unreachable,
        .list => |*list| {
          try self.createLiteralExpr(l, list.inner, e);
          return;
        },
        .map, .callable, .callable_type => blk: {
          self.loader.logger.ExpectedExprOfTypeXGotY(
            l.pos(), &[_]data.Type{t, .{.intrinsic = .literal}});
          break :blk data.Expression.poison(l.pos());
        },
        .intersection => |*inter| blk: {
          if (inter.scalar) |scalar| {
            try self.createLiteralExpr(l, scalar, e);
            return;
          }
          self.loader.logger.ExpectedExprOfTypeXGotY(
            l.pos(), &[_]data.Type{t, .{.intrinsic = .literal}});
          break :blk data.Expression.poison(l.pos());
        }
      },
      .instantiated => |ti| switch (ti.data) {
        .textual => unreachable, // TODO
        .numeric => unreachable, // TODO
        .float => unreachable, // TODO
        .tenum => unreachable, // TODO
        .record => blk: {
          self.loader.logger.ExpectedExprOfTypeXGotY(l.pos(),
            &[_]data.Type{
              t, .{.intrinsic = if (l.kind == .text) .literal else .space},
            });
          break :blk data.Expression.poison(l.pos());
        },
      },
    };
  }

  /// same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals. fills an already
  fn interpretWithTargetType(self: *Interpreter, input: *data.Node,
                             t: data.Type) !*data.Node {
    return switch (input.data) {
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| blk: {
        const e = try self.createPublic(data.Expression);
        try self.createLiteralExpr(l, t, e);
        e.expected_type = t;
        input.data = .{.expression = e};
        break :blk input;
      },
      .access, .assignment, .resolved_symref, .resolved_call, .branches =>
        self.tryInterpret(input, false),
      .concatenation => unreachable,
      .paragraphs => unreachable,
      .unresolved_symref, .unresolved_call, .expression => input,
      .voidNode => blk: {
        const e = try self.createPublic(data.Expression);
        e.* = data.Expression.voidExpr(input.pos);
        input.data = .{.expression = e};
        break :blk input;
      },
      .poisonNode => blk: {
        const e = try self.createPublic(data.Expression);
        e.* = data.Expression.poison(input.pos);
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
  pub fn associate(self: *Interpreter, node: *data.Node, t: data.Type)
      !?*data.Expression {
    return switch ((try self.interpretWithTargetType(node, t)).data) {
      .expression => |expr| blk: {
        if (self.types().lesserEqual(expr.expected_type, t)) {
          expr.expected_type = t;
          break :blk expr;
        }
        // TODO: semantic conversions here
        self.loader.logger.ExpectedExprOfTypeXGotY(
          node.pos, &[_]data.Type{t, expr.expected_type});
        expr.* = data.Expression.poison(node.pos);
        break :blk expr;
      },
      else => null
    };
  }

};