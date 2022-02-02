const std = @import("std");

pub const Evaluator = @import("runtime.zig").Evaluator;
pub const model = @import("model.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors");
pub const lib = @import("lib.zig");
pub const ModuleLoader = @import("load/load.zig").ModuleLoader;
pub const EncodedCharacter = @import("load/unicode.zig").EncodedCharacter;

pub const default_stack_size = 1024 * 1024; // 1MB

pub const Error = error {
  OutOfMemory,
  nyarna_stack_overflow,
  too_many_namespaces,
  step_produced_errors,
};

/// Globals is the owner of all data that lives through the processing pipeline.
/// This data includes intrinsic and generated types, and most allocated
/// model.Expression and model.Value objects. Quite some of those objects could
/// theoretically be garbage-collected earlier, but the current implementation
/// assumes we have enough memory to not waste time on implementing that.
///
/// This is an internal, not an external API. External code should solely
/// interact with Globals via the limited interface of the Context type.
pub const Globals = struct {
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
  /// TextScalar containing the name "this" which is used as variable name for
  /// methods.
  this_name: model.Value,

  pub fn create(backing_allocator: std.mem.Allocator,
                reporter: *errors.Reporter, stack_size: usize) !*Globals {
    const ret = try backing_allocator.create(Globals);
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
      .this_name = .{
        .origin = model.Position.intrinsic(),
        .data = .{.text = .{
          .t = .{.intrinsic = .literal},
          .content = "this",
        }},
      },
    };
    errdefer backing_allocator.destroy(ret);
    errdefer ret.storage.deinit();
    ret.stack = try backing_allocator.alloc(model.StackItem, stack_size);
    ret.stack_ptr = ret.stack.ptr;
    errdefer backing_allocator.free(ret.stack);

    var logger = errors.Handler{.reporter = reporter};
    var init_ctx = Context{.data = ret, .logger = &logger};
    ret.types = try types.Lattice.init(init_ctx);
    errdefer ret.types.deinit();
    ret.intrinsics = try lib.intrinsicModule(init_ctx);
    if (logger.count > 0) {
      return Error.step_produced_errors;
    }
    return ret;
  }

  pub fn destroy(self: *Globals) void {
    self.types.deinit();
    self.storage.deinit();
    self.backing_allocator.free(self.stack);
    self.backing_allocator.destroy(self);
  }
};

// to avoid ambiguity in the following struct
const Lattice = types.Lattice;
const SigBuilderRes = types.SigBuilderRes;

/// The Context is a public API for accessing global values and logging.
/// External code shall not directly interface with the data field and only use
/// the accessors defined in Context. This both provides a more stable external
/// API, and prevents external callers from bringing the data into an invalid
/// state.
pub const Context = struct {
  /// private, do not access outside of Nyarna source code.
  data: *Globals,
  /// public, used for reporting errors and warnings.
  logger: *errors.Handler,
  /// public interface for generating values.
  values: model.ValueGenerator = .{},

  /// The allocator used for any global data. All data allocated with this
  /// will be owned by Globals, though you are allowed (but not required)
  /// to deallocate it again using this allocator. Globals will deallocate
  /// all remaining data at the end of its lifetime.
  pub inline fn global(self: *const Context) std.mem.Allocator {
    return self.data.storage.allocator();
  }

  /// The allocator used for data local to some processing step. Data allocated
  /// with this is owned by the caller, who must explicitly deallocated it.
  pub inline fn local(self: *const Context) std.mem.Allocator {
    return self.data.backing_allocator;
  }

  /// Interface to the type lattice. It allows you to create and compare types.
  pub inline fn types(self: *const Context) *Lattice {
    return &self.data.types;
  }

  pub inline fn thisName(self: *const Context) *model.Value.TextScalar {
    return &self.data.this_name.data.text;
  }

  pub inline fn createValueExpr(
      self: *const Context, content: *model.Value) !*model.Expression {
    const e = try self.global().create(model.Expression);
    e.* = .{
      .pos = content.origin,
      .data = .{.value = content},
      .expected_type = self.types().valueType(content),
    };
    return e;
  }

  pub inline fn evaluator(self: *const Context) Evaluator {
    return Evaluator{.ctx = self.*};
  }
};