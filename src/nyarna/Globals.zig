//! Globals is the owner of all data that lives through the processing pipeline.
//! This data includes intrinsic and generated types, and most allocated
//! model.Expression and model.Value objects. Quite some of those objects could
//! theoretically be garbage-collected earlier, but the current implementation
//! assumes we have enough memory to not waste time on implementing that.
//!
//! This is an internal API. The external interface is provided via the Context
//! and Processor types.

const std = @import("std");

const highlight = @import("highlight.zig");
const nyarna    = @import("../nyarna.zig");

const errors = nyarna.errors;
const lib    = nyarna.lib;
const Loader = nyarna.Loader;
const model  = nyarna.model;
const Types  = nyarna.Types;

const ModuleLoader = Loader.Module;

pub const ModuleEntry = union(enum) {
  pushed_param   : *ModuleLoader,
  require_module : *ModuleLoader,
  require_options: *ModuleLoader,
  parsed         : *ModuleLoader,
  loaded         : *model.Module,
};

pub const ResolverEntry = struct {
  /// the prefix in absolute locators that refers to this resolver, e.g. "std"
  name: []const u8,
  /// whether this resolver is queried on any relative locator that can not be
  /// resolved otherwise.
  implicit: bool,
  /// the actual resolver
  resolver: *Loader.Resolver,
};

/// The error reporter for this loader, supplied externally.
reporter: *errors.Reporter,
/// The backing allocator for heap allocations used by this loader.
backing_allocator: std.mem.Allocator,
/// The type lattice contains all types ever named by operations of
/// this context. during the loading
/// process and provides the type lattice operations (e.g. type intersection
/// and type relation checks).
types: Types,
/// Used to allocate all non-source-local objects, i.e. all objects that are
/// not discarded after a source has been fully interpreted. Uses the
/// externally supplied allocator.
storage: std.heap.ArenaAllocator,
/// list of known keyword implementations. They bear no name since they are
/// referenced via their index.
keyword_registry: std.ArrayListUnmanaged(lib.Provider.KeywordWrapper) = .{},
/// list of known builtin implementations, analoguous to keyword_registry.
builtin_registry: std.ArrayListUnmanaged(lib.Provider.BuiltinWrapper) = .{},
/// list of symbols available in any namespace (\declare, \var, \import etc).
generic_symbols: std.ArrayListUnmanaged(*model.Symbol) = .{},
/// stack for evaluation. Size can be set during initialization.
stack: []model.StackItem,
/// current top of the stack, where new stack allocations happen.
stack_ptr: [*]model.StackItem,
/// modules that have already been referenced. the key is the absolute
/// locator. The first reference will add the module as .loading. The
/// loading process will load the last not onloaded module in a loop
///  until all modules have been loaded.
///
/// This list is also used to catch cyclic references.
known_modules: std.StringArrayHashMapUnmanaged(ModuleEntry) = .{},
/// known providers of keyword and builtin functions.
/// keys are absolute locators.
known_providers: std.StringArrayHashMapUnmanaged(*const lib.Provider) = .{},
/// known resolvers.
resolvers: []ResolverEntry,
/// set to true if any module encountered errors
seen_error: bool = false,
/// known indexes into keyword_registry for system-defined keywords.
/// used to identify calls to these keywords (e.g. during schema extension)
/// without calling them. Will be set during interpretation of system.ny
system_keywords: struct {
  matcher: usize,
} = undefined,
/// Nyarna syntax highlighter. can be used via \highlighter.
nyarna_syntax: highlight.NyarnaSyntax,

pub fn create(
  backing_allocator: std.mem.Allocator,
  reporter         : *errors.Reporter,
  stack_size       : usize,
  resolvers        : []ResolverEntry,
) !*@This() {
  const ret = try backing_allocator.create(@This());
  ret.* = .{
    .reporter          = reporter,
    .backing_allocator = backing_allocator,
    .types             = undefined,
    .storage           = std.heap.ArenaAllocator.init(backing_allocator),
    .stack             = undefined,
    .stack_ptr         = undefined,
    .resolvers         = resolvers,
    .nyarna_syntax     = highlight.NyarnaSyntax.init(resolvers[1].resolver),
  };
  errdefer backing_allocator.destroy(ret);
  errdefer ret.storage.deinit();
  ret.stack = try backing_allocator.alloc(model.StackItem, stack_size);
  ret.stack_ptr = ret.stack.ptr;
  errdefer backing_allocator.free(ret.stack);

  var logger = errors.Handler{.reporter = reporter};
  var init_ctx = nyarna.Context{.data = ret, .logger = &logger};
  ret.types = try Types.init(init_ctx);
  errdefer ret.types.deinit();
  if (logger.count > 0) {
    return nyarna.Error.init_error;
  }
  try ret.known_providers.put(
    ret.storage.allocator(), ".std.meta", &lib.meta.instance.provider);
  return ret;
}

pub fn destroy(self: *@This()) void {
  self.types.deinit();
  for (self.known_modules.values()) |value| switch (value) {
    .require_module, .require_options, .pushed_param => |ml| ml.destroy(),
    .parsed, .loaded => {},
  };
  self.storage.deinit();
  self.backing_allocator.free(self.stack);
  self.backing_allocator.destroy(self);
}

pub fn lastLoadingModule(self: *@This()) ?usize {
  var index: usize = self.known_modules.count();
  while (index > 0) {
    index -= 1;
    switch (self.known_modules.values()[index]) {
      .require_module  => return index,
      .require_options => |ml| switch (ml.state) {
        .initial, .parsing => return index,
        else               => {},
      },
      .parsed, .loaded, .pushed_param => {},
    }
  }
  return null;
}

/// while there is an unloaded module in .known_modules, continues loading the
/// last one. If the uppermost module encounters a parameter specification,
/// returns so that caller may inject those.
pub fn work(self: *@This()) !void {
  while (self.lastLoadingModule()) |index| {
    const loader = switch (self.known_modules.values()[index]) {
      .require_options => |ml| ml,
      .require_module  => |ml| blk: {
        break :blk ml;
      },
      .parsed, .loaded, .pushed_param => unreachable,
    };
    _ = try loader.work();
    if (loader.fullast) {
      if (loader.state == .interpreting) {
        self.known_modules.values()[index] = .{.parsed = loader};
      }
    } else {
      if (loader.state == .finished) {
        const module = try loader.finalize();
        self.known_modules.values()[index] = .{.loaded = module};
      }
    }
  }
}