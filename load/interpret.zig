const std = @import("std");
const data = @import("data");
const parse = @import("parse");
const errors = @import("errors");

pub const Errors = error {
  failed_to_interpret_node,
  referred_source_unavailable,
};

/// The Context is a view of the loader for the various processing steps
/// (lexer, parser, interpreter). It effectively implements the interpreter
/// since the parser can initiate interpretation of nodes.
pub const Context = struct {
  /// Maps each existing command character to the index of the namespace it
  /// references. Lexer uses this to check whether a character is a command
  /// character; the namespace mapping is relevant later for the interpreter.
  /// The values are indexes into the namespaces field.
  command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u16),
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

  pub fn init(allocator: *std.mem.Allocator, reporter: *errors.Reporter) !Context {
    var ret = Context{
      .temp_nodes = std.heap.ArenaAllocator.init(allocator),
      .source_content = std.heap.ArenaAllocator.init(allocator),
      .command_characters = .{},
      .namespaces = .{},
      .eh = .{
        .reporter = reporter,
      },
    };
    errdefer ret.deinit().deinit();
    try ret.command_characters.put(&ret.temp_nodes.allocator, '\\', 0);
    try ret.namespaces.append(&ret.temp_nodes.allocator, .{});
    return ret;
  }

  /// returns the allocator used for externally available source content.
  /// that allocator must be used to unload the generated content.
  pub fn deinit(self: *Context) std.heap.ArenaAllocator {
    self.temp_nodes.deinit();
    return self.source_content;
  }

  /// Interprets the given node and returns an expression.
  /// A call of a keyword will be allocated inside the temporary allocator of
  /// the current source, while anything else will be allocated in the public
  /// region containing the current file's content.
  pub fn interpret(self: *Context, input: *data.Node) !*data.Expression {
    // TODO
    return Errors.failed_to_interpret_node;
  }

  /// Evaluates the given expression, which must be a call to a keyword that
  /// returns an AstNode. Can return .referred_source_unavailable, in which case
  /// current interpretation must pause and the referred source must be
  /// interpreted instead. Afterwards, interpretation can continue.
  pub fn evaluateToAstNode(self: *Context, expr: *data.Expression) !*data.Node {
    // TODO
    return referred_source_unavailable;
  }

  pub fn resolveSymbol(self: *Context, pos: data.Position, ns: u16, name: []const u8) !*data.Node {
    var ret = try self.temp_nodes.allocator.create(data.Node);
    ret.pos = pos;

    var syms = &self.namespaces.items[ns];
    ret.data = .{
      .symref = .{
        .resolved = syms.get(name) orelse {
          ret.data = .{
            .symref = .{
              .unresolved = .{
                .ns = ns, .name = name
              }
            }
          };
          return ret;
        }
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
    /// the resolution failed because an identifier in the chain could not be resolved –
    /// this is not necessarily an error since the chain may be successfully resolved later.
    failed,
    /// this will be set if the chain is guaranteed to be faulty.
    poison,
  };

  /// resolves an accessor chain of *data.Node.
  pub fn resolveChain(self: *Context, chain: *data.Node, alloc: *std.mem.Allocator) !ChainResolution {
    switch (chain.data) {
      .access => |value| {
        const inner = try self.resolveChain(value.subject, alloc);
        switch (inner) {
          .var_chain => |value| {
            // TODO: find field in value's type, update value's type and the
            // field_chain, return it.
          },
          .func_ref => |value| {
            if (value.prefix != null) {
              // TODO: report error based on the name of target_expr
              return .poison;
            }
            // TODO: transform function reference to variable ref, then search
            // in that expression's type for the symbol.
            unreachable;
          }
        }
      },
      .symref => |value| {
        return switch (value) {
          .unresolved => .failed,
          .resolved => |sym| switch(sym.data) {
            .ext_func | .ny_func => .{
              .func_ref = .{
                .target = sym,
                .prefix = null,
              },
            },
            .variable => blk: {
              const expr = try alloc.create(data.Expression);
              // TODO: set expr to be variable reference
              break :blk .{
                .var_chain = .{
                  .target = sym,
                  .field_chain = .{},
                },
              };
            },
          }
        };
      },
      // TODO: can this ever be called on another kind of node?
      else => unreachable,
    }
  }
};