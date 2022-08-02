//! This resolver only resolves a single module, whose name is empty.
//! It can be used for giving a main module that doesn't have a context
//! in which sibling modules can be resolved, e.g. stdin.

const std = @import("std");

const nyarna   = @import("../../nyarna.zig");

const Resolver = @import("Resolver.zig");

const errors = nyarna.errors;
const model  = nyarna.model;

api    : Resolver,
content: []const u8,
cursor : Resolver.Cursor = .{.name = ""},

/// content must be readily consumable, i.e. must end with 4 EOF characters.
pub fn init(content: []const u8) @This() {
  const len = content.len;
  std.debug.assert(
    std.mem.eql(u8, content[len - 4 .. len], "\x04\x04\x04\x04"));
  return .{
    .api = .{
      .resolveFn = resolve,
      .getSourceFn = getSource,
    },
    .content = content,
  };
}

fn resolve(
  res      : *Resolver,
  allocator: std.mem.Allocator,
  path     : []const u8,
  pos      : model.Position,
  logger   : *errors.Handler,
) std.mem.Allocator.Error!?*Resolver.Cursor {
  _ = allocator; _ = pos; _ = logger;
  const self = @fieldParentPtr(@This(), "api", res);
  return if (path.len == 0) &self.cursor else null;
}

fn getSource(
  _         : *Resolver,
  allocator : std.mem.Allocator,
  cursor    : *Resolver.Cursor,
  descriptor: *const model.Source.Descriptor,
  _         : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  const self = @fieldParentPtr(@This(), "cursor", cursor);
  const ret = try allocator.create(model.Source);
  ret.* = .{
    .meta        = descriptor,
    .content     = self.content,
    .offsets     = .{},
    .locator_ctx = descriptor.genLocatorCtx(),
  };
  return ret;
}