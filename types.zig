const std = @import("std");
const data = @import("data.zig");


/// This is Nyarna's type lattice. It calculates type intersections, checks type
/// compatibility, and owns all data of structural types.
pub const Lattice = struct {
  const Self = @This();
  /// This node is used to efficiently store and search for intersection types;
  /// see doc on the intersections field.
  const TreeNode = struct {
    key: data.Type,
    value: ?*data.Type.Structural,
    next: ?*TreeNode,
    children: ?*TreeNode,
  };

  /// allocator used for data of structural types
  alloc: *std.mem.Allocator,
  optionals: std.HashMapUnmanaged(data.Type, *data.Type.Structural, data.Type.hash,
      data.Type.eql, std.hash_map.default_max_load_percentage),
  /// This is a search tree that holds all known intersection types. It is based
  /// on an artificial total order on types, implemented in the `OrderedIndex.less` fn.
  ///
  /// A TreeNode and its `next` pointer form a list whose types adhere to the
  /// artifical total order on types. Each tree node may have a list of children.
  /// The field `intersections` is the root node that only contains children and
  /// has an undefined key (this is mainly to avoid special cases for the root node).
  ///
  /// An intersection type is stored as value in a TreeNode `x`, so that the set of
  /// keys of those TreeNodes where you descend into children to reach `x`
  /// equals the set of types inside the intersection type. The order of the
  /// keys follows the artificial total order on types.
  ///
  /// I expect the worst-case time of discovering the intersection type for a
  /// list of n types to be (n log(m)) where m is the number of existing types
  /// allowed in an intersection, but I didn't calculate it. Note that the farther
  /// along the current list you descent, the fewer types can be in the child list.
  intersections: TreeNode,

  pub fn init(alloc: *std.mem.Allocator) Lattice {
    return .{
      .alloc = alloc,
      .optionals = .{},
      .intersections = .{
        .key = undefined,
        .value = null,
        .next = null,
        .children = null,
      },
    };
  }

  fn total_order_less(a: data.Type, b: data.Type) bool {
    const a_int = switch (a) {
      .intrinsic => |ia| {
        return switch (b) {
          .intrinsic => |ib| @enumToInt(ia) < @enumToInt(ib),
          else => true,
        };
      },
      .structural => |sa| @ptrToInt(sa),
      .instantiated => |ia| @ptrToInt(ia),
    };
    const b_int = switch (b) {
      .intrinsic => return false,
      .structural => |sb| @ptrToInt(sb),
      .instantiated => |ib| @ptrToInt(ib),
    };
    return a_int < b_int;
  }

  const NodeIter = struct {
    cur: *TreeNode,

    fn descend(self: *NodeIter, t: data.Type) !void {
      var next = &self.cur.children;
      while (next.*) |next_node| : (next = &next_node.next) {
        if (!total_order_less(next_node.key, t)) break;
      }
      self.cur = (if (next.*) |succ| if (t.eql(succ.key)) succ else null else null) orelse blk: {
        var new = try self.alloc.create(TreeNode);
        new.* = .{
          .key = cur_type,
          .value = null,
          .next = next.*,
          .children = null,
        };
        next.* = new;
        break :blk new;
      };
      self.count += 1;
    }
  };

  pub fn greaterEqual(self: *Self, left: *data.Type, right: *data.Type) bool {
    return left.eql(self.sup(left, right));
  }

  pub fn greater(self: *Self, left: *data.Type, right: *data.Type) bool {
    return !left.eql(right) and self.greaterEqual(left, right);
  }

  pub fn lesser(self: *Self, left: *data.Type, right: *data.Type) bool {
    return self.greater(right, left);
  }

  pub fn lesserEqual(self: *Self, left: *data.Type, right: *data.Type) bool {
    return self.greaterEqual(right, left);
  }

  pub fn sup(self: *Self, t1: data.Type, t2: data.Type) data.Type {
    if (t1.eql(t2)) return t1.*;
    // defer structural and intrinsic cases to their respective functions
    const types = [_]data.Type{t1, t2};
    for (types) |t, i| switch (t) {
      .structural => |struc| return self.supWithStructure(struc, types[(i + 1) % 2]),
      else => {},
    };
    for (types) |t, i| switch (t) {
      .intrinsic => |intr| return self.supWithIntrinsic(intr, types[(i + 1) % 2]),
      else => {},
    };
    const inst_types = [_]data.Type{t1.instantiated, t2.instantiated};
    for (inst_types) |t, i| switch (t.data) {
      .record => {
        return self.calcIntersection(.{&[_]data.Type{t1}, &[_]data.Type{t2}});
      },
      else => {},
    };
    for (inst_types) |t, i| switch (t.data) {
      .numeric => |n| {
        const other = inst_types[(i + 1) % 2];
        return switch (other.data) {
          .float => if (i == 0) t2 else t1,
          .numeric => |other_n| unreachable, // TODO
          other => .{.intrinsic = .raw},
        };
      },
      else => {},
    };
    for (inst_types) |t, i| switch (t.data) {
      .tenum => |e| {
        const other = inst_types[(i + 1) % 2];
        return switch (other.data) {
          .tenum => unreachable, // TODO: return predefined Identifier type
          .textual => |text| unreachable, // TODO: return sup of Identifier with text
          else => .{.intrinsic = .raw},
        };
      }
    };
    if (inst_types[0].data == .float and inst_types[1].data == .float)
      return if (@enumToInt(inst_types[0].data.float.precision) < @enumToInt(inst_types[1].data.float.precision))
        t2 else t1;
    if (inst_types[0].data == .textual and inst_types[1].data == .textual)
      unreachable; // TODO: form type that allows all characters accepted by any of the two types
    // at this point, we have two different instantiated types that are not records,
    // nor in any direct relationship with each other. therefore…
    return .{.intrinsic = .raw};
  }

  fn calcIntersection(self: *Self, input: anytype) data.Type {
    var iter = NodeIter{.cur = &self.intersections};
    var tcount = @as(usize, 0);
    var indexes: [input.len]usize = undefined;
    for (indexes) |*ptr| ptr.* = 0;
    while (true) {
      var cur_type: ?data.Type = null;
      inline for (input) |list, index| {
        if (indexes[index] < list.len) {
          const next_in_list = list[indexes[index]];
          if (cur_type) |previous| {
            if (total_order_less(next_in_list, previous)) cur_type = next_in_list;
          } else cur_type = next_in_list;
        }
      }
      if (cur_type) |next_type| {
        inline for (input) |list, index| {
          if (list[indexes[index]].eql(next_type)) indexes[index] += 1;
        }
        try iter.descend(next_type);
        if (!next_type.isScalar()) tcount += 1;
      } else break;
    }
    return .{.structural = iter.cur.value orelse blk: {
      var new = try self.alloc.create(data.Type.Structural);
      new.* = .{
        .intersection = undefined
      };
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = null,
        .types = try self.alloc.alloc(data.Type, tcount),
      };
      new_in.scalar = if (in1.scalar) |*s1|
        if (in2.scalar) |*s2| self.sup(s1, s2) else s1.*
      else if (in2.scalar) |*s2| s2.* else null;
      var target_index = @as(usize, 0);
      for (indexes) |*ptr| ptr.* = 0;
      while (true) {
        var cur_type: ?data.Type = null;
        inline for (input) |list, index| {
          if (indexes[index] < list.len) {
            const next_in_list = list[indexes[index]];
            if (cur_type) |previous| {
              if (total_order_less(next_in_list, previous)) cur_type = next_in_list;
            } else cur_type = next_in_list;
          }
        }
        if (cur_type) |next_type| {
          inline for (input) |list, index| {
            if (list[indexes[index]].eql(next_type)) indexes[index] += 1;
          }
          if (next_type.isScalar()) {
            new_in.scalar = next_type;
          } else {
            new_in.types[target_index] = next_type;
            target_index += 1;
          }
        } else break;
      }
      iter.cur.value = new;
      break :blk new;
    }};
  }

  fn supWithStructure(self: *Self, struc: *data.Type.Structural, other: data.Type) !data.Type {
    switch (other) {
      .intrinsic => |other_in| switch (other_in) {
        .every => return .{.structural = struc},
        .void => return switch (struc) {
          .concat => .{.structural = struc},
          else => try self.optional(.{.structural = struc}) orelse .{.intrinsic = .poison},
        },
        .space, .literal, .raw => {},
      },
      // we're handling some special cases here, but most are handled by the switch below.
      .structural => |other_struc| switch (struc) {
        .optional => |*op| switch (other_struc) {
          .optional => |*other_op| return try
            self.optional(self.sup(&other_op.inner, &op.inner)) orelse .{.intrinsic = .poison},
          .concat => |*other_con| return try
            self.concat(self.sup(&other_con.inner, &op.inner)) orelse .{.intrinsic = .poison},
          else => {},
        },
        .concat => |*other_con| switch (struc) {
          .optional => |*op| return try
            self.concat(self.sup(&op.inner, &other_con.inner)) orelse .{.intrinsic = .poison},
          .concat => |*con| return try
            self.concat(self.sup(&other_con.inner, &con.inner)) orelse .{.intrinsic = .poison},
          else => {},
        },
        .intersection => |*other_inter| switch (struc) {
          .intersection => |*inter| {
            const scalar_type = if (inter.scalar) |inter_scalar|
              if (other_inter.scalar) |other_scalar| try self.sup(inter_scalar, other_scalar)
              else inter_scalar
            else other_inter.scalar;

            return if (scalar_type) |st|
              self.calcIntersection(.{&[1]data.Type{st}, inter.types, other_inter.types})
            else self.calcIntersection(.{inter.types, other_inter.types});
          },
          else => {},
        },
        else => {},
      }
    }
    return switch (s2) {
      .optional => |*o| try self.optional(self.sup(&o.inner, t1)) orelse .{.intrinsic = .poison},
      .concat => |*c| try self.concat(self.sup(&c.inner, t1)) orelse .{.intrinsic = .poison},
      .paragraphs => {
        unreachable; // TODO
      },
      .list => |*l| try self.list(self.sup(&l.inner, t1)) orelse .{.intrinsic = .poison},
      .map => {
        unreachable; // TODO
      },
      .callable => {
        unreachable; // TODO
      },
      .intersection => |*inter| blk: {
        if (other.isScalar()) {
          const scalar_type = if (inter.scalar) |inter_scalar| try self.sup(other, inter_scalar) else other;
          break :blk try self.calcIntersection(&[_]data.Type{scalar_type}, inter.types);
        } else switch (other) {
          .instantiated => |other_inst| if (other_inst.data == .record) {
            break :blk try if (inter.scalar) |inter_scalar|
              self.calcIntersection(&[_]data.Type{inter_scalar}, &[_]data.Type{other}, inter.types)
            else self.calcIntersection(&[_]data.Type{other}, inter.types);
          }
        }
        break :blk .{.intrinsic = .poison};
      }
    };
  }

  fn supWithIntrinsic(self: *Self, intr: @typeInfo(data.Type).Union.fields[0].field_type, other: data.Type) data.Type {
    return switch(intr) {
      .void => try self.optional(other) orelse .{.intrinsic = .poison},
      .prototype, .schema, .extension, .ast_node => .{.intrinsic = .poison},
      .space, .literal, .raw => switch (other) {
        .intrinsic => |other_intr| switch (other_intr) {
          .every => .{.intrinsic = intr},
          .void => (try self.optional(other)).?,
          .space, .literal, .raw => .{.intrinsic = @intToEnum(@TypeOf(intr), @maximum(@enumToInt(intr), @enumToInt(other_intr)))},
          else => .{.intrinsic = .poison},
        },
        .structural => unreachable, // this case is handled in supWithStructural.
        .instantiated => .{.intrinsic = .poison},
      }
    };
  }

  pub fn supAll(self: *Self, types: anytype) data.Type {
    var res = data.Type{
      .intrinsic = .every
    };
    if (@typeInfo(@TypeOf(types)) == .Slice) {
      for (types) |*t| {
        res = self.sup(&res, t);
      }
    } else {
      inline for (types) |*t| {
        res = self.sup(&res, t);
      }
    }
    return res;
  }

  pub fn optional(self: *Self, t: data.Type) !?data.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension, .ast_node => return null,
        .every => return .{.intrinsic = .void},
        else => {},
      },
      .structural => |s| switch (s) {
        .optional, .concat, .paragraphs => return null,
        else => {},
      },
      .instantiated => {},
    }
    const res = try self.optionals.getOrPut(self.alloc, t.*);
    if (!res.found_existing) {
      res.value_ptr.* = self.alloc.create(data.Type.Structural);
      res.value_ptr.*.* = .{
        .optional = .{
          .inner = t.*
        }
      };
    }
    return data.Type{.structural = res.value_ptr.*};
  }
};