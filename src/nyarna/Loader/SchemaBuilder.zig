const std = @import("std");

const algo    = @import("../Interpreter/algo.zig");
const nyarna  = @import("../../nyarna.zig");
const Globals = @import("../Globals.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

const SchemaBuilder = @This();

loader: nyarna.Loader,
defs  : std.ArrayListUnmanaged(*model.Node.Definition),
root  : *model.Node,

pub fn create(
  base: *model.Value.SchemaDef,
  data: *Globals,
) !*SchemaBuilder {
  const ret = try data.backing_allocator.create(SchemaBuilder);
  try ret.loader.init(data, null, null, null, null);
  ret.defs = .{};
  try ret.defs.appendSlice(ret.loader.interpreter.allocator(), base.defs);
  ret.root = base.root;
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
) !?*model.Value.Schema {
  defer self.destroy();
  defer if (self.loader.logger.count > 0) {
    self.loader.data.seen_error = true;
  };
  var dres = try algo.DeclareResolution.create(
    self.loader.interpreter, self.defs.items, 0, null);
  try dres.execute();
  const expr = try self.loader.interpreter.interpretAs(
    self.root, self.loader.ctx().types().@"type"().predef());
  switch ((try self.loader.ctx().evaluator().evaluate(expr)).data) {
    .@"type" => |*tv| {
      return try self.loader.ctx().values.schema(
        pos, tv.t.at(tv.value().origin), self.loader.public_syms.items);
    },
    .poison => return null,
    else => unreachable,
  }
}