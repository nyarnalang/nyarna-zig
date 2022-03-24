const std = @import("std");
const nyarna = @import("nyarna.zig");
const types = nyarna.types;
const errors = nyarna.errors;
const model = nyarna.model;
const lib = nyarna.lib;
const magic = @import("lib/magic.zig");
const Context = nyarna.Context;
const Interpreter = @import("interpret.zig").Interpreter;
const parse = @import("parse.zig");
const lex = @import("parse/lex.zig");


/// interruptible loader of a module. Interrupts happen when a reference to
/// a module that has not yet been loaded occurs, or when a module's parameter
/// definition is encountered.
///
/// Interaction must follow this schema:
///
///   loader = ModuleLoader.create(…);
///
///   loader.work(…); // may be repeated as long as it returns false
///
///   // exactly one of these must be called. Each will deallocate the loader.
///   // finalizeNode() may be called before destroy(). The returned node will
///   // go out of scope after destroy() because it is owned by the ModuleLoader
///   loader.finalize() | [ loader.finalizeNode() ] loader.destroy()
///
///   // loader has been deallocated and mustn't be used anymore.
pub const ModuleLoader = struct {
  data: *nyarna.Globals,
  parser: parse.Parser,
  /// for data local to the module loading process. will go out of scope when
  /// the module has finished loading.
  storage: std.heap.ArenaAllocator,
  interpreter: *Interpreter,
  /// The error handler which is used to report any recoverable errors that
  /// are encountered. If one or more errors are encountered during loading,
  /// the input is considered to be invalid.
  logger: errors.Handler,
  public_syms: std.ArrayListUnmanaged(*model.Symbol) = .{},
  state: union(enum) {
    initial,
    /// encountered a parameter specification
    encountered_parameters,
    parsing,
    interpreting: *model.Node,
    finished: *model.Expression,
  },
  fullast: bool,

  /// allocates the loader and initializes it. Give no_interpret if you want to
  /// load the input as Node without interpreting it.
  pub fn create(
    data: *nyarna.Globals,
    input: *nyarna.Resolver.Cursor,
    resolver: *nyarna.Resolver,
    location: []const u8,
    fullast: bool,
    provider: ?*const lib.Provider,
  ) !*ModuleLoader {
    var ret = try data.storage.allocator().create(ModuleLoader);
    ret.* = .{
      .data = data,
      .logger = .{.reporter = data.reporter},
      .fullast = fullast,
      .state = .initial,
      .interpreter = undefined,
      .parser = parse.Parser.init(),
      .storage = std.heap.ArenaAllocator.init(data.backing_allocator),
    };
    errdefer data.storage.allocator().destroy(ret);
    const source =
      (try resolver.getSource(
        ret.storage.allocator(), data.storage.allocator(), input, location,
        &ret.logger))
      orelse blk: {
        const poison = try data.storage.allocator().create(model.Expression);
        poison.* = .{
          .pos = model.Position.intrinsic(),
          .data = .poison,
          .expected_type = data.types.poison(),
        };
        ret.state = .{.finished = poison};
        // it is safe to leave the source undefined here, as a finished
        // ModuleLoader will never call its interpreter.
        break :blk undefined;
      };
    ret.interpreter = try Interpreter.create(
      ret.ctx(), ret.storage.allocator(), source, &ret.public_syms, provider);
    return ret;
  }

  inline fn ctx(self: *ModuleLoader) Context {
    return Context{.data = self.data, .logger = &self.logger};
  }

  /// deallocates the loader and its owned data.
  pub fn destroy(self: *ModuleLoader) void {
    const allocator = self.data.storage.allocator();
    self.storage.deinit();
    allocator.destroy(self);
  }

  fn handleError(self: *ModuleLoader, e: parse.Error) nyarna.Error!bool {
    switch (e) {
      parse.UnwindReason.referred_module_unavailable =>
        if (self.state == .initial or self.state == .encountered_parameters) {
          self.state = .parsing;
        },
      parse.UnwindReason.encountered_parameters =>
        self.state = .encountered_parameters,
      else => |actual_error| return actual_error,
    }
    return false;
  }

  /// return true if finished
  pub fn work(self: *ModuleLoader) !bool {
    while (true) switch (self.state) {
      .initial => {
        const implicit_module = if (self.data.known_modules.count() == 0)
          // only happens if we're loading system.ny.
          // in that case, we're loading the magic module that help
          // bootstrapping system.ny and provides keyword exclusive to it.
          try magic.magicModule(self.interpreter.ctx)
        else self.data.known_modules.values()[0].loaded;
        try self.interpreter.importModuleSyms(implicit_module, 0);

        const node = self.parser.parseSource(self.interpreter, self.fullast)
          catch |e| return self.handleError(e);
        self.state = .{.interpreting = node};
      },
      .parsing, .encountered_parameters => {
        const node = self.parser.resumeParse()
          catch |e| return self.handleError(e);
        self.state = .{.interpreting = node};
      },
      .interpreting => |node| {
        if (self.fullast) return true;
        const root_type = switch (self.interpreter.specified_content) {
          .unspecified => self.data.types.raw(),
          .standalone => |*s| s.root_type,
          .library => self.data.types.@"void"(),
          .fragment => |*f| f.root_type,
        };

        const root = self.interpreter.interpretAs(node, root_type)
          catch |e| return self.handleError(e);
        self.state = .{.finished = root};
        return true;
      },
      .finished => return true,
    };
  }

  /// deallocates the loader and returns the loaded module.
  /// preconditions:
  ///
  ///  * self.work() must have returned true
  ///  * create() must have been called with fullast == false
  pub fn finalize(self: *ModuleLoader) !*model.Module {
    std.debug.assert(!self.fullast);
    defer self.destroy();
    std.debug.assert(self.interpreter.var_containers.items.len == 1);
    const ret = try self.ctx().global().create(model.Module);
    ret.* = .{
      .symbols = self.public_syms.items,
      .root = self.state.finished,
      .container = self.interpreter.var_containers.items[0].container,
    };
    if (self.logger.count > 0) self.data.seen_error = true;
    return ret;
  }

  /// returns the loaded node. does *not* destroy the loader. returned node does
  /// only live as long as the loader. caller must call destroy() on the loader.
  /// preconditions:
  ///
  ///  * self.work() must have returned true
  ///  * create() must have been called with fullast == true
  pub fn finalizeNode(self: *ModuleLoader) *model.Node {
    std.debug.assert(self.fullast);
    return self.state.interpreting;
  }

  /// this function mainly exists for testing the lexer. as far as the public
  /// API is concerned, the lexer is an implementation detail.
  pub fn initLexer(self: *ModuleLoader) !lex.Lexer {
    std.debug.assert(self.state == .initial);
    return lex.Lexer.init(self.interpreter);
  }

  /// tries to resolve the given locator to a module.
  /// if successful, returns the index of the module.
  ///
  /// creates a requirement for the module to provide its parameters.
  ///
  /// returns null if no module cannot be found for the given locator or if
  /// referencing the module would create a cyclic dependency. If null is
  /// returned, an error message has been logged.
  pub fn searchModule(
    self: *ModuleLoader,
    pos: model.Position,
    locator: model.Locator,
  ) !?usize {
    var resolver: *nyarna.Resolver = undefined;
    var abs_locator: []const u8 = undefined;
    const descriptor = if (locator.resolver) |name| blk: {
      if (self.data.known_modules.getIndex(locator.path)) |index| return index;
      for (self.data.resolvers) |*re| {
        if (std.mem.eql(u8, re.name, name)) {
          if (
            try re.resolver.resolve(
              self.data.storage.allocator(), locator.path, pos, &self.logger)
          ) |desc| {
            resolver = re.resolver;
            abs_locator =
              try self.data.storage.allocator().dupe(u8, locator.repr);
            break :blk desc;
          }
          self.logger.CannotResolveLocator(pos);
          return null;
        }
      }
      self.logger.UnknownResolver(pos, name);
      return null;
    } else blk: {
      // try to resolve the locator relative to the current module.
      var fullpath = try self.data.storage.allocator().alloc(
        u8, self.interpreter.input.locator_ctx.len + locator.path.len);
      std.mem.copy(u8, fullpath, self.interpreter.input.locator_ctx);
      std.mem.copy(
        u8, (fullpath.ptr + self.interpreter.input.locator_ctx.len)[
          0..locator.path.len], locator.path);
      const rel_loc = model.Locator.parse(fullpath) catch unreachable;
      const rel_name = rel_loc.resolver.?;
      for (self.data.resolvers) |*re| if (std.mem.eql(u8, rel_name, re.name)) {
        if (
          try re.resolver.resolve(
            self.data.storage.allocator(), rel_loc.path, pos, &self.logger)
        ) |desc| {
          resolver = re.resolver;
          abs_locator = fullpath;
          break :blk desc;
        }
        break;
      };
      // try with each resolver that is set to implicitly resolve paths.
      for (self.data.resolvers) |*re| if (re.implicit) {
        if (
          try re.resolver.resolve(
            self.data.storage.allocator(), locator.path, pos, &self.logger)
        ) |desc| {
          fullpath = try self.data.storage.allocator().realloc(
            fullpath, 2 + re.name.len + locator.path.len);
          fullpath[0] = '.';
          std.mem.copy(u8, fullpath[1..], re.name);
          fullpath[1 + re.name.len] = '.';
          std.mem.copy(u8, fullpath[2 + re.name.len..], locator.path);
          abs_locator = fullpath;
          resolver = re.resolver;
          break :blk desc;
        }
      };
      self.data.storage.allocator().free(fullpath);
      self.logger.CannotResolveLocator(pos);
      return null;
    };
    // TODO: builtin provider
    const loader =
      try create(self.data, descriptor, resolver, abs_locator, false, null);
    const res = try self.data.known_modules.getOrPut(
      self.data.storage.allocator(), abs_locator);
    std.debug.assert(!res.found_existing);
    res.value_ptr.* = .{.require_params = loader};
    return res.index;
  }

  /// tries to query the parameters of the module at the given index.
  /// returns null if the referenced module has not yet been loaded far enough
  /// for it to provide parameters.
  pub fn getModuleParams(
    self: *ModuleLoader,
    module_index: usize,
  ) ?*model.Signature {
    _ = self;
    _ = module_index;
    unreachable; // TODO
  }
};