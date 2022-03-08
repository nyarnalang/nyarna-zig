const std = @import("std");
const model = @import("../model.zig");
const errors = @import("errors");

pub const Resolver = struct {
  /// try to resolve the locator path given in `path`, which must be relative
  /// (i.e. without a resolve name in front). Returns a Source.Descriptor if a
  /// source can be found for the given path.
  resolveFn: fn(
    self: *Resolver,
    path: []const u8,
    pos: model.Position,
    logger: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source.Descriptor,
  /// takes a descriptor that has been returned by resolve(). calling load on
  /// descriptors not returned by resolve() is undefined behavior! Returns the
  /// source belonging to that descriptor. The source is allocated with the
  /// given allocator.
  getSourceFn: fn(
    self: *Resolver,
    descriptor: *const model.Source.Descriptor,
    allocator: std.mem.Allocator,
    logger: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source,

  pub inline fn resolve(
    self: *Resolver,
    path: []const u8,
    pos: model.Position,
    logger: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source.Descriptor {
    return self.resolveFn(self, path, pos, logger);
  }

  pub inline fn getSource(
    self: *Resolver,
    descriptor: *const model.Source.Descriptor,
    allocator: std.mem.Allocator,
    logger: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source {
    return self.getSourceFn(self, descriptor, allocator, logger);
  }
};

/// used for building paths. avoids allocation when building paths.
var buffer: [1024]u8 = undefined;

pub const FilesystemResolver = struct {
  const Descriptor = struct {
    api: model.Source.Descriptor,
    file: std.fs.File,
    stat: std.fs.File.Stat,
  };

  api: Resolver,
  base: []const u8,
  allocator: std.mem.Allocator,

  fn init(
    name: []const u8,
    implicit: bool,
    base_path: []const u8,
    allocator: std.mem.Allocator,
  ) FilesystemResolver {
    return .{
      .api = .{
        .name = name,
        .implicit = implicit,
        .resolveFn = resolve,
        .getSourceFn = getSource,
      },
      .base = base_path,
      .allocator = allocator,
    };
  }

  fn resolve(
    res: *Resolver,
    path: []const u8,
    pos: model.Position,
    logger: *errors.Handler,
  ) !?*model.Source.Descriptor {
    const self = @fieldParentPtr(FilesystemResolver, "api", res);
    const len = self.base.len + path.len + 4;
    var fs_path = if (len > 1024)
      try self.allocator.alloc(u8, len)
    else buffer[0..self.base.len + path.len];
    defer if (len > 1024) self.allocator.free(fs_path);
    std.mem.copy(u8, fs_path, self.base);
    var at = self.base.len;
    var it = std.mem.split(u8, path, ".");
    while (it.next()) |part| {
      fs_path[at] = std.fs.path.sep;
      at += 1;
      std.mem.copy(u8, fs_path[at..], part);
    }
    std.mem.copy(u8, fs_path[at..], ".ny");
    const file = std.fs.openFileAbsolute(fs_path, .{})
      catch |err| switch (err) {
        std.fs.File.OpenError.FileNotFound => return null,
        else => {
          logger.FailedToOpenFile(pos, @tagName(err));
          return null;
        }
      };
    const stat = file.stat() catch |err| {
      logger.FailedToOpen(pos, fs_path, @tagName(err));
      file.close();
      return null;
    };
    if (stat.kind != .File) {
      logger.NotAFile(pos, fs_path, @tagName(stat.kind));
      file.close();
      return null;
    }
    errdefer file.close();
    const locator = try self.allocator.alloc(u8, path.len + 2 + self.name.len);
    locator[0] = '.';
    std.mem.copy(u8, locator[1..], self.name);
    locator[self.name.len + 1] = '.';
    std.mem.copy(u8, locator[self.name.len + 1], path);

    const ret = try self.allocator.create(Descriptor);
    ret.* = .{
      .api = .{
        .name = try self.allocator.dupe(u8, fs_path),
        .locator = locator,
        .argument = false,
      },
      .file = file,
      .stat = stat,
    };
    return &ret.api;
  }

  fn getSource(
    _: *Resolver,
    descriptor: *const model.Source.Descriptor,
    allocator: std.mem.Allocator,
    logger: *errors.Handler,
  ) std.mem.Allocator.Error!?*model.Source {
    const fs_desc = @fieldParentPtr(Descriptor, "api", descriptor);
    defer fs_desc.file.close();
    const content = try allocator.alloc(u8, fs_desc.stat.size + 4);
    const read = fs_desc.file.readAll(content) catch |err| {
      logger.FailedToRead(fs_desc.api.name, @tagName(err));
      return null;
    };
    std.debug.assert(read == content.len - 4);
    std.mem.copy(u8, content.ptr + read, "\x04\x04\x04\x04");
    errdefer allocator.free(content);
    const ret = try allocator.create(model.Source);
    ret.* = .{
      .meta = descriptor,
      .content = content,
      .offsets = .{},
      .locator_ctx = descriptor.genLocatorCtx(),
    };
    return ret;
  }
};