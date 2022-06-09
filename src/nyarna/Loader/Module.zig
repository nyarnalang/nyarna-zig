//! interruptible loader of a module. Interrupts happen when a reference to
//! a module that has not yet been loaded occurs, or when a module's parameter
//! definition is encountered.
//!
//! Interaction must follow this schema:
//!
//!   loader = ModuleLoader.create(…);
//!
//!   loader.work(…); // may be repeated as long as it returns false
//!
//!   // exactly one of these must be called. Each will deallocate the loader.
//!   // finalizeNode() may be called before destroy(). The returned node will
//!   // go out of scope after destroy() because it is owned by the ModuleLoader
//!   loader.finalize() | [ loader.finalizeNode() ] loader.destroy()
//!
//!   // loader has been deallocated and mustn't be used anymore.

const std = @import("std");

const Globals     = @import("../Globals.zig");
const Lexer       = @import("../Parser/Lexer.zig");
const Loader      = @import("../Loader.zig");
const magic       = @import("../lib/magic.zig");
const nyarna      = @import("../../nyarna.zig");
const Parser      = @import("../Parser.zig");
const Resolver    = @import("Resolver.zig");

const Context     = nyarna.Context;
const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

const Module = @This();

const Option = struct {
  param: model.Signature.Parameter,
  given: bool,
};

source: *model.Source,
loader: Loader,
parser: Parser,
state: union(enum) {
  initial,
  /// encountered an option specification
  encountered_options,
  parsing,
  interpreting: *model.Node,
  finished    : ?*model.Function,
  /// for referenced module paths that cannot be resolved to a module source
  poison,
},
fullast: bool,
options: []Option = &.{},
option_container: model.VariableContainer = .{.num_values = 0},

/// allocates the loader and initializes it. Give no_interpret if you want to
/// load the input as Node without interpreting it.
pub fn create(
  data    : *Globals,
  input   : *Resolver.Cursor,
  resolver: *Resolver,
  location: model.Locator,
  fullast : bool,
  provider: ?*const lib.Provider,
) std.mem.Allocator.Error!*Module {
  var ret = try data.storage.allocator().create(Module);
  ret.* = .{
    .fullast = fullast,
    .state   = undefined,
    .parser  = Parser.init(),
    .loader  = undefined,
    .source  = undefined,
  };
  errdefer data.storage.allocator().destroy(ret);
  try ret.loader.init(
    data, provider, searchModule, registerOptions, enounteredOptions);
  if (
    try resolver.getSource(
      ret.loader.storage.allocator(), data.storage.allocator(),
      input, location, &ret.loader.logger)
  ) |source| {
    ret.state = .initial;
    ret.source = source;
  } else {
    ret.state = .poison;
    // source stays undefined as it's never accessed in poison state
  }
  return ret;
}

/// deallocates the loader and its owned data.
pub fn destroy(self: *Module) void {
  const allocator = self.loader.data.storage.allocator();
  self.loader.deinit();
  allocator.destroy(self);
}

fn handleError(self: *Module, e: Parser.Error) nyarna.Error!bool {
  switch (e) {
    Parser.UnwindReason.referred_module_unavailable =>
      if (self.state == .initial or self.state == .encountered_options) {
        self.state = .parsing;
      },
    Parser.UnwindReason.encountered_options =>
      self.state = .encountered_options,
    else => |actual_error| return actual_error,
  }
  return false;
}

fn ensureSpecifiedContent(self: *Module, pos: model.Position) !void {
  if (self.loader.interpreter.specified_content == .unspecified) {
    const root_def = try self.loader.interpreter.node_gen.rootDef(
      pos.before(), .standalone, null, null);
    _ = try self.loader.interpreter.interpret(root_def.node());
  }
}

/// return true if finished
pub fn work(self: *Module) !bool {
  while (true) switch (self.state) {
    .initial => {
      const implicit_module = if (self.loader.data.known_modules.count() == 0) (
        // only happens if we're loading system.ny.
        // in that case, we're loading the magic module that help
        // bootstrapping system.ny and provides keyword exclusive to it.
        try magic.magicModule(self.loader.interpreter.ctx)
      ) else self.loader.data.known_modules.values()[0].loaded;
      try self.loader.interpreter.importModuleSyms(implicit_module, 0);

      const node = (
        self.parser.parseSource(
          self.loader.interpreter, self.source, self.fullast)
      ) catch |e| return self.handleError(e);
      try self.ensureSpecifiedContent(node.pos);
      self.state = .{.interpreting = node};
    },
    .encountered_options => unreachable,
    .parsing => {
      const node = self.parser.resumeParse()
        catch |e| return self.handleError(e);
      try self.ensureSpecifiedContent(node.pos);
      self.state = .{.interpreting = node};
    },
    .interpreting => |node| {
      if (self.fullast) return true;
      const callable = switch (self.loader.interpreter.specified_content) {
        .unspecified => unreachable,
        .standalone  => |*s| s.callable,
        .library     => {
          const root = self.loader.interpreter.interpretAs(
            node, self.loader.data.types.@"void"().predef()
          ) catch |e| return self.handleError(e);
          // TODO: in case of library, ensure that content contains no statements
          // other than void literals.
          _ = root;
          self.state = .{.finished = null};
          return true;
        },
        .fragment    => |*f| f.callable,
      };

      const root = self.loader.interpreter.interpretAs(
        node, callable.sig.returns.predef()
      ) catch |e| return self.handleError(e);
      // TODO: in case of library, ensure that content contains no statements
      // other than void literals.
      const func =
        try self.loader.data.storage.allocator().create(model.Function);
      func.* = .{
        .callable   = callable,
        .name       = null,
        .data       = .{.ny = .{.body = root}},
        .defined_at = root.pos,
        .variables  = self.loader.interpreter.var_containers.items[0].container,
      };
      self.state = .{.finished = func};
      return true;
    },
    .finished, .poison => return true,
  };
}

