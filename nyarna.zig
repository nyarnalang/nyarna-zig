const std = @import("std");

pub const EncodedCharacter = @import("load/unicode.zig").EncodedCharacter;
pub const Lexer       = @import("load/lex.zig").Lexer;
pub const Interpreter = @import("load/interpret.zig").Interpreter;
pub const ModuleLoader = @import("load/load.zig").ModuleLoader;
pub const Evaluator = @import("runtime.zig").Evaluator;

pub const model = @import("model.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors");
pub const lib = @import("lib.zig");

pub const default_stack_size = 1024 * 1024; // 1MB

pub const Error = error {
  OutOfMemory,
  nyarna_stack_overflow,
  too_many_namespaces,
};

/// the Context is the entry point to the API and the owner of all non-local
/// resources allocated during operation. Local resources are internal data of
/// the lexer, parser and interpreter, including intermediate AST representation
/// of the input, while non-local resources are the generated expressions,
/// values, types and functions.
///
/// All modules created from the same context are interoperable with other
/// modules of that context, and must not be used with modules created by
/// another context.
///
/// all functionality of this type intended to be public is available via its
/// functions. these are not thread-safe. a called should usually not access
/// this type's fields directly.
pub const Context = struct {
  /// The error reporter for this loader, supplied externally.
  reporter: *errors.Reporter,
  /// The backing allocator for heap allocations used by this loader.
  backing_allocator: std.mem.Allocator,
  /// The type lattice contains all types ever instantiated by operations of
  /// this context. during the loading
  /// process and provides the type lattice operations (e.g. type intersection
  /// and type relation checks).
  types: types.Lattice,
  /// Used to allocate all non-source-local objects, i.e. all objects that are
  /// not discarded after a source has been fully interpreted. Uses the
  /// externally supplied allocator.
  storage: std.heap.ArenaAllocator,
  /// This module contains the definitions of intrinsic symbols.
  /// it is initialized with the loader and used in all files the loader
  /// processes.
  intrinsics: *const model.Module,
  /// list of known keyword implementations. They bear no name since they are
  /// referenced via their index.
  keyword_registry: std.ArrayListUnmanaged(lib.Provider.KeywordWrapper),
  /// list of known builtin implementations, analoguous to keyword_registry.
  builtin_registry: std.ArrayListUnmanaged(lib.Provider.BuiltinWrapper),
  /// stack for evaluation. Size can be set during initialization.
  stack: []model.StackItem,
  /// current top of the stack, where new stack allocations happen.
  stack_ptr: [*]model.StackItem,

  pub fn create(backing_allocator: std.mem.Allocator,
                reporter: *errors.Reporter, stack_size: usize) !*Context {
    const ret = try backing_allocator.create(Context);
    ret.* = .{
      .reporter = reporter,
      .backing_allocator = backing_allocator,
      .types = undefined,
      .storage = std.heap.ArenaAllocator.init(backing_allocator),
      .intrinsics = undefined,
      .keyword_registry = .{},
      .builtin_registry = .{},
      .stack = undefined,
      .stack_ptr = undefined,
    };
    errdefer backing_allocator.destroy(ret);
    errdefer ret.storage.deinit();
    ret.stack = try backing_allocator.alloc(model.StackItem, stack_size);
    ret.stack_ptr = ret.stack.ptr;
    errdefer backing_allocator.free(ret.stack);
    ret.types = try types.Lattice.init(&ret.storage);
    errdefer ret.types.deinit();
    ret.intrinsics = try lib.intrinsicModule(ret);
    return ret;
  }

  pub fn destroy(context: *Context) void {
    context.types.deinit();
    context.storage.deinit();
    context.backing_allocator.free(context.stack);
    context.backing_allocator.destroy(context);
  }

  pub inline fn fillLiteral(
      self: *Context, at: model.Position, e: *model.Expression,
      content: model.Value.Data) void {
    e.* = .{
      .pos = at,
      .data = .{
        .literal = .{
          .value = .{
            .origin = at,
            .data = content,
          },
        },
      },
      .expected_type = undefined,
    };
    e.expected_type = self.types.valueType(&e.data.literal.value);
  }

  /// allocator for context-owned memory. Will go out of scope when the context
  /// vanishes.
  pub inline fn allocator(self: *Context) std.mem.Allocator {
    return self.storage.allocator();
  }

  pub inline fn genLiteral(self: *Context, at: model.Position,
                           content: model.Value.Data) !*model.Expression {
    const e = try self.allocator().create(model.Expression);
    self.fillLiteral(at, e, content);
    return e;
  }
};