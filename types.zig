const std = @import("std");
const model = @import("model.zig");
const nyarna = @import("nyarna.zig");
const unicode = @import("load/unicode.zig");

/// a type or prototype constructor.
pub const Constructor = struct {
  /// contains the signature of the constructor when called.
  /// has kind set to .@"type" if it's a type, .prototype if it's a prototype.
  callable: *model.Type.Callable,
  /// index of the constructor's implementation.
  impl_index: usize,
};

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
  fn TreeNode(comptime Flag: type) type {
    return struct {
      key: model.Type = undefined,
      value: ?*model.Type.Structural = null,
      next: ?*TreeNode(Flag) = null,
      children: ?*TreeNode(Flag) = null,
      flag: Flag = undefined,

      /// This type is used to navigate the intersections field. Given a node,
      /// it will descend into its children and search the node matching the
      /// given type, or create and insert a node for it if none exists.
      const Iter = struct {
        cur: *TreeNode(Flag),
        lattice: *Lattice,

        fn descend(self: *Iter, t: model.Type, flag: Flag) !void {
          var next = &self.cur.children;
          // TODO: can be made faster with linear search but not sure whether that
          // is necessary.
          while (next.*) |next_node| : (next = &next_node.next) {
            if (next_node.flag == flag)
              if (!total_order_less(undefined, next_node.key, t)) break;
          }
          // inlining this causes a compiler bug :)
          const hit =
            if (next.*) |succ| if (t.eql(succ.key)) succ else null else null;
          self.cur = hit orelse blk: {
            var new = try self.lattice.allocator.create(TreeNode(Flag));
            new.* = .{
              .key = t,
              .value = null,
              .next = next.*,
              .children = null,
              .flag = flag,
            };
            next.* = new;
            break :blk new;
          };
        }
      };
    };
  }

  /// allocator used for data of structural types
  allocator: std.mem.Allocator,
  optionals: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  concats: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  lists: std.HashMapUnmanaged(model.Type, *model.Type.Structural,
      model.Type.HashContext, std.hash_map.default_max_load_percentage),
  /// this is the list type that contains itself. This is a special case and the
  /// only pure structural self-referential type structure (i.e. the only
  /// recursive type that is composed of nothing but structural types).
  /// other structurally equivalent types (concat, paragraphs, intersection,
  /// optional) are always flat in respect to their prototypes (concats cannot
  /// contain other concats etc) and can never contain lists, so there are no
  /// other such types.
  ///
  /// given two types A = List(B) and B = List(A), both would be structural
  /// equivalent to C = List(C) since every possible value of type A or B would
  /// have a structure allowed by type C. therefore, any List types that are
  /// transitively referring to themselves without other prototype kinds in
  /// between are equivalent to the type defined in this variable.
  self_ref_list: *model.Type.Structural,

  /// These are prefix trees that hold all known types of a specific prototype.
  /// Prefixes are lists of types.
  ///
  /// Each TreeNode holds the successors for a prefix continuation in `children`
  /// and the value of that prefix continuation, if any, in `value`.
  ///
  /// For intersections and paragraphs, the prefixes are the list of contained
  /// types, ordered by the artifical total type order. For callable types, the
  /// prefixes are the list of parameter types in parameter order, succeeded by
  /// the return type.
  ///
  /// At each level of the search tree, the singly-linked list of TreeNode
  /// values and their `next` pointers represent known continuations, and hold
  /// the value of that continuation, if any. The next level is given by the
  /// `children` pointer.
  ///
  /// TreeNodes for Callable types have an additional boolean flag which is true
  /// iff the parameter is mutable. On the return type, this flag is true iff
  /// the Callable is a type.
  ///
  /// The worst-case time of discovering an intersection or paragraphs type for
  /// a given list of n types is expected to be O(n log(m)) where m is the
  /// number of existing types allowed in an intersection, since the possible
  /// length of the children list shortens with each descend due to the total
  /// order of types, and it shortens more the longer you advanced in the
  /// previous list.
  ///
  /// For Callable types, the order of types is significant and types can occur
  /// multiple times, therefore the worst-case discovery time is O(nm). It is
  /// assumed that this is fine.
  prefix_trees: struct {
    intersection: TreeNode(void),
    paragraphs: TreeNode(void),
    callable: TreeNode(bool),
  },
  /// Constructors for all types that have constructors.
  /// These are to be queried via typeConstructor() and prototypeConstructor().
  constructors: struct {
    raw: Constructor,
    location: Constructor,
    definition: Constructor,

    // the signature of instantiated types' constructors differ per type.
    // they use the same implementation though. Those implementations' indexes
    // are given here.
    generic: struct {
      textual: usize,
      numeric: usize,
      float: usize,
      @"enum": usize,
    },

    /// Prototype implementations that generate types.
    prototypes: struct {
      optional: Constructor,
      concat: Constructor,
      list: Constructor,
      paragraphs: Constructor,
      map: Constructor,
      record: Constructor,
      intersection: Constructor,
      textual: Constructor,
      numeric: Constructor,
      float: Constructor,
      @"enum": Constructor,
    },
  },
  /// predefined types. TODO: move these to system.ny
  boolean: *model.Type.Instantiated,
  unicode_category: *model.Type.Instantiated,

  pub fn init(ctx: nyarna.Context) !Lattice {
    var ret = Lattice{
      .allocator = ctx.global(),
      .optionals = .{},
      .concats = .{},
      .lists = .{},
      .self_ref_list = try ctx.global().create(model.Type.Structural),
      .prefix_trees = .{
        .intersection = .{},
        .paragraphs = .{},
        .callable = .{},
      },
      .constructors = undefined, // set later by loading the intrinsic lib
      .boolean = undefined,
      .unicode_category = undefined,
    };

    var builder = try EnumTypeBuilder.init(ctx, model.Position.intrinsic());
    ret.boolean = blk: {
      try builder.add("false");
      try builder.add("true");
      const e = try builder.finish();
      const boolsym = try ret.allocator.create(model.Symbol);
      boolsym.defined_at = model.Position.intrinsic();
      boolsym.name = "Boolean";
      boolsym.data = .{.@"type" = .{.instantiated = e.instantiated()}};
      e.instantiated().name = boolsym;
      break :blk e.instantiated();
    };

    builder = try EnumTypeBuilder.init(ctx, model.Position.intrinsic());
    ret.unicode_category = blk: {
      inline for (@typeInfo(unicode.Category).Enum.fields) |f| {
        try builder.add(f.name);
      }
      try builder.add("Lut");
      try builder.add("LC");
      try builder.add("L");
      try builder.add("M");
      try builder.add("P");
      try builder.add("S");
      try builder.add("MPS");
      const e = try builder.finish();
      const unisym = try ret.allocator.create(model.Symbol);
      unisym.defined_at = model.Position.intrinsic();
      unisym.name = "UnicodeCategory";
      unisym.data = .{.@"type" = .{.instantiated = e.instantiated()}};
      e.instantiated().name = unisym;
      break :blk e.instantiated();
    };

    ret.self_ref_list.* = .{
      .list = .{
        .inner = .{
          .structural = ret.self_ref_list,
        },
      },
    };

    return ret;
  }

  pub fn deinit(_: *Self) void {
    // nothing to do – the supplied ArenaAllocator will take care of freeing
    // the instantiated types.
  }

  /// may only be called on types that do have constructors
  pub fn typeConstructor(self: *const Self, t: model.Type) Constructor {
    return switch (t) {
      .intrinsic => |it| switch (it) {
        .location   => self.constructors.location,
        .definition => self.constructors.definition,
        .raw,       => self.constructors.raw,
        else        => unreachable,
      },
      .instantiated => |inst| switch (inst.data) {
        .textual    => |*text| Constructor{
          .callable   = text.constructor,
          .impl_index = self.constructors.generic.textual,
        },
        .numeric    => |*numeric| Constructor{
          .callable   = numeric.constructor,
          .impl_index = self.constructors.generic.numeric,
        },
        .float      => |*float| Constructor{
          .callable   = float.constructor,
          .impl_index = self.constructors.generic.float,
        },
        .tenum      => |*tenum| Constructor{
          .callable   = tenum.constructor,
          .impl_index = self.constructors.generic.@"enum",
        },
        else => unreachable,
      },
      else => unreachable,
    };
  }

  pub fn prototypeConstructor(self: *const Self, pt: model.Prototype)
      Constructor {
    return switch (pt) {
      .optional     => self.constructors.prototypes.optional,
      .concat       => self.constructors.prototypes.concat,
      .list         => self.constructors.prototypes.list,
      .paragraphs   => self.constructors.prototypes.paragraphs,
      .map          => self.constructors.prototypes.map,
      .record       => self.constructors.prototypes.record,
      .intersection => self.constructors.prototypes.intersection,
      .textual      => self.constructors.prototypes.textual,
      .numeric      => self.constructors.prototypes.numeric,
      .float        => self.constructors.prototypes.float,
      .@"enum"      => self.constructors.prototypes.@"enum",
    };
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
    var iter = TreeNode(void).Iter{
      .cur = &self.prefix_trees.intersection, .lattice = self,
    };
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
        try iter.descend(next_type, {});
        if (next_type.isScalar()) {
          std.debug.assert(scalar == null);
          scalar = next_type;
        } else tcount += 1;
      } else break;
    }
    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.allocator.create(model.Type.Structural);
      new.* = .{
        .intersection = undefined
      };
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = scalar,
        .types = try self.allocator.alloc(model.Type, tcount),
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
    var iter = TreeNode(void).Iter{
      .cur = &self.prefix_trees.paragraphs, .lattice = self,
    };
    for (inner) |t| try iter.descend(t, {});
    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.allocator.create(model.Type.Structural);
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
        .@"type" => return switch (struc.*) {
          .callable => |*clb| if (clb.kind == .@"type") other
                              else model.Type{.intrinsic = .poison},
          else => model.Type{.intrinsic = .poison},
        },
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
        .void, .every => return model.Type{.intrinsic = .void},
        .prototype, .schema, .extension => return null,
        else => {},
      },
      .structural => |s| switch (s.*) {
        .optional, .concat => return t,
        .paragraphs => return null, // TODO
        else => {},
      },
      .instantiated => {},
    }
    const res = try self.optionals.getOrPut(self.allocator, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.allocator.create(model.Type.Structural);
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
    const res = try self.concats.getOrPut(self.allocator, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.allocator.create(model.Type.Structural);
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
        .void, .prototype, .schema, .extension => return null,
        else => {},
      },
      else => {},
    }
    const res = try self.lists.getOrPut(self.allocator, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.allocator.create(model.Type.Structural);
      res.value_ptr.*.* = .{
        .list = .{
          .inner = t
        }
      };
    }
    return model.Type{.structural = res.value_ptr.*};
  }

  pub fn valueType(self: *const Lattice, v: *model.Value) model.Type {
    return switch (v.data) {
      .text => |*txt| txt.t,
      .number => |*num| num.t.typedef(),
      .float => |*fl| fl.t.typedef(),
      .@"enum" => |*en| en.t.typedef(),
      .record => |*rec| rec.t.typedef(),
      .concat => |*con| con.t.typedef(),
      .para => |*para| para.t.typedef(),
      .list => |*list| list.t.typedef(),
      .map => |*map| map.t.typedef(),
      .@"type" => |tv| switch (tv.t) {
        .intrinsic => |i| switch (i) {
          .location, .definition, .literal, .space, .raw =>
            self.typeConstructor(tv.t).callable.typedef(),
          else => model.Type{.intrinsic = .@"type"},
        },
        .structural => model.Type{.intrinsic = .@"type"}, // TODO
        .instantiated => |inst| switch (inst.data) {
          .record => |rec| rec.constructor.typedef(),
          else => model.Type{.intrinsic = .@"type"}, // TODO
        },
      },
      .prototype => |pv| self.prototypeConstructor(pv.pt).callable.typedef(),
      .funcref => |*fr| fr.func.callable.typedef(),
      .location => .{.intrinsic = .location},
      .definition => .{.intrinsic = .definition},
      .ast => .{.intrinsic = .ast_node},
      .block_header => .{.intrinsic = .block_header},
      .void => .{.intrinsic = .void},
      .poison => .{.intrinsic = .poison},
    };
  }

  /// given the actual type of a value and the target type of an expression,
  /// calculate the expected type in E_(target) to which the value is to be
  /// coerced [8.3].
  pub fn expectedType(self: *Lattice, actual: model.Type, target: model.Type)
      model.Type {
    if (actual.eql(target)) return target;
    return switch (target) {
      .intrinsic => |intr| switch (intr) {
        // only subtypes are Callables with .kind == .@"type", and type checking
        // guarantees we get one of these.
        .@"type" => actual,
        // can never be used for a target type.
        .every => unreachable,
        // if a poison value is expected, it will never be used for anything,
        // and therefore we don't need to modify the value.
        .poison => actual,
        // all other types are non-virtual.
        else => target,
      },
      // no instantiated types are virtual.
      .instantiated => target,
      .structural => |strct| switch (strct.*) {
        .optional => |*opt| if (actual.is(.void) or actual.is(.every)) actual
                            else self.expectedType(actual, opt.inner),
        .concat, .paragraphs, .list, .map => target,
        .callable => unreachable, // TODO
        .intersection => |*inter| blk: {
          if (inter.scalar) |scalar_type|
            if (self.lesserEqual(actual, scalar_type)) break :blk scalar_type;
          for (inter.types) |cur|
            if (self.lesserEqual(actual, cur)) break :blk cur;
          // type checking ensures we'll never end up here.
          unreachable;
        },
      },
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

pub const SigBuilderResult = struct {
  /// the built signature
  sig: *model.Type.Signature,
  /// if build_repr has been set in init(), the representative signature
  /// for the type lattice. else null.
  repr: ?*model.Type.Signature,

  pub fn createCallable(
      self: *const @This(), allocator: std.mem.Allocator,
      kind: model.Type.Callable.Kind) !*model.Type.Callable {
    const strct = try allocator.create(model.Type.Structural);
    errdefer allocator.destroy(strct);
    strct.* = .{
      .callable = .{
        .sig = self.sig,
        .kind = kind,
        .repr = undefined,
      },
    };
    strct.callable.repr = if (self.repr) |repr_sig| blk: {
      const repr = try allocator.create(model.Type.Structural);
      errdefer allocator.destroy(repr);
      repr.* = .{
        .callable = .{
          .sig = repr_sig,
          .kind = kind,
          .repr = undefined,
        },
      };
      repr.callable.repr = &repr.callable;
      break :blk &repr.callable;
    } else &strct.callable;
    return &strct.callable;
  }
};

pub const SigBuilder = struct {
  const Result = SigBuilderResult;

  val: *model.Type.Signature,
  repr: ?*model.Type.Signature,
  ctx: nyarna.Context,
  next_param: u21,

  const Self = @This();

  /// if returns type is yet to be determined, give .{.intrinsic = .every}.
  /// the returns type is given early to know whether this is a keyword.
  ///
  /// if build_repr is true, a second signature will be built to be the
  /// signature of the repr Callable in the type lattice.
  pub fn init(ctx: nyarna.Context, num_params: usize,
              returns: model.Type, build_repr: bool) !Self {
    var ret = Self{
      .val = try ctx.global().create(model.Type.Signature),
      .repr = if (build_repr)
          try ctx.global().create(model.Type.Signature)
        else null,
      .ctx = ctx,
      .next_param = 0,
    };
    ret.val.* = .{
      .parameters = try ctx.global().alloc(
        model.Type.Signature.Parameter, num_params),
      .primary = null,
      .varmap = null,
      .auto_swallow = null,
      .returns = returns,
    };
    if (ret.repr) |sig| {
      sig.* = .{
        .parameters = try ctx.global().alloc(
          model.Type.Signature.Parameter, num_params),
        .primary = null,
        .varmap = null,
        .auto_swallow = null,
        .returns = returns,
      };
    }
    return ret;
  }

  pub fn push(self: *Self, loc: *model.Value.Location) !void {
    const param = &self.val.parameters[self.next_param];
    param.* = .{
      .pos = loc.value().origin,
      .name = loc.name.content,
      .ptype = loc.tloc,
      .capture = if (loc.varargs) |_| .varargs else if (loc.mutable) |_|
        @as(@TypeOf(param.capture), .mutable) else .default,
      .default = loc.default,
      .config = if (loc.header) |bh| bh.config else null,
    };
    // TODO: use contains(.ast_node) instead (?)
    const t = if (!self.val.isKeyword() and loc.tloc.is(.ast_node)) blk: {
      self.ctx.logger.AstNodeInNonKeyword(loc.value().origin);
      break :blk model.Type{.intrinsic = .poison};
    } else loc.tloc;
    if (loc.primary) |p| {
      if (self.val.primary) |pindex| {
        self.ctx.logger.DuplicateFlag(
          "primary", p, self.val.parameters[pindex].pos);
      } else {
        self.val.primary = self.next_param;
      }
    }
    if (loc.header) |bh| {
      if (bh.swallow_depth) |depth| {
        if (self.val.auto_swallow) |as| {
          var buf: [4]u8 = undefined;
          // inlining this into the errorMsg call leads to a compiler bug :)
          const repr = if (as.depth == 0) blk: {
            std.mem.copy(u8, &buf, ":>");
            break :blk @as([]const u8, buf[0..2]);
          } else std.fmt.bufPrint(&buf, ":{}>", .{as.depth})
            catch unreachable;
          self.ctx.logger.DuplicateAutoSwallow(
            repr, bh.value().origin, self.val.parameters[as.param_index].pos);
        } else {
          self.val.auto_swallow = .{
            .depth = depth,
            .param_index = self.next_param
          };
        }
      }
    }
    if (self.repr) |sig| {
      sig.parameters[self.next_param] = .{
        .pos = loc.value().origin,
        .name = loc.name.content,
        .ptype = t,
        .capture = .default,
        .default = null,
        .config = null,
      };
    }
    self.next_param += 1;
  }

  pub fn finish(self: *Self) Result {
    std.debug.assert(self.next_param == self.val.parameters.len);
    return Result{
      .sig = self.val,
      .repr = self.repr,
    };
  }
};

pub const CallableReprFinder = struct {
  pub const Result = struct {
    found: *?*model.Type.Structural,
    needs_different_repr: bool,
  };
  const Self = @This();

  iter: Lattice.TreeNode(bool).Iter,
  needs_different_repr: bool,

  pub fn init(lattice: *Lattice) CallableReprFinder {
    return .{
      .iter = .{
        .cur = &lattice.prefix_trees.callable,
        .lattice = lattice,
      },
      .needs_different_repr = false,
    };
  }

  pub fn push(self: *Self, loc: *model.Value.Location) !void {
    try self.iter.descend(loc.tloc, loc.mutable != null);
    if (loc.default != null or loc.primary != null or loc.varargs != null or
        loc.varmap != null or loc.header != null)
      self.needs_different_repr = true;
  }

  pub fn finish (self: *Self, returns: model.Type, is_type: bool) !Result {
    try self.iter.descend(returns, is_type);
    return Result{
      .found = &self.iter.cur.value,
      .needs_different_repr = self.needs_different_repr,
    };
  }
};

pub const ParagraphTypeBuilder = struct {
  pub const Result = struct {
    scalar_type_sup: model.Type,
    resulting_type: model.Type,
  };

  types: *Lattice,
  list: std.ArrayListUnmanaged(model.Type),
  cur_scalar: model.Type,
  non_voids: u21,
  poison: bool,

  pub fn init(types: *Lattice, force_paragraphs: bool) ParagraphTypeBuilder {
    return .{
      .types = types,
      .list = .{},
      .cur_scalar = .{.intrinsic = .every},
      .non_voids = if (force_paragraphs) 2 else 0,
      .poison = false,
    };
  }

  pub fn push(self: *ParagraphTypeBuilder, t: model.Type) !void {
    if (t.is(.void)) return;
    if (t.is(.poison)) {
      self.poison = true;
      return;
    }
    self.non_voids += 1;
    for (self.list.items) |existing|
      if (self.types.lesserEqual(t, existing)) return;
    if (containedScalar(t)) |scalar_type|
      self.cur_scalar = try self.types.sup(self.cur_scalar, scalar_type);
    try self.list.append(self.types.allocator, t);
  }

  pub fn finish(self: *ParagraphTypeBuilder) !Result {
    return if (self.poison) Result{
      .scalar_type_sup = self.cur_scalar,
      .resulting_type = .{.intrinsic = .poison},
    } else switch (self.non_voids) {
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

pub const EnumTypeBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.Enum,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const inst = try ctx.global().create(model.Type.Instantiated);
    inst.* = .{
      .at = pos,
      .name = null,
      .data = .{.tenum = .{.constructor = undefined, .values = .{}}},
    };
    return Self{.ctx = ctx, .ret = &inst.data.tenum};
  }

  pub inline fn add(self: *Self, value: []const u8) !void {
    try self.ret.values.put(self.ctx.global(), value, 0);
  }

  pub fn finish(self: *Self) !*model.Type.Enum {
    var sb = try SigBuilder.init(
      self.ctx, 1, self.ret.typedef(), true);
    try sb.push((try self.ctx.values.location(
      self.ret.instantiated().at, try self.ctx.values.textScalar(
        model.Position.intrinsic(), .{.intrinsic = .raw}, "input"
      ), self.ret.typedef())).withPrimary(model.Position.intrinsic()));
    self.ret.constructor =
      try sb.finish().createCallable(self.ctx.global(), .type);
    return self.ret;
  }
};