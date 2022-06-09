const std = @import("std");

const nyarna = @import("../../nyarna.zig");
const Globals = @import("../Globals.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

const SchemaBuilder = @This();

loader: nyarna.Loader,
defs  : std.ArrayListUnmanaged(*model.Node.Definition),

pub fn create(
  base: *model.Value.SchemaDef,
  data: *Globals,
) !*SchemaBuilder {
  const ret = try data.backing_allocator.create(SchemaBuilder);
  ret.loader.init(data, null, null, null, null);
  ret.defs = .{};
  ret.defs.appendSlice(ret.loader.interpreter.allocator(), base.defs);
  return ret;
}

pub fn destroy(self: *SchemaBuilder) void {
  const globals = self.loader.data;
  self.loader.deinit();
  globals.backing_allocator.destroy(self);
}

pub fn finalize(
  self: *SchemaBuilder,
  pos : model.Position,
  ns  : u15,
) !*model.Value.Schema {
  errdefer self.destroy();
  var dres = try DeclareResolution.create(intpr, self.defs.items, ns, null);
  try dres.execute();
  const schema = try self.loader.ctx().values.schema(pos); // ...
}