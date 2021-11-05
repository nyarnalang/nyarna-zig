const std = @import("std");
const data = @import("data.zig");
const interpret = @import("load/interpret.zig");

/// This is Nyarna's type lattice. It calculates type intersections, checks type
/// compatibility, and owns all data of structural types.
///
/// As it is defined, the type lattice defines only a partial order on types.
/// To simplify processing, the Lattice additionally defines an internal,
/// artificial total order on types. This total order has the single constraint
/// of being stable: Adding new types must not change the relation between
/// existing types. No information about the relation between types as per
/// language specification can thus be extracted from the total order.
///
/// The total order is used for keeping type lists sorted. By having sorted type
/// lists, operations like calculating the supremum of two intersections will
/// be faster because they will be a single O(n) merge operation. This is also
/// less complex to implement.
///
/// The lattice owns all allocated type information. Allocated type information
/// exists for structural and instantiated types. The lattice ensures that for
/// every distinct type, only a single data object exists. This makes type
/// calculations fast, as the identity can be calculated as pointer equality.
///
/// To facilitate type uniqueness, the Lattice provides idempotent functions for
/// obtaining structural types: optional(self, t) for example will, when called
/// on some distinct t for the first time, allocate that type and return it, and
/// any subsequent call with the same t will return that allocated type.
pub const Lattice = struct {
  const Self = @This();
  /// This node is used to efficiently store and search for intersection types;
  /// see doc on the intersections field.
  const TreeNode = struct {
    key: data.Type,
    value: ?*data.Type.Structural,
    next: ?*TreeNode,
    children: ?*TreeNode,

    /// This type is used to navigate the intersections field. Given a node,
    /// it will descend into its children and search the node matching the
    /// given type, or create and insert a node for it if none exists.
    const Iter = struct {
      cur: *TreeNode,
      lattice: *Lattice,

      fn descend(self: *Iter, t: data.Type) !void {
        var next = &self.cur.children;
        while (next.*) |next_node| : (next = &next_node.next) {
          if (!total_order_less(next_node.key, t)) break;
        }
        // inlining this causes a compiler bug :)
        const hit = if (next.*) |succ| if (t.eql(succ.key)) succ else null else null;
        self.cur = hit orelse blk: {
          var new = try self.lattice.alloc.create(TreeNode);
          new.* = .{
            .key = t,
            .value = null,
            .next = next.*,
            .children = null,
          };
          next.* = new;
          break :blk new;
        };
      }
    };
  };

  /// allocator used for data of structural types
  alloc: *std.mem.Allocator,
  optionals: std.HashMapUnmanaged(data.Type, *data.Type.Structural,
      data.Type.HashContext, std.hash_map.default_max_load_percentage),
  concats: std.HashMapUnmanaged(data.Type, *data.Type.Structural,
      data.Type.HashContext, std.hash_map.default_max_load_percentage),
  lists: std.HashMapUnmanaged(data.Type, *data.Type.Structural,
      data.Type.HashContext, std.hash_map.default_max_load_percentage),
  /// This is a search tree that holds all known intersection types.
  ///
  /// A TreeNode and its `next` pointer form a list whose types adhere to the
  /// artifical total order on types. Each tree node may have a list of children.
  /// The field `intersections` is the root node that only contains children and
  /// has an undefined key.
  ///
  /// An intersection type is stored as value in a TreeNode `x`, so that the set of
  /// keys of those TreeNodes where you descend into children to reach `x`
  /// equals the set of types inside the intersection type. The order of the
  /// keys follows the artificial total order on types.
  ///
  /// I expect the worst-case time of discovering the intersection type for a
  /// list of n types to be (n log(m)) where m is the number of existing types
  /// allowed in an intersection, but I didn't calculate it. Note that the farther
  /// along the current list you descent, the fewer types can be in the child list
  /// since the child list can only contain types that come after the type you
  /// descend on in the artificial total order.
  intersections: TreeNode,
  /// constructors for all types that have constructors.
  /// these are to be queried via fn constructor().
  type_constructors: []data.Symbol.ExtFunc,
  /// predefined types. TODO: move these to system.ny
  boolean: data.Type.Instantiated,

  pub fn init(alloc: *std.mem.Allocator) !Lattice {
    var ret = Lattice{
      .alloc = alloc,
      .optionals = .{},
      .concats = .{},
      .lists = .{},
      .intersections = .{
        .key = undefined,
        .value = null,
        .next = null,
        .children = null,
      },
      .type_constructors = try alloc.alloc(data.Symbol.ExtFunc, 1),
      .boolean = .{.at = data.Position.intrinsic(), .name = null, .data = .{.tenum = undefined}},
    };
    ret.boolean.data.tenum = try data.Type.Enum.predefBoolean(alloc);
    const boolsym = try alloc.create(data.Symbol);
    boolsym.defined_at = data.Position.intrinsic();
    boolsym.name = "Boolean";
    boolsym.data = .{.ny_type = .{.instantiated = &ret.boolean}};
    ret.boolean.name = boolsym;

    return ret;
  }

  /// may only be called on types that do have constructors
  pub fn constructor(self: *Self, t: data.Type) *data.Symbol.ExtFunc {
    const index = switch (t) {
      .intrinsic => |it| switch (it) {
        .location => 0,
        else => unreachable,
      },
      else => unreachable,
    };
    return &self.type_constructors[index];
  }

  /// this function implements the artificial total order. The total order's
  /// constraint is satisfied by ordering all intrinsic types (which do not have
  /// allocated information) before all other types, and ordering the other types
  /// according to the pointers to their allocated memory.
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

  pub fn greaterEqual(self: *Self, left: data.Type, right: data.Type) bool {
    return left.eql(self.sup(left, right) catch return false);
  }

  pub fn greater(self: *Self, left: data.Type, right: data.Type) bool {
    return !left.eql(right) and self.greaterEqual(left, right);
  }

  pub fn lesser(self: *Self, left: data.Type, right: data.Type) bool {
    return self.greater(right, left);
  }

  pub fn lesserEqual(self: *Self, left: data.Type, right: data.Type) bool {
    return self.greaterEqual(right, left);
  }

  pub fn sup(self: *Self, t1: data.Type, t2: data.Type) std.mem.Allocator.Error!data.Type {
    if (t1.eql(t2)) return t1;
    // defer structural and intrinsic cases to their respective functions
    const types = [_]data.Type{t1, t2};
    for (types) |t, i| switch (t) {
      .structural => |struc| return try self.supWithStructure(struc, types[(i + 1) % 2]),
      else => {},
    };
    for (types) |t, i| switch (t) {
      .intrinsic => |intr| return try self.supWithIntrinsic(intr, types[(i + 1) % 2]),
      else => {},
    };
    const inst_types = [_]*data.Type.Instantiated{t1.instantiated, t2.instantiated};
    for (inst_types) |t| switch (t.data) {
      .record => {
        return self.calcIntersection(.{&[_]data.Type{t1}, &[_]data.Type{t2}});
      },
      else => {},
    };
    for (inst_types) |t, i| switch (t.data) {
      .numeric => |_| {
        const other = inst_types[(i + 1) % 2];
        return switch (other.data) {
          .float => if (i == 0) t2 else t1,
          .numeric => |_| unreachable, // TODO
          else => .{.intrinsic = .raw},
        };
      },
      else => {},
    };
    for (inst_types) |t, i| switch (t.data) {
      .tenum => |_| {
        const other = inst_types[(i + 1) % 2];
        return switch (other.data) {
          .tenum => unreachable, // TODO: return predefined Identifier type
          .textual => |_| unreachable, // TODO: return sup of Identifier with text
          else => .{.intrinsic = .raw},
        };
      },
      else => {},
    };
    if (inst_types[0].data == .float and inst_types[1].data == .float)
      return if (@enumToInt(inst_types[0].data.float.precision) < @enumToInt(inst_types[1].data.float.precision))
        t2 else t1;
    if (inst_types[0].data == .textual and inst_types[1].data == .textual)
      unreachable; // TODO: form type that allows all characters accepted by any of the two types
    // at this point, we have two different instantiated types that are not records,
    // nor in any direct relationship with each other. therefore…
    return data.Type{.intrinsic = .raw};
  }

  fn calcIntersection(self: *Self, input: anytype) !data.Type {
    var iter = TreeNode.Iter{.cur = &self.intersections, .lattice = self};
    var tcount = @as(usize, 0);
    var indexes: [input.len]usize = undefined;
    for (indexes) |*ptr| ptr.* = 0;
    const fields = std.meta.fields(@TypeOf(input));
    var scalar: ?data.Type = null;
    while (true) {
      var cur_type: ?data.Type = null;
      inline for (fields) |field, index| {
        const vals = @field(input, field.name);
        if (indexes[index] < vals.len) {
          const next_in_list = vals[indexes[index]];
          if (cur_type) |previous| {
            if (total_order_less(next_in_list, previous)) cur_type = next_in_list;
          } else cur_type = next_in_list;
        }
      }
      if (cur_type) |next_type| {
        inline for (fields) |field, index| {
          const vals = @field(input, field.name);
          if (vals[indexes[index]].eql(next_type)) indexes[index] += 1;
        }
        try iter.descend(next_type);
        if (next_type.isScalar()) {
          std.debug.assert(scalar == null);
          scalar = next_type;
        } else tcount += 1;
      } else break;
    }
    return data.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.alloc.create(data.Type.Structural);
      new.* = .{
        .intersection = undefined
      };
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = scalar,
        .types = try self.alloc.alloc(data.Type, tcount),
      };
      var target_index = @as(usize, 0);
      for (indexes) |*ptr| ptr.* = 0;
      while (true) {
        var cur_type: ?data.Type = null;
        inline for (fields) |field, index| {
          const vals = @field(input, field.name);
          if (indexes[index] < vals.len) {
            const next_in_list = vals[indexes[index]];
            if (cur_type) |previous| {
              if (total_order_less(next_in_list, previous)) cur_type = next_in_list;
            } else cur_type = next_in_list;
          }
        }
        if (cur_type) |next_type| {
          inline for (fields) |field, index| {
            const vals = @field(input, field.name);
            if (vals[indexes[index]].eql(next_type)) indexes[index] += 1;
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
        .every => return data.Type{.structural = struc},
        .void => return switch (struc.*) {
          .concat => data.Type{.structural = struc},
          else => (try self.optional(.{.structural = struc})) orelse data.Type{.intrinsic = .poison},
        },
        .space, .literal, .raw => {},
        else => return data.Type{.intrinsic = .poison},
      },
      // we're handling some special cases here, but most are handled by the switch below.
      .structural => |other_struc| switch (struc.*) {
        .optional => |*op| switch (other_struc.*) {
          .optional => |*other_op| return
            (try self.optional(try self.sup(other_op.inner, op.inner))) orelse data.Type{.intrinsic = .poison},
          .concat => |*other_con| return
            (try self.concat(try self.sup(other_con.inner, op.inner))) orelse data.Type{.intrinsic = .poison},
          else => {},
        },
        .concat => |*other_con| switch (struc.*) {
          .optional => |*op| return
            (try self.concat(try self.sup(op.inner, other_con.inner))) orelse data.Type{.intrinsic = .poison},
          .concat => |*con| return
            (try self.concat(try self.sup(other_con.inner, con.inner))) orelse data.Type{.intrinsic = .poison},
          else => {},
        },
        .intersection => |*other_inter| switch (struc.*) {
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
      },
      .instantiated => {},
    }
    return switch (struc.*) {
      .optional => |*o| (try self.optional(try self.sup(o.inner, other))) orelse data.Type{.intrinsic = .poison},
      .concat => |*c| (try self.concat(try self.sup(c.inner, other))) orelse data.Type{.intrinsic = .poison},
      .paragraphs => {
        unreachable; // TODO
      },
      .list => |*l| (try self.list(try self.sup(l.inner, other))) orelse data.Type{.intrinsic = .poison},
      .map => {
        unreachable; // TODO
      },
      .callable => {
        unreachable; // TODO
      },
      .callable_type => {
        unreachable; // TODO
      },
      .intersection => |*inter| blk: {
        if (other.isScalar()) {
          const scalar_type = if (inter.scalar) |inter_scalar| try self.sup(other, inter_scalar) else other;
          break :blk try self.calcIntersection(.{&[_]data.Type{scalar_type}, inter.types});
        } else switch (other) {
          .instantiated => |other_inst| if (other_inst.data == .record) {
            break :blk try if (inter.scalar) |inter_scalar|
              self.calcIntersection(.{&[_]data.Type{inter_scalar}, &[_]data.Type{other}, inter.types})
            else self.calcIntersection(.{&[_]data.Type{other}, inter.types});
          },
          else => {},
        }
        break :blk data.Type{.intrinsic = .poison};
      }
    };
  }

  fn supWithIntrinsic(self: *Self, intr: @typeInfo(data.Type).Union.fields[0].field_type, other: data.Type) !data.Type {
    return switch(intr) {
      .void => (try self.optional(other)) orelse data.Type{.intrinsic = .poison},
      .prototype, .schema, .extension, .ast_node => .{.intrinsic = .poison},
      .space, .literal, .raw => switch (other) {
        .intrinsic => |other_intr| switch (other_intr) {
          .every => data.Type{.intrinsic = intr},
          .void => (try self.optional(other)).?,
          .space, .literal, .raw => data.Type{.intrinsic = @intToEnum(@TypeOf(intr), std.math.max(@enumToInt(intr), @enumToInt(other_intr)))},
          else => data.Type{.intrinsic = .poison},
        },
        .structural => unreachable, // this case is handled in supWithStructural.
        .instantiated => data.Type{.intrinsic = .poison},
      },
      .every => other,
      else => .{.intrinsic = .poison},
    };
  }

  pub fn supAll(self: *Self, types: anytype) !data.Type {
    var res = data.Type{
      .intrinsic = .every
    };
    if (@typeInfo(@TypeOf(types)) == .Slice) {
      for (types) |t| {
        res = try self.sup(&res, t);
      }
    } else {
      inline for (types) |t| {
        res = try self.sup(&res, t);
      }
    }
    return res;
  }

  /// returns Nyarna's builtin boolean type
  pub fn getBoolean(self: *Self) *const data.Type.Enum {
    return &self.boolean.data.tenum;
  }

  pub fn optional(self: *Self, t: data.Type) !?data.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension => return null,
        .every => return data.Type{.intrinsic = .void},
        else => {},
      },
      .structural => |s| switch (s.*) {
        .optional, .concat, .paragraphs => return null,
        else => {},
      },
      .instantiated => {},
    }
    const res = try self.optionals.getOrPut(self.alloc, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.alloc.create(data.Type.Structural);
      res.value_ptr.*.* = .{
        .optional = .{
          .inner = t
        }
      };
    }
    return data.Type{.structural = res.value_ptr.*};
  }

  pub fn concat(self: *Self, t: data.Type) std.mem.Allocator.Error!?data.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension, .ast_node => return null,
        .space, .literal, .raw => return t,
        else => {},
      },
      .structural => |s| switch (s.*) {
        .optional => |opt| return try self.concat(opt.inner),
        .concat => return t,
        .paragraphs => return null,
        else => {},
      },
      .instantiated => |ins| switch (ins.data) {
        .textual => return t,
        .record => {},
        else => return null,
      },
    }
    const res = try self.concats.getOrPut(self.alloc, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.alloc.create(data.Type.Structural);
      res.value_ptr.*.* = .{
        .concat = .{
          .inner = t
        }
      };
    }
    return data.Type{.structural = res.value_ptr.*};
  }

  pub fn list(self: *Self, t: data.Type) std.mem.Allocator.Error!?data.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension, .ast_node => return null,
        else => {},
      },
      else => {},
    }
    const res = try self.lists.getOrPut(self.alloc, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.alloc.create(data.Type.Structural);
      res.value_ptr.*.* = .{
        .list = .{
          .inner = t
        }
      };
    }
    return data.Type{.structural = res.value_ptr.*};
  }
};

