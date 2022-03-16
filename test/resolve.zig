const std = @import("std");

const nyarna = @import("nyarna");
const model = nyarna.model;
const errors = nyarna.errors;
const tml = @import("tml.zig");

pub const TestDataResolver = struct {
  const Cursor = struct {
    api: nyarna.Resolver.Cursor,
    value: *tml.Value,
  };

  api: nyarna.Resolver,
  stdlib: nyarna.FileSystemResolver,
  source: tml.File,

  pub fn init(path: []const u8) !TestDataResolver {
    const abs_path =
      try std.fs.cwd().realpathAlloc(std.testing.allocator, "lib");
    errdefer std.testing.allocator.free(abs_path);
    return TestDataResolver{
      .api = .{
        .resolveFn = resolve,
        .getSourceFn = getSource,
      },
      .stdlib = nyarna.FileSystemResolver.init(abs_path),
      .source = try tml.File.loadPath(path),
    };
  }

  pub fn deinit(self: *TestDataResolver) void {
    self.source.deinit();
    std.testing.allocator.free(self.stdlib.base);
  }

  fn resolve(
    res: *nyarna.Resolver,
    allocator: std.mem.Allocator,
    path: []const u8,
    _: model.Position,
    _: *errors.Handler,
  ) std.mem.Allocator.Error!?*nyarna.Resolver.Cursor {
    const self = @fieldParentPtr(TestDataResolver, "api", res);
    const item = if (std.mem.eql(u8, "input", path))
      self.source.items.getPtr(path) orelse {
        std.debug.print("failed to fetch '{s}'\nexisting items:\n", .{path});
        var iter = self.source.items.keyIterator();
        while (iter.next()) |key| std.debug.print("{s}\n", .{key.*});
        std.debug.print("existing inputs:\n", .{});
        iter = self.source.params.input.keyIterator();
        while (iter.next()) |key| std.debug.print("{s}\n", .{key.*});
        unreachable;
      }
    else self.source.params.input.getPtr(path) orelse {
      std.debug.print("failed to fetch '{s}'\nexisting inputs:\n", .{path});
      var iter = self.source.params.input.keyIterator();
      while (iter.next()) |key| std.debug.print("{s}\n", .{key.*});
      return null;
    };
    const ret = try allocator.create(Cursor);
    ret.* = .{
      .api = .{.name = path},
      .value = item,
    };
    return &ret.api;
  }

  fn getSource(
    res: *nyarna.Resolver,
    allocator: std.mem.Allocator,
    cursor: *nyarna.Resolver.Cursor,
    descriptor: *const model.Source.Descriptor,
    _: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source {
    const self = @fieldParentPtr(TestDataResolver, "api", res);
    const test_cursor = @fieldParentPtr(Cursor, "api", cursor);
    try test_cursor.value.content.appendSlice(
      self.source.allocator(), "\x04\x04\x04\x04");
    const ret = try allocator.create(model.Source);
    ret.* = .{
      .meta = descriptor,
      .content = test_cursor.value.content.items,
      .offsets = .{
        .line = test_cursor.value.line_offset,
        .column = 0,
      },
      .locator_ctx = descriptor.genLocatorCtx(),
    };
    return ret;
  }

  pub fn valueLines(
    self: *TestDataResolver,
    name: []const u8,
  ) std.mem.SplitIterator(u8) {
    return std.mem.split(u8, self.source.items.get(name).?.content.items, "\n");
  }

  pub fn paramLines(
    self: *TestDataResolver,
    comptime param: []const u8,
    name: []const u8,
  ) std.mem.SplitIterator(u8) {
    return std.mem.split(
      u8, @field(self.source.params, param).get(name).?.content.items, "\n");
  }
};