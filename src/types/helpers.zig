const model = @import("../model.zig");

/// this function implements the artificial total order. The total order's
/// constraint is satisfied by ordering all intrinsic types (which do not have
/// allocated information) before all other types, and ordering the other
/// types according to the pointers to their allocated memory.
///
/// The first argument exists so that this fn can be used for std.sort.sort.
pub fn totalOrderLess(_: void, a: model.Type, b: model.Type) bool {
  const a_int = switch (a) {
    .structural => |sa| @ptrToInt(sa),
    .named => |ia| @ptrToInt(ia),
  };
  const b_int = switch (b) {
    .structural => |sb| @ptrToInt(sb),
    .named => |ib| @ptrToInt(ib),
  };
  return a_int < b_int;
}

pub fn recTotalOrderLess(
  _: void,
  a: *model.Type.Record,
  b: *model.Type.Record,
) bool {
  return @ptrToInt(a.named()) < @ptrToInt(b.named());
}