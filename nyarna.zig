const std = @import("std");

pub const Evaluator = @import("runtime.zig").Evaluator;
pub const model = @import("model.zig");
pub const types = @import("types.zig");
pub const errors = @import("errors");
pub const lib = @import("lib.zig");
pub const resolve = @import("resolve.zig");
pub const ModuleLoader = @import("load/load.zig").ModuleLoader;
pub const EncodedCharacter = @import("load/unicode.zig").EncodedCharacter;
pub const Resolver = resolve.Resolver;

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
/// interact with Globals via the limited interface of the Context and Processor
/// types.
pub const Globals = struct {
  pub const ModuleEntry = union(enum) {
    require_module: *ModuleLoader,
    require_params: *ModuleLoader,
    loaded: *model.Module,
  };
  const ResolverEntry = struct {
    /// the prefix in absolute locators that refers to this resolver, e.g. "std"
    name: []const u8,
    /// whether this resolver is queried on any relative locator that can not be
    /// resolved otherwise.
    implicit: bool,
    /// the actual resolver
    resolver: *resolve.Resolver,
  };

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
  /// modules that have already been referenced. the key is the absolute
  /// locator. The first reference will add the module as .loading. The
  /// loading process will load the last not onloaded module in a loop
  ///  until all modules have been loaded.
  ///
  /// This list is also used to catch cyclic references.
  known_modules: std.StringArrayHashMapUnmanaged(ModuleEntry) = .{},
  /// known resolvers.
  resolvers: []ResolverEntry,
  /// set to true if any module encountered errors
  seen_error: bool = false,

  pub fn create(backing_allocator: std.mem.Allocator,
                reporter: *errors.Reporter, stack_size: usize,
                resolvers: []ResolverEntry) !*Globals {
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
      .resolvers = resolvers,
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
    for (self.known_modules.values()) |value| switch (value) {
      .require_module => |ml| ml.destroy(),
      .require_params => |ml| ml.destroy(),
      .loaded => {},
    };
    self.storage.deinit();
    self.backing_allocator.free(self.stack);
    self.backing_allocator.destroy(self);
  }

  fn lastLoadingModule(self: *Globals) ?usize {
    var index: usize = self.known_modules.count();
    while (index > 0) {
      index -= 1;
      switch (self.known_modules.values()[index]) {
        .require_module => return index,
        .require_params => |ml| switch (ml.state) {
          .initial, .parsing => return index,
          else => {},
        },
        .loaded => {},
      }
    }
    return null;
  }

  /// while there is an unloaded module in .known_modules, continues loading the
  /// last one. If the uppermost module encounters a parameter specification,
  /// returns so that caller may inject those.
  fn work(self: *Globals) !void {
    while (self.lastLoadingModule()) |index| {
      var must_finish = false;
      const loader = switch (self.known_modules.values()[index]) {
        .require_params => |ml| ml,
        .require_module => |ml| blk: {
          must_finish = true;
          break :blk ml;
        },
        .loaded => unreachable,
      };
      while (true) {
        _ = try loader.work();
        switch (loader.state) {
          .initial => unreachable,
          .finished => {
            const module = try loader.finalize();
            self.known_modules.values()[index] = .{.loaded = module};
            break;
          },
          .encountered_parameters => if (!must_finish) break,
          .parsing, .interpreting => break,
        }
      }
    }
  }
};

// to avoid ambiguity in the following struct
const Lattice = types.Lattice;
const SigBuilderRes = types.SigBuilderRes;

/// The Context is a public API for accessing global values and logging. This
/// API is useful for external code that implements external functions for
/// Nyarna.
///
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

  /// search a referenced module. must only be called while interpreting,
  /// otherwise leads to undefined behavior.
  pub inline fn searchModule(self: *const Context, pos: model.Position,
                             locator: model.Locator) !?usize {
    return @fieldParentPtr(ModuleLoader, "logger", self.logger).searchModule(
      pos, locator);
  }

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

  /// Create an enum value from a given text. If unsuccessful, logs error and
  /// returns null.
  pub fn enumFrom(self: *const Context, pos: model.Position, text: []const u8,
                  t: *const model.Type.Enum) !?*model.Value.Enum {
    const index = t.values.getIndex(text) orelse {
      self.logger.NotInEnum(pos, t.typedef(), text);
      return null;
    };
    return try self.values.@"enum"(pos, t, index);
  }

  pub fn numberFrom(self: *const Context, pos: model.Position,
                    text: []const u8, t: *const model.Type.Numeric)
      !?*model.Value.Number {
    var val: i64 = 0;
    var neg = false;
    var rest = switch (if (text.len == 0) @as(u8, 0) else text[0]) {
      '+' => text[1..],
      '-' => blk: {
        neg = true;
        break :blk text[1..];
      },
      else => text,
    };
    if (rest.len == 0) {
      self.logger.NotANumber(pos, t.typedef(), text);
      return null;
    }
    var dec_factor: ?i64 = null;
    var cur = rest.ptr;
    const end = rest[rest.len - 1 ..].ptr;
    while (true) : (cur += 1) {
      if (cur[0] == '.') {
        if (dec_factor != null or cur == end) {
          self.logger.NotANumber(pos, t.typedef(), text);
          return null;
        }
        const num_decimals = @ptrToInt(end) - @ptrToInt(cur);
        if (num_decimals > t.decimals) {
          self.logger.TooManyDecimals(pos, t.typedef(), text);
          return null;
        }
        dec_factor = std.math.pow(
          i64, 10, @intCast(i64, t.decimals - num_decimals));
      } else if (cur[0] < '0' or cur[0] > '9') {
        self.logger.NotANumber(pos, t.typedef(), text);
        return null;
      } else {
        if (@mulWithOverflow(i64, val, 10, &val) or
            @addWithOverflow(i64, val, cur[0] - '0', &val)) {
          self.logger.NumberTooLarge(pos, t.typedef(), text);
          return null;
        }
      }
      if (cur == end) break;
    }
    if (neg) dec_factor = if (dec_factor) |factor| factor * -1 else -1;
    if (dec_factor) |factor| if (@mulWithOverflow(i64, val, factor, &val)) {
      self.logger.NumberTooLarge(pos, t.typedef(), text);
      return null;
    };
    if (val < t.min or val > t.max) {
      self.logger.OutOfRange(pos, t.typedef(), text);
      return null;
    }
    return try self.values.number(pos, t, val);
  }
};

