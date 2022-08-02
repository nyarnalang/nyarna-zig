//! a Loader generates an interpreted entity from some input.
//! it owns the storage in which any nodes are to be allocated into during the
//! loading process. A loader contains an Interpreter.
//!
//! There are two loaders:
//!
//!  * Loader.Module loads a module from an input stream.
//!  * Loader.Schema loads a Schema from a SchemaDef.

const std = @import("std");

const Globals = @import("Globals.zig");
const nyarna  = @import("../nyarna.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

pub const Resolver           = @import("Loader/Resolver.zig");
pub const FileSystemResolver = @import("Loader/FileSystemResolver.zig");
pub const Main               = @import("Loader/Main.zig");
pub const Module             = @import("Loader/Module.zig");
pub const ParamResolver      = @import("Loader/ParamResolver.zig");
pub const SchemaBuilder      = @import("Loader/SchemaBuilder.zig");
pub const SingleResolver     = @import("Loader/SingleResolver.zig");

const Loader = @This();

const SearchModuleImpl = fn(
  self   : *Loader,
  pos    : model.Position,
  locator: model.Locator,
) std.mem.Allocator.Error!?usize;

const RegisterOptionsImpl = fn(self: *Loader) Module.OptionRegistrar;

const EncOptionsImpl = fn(self: *Loader) bool;

data       : *Globals,
/// for data local to the module loading process. will go out of scope when
/// the module has finished loading.
storage    : std.heap.ArenaAllocator,
interpreter: *Interpreter,
/// The error handler which is used to report any recoverable errors that
/// are encountered. If one or more errors are encountered during loading,
/// the input is considered to be invalid.
logger     : errors.Handler,
public_syms: std.ArrayListUnmanaged(*model.Symbol),
sm_impl    : ?SearchModuleImpl,
ro_impl    : ?RegisterOptionsImpl,
eo_impl    : ?EncOptionsImpl,

pub fn init(
  self    : *Loader,
  data    : *Globals,
  provider: ?* const lib.Provider,
  sm_impl : ?SearchModuleImpl,
  ro_impl : ?RegisterOptionsImpl,
  eo_impl : ?EncOptionsImpl,
) !void {
  self.data = data;
  self.storage = std.heap.ArenaAllocator.init(data.backing_allocator);
  self.logger = .{.reporter = data.reporter};
  self.interpreter = try Interpreter.create(self, provider);
  self.public_syms = .{};
  self.sm_impl = sm_impl;
  self.ro_impl = ro_impl;
  self.eo_impl = eo_impl;
}

pub fn deinit(self: *Loader) void {
  self.storage.deinit();
}

pub fn searchModule(
  self   : *Loader,
  pos    : model.Position,
  locator: model.Locator,
) std.mem.Allocator.Error!?usize {
  if (self.sm_impl) |impl| return impl(self, pos, locator) else return null;
}

pub fn registerOptions(self: *Loader) Module.OptionRegistrar {
  if (self.ro_impl) |impl| return impl(self) else unreachable;
}

pub fn hasEncounteredOptions(self: *Loader) bool {
  return if (self.eo_impl) |impl| impl(self) else false;
}

pub fn ctx(self: *Loader) nyarna.Context {
  return .{.data = self.data, .logger = &self.logger};
}