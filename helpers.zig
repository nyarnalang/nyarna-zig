const std = @import("std");

pub inline fn last(slice: anytype) *std.meta.Elem(@TypeOf(slice)) {
  return &slice[slice.len - 1];
}