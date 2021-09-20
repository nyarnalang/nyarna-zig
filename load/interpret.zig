const std = @import("std");
const data = @import("data");
const parse = @import("parse.zig");
const errors = @import("errors");
const types = @import("types");
const syntaxes = @import("syntaxes.zig");

pub const Errors = error {
  failed_to_interpret_node,
  referred_source_unavailable,
};

const InterpretError = error {
  failed_to_interpret_node,
  OutOfMemory
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
  /// it also owns the context's structural types.
  lattice: types.Lattice,
  /// predefined types. TODO: move these to system.ny
  boolean: data.Type.Instantiated,
  /// Array of known syntaxes. TODO: make this user-extensible
  syntax_registry: [2]syntaxes.SpecialSyntax,

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
      .lattice = .{.alloc = allocator},
      .boolean = .{.at = .intrinsic, .name = null, .data = .{.tenum = undefined}},
      .syntax_registry = .{syntaxes.SymbolDefs.locations(), syntaxes.SymbolDefs.definitions()},
    };
    errdefer ret.deinit().deinit();
    ret.boolean.data.tenum = try data.Type.Enum.predefBoolean(&ret.source_content.allocator);
    const boolsym = try ret.source_content.allocator.create(data.Symbol);
    boolsym.defined_at = .intrinsic;
    boolsym.name = "Boolean";
    boolsym.data = .{.ny_type = .{.instantiated = &ret.boolean}};
    ret.boolean.name = boolsym;
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
    try self.command_characters.put(alloc, character, @intCast(u15, self.namespaces.items.len));
    try self.namespaces.append(alloc, .{});
  }

  pub fn removeNamespace(self: *Context, character: u21) void {
    const ns_index = self.command_characters.remove(character).?;
    std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
    _ = self.namespaces.pop();
  }

  /// Interprets the given node and returns an expression.
  /// A call of a keyword will be allocated inside the temporary allocator of
  /// the current source, while anything else will be allocated in the public
  /// region containing the current file's content.
  pub fn interpret(self: *Context, input: *data.Node) InterpretError!*data.Expression {
    // TODO
    return InterpretError.failed_to_interpret_node;
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
      /// the target symbol that is to be indexed.
      /// May be a function reference or a variable reference.
      target: *data.Symbol,
      /// chain into the fields of a variable. Each item is the index of a nested
      /// field.
      field_chain: std.ArrayListUnmanaged(usize) = .{},
      // TODO: needs a field containing the current type.
    },
    /// last chain item was resolved to a function.
    func_ref: struct {
      target: *data.Symbol,
      /// set if targt is a function reference in the namespace of a type,
      /// which has been accessed via an expression of that type. That is only
      /// allowed in the context of a call. The caller of resolveChain is to
      /// enforce this.
      prefix: ?*data.Expression = null,
    },
    /// last chain item was resolved to a type.
    type_ref: *data.Symbol,
    /// chain starts at an expression and descends into the returned value.
    expr_chain: struct {
      expr: *data.Expression,
      field_chain: std.ArrayListUnmanaged(usize) = .{},
    },
    /// the resolution failed because an identifier in the chain could not be resolved –
    /// this is not necessarily an error since the chain may be successfully resolved later.
    failed,
    /// this will be set if the chain is guaranteed to be faulty.
    poison,
  };

  /// resolves an accessor chain of *data.Node.
  pub fn resolveChain(self: *Context, chain: *data.Node, alloc: *std.mem.Allocator) std.mem.Allocator.Error!ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, alloc);
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
        .ny_type => ChainResolution{
          .type_ref = sym,
        },
        .variable => blk: {
          const expr = try alloc.create(data.Expression);
          // TODO: set expr to be variable reference
          break :blk ChainResolution{
            .var_chain = .{
              .target = sym,
              .field_chain = .{},
            },
          };
        },
      },
      else => {
        const expr = self.interpret(chain) catch |err| switch(err) {
          InterpretError.failed_to_interpret_node => return @as(ChainResolution, .failed),
          InterpretError.OutOfMemory => |oom| return oom,
        };
        // TODO: resolve accessor chain in context of expression's type and
        // return expr_chain
        unreachable;
      }
    }
  }

  /// returns Nyarna's builtin boolean type
  pub fn getBoolean(self: *Context) *const data.Type.Enum {
    return &self.boolean.data.tenum;
  }
};

