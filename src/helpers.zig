const std = @import("std");

pub inline fn last(slice: anytype) *std.meta.Elem(@TypeOf(slice)) {
  return &slice[slice.len - 1];
}

/// workaround for https://github.com/ziglang/zig/issues/6611
pub fn offset(comptime T: type, comptime field: []const u8) usize {
  var data = @unionInit(T, field, undefined);
  return @ptrToInt(&@field(data, field)) - @ptrToInt(&data);
}