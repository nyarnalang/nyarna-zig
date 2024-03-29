const std = @import("std");

const nyarna   = @import("../../nyarna.zig");
const Resolver = @import("Resolver.zig");

const errors = nyarna.errors;
const model  = nyarna.model;

/// used for building paths. avoids allocation when building paths.
var buffer: [1024]u8 = undefined;

const Cursor = struct {
  api : Resolver.Cursor,
  file: std.fs.File,
  stat: std.fs.File.Stat,
  pos : model.Position,
};

api : Resolver,
base: []const u8,

pub fn init(base_path: []const u8) @This() {
  std.debug.assert(std.fs.path.isAbsolute(base_path));
  return .{
    .api = .{
      .resolveFn = resolve,
      .getSourceFn = getSource,
    },
    .base = base_path,
  };
}

fn resolve(
  res      : *Resolver,
  allocator: std.mem.Allocator,
  path     : []const u8,
  pos      : model.Position,
  logger   : *errors.Handler,
) std.mem.Allocator.Error!?*Resolver.Cursor {
  const self = @fieldParentPtr(@This(), "api", res);
  const len = self.base.len + path.len + 4;
  var fs_path = if (len > 1024) (
    try allocator.alloc(u8, len)
  ) else buffer[0..len];
  defer if (len > 1024) allocator.free(fs_path);
  std.mem.copy(u8, fs_path, self.base);
  var at = self.base.len;
  var it = std.mem.split(u8, path, ".");
  while (it.next()) |part| {
    fs_path[at] = std.fs.path.sep;
    at += 1;
    std.mem.copy(u8, fs_path[at..], part);
    at += part.len;
  }
  std.mem.copy(u8, fs_path[at..], ".ny");
  const file = std.fs.openFileAbsolute(fs_path, .{}) catch |err| switch (err) {
    std.fs.File.OpenError.FileNotFound => return null,
    else => {
      logger.FailedToOpen(pos, fs_path, @errorName(err));
      return null;
    }
  };
  const stat = file.stat() catch |err| {
    logger.FailedToOpen(pos, fs_path, @errorName(err));
    file.close();
    return null;
  };
  if (stat.kind != .File) {
    logger.NotAFile(pos, fs_path, @tagName(stat.kind));
    file.close();
    return null;
  }
  errdefer file.close();

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
  _         : *Resolver,
  allocator : std.mem.Allocator,
  cursor    : *Resolver.Cursor,
  descriptor: *const model.Source.Descriptor,
  logger    : *errors.Handler,
) std.mem.Allocator.Error!?*model.Source {
  const fs_cursor = @fieldParentPtr(Cursor, "api", cursor);
  defer allocator.destroy(fs_cursor);
  defer fs_cursor.file.close();
  const content = try allocator.alloc(u8, fs_cursor.stat.size + 4);
  const read = fs_cursor.file.readAll(content) catch |err| {
    logger.FailedToRead(fs_cursor.pos, fs_cursor.api.name, @errorName(err));
    return null;
  };
  std.debug.assert(read == content.len - 4);
  std.mem.copy(u8, content[read..], "\x04\x04\x04\x04");
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