/// deallocates the loader and returns the loaded module.
/// preconditions:
///
///  * self.work() must have returned true
///  * create() must have been called with fullast == false
pub fn finalize(self: *Module) !*model.Module {
  std.debug.assert(!self.fullast);
  defer self.destroy();
  std.debug.assert(self.loader.interpreter.var_containers.items.len == 1);
  const ret = try self.loader.ctx().global().create(model.Module);
  ret.* = .{
    .symbols   = self.loader.public_syms.items,
    .root      = switch (self.state) {
      .finished => |f| f,
      .poison => blk: {
        self.loader.data.seen_error = true;
        break :blk null;
      },
      else => unreachable,
    },
    .standalone = self.loader.interpreter.specified_content == .standalone,
    .schema = switch (self.loader.interpreter.specified_content) {
      .standalone => |sa| sa.schema,
      else => null,
    },
  };
  if (self.loader.logger.count > 0) self.loader.data.seen_error = true;
  return ret;
}

/// returns the loaded node. does *not* destroy the loader. returned node does
/// only live as long as the loader. caller must call destroy() on the loader.
/// preconditions:
///
///  * self.work() must have returned true
///  * create() must have been called with fullast == true
pub fn finalizeNode(self: *Module) !*model.Node {
  std.debug.assert(self.fullast);
  return switch (self.state) {
    .interpreting => |n| n,
    .poison =>
      self.loader.interpreter.node_gen.poison(model.Position.intrinsic()),
    else => unreachable,
  };
}

