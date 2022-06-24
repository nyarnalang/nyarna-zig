//! The Main loader is the loader processing the potential arguments given in
//! the invocation context (e.g. the command line) to the main module.

const std = @import("std");

const Globals = @import("../Globals.zig");
const nyarna  = @import("../../nyarna.zig");
const Parser  = @import("../Parser.zig");

const Context     = nyarna.Context;
const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const Loader      = nyarna.Loader;
const model       = nyarna.model;

const Main = @This();

loader: Loader,
name  : []const u8,

const callsite_pos = model.Position{
  .source = &callsite_desc,
  .start  = model.Cursor.unknown(),
  .end    = model.Cursor.unknown(),
};

const callsite_desc = model.Source.Descriptor{
  .name     = "callsite",
  .locator  = model.Locator.parse(".callsite.args") catch unreachable,
  .argument = true,
};

/// internal nyarna API. external code shall use nyarna.Processor.startLoading.
pub fn create(data: *Globals, name: []const u8) !*Main {
  const ret = try data.backing_allocator.create(Main);
  errdefer data.backing_allocator.destroy(ret);
  try ret.loader.init(data, null, null, null, null);
  ret.name = try data.storage.allocator().dupe(u8, name);
  return ret;
}

/// for deinitialization in error scenarios.
/// must not be called if finalize() is called.
pub fn destroy(self: *Main) void {
  const globals = self.loader.data;
  self.loader.deinit();
  globals.backing_allocator.destroy(self);
  globals.destroy();
}

/// finish loading the module. Invalidates and destroys the given Main loader.
pub fn finalize(self: *Main) !?*nyarna.DocumentContainer {
  errdefer self.destroy();
  const module = try self.finishMainModule();
  if (self.loader.data.seen_error) {
    self.destroy();
    return null;
  }

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
  var intpr = try Interpreter.create(&self.loader, null);

  var mapper = try Parser.Mapper.ToSignature.init(
    intpr, try intpr.genValueNode((try intpr.ctx.values.funcRef(
      source.at(model.Cursor.unknown()), module.root.?
    )).value()), 0, module.root.?.callable.sig);
  for (self.loader.data.known_modules.values()) |me| switch (me) {
    .pushed_param => |ml| {
      const res = try ml.work();
      std.debug.assert(res);
      const node = try ml.finalizeNode();
      if (
        try mapper.mapper.map(
          callsite_pos, .{.named = node.pos.source.name}, .flow)
      ) |cursor| {
        try mapper.mapper.push(cursor, node);
      }
    },
    else => {},
  };
  const call = try mapper.mapper.finalize(source.at(model.Cursor.unknown()));
  const result = try intpr.ctx.evaluator().evaluate(try intpr.interpret(call));
  if (self.loader.logger.count > 0) {
    self.destroy();
    return null;
  }
  const ret =
    try self.loader.data.storage.allocator().create(nyarna.DocumentContainer);
  ret.* = .{
    .documents = .{},
    .globals   = self.loader.data,
  };
  try ret.documents.append(ret.globals.storage.allocator(),
    try intpr.ctx.values.output(
      module.root.?.defined_at, try intpr.ctx.values.textScalar(
        callsite_pos, intpr.ctx.types().text(),
        if (module.schema == null) "" else self.name),
      module.schema, result,
    ),
  );
  self.loader.deinit();
  self.loader.data.backing_allocator.destroy(self);
  return ret;
}

fn mainModule(self: *Main) *Globals.ModuleEntry {
  return &self.loader.data.known_modules.values()[1];
}

/// finish interpreting the main module and returns it. Does not finalize
/// the Main loader. finalize() or deinit() must still be called afterwards.
pub fn finishMainModule(self: *Main) !*model.Module {
  switch (self.mainModule().*) {
    .require_options, .require_module => |ml| {
      if (ml.state == .encountered_options) {
        try ml.finalizeOptions(model.Position.intrinsic());
      }
    },
    .loaded => {},
    .pushed_param => unreachable,
  }
  try self.loader.data.work();
  return self.loader.data.known_modules.values()[1].loaded;
}

pub fn pushArg(
  self   : *Main,
  name   : []const u8,
  content: []const u8,
) !void {
  const repr =
    try self.loader.data.storage.allocator().alloc(u8, name.len + 7);
  std.mem.copy(u8, repr, ".param.");
  std.mem.copy(u8, repr[7..], name);
  var locator = model.Locator.parse(repr) catch {
    self.loader.logger.InvalidLocator(callsite_pos);
    return;
  };
  var cursor = Loader.ParamResolver.Cursor{
    .api     = .{.name = name},
    .content = content,
  };
  var resolver = Loader.ParamResolver.init();
  const loader = try Loader.Module.create(
    self.loader.data, &cursor.api, &resolver.api, locator, true, null);
  const res = try self.loader.data.known_modules.getOrPut(
    self.loader.data.storage.allocator(), repr);
  if (res.found_existing) {
    self.loader.logger.DuplicateParameterArgument(
      name, callsite_pos, callsite_pos);
  } else {
    switch (self.mainModule().*) {
      .pushed_param    => unreachable,
      .require_options => |ml| if (ml.getOption(name)) |option| {
        // TODO: these assertions should be enforced by disallowing
        // \fragment \library and \standalone in parameters.
        // This should be done by presetting the module kind.
        const finished = try loader.work();
        std.debug.assert(finished);
        const node = try loader.finalizeNode();
        try option.set(node);
        return;
      },
      .require_module, .loaded => {},
    }
    res.value_ptr.* = .{.pushed_param = loader};
  }
}