const std = @import("std");

const nyarna = @import("nyarna");
const tml    = @import("tml.zig");

const errors   = nyarna.errors;
const Loader   = nyarna.Loader;
const model    = nyarna.model;

pub const TestDataResolver = struct {
  const Cursor = struct {
    api  : Loader.Resolver.Cursor,
    value: *tml.Value,
  };

  api   : Loader.Resolver,
  stdlib: Loader.FileSystemResolver,
  source: tml.File,

  pub fn init(path: []const u8) !TestDataResolver {
    const abs_path =
      try std.fs.cwd().realpathAlloc(std.testing.allocator, "lib");
    errdefer std.testing.allocator.free(abs_path);
    return TestDataResolver{
      .api = .{
        .resolveFn   = resolve,
        .getSourceFn = getSource,
      },
      .stdlib = Loader.FileSystemResolver.init(abs_path),
      .source = try tml.File.loadPath(std.testing.allocator, path),
    };
  }

  pub fn deinit(self: *TestDataResolver) void {
    self.source.deinit();
    std.testing.allocator.free(self.stdlib.base);
  }

  fn resolve(
    res      : *Loader.Resolver,
    allocator: std.mem.Allocator,
    path     : []const u8,
    _        : model.Position,
    _        : *errors.Handler,
  ) std.mem.Allocator.Error!?*Loader.Resolver.Cursor {
    const self = @fieldParentPtr(TestDataResolver, "api", res);
    const name = if (std.mem.eql(u8, "input", path)) "" else path;
    const item = self.source.params.input.getPtr(name) orelse return null;
    const ret = try allocator.create(Cursor);
    ret.* = .{
      .api = .{.name = path},
      .value = item,
    };
    return &ret.api;
  }

  fn getSource(
    res       : *Loader.Resolver,
    allocator : std.mem.Allocator,
    cursor    : *Loader.Resolver.Cursor,
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
             self : *TestDataResolver,
    comptime param: []const u8,
             name : []const u8,
  ) std.mem.SplitIterator(u8) {
    return std.mem.split(
      u8, @field(self.source.params, param).get(name).?.content.items, "\n");
  }
};