//! An Iterator iterates over values of iterable types.

const nyarna = @import("../../nyarna.zig");

const model = nyarna.model;

index: usize = 0,
backend: union(enum) {
  values: []*model.Value,
  items : []model.Value.Seq.Item,
},

const Iterator = @This();

pub fn init(subject: **model.Value) Iterator {
  return .{
    .backend = switch (subject.*.data) {
      .concat => |*con| .{.values = con.content.items},
      .list   => |*lst| .{.values = lst.content.items},
      .seq    => |*seq| .{.items  = seq.content.items},
      .poison, .void => .{.values = &.{}},
      else    => .{.values = @ptrCast(*[1]*model.Value,subject)[0..1]},
    }
  };
}

pub fn next(self: *Iterator) ?*model.Value {
  defer self.index += 1;
  return switch (self.backend) {
    .values => |vals| if (self.index == vals.len) null else vals[self.index],
    .items  => |its|
      if (self.index == its.len) null else its[self.index].content,
  };
}