//! This resolver resolves names to entries in a HashMap.

const std = @import("std");

const nyarna   = @import("../../nyarna.zig");

const Resolver = @import("Resolver.zig");

const Content = std.StringHashMap([]const u8);

const Cursor = struct {
  api  : Resolver.Cursor,
  entry: Content.Entry,
};

const errors = nyarna.errors;
const model  = nyarna.model;

api    : Resolver,
content: std.StringHashMap([]const u8),

pub fn init() @This() {
  return .{
    .api = .{
      .resolveFn = resolve,
      .getSourceFn = getSource,
    },
    .content = std.StringHashMap([]const u8).init(std.heap.page_allocator),
  };
}

fn resolve(
  res      : *Resolver,
  allocator: std.mem.Allocator,
  path     : []const u8,
  _        : model.Position,
  _        : *errors.Handler,
) std.mem.Allocator.Error!?*Resolver.Cursor {
  const self = @fieldParentPtr(@This(), "api", res);

  const entry = self.content.getEntry(path) orelse return null;

  const ret = try allocator.create(Cursor);
  ret.* = .{
    .api   = .{.name = try allocator.dupe(u8, path)},
    .entry = entry,
  };
  return &ret.api;
}

fn getSource(
  _         : *Resolver,
  allocator : std.mem.Allocator,
  cursor    : *Resolver.Cursor,
  descriptor: *const model.Source.Descriptor,
  _         : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  const my_cursor = @fieldParentPtr(Cursor, "api", cursor);

  const res = try allocator.create(model.Source);
  res.* = .{
    .meta    = descriptor,
    .content = my_cursor.entry.value_ptr.*,
    .offsets = .{},
    .locator_ctx = descriptor.genLocatorCtx(),
  };
  return res;
}