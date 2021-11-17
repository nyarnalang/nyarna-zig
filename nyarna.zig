const std = @import("std");

pub const EncodedCharacter = @import("load/unicode.zig").EncodedCharacter;
pub const Lexer       = @import("load/lex.zig").Lexer;
pub const Interpreter = @import("load/interpret.zig").Interpreter;
pub const ModuleLoader = @import("load/load.zig").ModuleLoader;
pub const Evaluator = @import("runtime.zig").Evaluator;

pub const data = @import("data.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors");
pub const lib = @import("lib.zig");

pub const default_stack_size = 1024 * 1024; // 1MB

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
  allocator: *std.mem.Allocator,
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
  intrinsics: *const data.Module,
  /// list of known keyword implementations. They bear no name since they are
  /// referenced via their index.
  keyword_registry: std.ArrayListUnmanaged(lib.Provider.KeywordWrapper),
  /// list of known builtin implementations, analoguous to keyword_registry.
  builtin_registry: std.ArrayListUnmanaged(lib.Provider.BuiltinWrapper),
  /// stack for evaluation. Size can be set during initialization.
  stack: []data.StackItem,
  /// current top of the stack, where new stack allocations happen.
  stack_ptr: [*]data.StackItem,

  pub fn init(allocator: *std.mem.Allocator, reporter: *errors.Reporter,
              stack_size: usize) !Context {
    var ret = Context{
      .reporter = reporter,
      .allocator = allocator,
      .types = undefined,
      .storage = std.heap.ArenaAllocator.init(allocator),
      .intrinsics = undefined,
      .keyword_registry = .{},
      .builtin_registry = .{},
      .stack = undefined,
      .stack_ptr = undefined,
    };
    errdefer ret.storage.deinit();
    ret.stack = try allocator.alloc(data.StackItem, stack_size);
    ret.stack_ptr = ret.stack.ptr;
    errdefer allocator.free(ret.stack);
    ret.types = try types.Lattice.init(&ret.storage);
    errdefer ret.types.deinit();
    ret.intrinsics = try lib.intrinsicModule(&ret);
    return ret;
  }

  pub fn deinit(context: *Context) void {
    context.types.deinit();
    context.storage.deinit();
    context.allocator.free(context.stack);
  }
};