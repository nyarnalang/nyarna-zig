//! TODO: this test currently isn't functional. Needs to be reworked to read in
//! system.ny so that all types are properly initialized.

const std = @import("std");
const nyarna = @import("nyarna");
const Type = nyarna.model.Type;

const Test = struct {
  types: nyarna.Types,
  alloc: std.heap.ArenaAllocator,

  fn create() !*Test {
    var ret = try std.testing.allocator.create(Test);
    errdefer std.testing.allocator.destroy(ret);
    ret.* = .{
      .types = undefined,
      .alloc = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    ret.types = try nyarna.Types.init(&ret.alloc);
    return ret;
  }

  fn destroy(self: *Test) void {
    self.alloc.deinit();
    std.testing.allocator.destroy(self);
  }

  fn testIsLesser(self: *Test, a: Type, b: Type) !void {
    try std.testing.expect(self.types.lesser(a, b));
    try std.testing.expect(self.types.lesserEqual(a, b));
    try std.testing.expect(!self.types.greater(a, b));
    try std.testing.expect(!self.types.greaterEqual(a, b));
  }

  fn testIsGreater(self: *Test, a: Type, b: Type) !void {
    try std.testing.expect(!self.types.lesser(a, b));
    try std.testing.expect(!self.types.lesserEqual(a, b));
    try std.testing.expect(self.types.greater(a, b));
    try std.testing.expect(self.types.greaterEqual(a, b));
  }
};

test "void <-> optional" {
  var ctx = try Test.create();
  defer ctx.destroy();
  const void_type = ctx.types.@"void"();

  const optional_nctype =
    (try ctx.types.optional(ctx.types.@"type"())).?;
  try ctx.testIsLesser(void_type, optional_nctype);
  try ctx.testIsGreater(optional_nctype, void_type);
}