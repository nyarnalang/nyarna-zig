const std = @import("std");

const nyarna = @import("nyarna");
const model = nyarna.model;
const errors = nyarna.errors;
const tml = @import("tml.zig");

pub const TestDataResolver = struct {
  const Descriptor = struct {
    api: model.Source.Descriptor,
    value: *tml.Value,
  };

  api: nyarna.Resolver,
  source: tml.File,

  pub fn init(path: []const u8) !TestDataResolver {
    return TestDataResolver{
      .api = .{
        .resolveFn = resolve,
        .getSourceFn = getSource,
      },
      .source = try tml.File.loadPath(path),
    };
  }

  pub fn deinit(self: *TestDataResolver) void {
    self.source.deinit();
  }

  fn resolve(res: *nyarna.Resolver, path: []const u8, _: model.Position,
             _: *errors.Handler) !?*model.Source.Descriptor {
    const self = @fieldParentPtr(TestDataResolver, "api", res);
    const item = self.source.items.getPtr(path) orelse return null;
    const absolute = try self.source.arena.allocator().alloc(u8, path.len + 5);
    std.mem.copy(u8, absolute, ".doc.");
    std.mem.copy(u8, (absolute.ptr + 5)[0..path.len], path);
    const ret = try self.source.arena.allocator().create(Descriptor);
    ret.* = .{
      .api = .{
        .name = path,
        .locator = absolute,
        .argument = false,
      },
      .value = item,
    };
    return &ret.api;
  }

  fn getSource(
      res: *nyarna.Resolver, descriptor: *const model.Source.Descriptor,
      allocator: std.mem.Allocator, _: *errors.Handler)
      std.mem.Allocator.Error!?*model.Source {
    const self = @fieldParentPtr(TestDataResolver, "api", res);
    const test_desc = @fieldParentPtr(Descriptor, "api", descriptor);
    try test_desc.value.content.appendSlice(
      self.source.allocator(), "\x04\x04\x04\x04");
    const ret = try allocator.create(model.Source);
    ret.* = .{
      .meta = descriptor,
      .content = test_desc.value.content.items,
      .offsets = .{
        .line = test_desc.value.line_offset,
        .column = 0,
      },
      .locator_ctx = descriptor.genLocatorCtx(),
    };
    return ret;
  }

  pub fn valueLines(self: *TestDataResolver, name: []const u8)
      std.mem.SplitIterator(u8) {
    return std.mem.split(u8, self.source.items.get(name).?.content.items, "\n");
  }
};