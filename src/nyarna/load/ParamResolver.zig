//! this implementation exists for the sole reason of feeding command line
//! parameters into the ModuleLoader just like everything else. There is no
//! other benefit of hiding this trivial implementation behind the Resolver API.

const std = @import("std");

const errors   = @import("../errors.zig");
const model    = @import("../model.zig");
const Resolver = @import("Resolver.zig");

pub const Cursor = struct {
  api : Resolver.Cursor,
  content: []const u8,
};

api : Resolver,

pub fn init() @This() {
  return .{
    .api = .{
      .resolveFn = resolve,
      .getSourceFn = getSource,
    },
  };
}

fn resolve(
  _ : *Resolver,
  _ : std.mem.Allocator,
  _ : []const u8,
  _ : model.Position,
  _ : *errors.Handler,
) std.mem.Allocator.Error!?*Resolver.Cursor {
  // never called. The ParamResolver is only used for pushing a Cursor into the
  // ModuleLoader, which will only call getSource().
  unreachable;
}

fn getSource(
  _         : *Resolver,
  allocator : std.mem.Allocator,
  cursor    : *Resolver.Cursor,
  descriptor: *const model.Source.Descriptor,
  _         : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  var fc = @fieldParentPtr(Cursor, "api", cursor);
  const content = try allocator.alloc(u8, fc.content.len + 4);
  errdefer allocator.free(content);
  std.mem.copy(u8, content, fc.content);
  std.mem.copy(u8, content[fc.content.len..], "\x04\x04\x04\x04");
  const ret = try allocator.create(model.Source);
  ret.* = .{
    .meta        = descriptor,
    .content     = content,
    .offsets     = .{},
    .locator_ctx = descriptor.genLocatorCtx(),
  };
  return ret;
}