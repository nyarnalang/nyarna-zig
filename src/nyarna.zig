const std = @import("std");

pub const Evaluator    = @import("nyarna/Evaluator.zig");
pub const errors       = @import("nyarna/errors.zig");
pub const Interpreter  = @import("nyarna/Interpreter.zig");
pub const lib          = @import("nyarna/lib.zig");
pub const load         = @import("nyarna/load.zig");
pub const model        = @import("nyarna/model.zig");
pub const ModuleLoader = @import("nyarna/load.zig").ModuleLoader;
pub const Types        = @import("nyarna/Types.zig");

const Globals = @import("nyarna/Globals.zig");
const Parser  = @import("nyarna/Parser.zig");
const unicode = @import("nyarna/unicode.zig");

const gcd = @import("nyarna/helpers.zig").gcd;

pub const default_stack_size = 1024 * 1024; // 1MB

pub const Error = error {
  /// occurs when any allocation failed during processing.
  OutOfMemory,
  /// occurs when the given stack size has been exceeded.
  nyarna_stack_overflow,
  /// occurs when there are more than 2^15-1 namespaces declared in a single
  /// module.
  too_many_namespaces,
  /// An unexpected error occurred during initialization. This problem is
  /// independent from user code. It can occur when the system.ny file
  /// does not have expected content or doesn't exist at the stdlib search path.
  ///
  /// Details about the error are reported to the logger.
  init_error,
};

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
  /// set if this is a static context that has a module loader. null if this is
  /// a runtime context.
  loader: ?*ModuleLoader,

  /// search a referenced module. can only succeed in static context, otherwise
  /// always returns null
  pub inline fn searchModule(
    self   : Context,
    pos    : model.Position,
    locator: model.Locator,
  ) !?usize {
    return if (self.loader) |ml| ml.searchModule(pos, locator) else null;
  }

  /// The allocator used for any global data. All data allocated with this
  /// will be owned by Globals, though you are allowed (but not required)
  /// to deallocate it again using this allocator. Globals will deallocate
  /// all remaining data at the end of its lifetime.
  pub inline fn global(self: Context) std.mem.Allocator {
    return self.data.storage.allocator();
  }

  /// The allocator used for data local to some processing step. Data allocated
  /// with this is owned by the current ModuleLoader and will be deallocated
  /// when the module finished loading. In a runtime context, there is no module
  /// loader and thus the global allocator will be returned.
  pub inline fn local(self: Context) std.mem.Allocator {
    return if (self.loader) |ml| ml.storage.allocator() else self.global();
  }

  /// Interface to the type lattice. It allows you to create and compare types.
  pub inline fn types(self: Context) *Types {
    return &self.data.types;
  }

  pub inline fn createValueExpr(
    self   : Context,
    content: *model.Value,
  ) !*model.Expression {
    const e = try self.global().create(model.Expression);
    e.* = .{
      .pos = content.origin,
      .data = .{.value = content},
      .expected_type = try self.types().valueType(content),
    };
    return e;
  }

  pub inline fn evaluator(self: *const Context) Evaluator {
    return Evaluator{.ctx = self.*};
  }

  /// Create an enum value from a given text. If unsuccessful, logs error and
  /// returns null.
  pub fn enumFrom(
    self: Context,
    pos : model.Position,
    text: []const u8,
    t   : *const model.Type.Enum,
  ) !?*model.Value.Enum {
    const index = t.values.getIndex(text) orelse {
      self.logger.NotInEnum(pos, t.typedef(), text);
      return null;
    };
    return try self.values.@"enum"(pos, t, index);
  }

  pub fn applyIntUnit(
    self  : Context,
    unit  : model.Type.IntNum.Unit,
    input : Parser.LiteralNumber,
    pos   : model.Position,
    target: *i64,
  ) bool {
    var divisor = std.math.pow(i64, 10, input.decimals);
    var factor = unit.factor;
    const x = gcd(divisor, factor);
    divisor = @divExact(divisor, x);
    factor = @divExact(factor, x);
    if (@mod(input.value, divisor) != 0) {
      self.logger.InvalidDecimals(pos, input.repr);
      return false;
    }
    if (
      @mulWithOverflow(
        i64, @divExact(input.value, divisor), factor, target)
    ) {
      self.logger.NumberTooLarge(pos, input.repr);
      return false;
    } else return true;
  }

  pub fn intFromText(
    self: Context,
    pos : model.Position,
    text: []const u8,
    t   : *const model.Type.IntNum,
  ) !?*model.Value.IntNum {
    switch (Parser.LiteralNumber.from(text)) {
      .invalid => self.logger.InvalidNumber(pos, text),
      .too_large => self.logger.NumberTooLarge(pos, text),
      .success => |parsed| if (parsed.suffix.len == 0) {
        if (t.suffixes.len > 0) {
          self.logger.MissingSuffix(pos, t.typedef(), parsed.repr);
          return null;
        }
        if (parsed.decimals > 0) {
          self.logger.TooManyDecimalsForType(pos, t.typedef(), parsed.repr);
          return null;
        }
        if (parsed.value < t.min or parsed.value > t.max) {
          self.logger.OutOfRange(pos, t.typedef(), text);
          return null;
        }
        return try self.values.int(pos, t, parsed.value, 0);
      } else {
        for (t.suffixes) |unit, index| {
          if (std.mem.eql(u8, unit.suffix, parsed.suffix)) {
            var val: i64 = undefined;
            if (!self.applyIntUnit(unit, parsed, pos, &val)) return null;
            if (val < t.min or val > t.max) {
              self.logger.OutOfRange(pos, t.typedef(), text);
              return null;
            }
            return try self.values.int(pos, t, val, index);
          }
        }
        self.logger.UnknownSuffix(pos, t.typedef(), parsed.suffix);
      }
    }
    return null;
  }

  pub fn intAsValue(
    self : Context,
    pos  : model.Position,
    value: i64,
    unit : usize,
    t    : *const model.Type.IntNum,
  ) !*model.Value {
    if (value < t.min or value > t.max) {
      const str = try std.fmt.allocPrint(self.global(), "{}", .{value});
      self.logger.OutOfRange(pos, t.typedef(), str);
      return try self.values.poison(pos);
    } else return (try self.values.int(pos, t, value, unit)).value();
  }

  pub fn applyFloatUnit(
    unit  : model.Type.FloatNum.Unit,
    input : Parser.LiteralNumber,
  ) f64 {
    var divisor = std.math.pow(f64, 10, @intToFloat(f64, input.decimals));
    var factor = unit.factor;
    return @intToFloat(f64, input.value) * (factor / divisor);
  }

  pub fn floatAsValue(
    self : Context,
    pos  : model.Position,
    value: f64,
    unit : usize,
    t    : *const model.Type.FloatNum,
  ) !*model.Value {
    if (value < t.min or value > t.max) {
      const str = try std.fmt.allocPrint(self.global(), "{}", .{value});
      self.logger.OutOfRange(pos, t.typedef(), str);
      return try self.values.poison(pos);
    } else return (try self.values.float(pos, t, value, unit)).value();
  }

  pub fn textFromString(
    self : Context,
    pos  : model.Position,
    input: []const u8,
    t    : *const model.Type.Textual,
  ) !?*model.Value.TextScalar {
    var seen_error = false;
    const include_all =
      t.include.categories.content == unicode.CategorySet.all().content and
      t.exclude.count() == 0;
    if (!include_all) {
      var iter = std.unicode.Utf8Iterator{.bytes = input, .i = 0};
      while (iter.nextCodepoint()) |cp| if (!t.includes(cp)) {
        const e = unicode.EncodedCharacter.init(cp);
        self.logger.CharacterNotAllowed(pos, t.typedef(), e.repr());
        seen_error = true;
      };
    }
    return if (seen_error) null
    else try self.values.textScalar(pos, t.typedef(), input);
  }

  pub fn floatFromText(
    self: Context,
    pos : model.Position,
    text: []const u8,
    t   : *const model.Type.FloatNum,
  ) !?*model.Value.FloatNum {
    switch (Parser.LiteralNumber.from(text)) {
      .invalid => self.logger.InvalidNumber(pos, text),
      .too_large => self.logger.NumberTooLarge(pos, text),
      .success => |parsed| if (parsed.suffix.len == 0) {
        if (t.suffixes.len > 0) {
          self.logger.MissingSuffix(pos, t.typedef(), parsed.repr);
          return null;
        }
        var val = @intToFloat(f64, parsed.value);
        if (val < t.min or val > t.max) {
          self.logger.OutOfRange(pos, t.typedef(), text);
          return null;
        }
        return try self.values.float(pos, t, val, 0);
      } else {
        for (t.suffixes) |unit, index| {
          if (std.mem.eql(u8, unit.suffix, parsed.suffix)) {
            var val = applyFloatUnit(unit, parsed);
            if (val < t.min or val > t.max) {
              self.logger.OutOfRange(pos, t.typedef(), text);
              return null;
            }
            return try self.values.float(pos, t, val, index);
          }
        }
        self.logger.UnknownSuffix(pos, t.typedef(), parsed.suffix);
      }
    }
    return null;
  }

  pub fn unaryTypeVal(
             self      : Context,
    comptime name      : []const u8,
             pos       : model.Position,
             inner     : model.Type,
             inner_pos : model.Position,
    comptime error_name: []const u8,
  ) !*model.Value {
    if (try @field(self.types(), name)(inner)) |t| {
      if (t.isStruc(@field(model.Type.Structural, name))) {
        return (try self.values.@"type"(pos, t)).value();
      }
    }
    @field(self.logger, error_name)(&.{inner.at(inner_pos)});
    return try self.values.poison(pos);
  }
};

