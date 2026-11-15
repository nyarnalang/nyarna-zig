const std = @import("std");

pub fn last(slice: anytype) *std.meta.Elem(@TypeOf(slice)) {
  return &slice[slice.len - 1];
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
    const t = x;
    x = @mod(y, x);
    y = t;
  }
  return y;
}
/// stores the possibly overflown result of a + b in res and returns whether
/// the operation did overflow.
pub fn addOverflow(a: i64, b: i64, res: *i64) bool {
  const ret = @addWithOverflow(a, b);
  res.* = ret[0];
  return ret[1] != 0;
}

/// stores the possibly overflown result of a - b in res and returns whether
/// the operation did overflow.
pub fn subOverflow(a: i64, b: i64, res: *i64) bool {
  const ret = @subWithOverflow(a, b);
  res.* = ret[0];
  return ret[1] != 0;
}

/// stores the possibly overflown result of a * b in res and returns whether
/// the operation did overflow.
pub fn mulOverflow(a: i64, b: i64, res: *i64) bool {
  const ret = @mulWithOverflow(a, b);
  res.* = ret[0];
  return ret[1] != 0;
}
