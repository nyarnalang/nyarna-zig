const std = @import("std");
const nyarna = @import("../nyarna.zig");

pub const LiteralNumber = struct {
  value: i64,
  decimals: usize,
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
    var num_decimals: usize = 0;
    var cur = rest.ptr;
    const end = rest[rest.len - 1 ..].ptr;
    while (true) : (cur += 1) {
      if (cur[0] == '.') {
        if (num_decimals != 0 or cur == end) return Result.invalid;
        num_decimals = @ptrToInt(end) - @ptrToInt(cur);
      } else if (cur[0] < '0' or cur[0] > '9') {
        return Result.invalid;
      } else {
        if (
          @mulWithOverflow(i64, val, 10, &val) or
          @addWithOverflow(i64, val, cur[0] - '0', &val)
        ) {
          return Result.too_large;
        }
      }
      if (cur == end) break;
    }
    if (neg) {
      if (@mulWithOverflow(i64, val, -1, &val)) return Result.too_large;
    }
    return Result{
      .success = .{.value = val, .decimals = num_decimals, .repr = text},
    };
  }
};