/// this function mainly exists for testing the lexer. as far as the public
/// API is concerned, the lexer is an implementation detail.
pub fn initLexer(self: *Module) !Lexer {
  std.debug.assert(self.state == .initial);
  return Lexer.init(self.loader.interpreter, self.source);
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
  loader : *Loader,
  pos    : model.Position,
  locator: model.Locator,
) std.mem.Allocator.Error!?usize {
  const self = @fieldParentPtr(Module, "loader", loader);
  var resolver: *Resolver = undefined;
  var abs_locator: []const u8 = undefined;
  const data = self.loader.data;
  const descriptor = if (locator.resolver) |name| blk: {
    if (data.known_modules.getIndex(locator.path)) |index| return index;
    for (data.resolvers) |*re| {
      if (std.mem.eql(u8, re.name, name)) {
        if (
          try re.resolver.resolve(
            data.storage.allocator(), locator.path, pos, &self.loader.logger)
        ) |desc| {
          resolver = re.resolver;
          abs_locator = try data.storage.allocator().dupe(u8, locator.repr);
          break :blk desc;
        }
        self.loader.logger.CannotResolveLocator(pos);
        return null;
      }
    }
    self.loader.logger.UnknownResolver(pos, name);
    return null;
  } else blk: {
    // try to resolve the locator relative to the current module.
    var fullpath = try data.storage.allocator().alloc(
      u8, self.source.locator_ctx.len + locator.path.len);
    std.mem.copy(u8, fullpath, self.source.locator_ctx);
    std.mem.copy(
      u8, (fullpath.ptr + self.source.locator_ctx.len)[
        0..locator.path.len], locator.path);
    const rel_loc = model.Locator.parse(fullpath) catch unreachable;
    const rel_name = rel_loc.resolver.?;
    for (data.resolvers) |*re| if (std.mem.eql(u8, rel_name, re.name)) {
      if (
        try re.resolver.resolve(
          data.storage.allocator(), rel_loc.path, pos, &self.loader.logger)
      ) |desc| {
        resolver = re.resolver;
        abs_locator = fullpath;
        break :blk desc;
      }
      break;
    };
    // try with each resolver that is set to implicitly resolve paths.
    for (data.resolvers) |*re| if (re.implicit) {
      if (
        try re.resolver.resolve(
          data.storage.allocator(), locator.path, pos, &self.loader.logger)
      ) |desc| {
        fullpath = try data.storage.allocator().realloc(
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
    data.storage.allocator().free(fullpath);
    self.loader.logger.CannotResolveLocator(pos);
    return null;
  };
  // TODO: builtin provider
  const module_loader = try create(
    data, descriptor, resolver,
    model.Locator.parse(abs_locator) catch unreachable, false, null);
  const res = try data.known_modules.getOrPut(
    data.storage.allocator(), abs_locator);
  std.debug.assert(!res.found_existing);
  res.value_ptr.* = .{.require_options = module_loader};
  return res.index;
}

pub fn registerOptions(loader: *Loader) OptionRegistrar {
  return .{.ml = @fieldParentPtr(Module, "loader", loader)};
}

pub fn enounteredOptions(loader: *Loader) bool {
  return
    @fieldParentPtr(Module, "loader", loader).state == .encountered_options;
}

pub const OptionSetter = struct {
  ml   : *Module,
  index: usize,

  pub fn set(self: OptionSetter, node: *model.Node) !void {
    const item = &self.ml.options[self.index];
    const slot = &self.ml.option_container.cur_frame.?[1 + self.index];
    if (item.given) {
      self.ml.loader.logger.DuplicateParameterArgument(
        item.param.name, node.pos, slot.value.origin);
      return;
    }
    const value = blk: {
      const intpr = self.ml.loader.interpreter;
      const expr = (
        try intpr.associate(node, item.param.spec, .{.kind = .final})
      ) orelse break :blk try intpr.ctx.values.poison(node.pos);
      break :blk try intpr.ctx.evaluator().evaluate(expr);
    };
    slot.* = .{.value = value};
    item.given = true;
  }
};

pub fn getOption(
  self: *Module,
  name: []const u8,
) ?OptionSetter {
  for (self.options) |*item, index| {
    if (std.mem.eql(u8, item.param.name, name)) {
      return OptionSetter{.ml = self, .index = index};
    }
  }
  return null;
}

/// try to push a named parameter as option. Returns true iff an option of that
/// name exists and thus the node has been consumed.
pub fn tryPushOption(
  self: *Module,
  name: []const u8,
  node: *model.Node,
) !bool {
  if (self.getOption(name)) |setter| {
    try setter.set(node);
    return true;
  } else return false;
}

pub fn finalizeOptions(self: *Module, pos: model.Position) !void {
  std.debug.assert(self.state == .encountered_options);
  for (self.options) |item, index| {
    const slot = &self.option_container.cur_frame.?[1 + index];
    if (!item.given) {
      self.loader.logger.MissingParameterArgument(
        item.param.name, pos, item.param.pos);
      slot.* = .{.value = try self.loader.interpreter.ctx.values.poison(pos)};
    }
  }
  self.state = .parsing;
}

pub const OptionRegistrar = struct {
  const Item = struct {
    param   : model.Signature.Parameter,
    name_pos: model.Position,
  };

  ml  : *Module,
  data: std.ArrayListUnmanaged(Item) = .{},

  pub fn push(self: *OptionRegistrar, loc: *model.Value.Location) !void {
    if (loc.header) |header| {
      self.ml.loader.logger.NotAllowedForOption(header.value().origin);
    }
    for ([_]?model.Position{loc.primary, loc.varargs, loc.varmap}) |item| {
      if (item) |pos| self.ml.loader.logger.NotAllowedForOption(pos);
    }
    for (self.ml.options) |item| {
      if (std.mem.eql(u8, item.param.name, loc.name.content)) {
        self.ml.loader.logger.DuplicateSymbolName(
          item.param.name, loc.name.value().origin, item.param.pos);
        return;
      }
    }
    try self.data.append(self.ml.loader.storage.allocator(), .{
      .param = .{
        .pos     = loc.value().origin,
        .name    = loc.name.content,
        .spec    = loc.spec,
        .capture = .default,
        .default = loc.default,
        .config  = null,
      },
      .name_pos = loc.name.value().origin,
    });
  }

  pub fn finalize(self: *OptionRegistrar, ns: u15) !void {
    const option_stack = try self.ml.loader.storage.allocator().alloc(
      model.StackItem, self.data.items.len + 1);
    option_stack[0] = .{.frame_ref = null};
    const option_arr =
      try self.ml.loader.storage.allocator().alloc(Option, self.data.items.len);
    self.ml.option_container.num_values = @intCast(u15, self.data.items.len);
    self.ml.option_container.cur_frame = option_stack.ptr;
    for (self.data.items) |item, index| {
      option_arr[index] = .{.param = item.param, .given = false};
      const varsym =
        try self.ml.loader.storage.allocator().create(model.Symbol);
      varsym.* = .{
        .defined_at = item.name_pos,
        .name       = item.param.name,
        .data       = .{.variable = .{
          .spec       = item.param.spec,
          .container  = &self.ml.option_container,
          .offset     = @intCast(u15, index),
          .kind       = .static,
        }},
      };
      _ = try self.ml.loader.interpreter.namespace(ns).tryRegister(
        self.ml.loader.interpreter, varsym);
    }
    self.ml.options = option_arr;
    self.ml.state = .encountered_options;
  }
};