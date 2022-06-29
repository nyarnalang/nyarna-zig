const std = @import("std");

const nyarna = @import("../../nyarna.zig");

const model  = nyarna.model;
const errors = nyarna.errors;

/// Resolver-specific cursor. Describes a source that can be loaded.
pub const Cursor = struct {
  /// name, owned by the caller.
  name: []const u8,
};

resolveFn: fn(
  self     : *@This(),
  allocator: std.mem.Allocator,
  path     : []const u8,
  pos      : model.Position,
  logger   : *errors.Handler,
) std.mem.Allocator.Error!?*Cursor,

getSourceFn: fn(
  self      : *@This(),
  allocator : std.mem.Allocator,
  cursor    : *Cursor,
  descriptor: *const model.Source.Descriptor,
  logger    : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source,

/// try to resolve the locator path given in `path`, which must be relative
/// (i.e. without a resolve name in front). Returns a Cursor if a source can
/// be found for the given path. Resolver implementations can return a pointer
/// into a larger struct to carry additional information. The Cursor's name is
/// to be allocated via `allocator`.
pub inline fn resolve(
  self     : *@This(),
  allocator: std.mem.Allocator,
  path     : []const u8,
  pos      : model.Position,
  logger   : *errors.Handler,
) std.mem.Allocator.Error!?*Cursor {
  return self.resolveFn(self, allocator, path, pos, logger);
}

/// Given `cursor` must have been returned by `resolve` of same Resolver.
/// Calling getSourceFn on another cursor is undefined behavior.
/// Returns the source belonging to that descriptor. The source is allocated
/// with the given allocator and is assigned the given descriptor.
pub inline fn getSource(
  self                : *@This(),
  source_allocator    : std.mem.Allocator,
  descriptor_allocator: std.mem.Allocator,
  cursor              : *Cursor,
  absolute_locator    : model.Locator,
  logger              : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  const descriptor = try descriptor_allocator.create(model.Source.Descriptor);
  descriptor.* = .{
    .name     = cursor.name,
    .locator  = absolute_locator,
    .argument = false,
  };
  return self.getSourceFn(self, source_allocator, cursor, descriptor, logger);
}