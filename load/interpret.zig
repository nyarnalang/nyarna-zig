const std = @import("std");
const data = @import("data");
const parse = @import("parse.zig");
const errors = @import("errors");
const types = @import("types");
const lib = @import("lib.zig");
const syntaxes = @import("syntaxes.zig");

pub const Errors = error {
  referred_source_unavailable,
};

/// The Context is a view of the loader for the various processing steps
/// (lexer, parser, interpreter). It effectively implements the interpreter
/// since the parser can initiate interpretation of nodes.
pub const Context = struct {
  /// input contains the source that is being parsed.
  input: *data.Source,
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer uses this to check whether a character is a command
  /// character; the namespace mapping is relevant later for the interpreter.
  /// The values are indexes into the namespaces field.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15),
  /// Allocator used for AST nodes that will be discarded after interpretation
  /// has produced an expression.
  temp_nodes: std.heap.ArenaAllocator,
  /// Allocator used for expressions and AST nodes that can be accessed by other
  /// sources after interpretation has finished.
  source_content: std.heap.ArenaAllocator,
  /// Namespaces in the current source file. A namespace will not be deleted
  /// when it goes out of scope, so that we do not need to apply special care
  /// for delayed resolution of symrefs: If a symref cannot initially be
  /// resolved to a symbol, it will be stored with namespace index and target
  /// name. Since namespaces are never deleted, it will still try to find its
  /// target symbol in the same namespace when delayed resolution is triggered.
  namespaces: std.ArrayListUnmanaged(std.StringArrayHashMapUnmanaged(*data.Symbol)),
  /// The error handler which is used to report any recoverable errors that are
  /// encountered. If one or more errors are encountered during loading of one
  /// source, the source is treated having failed to load.
  eh: errors.Handler,
  /// The type lattice that handles types for this interpreter.
  /// it owns the context's structural types.
  types: types.Lattice,
  /// Array of known syntaxes. TODO: make this user-extensible
  syntax_registry: [2]syntaxes.SpecialSyntax,
  /// list of known keyword implementations. They bear no name since they are
  /// referenced via their index.
  keyword_registry: std.ArrayListUnmanaged(lib.Provider.KeywordWrapper),
  /// list of known builtin implementations, analoguous to keyword_registry.
  builtin_registry: std.ArrayListUnmanaged(lib.Provider.BuiltinWrapper),
  /// intrinsic function definitions
  intrinsics: *data.Module,

  pub fn init(allocator: *std.mem.Allocator, reporter: *errors.Reporter) !Context {
    var ret = Context{
      .input = undefined,
      .temp_nodes = std.heap.ArenaAllocator.init(allocator),
      .source_content = std.heap.ArenaAllocator.init(allocator),
      .command_characters = .{},
      .namespaces = .{},
      .eh = .{
        .reporter = reporter,
      },
      .types = try types.Lattice.init(allocator),
      .syntax_registry = .{syntaxes.SymbolDefs.locations(), syntaxes.SymbolDefs.definitions()},
      .keyword_registry = .{},
      .builtin_registry = .{},
      .intrinsics = undefined,
    };
    errdefer ret.deinit().deinit();
    ret.intrinsics = try lib.intrinsicModule(&ret);
    try ret.addNamespace(&ret.temp_nodes.allocator, '\\');
    return ret;
  }

  /// returns the allocator used for externally available source content.
  /// that allocator must be used to unload the generated content.
  pub fn deinit(self: *Context) std.heap.ArenaAllocator {
    self.temp_nodes.deinit();
    return self.source_content;
  }

  pub fn addNamespace(self: *Context, alloc: *std.mem.Allocator, character: u21) !void {
    // TODO: error message when too many namespaces are used (?)
    const index = self.namespaces.items.len;
    try self.command_characters.put(alloc, character, @intCast(u15, index));
    try self.namespaces.append(alloc, .{});
    const ns = &self.namespaces.items[index];
    // intrinsic symbols of every namespace.
    try self.importModuleSyms(self.intrinsics, index);
  }

  pub fn importModuleSyms(self: *Context, module: *data.Module, ns_index: usize) !void {
    const ns = &self.namespaces.items[ns_index];
    for (module.symbols) |sym| {
      try ns.put(&self.source_content.allocator, sym.name, sym);
    }
  }

  pub fn removeNamespace(self: *Context, character: u21) void {
    const ns_index = self.command_characters.fetchRemove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  /// Interprets the given node and returns an expression, if possible.
  /// A call of a keyword will be allocated inside the temporary allocator of
  /// the current source, while anything else will be allocated in the public
  /// region containing the current file's content.
  ///
  /// if report_failure is set, emits errors if this or a child node cannot be
  /// interpreted. Regardless of whether report_failure is set, null is returned
  /// if the node cannot be interpreted.
  pub fn tryInterpret(self: *Context, input: *data.Node, report_failure: bool) !?*data.Expression {
    return switch (input.data) {
      .access => switch (try self.resolveChain(input, report_failure)) {
        .var_chain => |vc| {
          const retr = try self.source_content.allocator.create(data.Expression);
          retr.* = .{
            .pos = vc.target.pos,
            .data = .{
              .var_retrieval = .{
                .variable = vc.target.variable
              },
            },
            .expected_type = vc.target.variable.t,
          };
          const expr = try self.source_content.allocator.create(data.Expression);
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
          const expr = try self.source_content.allocator.create(data.Expression);
          if (ref.prefix != null) {
            self.eh.PrefixedFunctionMustBeCalled(input.pos);
            expr.* = data.Expression.poison(input.pos);
          } else {
            expr.* = data.Expression.literal(input.pos, .{
              .funcref = .{
                .func = ref.target
              },
            });
          }
          return expr;
        },
        .type_ref => |ref| {
          const expr = try self.source_content.allocator.create(data.Expression);
          expr.* = data.Expression.literal(input.pos, .{
            .typeval = .{
              .t = ref.*,
            },
          });
          return expr;
        },
        .expr_chain => |ec| {
          const expr = try self.source_content.allocator.create(data.Expression);
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
        .failed => null,
        .poison => {
          const expr = try self.source_content.allocator.create(data.Expression);
          expr.* = data.Expression.poison(input.pos);
          return expr;
        },
      },
      // TODO: assignment (needs type checking)
      // TODO: concatenation (needs type lattice)
      // TODO: paragraphs (needs type lattice)
      .resolved_symref => |ref| {
        const expr = try self.source_content.allocator.create(data.Expression);
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
        return expr;
      },
      // TODO: resolved call (needs type checking)
      .expression => |e| return e,
      .voidNode => {
        const expr = try self.source_content.allocator.create(data.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .void,
          .expected_type = .{.intrinsic = .void},
        };
        return expr;
      },
      else => null
    };
  }

  pub fn interpret(self: *Context, input: *data.Node) !*data.Expression {
    return (try self.tryInterpret(input, true)) orelse blk: {
      var ret = try self.source_content.allocator.create(data.Expression);
      ret.* = data.Expression.poison(input.pos);
      break :blk ret;
    };
  }

  /// Evaluates the given expression, which must be a call to a keyword that
  /// returns an AstNode. Can return .referred_source_unavailable, in which case
  /// current interpretation must pause and the referred source must be
  /// interpreted instead. Afterwards, interpretation can continue.
  pub fn evaluateToAstNode(self: *Context, expr: *data.Expression) !*data.Node {
    // TODO
    return referred_source_unavailable;
  }

  pub fn resolveSymbol(self: *Context, pos: data.Position, ns: u15, name: []const u8) !*data.Node {
    var ret = try self.temp_nodes.allocator.create(data.Node);
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
      /// set if targt is a function reference in the namespace of a type,
      /// which has been accessed via an expression of that type. That is only
      /// allowed in the context of a call. The caller of resolveChain is to
      /// enforce this.
      prefix: ?*data.Expression = null,
    },
    /// last chain item was resolved to a type. Type is a pointer into a data.Symbol.
    type_ref: *data.Type,
    /// chain starts at an expression and descends into the returned value.
    expr_chain: struct {
      expr: *data.Expression,
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      t: data.Type,
    },
    /// the resolution failed because an identifier in the chain could not be resolved –
    /// this is not necessarily an error since the chain may be successfully resolved later.
    failed,
    /// this will be set if the chain is guaranteed to be faulty.
    poison,
  };

  /// resolves an accessor chain of *data.Node.
  /// iff force_fail is true, failure to resolve the base symbol will be reported
  /// as error and .poison will be returned; else no error will be reported and
  /// .failed will be returned.
  pub fn resolveChain(self: *Context, chain: *data.Node, force_fail: bool) std.mem.Allocator.Error!ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, force_fail);
        switch (inner) {
          .var_chain => |vc| {
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
          .type_ref => |ref| {
            // TODO: search in the namespace of the type for the given name.
            unreachable;
          },
          .expr_chain => |ec| {
            // TODO: same as var_chain basically
            unreachable;
          },
          .failed => return .failed,
          .poison => return .poison,
        }
      },
      .unresolved_symref => return .failed,
      .resolved_symref => |sym| return switch(sym.data) {
        .ext_func, .ny_func => ChainResolution{
          .func_ref = .{
            .target = sym,
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
        return if (try self.tryInterpret(chain, force_fail)) |expr| {
          // TODO: resolve accessor chain in context of expression's type and
          // return expr_chain
          unreachable;
        } else @as(ChainResolution, if (force_fail) .poison else .failed);
      }
    }
  }

  /// returns the given node's type, if it can be calculated.
  ///
  /// this will modify the given node by interpreting all substructures that
  /// are guaranteed not to be type-dependent on context. This means that all
  /// nodes are evaluated except for literal nodes, paragraphs, concatenations
  /// transitively.
  fn probeType(self: *Context, node: *data.Node) !?data.Type {
    return switch (node.data) {
      .literal => .{.intrinsic = if (l.kind == space) .space else .literal},
      .access, .assignment => if (try self.tryInterpret(node, false)) |expr| blk: {
        node.data = .{
          .expression = expr
        };
        break :blk expr.expected_type;
      } else null,
      .concatenation => |con| blk: {
        var t = .{.intrinsic = .every};
        for (con.content) |item| {
          t = try self.types.sup(t, try self.probeType(item) orelse break :blk null);
        }
        break :blk t;
      },
      .paragraphs => unreachable, // TODO
      .unresolved_symref => null,
      .resolved_symref => |ref| switch (ref.data) {
        .ext_func => |ext| unreachable,
        .ny_func => |nyf| unreachable,
        .variable => |va| unreachable,
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
      .resolved_call => |rc| rc.target.expected_type.structural.callable.returns,
      .expression => |e| e.expected_type,
      .voidNode => .{.intrinsic = .void},
    };
  }

  fn createLiteralExpr(self: *Context, l: *data.Node.Literal, t: data.Type, e: *data.Expression) void {
    e.* = switch (t) {
      .intrinsic => |it| switch (it) {
        .space => if (l.kind == .space) data.Expression.literal(node.pos, .{
          .text = .{
            .t = t,
            .value = try std.mem.dupe(self.source_content, u8, l.content),
          },
        }) else blk: {
          self.eh.ExpectedExprOfTypeXGotY(l.pos(), t, .{.intrinsic = .literal});
          break :blk data.Expression.poison(l.pos());
        },
        .literal, .raw => data.Expression.literal(l.pos(), .{
          .text = .{
            .t = t,
            .value = try std.mem.dupe(self.source_content, u8, l.content),
          },
        }),
        else => data.Expression.literal(l.pos(), .{
          .text = .{
            .t = .{.intrinsic = if (l.kind == .text) .literal else .space},
            .value = try std.mem.dupe(self.source_content, u8, l.content),
          },
        }),
      },
      .structural => |struc| switch (struc) {
        .optional => |op| { self.createLiteralExpr(t, op.inner, e); return; },
        .concat => |con| {self.createLiteralExpr(t, con.inner, e); return; },
        .paragraphs => unreachable,
        .list => |list| {self.createLiteralExpr(t, list.inner, e); return; },
        .map, .callable, .callable_type => blk: {
          self.eh.ExpectedExprOfTypeXGotY(l.pos(), t, .{.intrinsic = .literal});
          break :blk data.Expression.poison(l.pos());
        },
        .intersection => |inter| blk: {
          if (inter.scalar) |scalar| {self.createLiteralExpr(t, scalar, e); return; }
          self.eh.ExpectedExprOfTypeXGotY(l.pos(), t, .{.intrinsic = .literal});
          break :blk data.Expression.poison(l.pos());
        }
      },
      .instantiated => |ti| switch (ti.data) {
        .textual => unreachable, // TODO
        .numeric => unreachable, // TODO
        .float => unreachable, // TODO
        .tenum => unreachable, // TODO
        .record => blk: {
          self.eh.ExpectedExprOfTypeXGotY(node.pos, t,
            .{.intrinsic = if (l.kind == .text) .literal else .space});
          break :blk data.Expression.poison(node.pos);
        },
      },
    };
  }

  /// same as tryInterpret, but takes a target type that may be used to generate
  /// typed literal values from text literals. fills an already
  fn interpretWithTargetType(self: *Context, node: *data.Node, t: data.Type) !?*data.Expression {
    return switch (node.data) {
      // for text literals, do compile-time type conversions if possible
      .literal => |*l| blk: {
        const e = try self.source_content.allocator.create(data.Expression);
        self.createLiteralExpr(l, t, e);
        e.expected_type = t;
        break :blk e;
      },
      .access, .assignment, .resolved_symref, .resolved_call => try self.tryInterpret(node, false),
      .concatenation => unreachable,
      .paragraphs => unreachable,
      .unresolved_symref, .unresolved_call => null,
      .expression => |e| e,
      .voidNode => blk: {
        const e = try self.source_content.allocator.create(data.Expression);
        e.* = data.Expression.voidExpr(node.pos);
        break :blk e;
      }
    };
  }

  /// associates the given node with the given data type, returning an expression.
  /// association takes care of:
  ///  * interpreting the node
  ///  * checking whether the resulting expression is compatible with t – if not,
  ///    generate a poison expression
  ///  * checking whether the resulting expression needs to be converted to conform
  ///    to the given type, and if yes, wraps the expression in a conversion.
  /// null is returned if the association cannot be made currently because of
  /// unresolved symbols.
  pub fn associate(self: *Context, node: *data.Node, t: data.Type) !?*data.Expression {
    const e = try self.interpretWithTargetType(node, t) orelse return null;
    if (self.types.lesserEqual(e.expected_type, t)) {
      e.expected_type = t;
      return e;
    }
    // TODO: semantic conversions here
    self.eh.ExpectedExprOfTypeXGotY(node.pos, t, e.expected_type);
    e.* = data.Expression.poison(node.pos);
    return e;
  }

};