const SigBuilderEnv = enum{
  intrinsic, userdef,

  fn contextType(comptime e: SigBuilderEnv) type {
    return switch (e) {
      .intrinsic => *std.mem.Allocator,
      .userdef => *interpret.Context
    };
  }

  fn create(comptime e: SigBuilderEnv, ctx: anytype, comptime T: type) !*T {
    return switch (e) {
      .intrinsic => ctx.create(T),
      .userdef => ctx.source_content.allocator.create(T)
    };
  }

  fn alloc(comptime e: SigBuilderEnv, ctx: anytype, comptime T: type, num: usize) ![]T {
    return switch (e) {
      .intrinsic => ctx.alloc(T, num),
      .userdef => ctx.source_content.allocator.alloc(T, num),
    };
  }

  fn errorMsg(comptime e: SigBuilderEnv, ctx: anytype, comptime error_name: []const u8, args: anytype) void {
    switch (e) {
      .intrinsic => unreachable,
      .userdef => @call(.{}, @field(ctx.eh, error_name), args),
    }
  }
};

pub fn SigBuilder(comptime kind: SigBuilderEnv) type {
  return struct {
    val: *data.Type.Signature,
    ctx: kind.contextType(),
    needs_different_repr: bool,
    next_param: u21,
    seen_error: bool,

    const Self = @This();

    /// if returns type is yet to be determined, give .{.intrinsic = .every}.
    /// the returns type is given early to know whether this is a keyword.
    pub fn init(context: kind.contextType(), num_params: usize, returns: data.Type) !Self {
      var ret = Self{
        .val = try kind.create(context, data.Type.Signature),
        .ctx = context,
        .needs_different_repr = false,
        .next_param = 0,
        .seen_error = false,
      };
      ret.val.* = .{
        .parameters = try kind.alloc(context, data.Type.Signature.Parameter, num_params),
        .primary = null,
        .varmap = null,
        .auto_swallow = null,
        .returns = returns,
        .repr = undefined
      };
      return ret;
    }

    pub fn push(self: *Self, loc: *data.Value.Location) !void {
      const param = &self.val.parameters[self.next_param];
      param.* = .{
        .pos = loc.value().origin,
        .name = loc.name,
        .ptype = loc.tloc,
        .capture = if (loc.varargs) |_| .varargs else if (loc.mutable) |_| @as(@TypeOf(param.capture), .mutable) else .default,
        .default = loc.default,
        .config = if (loc.block_header) |bh| bh.config else null,
      };
      // TODO: use contains(.ast_node) instead (?)
      if (!self.val.isKeyword() and loc.tloc.is(.ast_node)) {
        kind.errorMsg(self.ctx, "AstNodeInNonKeyword", .{loc.value().origin});
        self.seen_error = true;
      }
      if (loc.primary) |p| {
        if (self.val.primary) |pindex| {
          kind.errorMsg(self.ctx, "DuplicateFlag", .{"primary", p, self.val.parameters[pindex].pos});
          self.seen_error = true;
        } else {
          self.val.primary = self.next_param;
          self.needs_different_repr = true;
        }
      }
      if (loc.block_header) |bh| {
        if (bh.swallow_depth) |depth| {
          if (self.val.auto_swallow) |as| {
            var buf: [4]u8 = undefined;
            // inlining this into the errorMsg call leads to a compiler bug :)
            const repr = if (as.depth == 0) blk: {
              std.mem.copy(u8, &buf, ":>"); break :blk @as([]const u8, buf[0..2]);
            } else std.fmt.bufPrint(&buf, ":{}>", .{as.depth}) catch unreachable;
            kind.errorMsg(self.ctx, "DuplicateAutoSwallow", .{
              repr, bh.value().origin, self.val.parameters[as.param_index].pos
            });
            self.seen_error = true;
          } else {
            self.val.auto_swallow = .{
              .depth = depth,
              .param_index = self.next_param
            };
            self.needs_different_repr = true;
          }
        }
      }

      if (param.capture != .default or param.config != null or param.default != null)
        self.needs_different_repr = true;
      self.next_param += 1;
    }

    pub fn finish(self: *Self) if (kind == .intrinsic) *data.Type.Signature else ?*data.Type.Signature {
      std.debug.assert(self.next_param == self.val.parameters.len);
      if (self.seen_error) if (kind == .intrinsic) unreachable else return null;
      if (self.needs_different_repr) {
        // TODO: create different representation.
        // needed for comparison of callable types.
      }
      return self.val;
    }
  };
}