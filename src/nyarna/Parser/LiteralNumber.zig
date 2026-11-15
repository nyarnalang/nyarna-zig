const std = @import("std");

const addOverflow = @import("../helpers.zig").addOverflow;
const mulOverflow = @import("../helpers.zig").mulOverflow;

const LiteralNumber = @This();

value: i64,
decimals: i64,
suffix: []const u8,
repr: []const u8,

pub const Result = union(enum) {
  success: LiteralNumber,
  invalid, too_large,
};

pub fn from(text: []const u8) Result {
  var val: i64 = 0;
  var neg = false;
  var rest = switch (if (text.len == 0) @as(u8, 0) else text[0]) {
    '+' => text[1..],
    '-' => blk: {
      neg = true;
      break :blk text[1..];
    },
    else => text,
  };
  if (rest.len == 0) return Result.invalid;
  var decimal_start: ?usize = null;
  var cur = rest.ptr;
  const end = rest[rest.len - 1 ..].ptr;
  while (true) : (cur += 1) {
    if (cur[0] == '.') {
      if (decimal_start != null or cur == end) return Result.invalid;
      decimal_start = @intFromPtr(cur);
    } else if (cur[0] < '0' or cur[0] > '9') {
      cur -= 1;
      break;
    } else {
      if (
        mulOverflow(val, 10, &val) or
        addOverflow(val, cur[0] - '0', &val)
      ) {
        return Result.too_large;
      }
    }
    if (cur == end) break;
  }
  if (@intFromPtr(cur) < @intFromPtr(rest.ptr)) return Result.invalid;
  if (neg) {
    if (mulOverflow(val, -1, &val)) return Result.too_large;
  }
  return Result{
    .success = .{
      .value = val,
      .decimals = if (decimal_start) |start| (
        @as(i64, @intCast(@intFromPtr(cur) - start))
      ) else 0,
      .repr = text,
      .suffix = rest[@intFromPtr(cur) - @intFromPtr(rest.ptr) + 1 ..],
    },
  };
}