/// This type is the API's entry point.
pub const Processor = struct {
  pub const MainLoader = struct {
    globals: *Globals,

    /// for deinitialization in error scenarios.
    /// must not be called if finalize() is called.
    pub fn deinit(self: *MainLoader) void {
      self.globals.destroy();
    }

    /// finish loading the document.
    pub fn finalize(self: *MainLoader) !?*model.Document {
      errdefer self.deinit();
      try self.globals.work();
      if (self.globals.seen_error) {
        self.deinit();
        return null;
      }
      const doc = try self.globals.storage.allocator().create(model.Document);
      doc.* = .{
        .main = self.globals.known_modules.values()[0].loaded,
        .globals = self.globals,
      };
      return doc;
    }
  };

  allocator: std.mem.Allocator,
  stack_size: usize,
  reporter: *errors.Reporter,
  resolvers: std.ArrayListUnmanaged(Globals.ResolverEntry) = .{},

  const Self = @This();

  pub fn init(allocator: std.mem.Allocator, stack_size: usize,
              reporter: *errors.Reporter) !Processor {
    var ret = Processor{
      .allocator = allocator, .stack_size = stack_size, .reporter = reporter,
    };
    try ret.resolvers.append(allocator, .{
      .name = "doc",
      .implicit = false,
      .resolver = undefined, // given in startLoading()
    });
    // TODO: std resolver
    return ret;
  }

  pub fn deinit(self: *Processor) void {
    self.resolvers.deinit(self.allocator);
  }

  /// initialize loading of the given main module. should only be used for
  /// low-level access (useful for testing). The returned ModuleLoader has not
  /// started any loading yet, and thus you can't push arguments
  /// (but can finalize()).
  ///
  /// This is used for testing.
  pub fn initMainModule(self: *Self, doc_resolver: *resolve.Resolver,
                        main_module: []const u8, fullast: bool)
      !MainLoader {
    self.resolvers.items[0].resolver = doc_resolver;
    var ret = MainLoader{
      .globals = try Globals.create(self.allocator, self.reporter,
                                    self.stack_size, self.resolvers.items),
    };
    errdefer ret.globals.destroy();
    var logger = errors.Handler{.reporter = self.reporter};
    const desc = (try doc_resolver.resolve(
      main_module, model.Position.intrinsic(), &logger)).?;

    const ml =
      try ModuleLoader.create(ret.globals, desc, doc_resolver, fullast);
    if (fullast) {
      try ret.globals.known_modules.put(
        ret.globals.storage.allocator(), desc.name, .{.require_module = ml});
    } else {
      try ret.globals.known_modules.put(
        ret.globals.storage.allocator(), desc.name, .{.require_params = ml});
    }
    return ret;
  }

  /// start loading a document. preconditions:
  ///   * doc_resolver must be the resolver which provides the main module.
  ///   * main_module must be a relative locator to be resolved by doc_resolver.
  /// not fulfilling the preconditions will result in undefined behavior.
  ///
  /// the main module's source is loaded until a declaration of module
  /// parameters is encountered.
  ///
  /// use the returned MainLoader's pushArg() to push arguments.
  /// use the returned MainLoader's finalize() to finish loading.
  ///
  /// caller must either deinit() or finalize() the returned MainLoader.
  pub fn startLoading(self: *Self, doc_resolver: *resolve.Resolver,
                      main_module: []const u8) !MainLoader {
    const ret = try self.initMainModule(doc_resolver, main_module, false);
    try ret.globals.work();
    return ret;
  }

  /// parse a command-line argument, be it a direct string or a reference to a
  /// file.
  pub fn parseArg(self: *Self, source: *const model.Source) !*model.Node {
    const loader = try ModuleLoader.create(self.data, source);
    defer loader.destroy();
    return try loader.loadAsNode(true);
  }
};