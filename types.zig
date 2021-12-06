const std = @import("std");
const model = @import("model.zig");
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
    key: model.Type,
    value: ?*model.Type.Structural,
    next: ?*TreeNode,
    children: ?*TreeNode,

    /// This type is used to navigate the intersections field. Given a node,
    /// it will descend into its children and search the node matching the
    /// given type, or create and insert a node for it if none exists.
    const Iter = struct {
      cur: *TreeNode,
      lattice: *Lattice,

      fn descend(self: *Iter, t: model.Type) !void {
        var next = &self.cur.children;
        while (next.*) |next_node| : (next = &next_node.next) {
          if (!total_order_less(undefined, next_node.key, t)) break;
        }
        // inlining this causes a compiler bug :)
        const hit =
          if (next.*) |succ| if (t.eql(succ.key)) succ else null else null;
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
  optionals: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  concats: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  lists: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  /// This is a search tree that holds all known intersection types.
  ///
  /// A TreeNode and its `next` pointer form a list whose types adhere to the
  /// artifical total order on types. Each tree node may have a list of
  /// children. The field `intersections` is the root node that only contains
  /// children and has an undefined key.
  ///
  /// An intersection type is stored as value in a TreeNode `x`, so that the set
  /// of keys of those TreeNodes where you descend into children to reach `x`
  /// equals the set of types inside the intersection type. The order of the
  /// keys follows the artificial total order on types.
  ///
  /// I expect the worst-case time of discovering the intersection type for a
  /// list of n types to be (n log(m)) where m is the number of existing types
  /// allowed in an intersection, but I didn't calculate it. Note that the
  /// farther along the current list you descent, the fewer types can be in the
  /// child list since the child list can only contain types that come after the
  /// type you descend on in the artificial total order.
  intersections: TreeNode,
  /// This is a search tree that holds all known paragraphs types.
  /// It works akin to the intersections tree.
  paragraphs_types: TreeNode,
  /// constructors for all types that have constructors.
  /// these are to be queried via fn constructor().
  type_constructors: []model.Symbol.ExtFunc,
  /// predefined types. TODO: move these to system.ny
  boolean: model.Type.Instantiated,

  pub fn init(alloc: *std.heap.ArenaAllocator) !Lattice {
    var ret = Lattice{
      .alloc = &alloc.allocator,
      .optionals = .{},
      .concats = .{},
      .lists = .{},
      .intersections = .{
        .key = undefined,
        .value = null,
        .next = null,
        .children = null,
      },
      .paragraphs_types = .{
        .key = undefined,
        .value = null,
        .next = null,
        .children = null,
      },
      .type_constructors = try alloc.allocator.alloc(model.Symbol.ExtFunc, 2),
      .boolean = .{
        .at = model.Position.intrinsic(), .name = null,
        .data = .{.tenum = undefined}
      },
    };
    ret.boolean.data.tenum = try model.Type.Enum.predefBoolean(ret.alloc);
    const boolsym = try ret.alloc.create(model.Symbol);
    boolsym.defined_at = model.Position.intrinsic();
    boolsym.name = "Boolean";
    boolsym.data = .{.ny_type = .{.instantiated = &ret.boolean}};
    ret.boolean.name = boolsym;

    return ret;
  }

  pub fn deinit(_: *Self) void {
    // nothing to do – the supplied ArenaAllocator will take care of freeing
    // the instantiated types.
  }

  /// may only be called on types that do have constructors
  pub fn constructor(self: *Self, t: model.Type) *model.Symbol.ExtFunc {
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
  /// allocated information) before all other types, and ordering the other
  /// types according to the pointers to their allocated memory.
  ///
  /// The first argument exists so that this fn can be used for std.sort.sort.
  fn total_order_less(_: void, a: model.Type, b: model.Type) bool {
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

  pub fn greaterEqual(self: *Self, left: model.Type, right: model.Type) bool {
    return left.eql(self.sup(left, right) catch return false);
  }

  pub fn greater(self: *Self, left: model.Type, right: model.Type) bool {
    return !left.eql(right) and self.greaterEqual(left, right);
  }

  pub fn lesser(self: *Self, left: model.Type, right: model.Type) bool {
    return self.greater(right, left);
  }

  pub fn lesserEqual(self: *Self, left: model.Type, right: model.Type) bool {
    return self.greaterEqual(right, left);
  }

  pub fn sup(self: *Self, t1: model.Type, t2: model.Type)
      std.mem.Allocator.Error!model.Type {
    if (t1.eql(t2)) return t1;
    // defer structural and intrinsic cases to their respective functions
    const types = [_]model.Type{t1, t2};
    for (types) |t, i| switch (t) {
      .structural => |struc|
        return try self.supWithStructure(struc, types[(i + 1) % 2]),
      else => {},
    };
    for (types) |t, i| switch (t) {
      .intrinsic => |intr|
        return try self.supWithIntrinsic(intr, types[(i + 1) % 2]),
      else => {},
    };
    const inst_types =
      [_]*model.Type.Instantiated{t1.instantiated, t2.instantiated};
    for (inst_types) |t| switch (t.data) {
      .record =>
        return self.calcIntersection(.{&[_]model.Type{t1}, &[_]model.Type{t2}}),
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
          .textual => |_|
            unreachable, // TODO: return sup of Identifier with text
          else => .{.intrinsic = .raw},
        };
      },
      else => {},
    };
    if (inst_types[0].data == .float and inst_types[1].data == .float)
      return if (@enumToInt(inst_types[0].data.float.precision) <
                 @enumToInt(inst_types[1].data.float.precision)) t2 else t1;
    if (inst_types[0].data == .textual and inst_types[1].data == .textual)
      unreachable; // TODO: form type that allows all characters accepted by any
                   // of the two types
    // at this point, we have two different instantiated types that are not
    // records, nor in any direct relationship with each other. therefore…
    return model.Type{.intrinsic = .raw};
  }

  /// input is to be a tuple of []model.Type.
  /// precondition is that each type in input is either a scalar or a record
  /// type.
  fn calcIntersection(self: *Self, input: anytype) !model.Type {
    var iter = TreeNode.Iter{.cur = &self.intersections, .lattice = self};
    var tcount = @as(usize, 0);
    var indexes: [input.len]usize = undefined;
    for (indexes) |*ptr| ptr.* = 0;
    const fields = std.meta.fields(@TypeOf(input));
    var scalar: ?model.Type = null;
    while (true) {
      var cur_type: ?model.Type = null;
      inline for (fields) |field, index| {
        const vals = @field(input, field.name);
        if (indexes[index] < vals.len) {
          const next_in_list = vals[indexes[index]];
          if (cur_type) |previous| {
            if (total_order_less(undefined, next_in_list, previous))
              cur_type = next_in_list;
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
    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.alloc.create(model.Type.Structural);
      new.* = .{
        .intersection = undefined
      };
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = scalar,
        .types = try self.alloc.alloc(model.Type, tcount),
      };
      var target_index = @as(usize, 0);
      for (indexes) |*ptr| ptr.* = 0;
      while (true) {
        var cur_type: ?model.Type = null;
        inline for (fields) |field, index| {
          const vals = @field(input, field.name);
          if (indexes[index] < vals.len) {
            const next_in_list = vals[indexes[index]];
            if (cur_type) |previous| {
              if (total_order_less(undefined, next_in_list, previous))
                cur_type = next_in_list;
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

  fn calcParagraphs(self: *Self, inner: []model.Type) !model.Type {
    std.sort.sort(model.Type, inner, {}, total_order_less);
    var iter = TreeNode.Iter{.cur = &self.paragraphs_types, .lattice = self};
    for (inner) |t| try iter.descend(t);
    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.alloc.create(model.Type.Structural);
      new.* = .{
        .paragraphs = .{
          .inner = inner,
          .auto = null,
        },
      };
      iter.cur.value = new;
      break :blk new;
    }};
  }

  fn supWithStructure(
      self: *Self, struc: *model.Type.Structural, other: model.Type)
      !model.Type {
    switch (other) {
      .intrinsic => |other_in| switch (other_in) {
        .every => return model.Type{.structural = struc},
        .void => return switch (struc.*) {
          .concat => model.Type{.structural = struc},
          else => (try self.optional(.{.structural = struc})) orelse
            model.Type{.intrinsic = .poison},
        },
        .space, .literal, .raw => {},
        else => return model.Type{.intrinsic = .poison},
      },
      // we're handling some special cases here, but most are handled by the
      // switch below.
      .structural => |other_struc| switch (struc.*) {
        .optional => |*op| switch (other_struc.*) {
          .optional => |*other_op| return
            (try self.optional(try self.sup(other_op.inner, op.inner))) orelse
              model.Type{.intrinsic = .poison},
          .concat => |*other_con| return
            (try self.concat(try self.sup(other_con.inner, op.inner))) orelse
              model.Type{.intrinsic = .poison},
          else => {},
        },
        .concat => |*other_con| switch (struc.*) {
          .optional => |*op| return
            (try self.concat(try self.sup(op.inner, other_con.inner))) orelse
              model.Type{.intrinsic = .poison},
          .concat => |*con| return
            (try self.concat(try self.sup(other_con.inner, con.inner))) orelse
              model.Type{.intrinsic = .poison},
          else => {},
        },
        .intersection => |*other_inter| switch (struc.*) {
          .intersection => |*inter| {
            const scalar_type = if (inter.scalar) |inter_scalar|
              if (other_inter.scalar) |other_scalar| try
                self.sup(inter_scalar, other_scalar)
              else inter_scalar
            else other_inter.scalar;

            return if (scalar_type) |st|
              self.calcIntersection(.{&[1]model.Type{st}, inter.types,
                other_inter.types})
            else self.calcIntersection(.{inter.types, other_inter.types});
          },
          else => {},
        },
        else => {},
      },
      .instantiated => {},
    }
    return switch (struc.*) {
      .optional => |*o|
        (try self.optional(try self.sup(o.inner, other))) orelse
          model.Type{.intrinsic = .poison},
      .concat => |*c|
        (try self.concat(try self.sup(c.inner, other))) orelse
          model.Type{.intrinsic = .poison},
      .paragraphs => {
        unreachable; // TODO
      },
      .list => |*l|
        (try self.list(try self.sup(l.inner, other))) orelse
          model.Type{.intrinsic = .poison},
      .map => {
        unreachable; // TODO
      },
      .callable => {
        unreachable; // TODO
      },
      .intersection => |*inter| blk: {
        if (other.isScalar()) {
          const scalar_type = if (inter.scalar) |inter_scalar|
            try self.sup(other, inter_scalar) else other;
          break :blk try self.calcIntersection(
            .{&[_]model.Type{scalar_type}, inter.types});
        } else switch (other) {
          .instantiated => |other_inst| if (other_inst.data == .record) {
            break :blk try if (inter.scalar) |inter_scalar|
              self.calcIntersection(
                .{&[_]model.Type{inter_scalar}, &[_]model.Type{other},
                inter.types})
            else self.calcIntersection(.{&[_]model.Type{other}, inter.types});
          },
          else => {},
        }
        break :blk model.Type{.intrinsic = .poison};
      }
    };
  }

  fn supWithIntrinsic(
      self: *Self, intr: @typeInfo(model.Type).Union.fields[0].field_type,
      other: model.Type) !model.Type {
    return switch(intr) {
      .void =>
        (try self.optional(other)) orelse model.Type{.intrinsic = .poison},
      .prototype, .schema, .extension, .ast_node => .{.intrinsic = .poison},
      .space, .literal, .raw => switch (other) {
        .intrinsic => |other_intr| switch (other_intr) {
          .every => model.Type{.intrinsic = intr},
          .void => (try self.optional(other)).?,
          .space, .literal, .raw =>
            model.Type{.intrinsic = @intToEnum(@TypeOf(intr),
              std.math.max(@enumToInt(intr), @enumToInt(other_intr)))},
          else => model.Type{.intrinsic = .poison},
        },
        .structural => unreachable, // case is handled in supWithStructural.
        .instantiated => model.Type{.intrinsic = .poison},
      },
      .every => other,
      else => .{.intrinsic = .poison},
    };
  }

  pub fn supAll(self: *Self, types: anytype) !model.Type {
    var res = model.Type{
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
  pub fn getBoolean(self: *Self) *const model.Type.Enum {
    return &self.boolean.data.tenum;
  }

  pub fn optional(self: *Self, t: model.Type) !?model.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension => return null,
        .every => return model.Type{.intrinsic = .void},
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
      res.value_ptr.* = try self.alloc.create(model.Type.Structural);
      res.value_ptr.*.* = .{
        .optional = .{
          .inner = t
        }
      };
    }
    return model.Type{.structural = res.value_ptr.*};
  }

  pub fn concat(self: *Self, t: model.Type)
      std.mem.Allocator.Error!?model.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension, .ast_node => return null,
        .space, .literal, .raw, .poison => return t,
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
      res.value_ptr.* = try self.alloc.create(model.Type.Structural);
      res.value_ptr.*.* = .{
        .concat = .{
          .inner = t
        }
      };
    }
    return model.Type{.structural = res.value_ptr.*};
  }

  pub fn list(self: *Self, t: model.Type) std.mem.Allocator.Error!?model.Type {
    switch (t) {
      .intrinsic => |i| switch (i) {
        .void, .prototype, .schema, .extension, .ast_node => return null,
        else => {},
      },
      else => {},
    }
    const res = try self.lists.getOrPut(self.alloc, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.alloc.create(model.Type.Structural);
      res.value_ptr.*.* = .{
        .list = .{
          .inner = t
        }
      };
    }
    return model.Type{.structural = res.value_ptr.*};
  }

  pub fn valueType(self: *Lattice, v: *model.Value) model.Type {
    return switch (v.data) {
      .text => |*txt| txt.t,
      .number => |*num| num.t.typedef(),
      .float => |*fl| fl.t.typedef(),
      .enumval => |*en| en.t.typedef(),
      .record => |*rec| rec.t.typedef(),
      .concat => |*con| con.t.typedef(),
      .list => |*list| list.t.typedef(),
      .map => |*map| map.t.typedef(),
      .typeval => |t| switch (t.t) {
        .intrinsic => |i| switch (i) {
          .location => self.type_constructors[0].callable.typedef(),
          .definition => self.type_constructors[1].callable.typedef(),
          else => model.Type{.intrinsic = .non_callable_type}, // TODO
        },
        .structural => model.Type{.intrinsic = .non_callable_type}, // TODO
        .instantiated => |inst| switch (inst.data) {
          .record => |rec| rec.callable.typedef(),
          else => model.Type{.intrinsic = .non_callable_type}, // TOYO
        },
      },
      .funcref => |*fr| switch (fr.func.data) {
        .ny_func => |*nf| nf.callable.typedef(),
        .ext_func => |*ef| ef.callable.typedef(),
        else => unreachable,
      },
      .location => .{.intrinsic = .location},
      .definition => .{.intrinsic = .definition},
      .ast => .{.intrinsic = .ast_node},
      .block_header => .{.intrinsic = .block_header},
      .void => .{.intrinsic = .void},
      .poison => .{.intrinsic = .poison},
    };
  }
};

/// searches direct scalar types as well as scalar types in concatenation,
/// optional and paragraphs types.
pub fn containedScalar(t: model.Type) ?model.Type {
  return switch (t) {
    .intrinsic => |intr| switch (intr) {
      .space, .literal, .raw => t,
      else => null,
    },
    .structural => |strct| switch (strct.*) {
      .optional => |*opt| containedScalar(opt.inner),
      .concat => |*con| containedScalar(con.inner),
      .paragraphs => |*para| blk: {
        for (para.inner) |inner_type| {
          // the first scalar type found will be the correct one due to the
          // semantics of paragraphs.
          if (containedScalar(inner_type)) |ret| break :blk ret;
        }
        break :blk null;
      },
      else => null,
    },
    .instantiated => |inst| switch (inst.data) {
      .textual, .numeric, .float, .tenum => t,
      else => null
    }
  };
}

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

  fn alloc(comptime e: SigBuilderEnv, ctx: anytype, comptime T: type,
           num: usize) ![]T {
    return switch (e) {
      .intrinsic => ctx.alloc(T, num),
      .userdef => ctx.source_content.allocator.alloc(T, num),
    };
  }

  fn errorMsg(comptime e: SigBuilderEnv, ctx: anytype,
              comptime error_name: []const u8, args: anytype) void {
    switch (e) {
      .intrinsic => unreachable,
      .userdef => @call(.{}, @field(ctx.eh, error_name), args),
    }
  }
};

pub fn SigBuilder(comptime kind: SigBuilderEnv) type {
  return struct {
    val: *model.Type.Signature,
    ctx: kind.contextType(),
    needs_different_repr: bool,
    next_param: u21,
    seen_error: bool,

    const Self = @This();

    /// if returns type is yet to be determined, give .{.intrinsic = .every}.
    /// the returns type is given early to know whether this is a keyword.
    pub fn init(context: kind.contextType(), num_params: usize,
                returns: model.Type) !Self {
      var ret = Self{
        .val = try kind.create(context, model.Type.Signature),
        .ctx = context,
        .needs_different_repr = false,
        .next_param = 0,
        .seen_error = false,
      };
      ret.val.* = .{
        .parameters =
          try kind.alloc(context, model.Type.Signature.Parameter, num_params),
        .primary = null,
        .varmap = null,
        .auto_swallow = null,
        .returns = returns,
        .repr = undefined
      };
      return ret;
    }

    pub fn push(self: *Self, loc: *model.Value.Location) !void {
      const param = &self.val.parameters[self.next_param];
      param.* = .{
        .pos = loc.value().origin,
        .name = loc.name,
        .ptype = loc.tloc,
        .capture = if (loc.varargs) |_| .varargs else if (loc.mutable) |_|
          @as(@TypeOf(param.capture), .mutable) else .default,
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
          kind.errorMsg(self.ctx, "DuplicateFlag",
            .{"primary", p, self.val.parameters[pindex].pos});
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
              std.mem.copy(u8, &buf, ":>");
              break :blk @as([]const u8, buf[0..2]);
            } else std.fmt.bufPrint(&buf, ":{}>", .{as.depth})
              catch unreachable;
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

      if (param.capture != .default or param.config != null or
          param.default != null)
        self.needs_different_repr = true;
      self.next_param += 1;
    }

    pub fn finish(self: *Self)
      if (kind == .intrinsic) *model.Type.Signature else ?*model.Type.Signature
    {
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

pub const ParagraphTypeBuilder = struct {
  pub const Result = struct {
    scalar_type_sup: model.Type,
    resulting_type: model.Type,
  };

  types: *Lattice,
  list: std.ArrayListUnmanaged(model.Type),
  cur_scalar: model.Type,
  non_voids: u21,

  pub fn init(types: *Lattice, force_paragraphs: bool) ParagraphTypeBuilder {
    return .{
      .types = types,
      .list = .{},
      .cur_scalar = .{.intrinsic = .every},
      .non_voids = if (force_paragraphs) 2 else 0,
    };
  }

  pub fn push(self: *ParagraphTypeBuilder, t: model.Type) !void {
    if (t.is(.void)) return;
    self.non_voids += 1;
    for (self.list.items) |existing|
      if (self.types.lesserEqual(t, existing)) return;
    if (containedScalar(t)) |scalar_type|
      self.cur_scalar = try self.types.sup(self.cur_scalar, scalar_type);
    try self.list.append(self.types.alloc, t);
  }

  pub fn finish(self: *ParagraphTypeBuilder) !Result {
    return switch (self.non_voids) {
      0 => Result{
        .scalar_type_sup = self.cur_scalar,
        .resulting_type = .{.intrinsic = .void},
      },
      1 => Result{
        .scalar_type_sup = self.cur_scalar,
        .resulting_type = self.list.items[0],
      },
      else => blk: {
        for (self.list.items) |*inner_type| {
          if (containedScalar(inner_type.*) != null)
            inner_type.* = try self.types.sup(self.cur_scalar, inner_type.*);
        }
        break :blk Result{
          .scalar_type_sup = self.cur_scalar,
          .resulting_type = try self.types.calcParagraphs(self.list.items),
        };
      },
    };
  }
};