const std = @import("std");

pub inline fn last(slice: anytype) *std.meta.Elem(@TypeOf(slice)) {
  return &slice[slice.len - 1];
}

/// workaround for https://github.com/ziglang/zig/issues/6611
pub fn offset(comptime T: type, comptime field: []const u8) usize {
  var data = @unionInit(T, field, undefined);
  return @ptrToInt(&@field(data, field)) - @ptrToInt(&data);
}

/// This is an artificial order based on raw byte values, where eg "Z" < "a".
/// Used internally for sorted lists, do not use for user-faced ordering.
pub fn stringOrder(lhs: []const u8, rhs: []const u8) std.math.Order {
  var i: usize = 0; while (i < lhs.len) : (i += 1) {
    const order = if (i < rhs.len) std.math.order(lhs[i], rhs[i]) else .gt;
    if (order != .eq) return order;
  } else return std.math.order(i, rhs.len);
}

pub fn gcd(a: i64, b: i64) i64 {
  var x = a;
  var y = b;
  while (x > 0) {
    var t = x;
    x = @mod(y, x);
    y = t;
  }
  return y;
}