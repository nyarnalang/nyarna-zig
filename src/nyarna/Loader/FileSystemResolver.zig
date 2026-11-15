const std = @import("std");

const nyarna   = @import("../../nyarna.zig");
const Resolver = @import("Resolver.zig");

const errors = nyarna.errors;
const model  = nyarna.model;

/// used for building paths. avoids allocation when building paths.
var buffer: [1024]u8 = undefined;

const Cursor = struct {
  api : Resolver.Cursor,
  file: std.Io.File,
  stat: std.Io.File.Stat,
  pos : model.Position,
};

api : Resolver,
base: []const u8,
io  : std.Io,

pub fn init(io: std.Io, base_path: []const u8) @This() {
  std.debug.assert(std.fs.path.isAbsolute(base_path));
  return .{
    .api = .{
      .resolveFn = resolve,
      .getSourceFn = getSource,
    },
    .base = base_path,
    .io   = io,
  };
}

fn resolve(
  res      : *Resolver,
  allocator: std.mem.Allocator,
  path     : []const u8,
  pos      : model.Position,
  logger   : *errors.Handler,
) std.mem.Allocator.Error!?*Resolver.Cursor {
  const self: *@This() = @fieldParentPtr("api", res);
  const len = self.base.len + path.len + 4;
  var fs_path = if (len > 1024) (
    try allocator.alloc(u8, len)
  ) else buffer[0..len];
  defer if (len > 1024) allocator.free(fs_path);
  @memcpy(fs_path[0..self.base.len], self.base);
  var at = self.base.len;
  var it = std.mem.splitScalar(u8, path, '.');
  while (it.next()) |part| {
    fs_path[at] = std.fs.path.sep;
    at += 1;
    @memcpy(fs_path[at..][0..part.len], part);
    at += part.len;
  }
  @memcpy(fs_path[at..][0..3], ".ny");
  const file = std.Io.Dir.openFileAbsolute(
    self.io, fs_path, .{}
  ) catch |err| switch (err) {
    error.FileNotFound => return null,
    else => {
      logger.FailedToOpen(pos, fs_path, @errorName(err));
      return null;
    }
  };
  const stat = file.stat(self.io) catch |err| {
    logger.FailedToOpen(pos, fs_path, @errorName(err));
    file.close(self.io);
    return null;
  };
  if (stat.kind != .file) {
    logger.NotAFile(pos, fs_path, @tagName(stat.kind));
    file.close(self.io);
    return null;
  }
  errdefer file.close(self.io);

  const ret = try allocator.create(Cursor);
  ret.* = .{
    .api  = .{.name = try allocator.dupe(u8, fs_path)},
    .file = file,
    .stat = stat,
    .pos  = pos,
  };
  return &ret.api;
}

fn getSource(
  res       : *Resolver,
  allocator : std.mem.Allocator,
  cursor    : *Resolver.Cursor,
  descriptor: *const model.Source.Descriptor,
  logger    : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  const self: *@This() = @fieldParentPtr("api", res);
  const fs_cursor: *Cursor = @alignCast(@fieldParentPtr("api", cursor));
  defer allocator.destroy(fs_cursor);
  defer fs_cursor.file.close(self.io);
  const content = try allocator.alloc(u8, fs_cursor.stat.size + 4);
  const read = fs_cursor.file.readPositionalAll(
    self.io, content[0..content.len - 4], 0
  ) catch |err| {
    logger.FailedToRead(fs_cursor.pos, fs_cursor.api.name, @errorName(err));
    return null;
  };
  std.debug.assert(read == content.len - 4);
  @memcpy(content[read..][0..4], "\x04\x04\x04\x04");
  errdefer allocator.free(content);
  const ret = try allocator.create(model.Source);
  ret.* = .{
    .meta        = descriptor,
    .content     = content,
    .offsets     = .{},
    .locator_ctx = descriptor.genLocatorCtx(),
  };
  return ret;
}