const callsite_desc = model.Source.Descriptor{
  .name     = "callsite",
  .locator  = model.Locator.parse(".callsite.args") catch unreachable,
  .argument = true,
};
const callsite_pos = model.Position{
  .source = &callsite_desc,
  .start = model.Cursor.unknown(),
  .end = model.Cursor.unknown(),
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
      const module = try self.finishMainModule();
      if (self.globals.seen_error) {
        self.deinit();
        return null;
      }

      var logger = errors.Handler{.reporter = self.globals.reporter};
      // TODO: check if main module is standalone
      const descr = model.Source.Descriptor{
        .name = ".exec.invoke",
        .locator = model.Locator.parse(".exec.invoke") catch unreachable,
        .argument = false,
      };
      var source = model.Source{
        .meta        = &descr,
        .content     = "",
        .locator_ctx = descr.name[0..6],
        .offsets     = .{},
      };
      var ns = std.ArrayListUnmanaged(*model.Symbol){};
      var intpr = try Interpreter.create(
        Context{.data = self.globals, .logger = &logger, .loader = null},
        self.globals.storage.allocator(),
        &source, &ns, null);

      var mapper = try Parser.Mapper.ToSignature.init(
        intpr, try intpr.genValueNode((try intpr.ctx.values.funcRef(
          source.at(model.Cursor.unknown()), module.root.?
        )).value()), 0, module.root.?.callable.sig);
      for (self.globals.known_modules.values()) |me| switch (me) {
        .pushed_param => |ml| {
          const res = try ml.work();
          std.debug.assert(res);
          const node = ml.finalizeNode();
          if (
            try mapper.mapper.map(
              callsite_pos, .{.named = node.pos.source.name}, .flow)
          ) |cursor| {
            try mapper.mapper.push(cursor, node);
          }
        },
        else => {},
      };
      const call =
        try mapper.mapper.finalize(source.at(model.Cursor.unknown()));
      const result = try intpr.ctx.evaluator().evaluate(
        try intpr.interpret(call));
      if (logger.count > 0) {
        self.deinit();
        return null;
      }
      const doc = try self.globals.storage.allocator().create(model.Document);
      doc.* = .{
        .root    = result,
        .globals = self.globals,
      };
      return doc;
    }

    fn mainModule(self: *MainLoader) *Globals.ModuleEntry {
      return &self.globals.known_modules.values()[1];
    }

    /// finish interpreting the main module and returns it. Does not finalize
    /// the MainLoader. finalize() or deinit() must still be called afterwards.
    pub fn finishMainModule(self: *MainLoader) !*model.Module {
      switch (self.mainModule().*) {
        .require_options, .require_module => |ml| {
          if (ml.state == .encountered_options) {
            try ml.finalizeOptions(model.Position.intrinsic());
          }
        },
        .loaded => {},
        .pushed_param => unreachable,
      }
      try self.globals.work();
      return self.globals.known_modules.values()[1].loaded;
    }

    pub fn pushArg(
      self   : *MainLoader,
      name   : []const u8,
      content: []const u8,
    ) !void {
      const repr = try self.globals.storage.allocator().alloc(u8, name.len + 7);
      std.mem.copy(u8, repr, ".param.");
      std.mem.copy(u8, repr[7..], name);
      var logger = errors.Handler{.reporter = self.globals.reporter};
      var locator = model.Locator.parse(repr) catch {
        logger.InvalidLocator(callsite_pos);
        return;
      };
      var cursor = load.ParamResolver.Cursor{
        .api     = .{.name = name},
        .content = content,
      };
      var resolver = load.ParamResolver.init();
      const loader = try ModuleLoader.create(
        self.globals, &cursor.api, &resolver.api, locator, true, null);
      const res = try self.globals.known_modules.getOrPut(
        self.globals.storage.allocator(), repr);
      if (res.found_existing) {
        logger.DuplicateParameterArgument(name, callsite_pos, callsite_pos);
      } else {
        switch (self.mainModule().*) {
          .pushed_param    => unreachable,
          .require_options => |ml| if (ml.getOption(name)) |option| {
            // TODO: these assertions should be enforced by disallowing
            // \fragment \library and \standalone in parameters.
            // This should be done by presetting the module kind.
            const finished = try loader.work();
            std.debug.assert(finished);
            const node = loader.finalizeNode();
            try option.set(node);
            return;
          },
          .require_module, .loaded => {},
        }
        res.value_ptr.* = .{.pushed_param = loader};
      }
    }
  };

  allocator: std.mem.Allocator,
  stack_size: usize,
  reporter: *errors.Reporter,
  resolvers: std.ArrayListUnmanaged(Globals.ResolverEntry) = .{},

  const Self = @This();

  pub fn init(
    allocator: std.mem.Allocator,
    stack_size: usize,
    reporter: *errors.Reporter,
    stdlib: *load.Resolver,
  ) !Processor {
    var ret = Processor{
      .allocator = allocator, .stack_size = stack_size, .reporter = reporter,
    };
    try ret.resolvers.append(allocator, .{
      .name = "doc",
      .implicit = false,
      .resolver = undefined, // given in startLoading()
    });
    try ret.resolvers.append(allocator, .{
      .name = "std",
      .implicit = true,
      .resolver = stdlib,
    });
    return ret;
  }

  pub fn deinit(self: *Processor) void {
    self.resolvers.deinit(self.allocator);
  }

  fn loadSystemNy(
    self: *Processor,
    logger: *errors.Handler,
    globals: *Globals,
  ) !void {
    // load system.ny.
    const system_ny = (try self.resolvers.items[1].resolver.resolve(
      globals.storage.allocator(), "system", model.Position.intrinsic(),
      logger)).?;
    const system_loader = try ModuleLoader.create(
      globals, system_ny, self.resolvers.items[1].resolver,
      model.Locator.parse(".std.system") catch unreachable,
      false, &lib.system.instance.provider);
    _ = try system_loader.work();
    const source = system_loader.interpreter.input.meta;
    const module = try system_loader.finalize();
    try globals.known_modules.put(
      globals.storage.allocator(), system_ny.name, .{.loaded = module});

    var checker = lib.system.Checker.init(&globals.types, logger);
    for (module.symbols) |sym| checker.check(sym);
    checker.finish(source, globals.types);
  }

  /// initialize loading of the given main module. should only be used for
  /// low-level access (useful for testing). The returned ModuleLoader has not
  /// started any loading yet, and thus you can't push arguments
  /// (but can finalize()).
  ///
  /// This is used for testing.
  pub fn initMainModule(
    self: *Self,
    doc_resolver: *load.Resolver,
    main_module: []const u8,
    fullast: bool,
  ) !MainLoader {
    self.resolvers.items[0].resolver = doc_resolver;
    var ret = MainLoader{
      .globals = try Globals.create(
        self.allocator, self.reporter, self.stack_size, self.resolvers.items),
    };
    errdefer ret.globals.destroy();

    var logger = errors.Handler{.reporter = self.reporter};
    try self.loadSystemNy(&logger, ret.globals);
    if (ret.globals.seen_error or logger.count > 0) return Error.init_error;

    // now setup loading of the main module
    const desc = (try doc_resolver.resolve(
      ret.globals.storage.allocator(), main_module, model.Position.intrinsic(),
      &logger)).?;
    const locator =
      try ret.globals.storage.allocator().alloc(u8, main_module.len + 5);
    std.mem.copy(u8, locator, ".doc.");
    std.mem.copy(u8, locator[5..], main_module);
    // TODO: what if main_module is misnamed?
    const ml = try ModuleLoader.create(
      ret.globals, desc, doc_resolver,
      model.Locator.parse(locator) catch unreachable, fullast, null);
    if (fullast) {
      try ret.globals.known_modules.put(
        ret.globals.storage.allocator(), desc.name, .{.require_module = ml});
    } else {
      try ret.globals.known_modules.put(
        ret.globals.storage.allocator(), desc.name, .{.require_options = ml});
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
  pub fn startLoading(
    self: *Self,
    doc_resolver: *load.Resolver,
    main_module: []const u8,
  ) !MainLoader {
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