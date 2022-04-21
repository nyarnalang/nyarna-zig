const std = @import("std");

const model       = @import("model.zig");
const nyarna      = @import("nyarna.zig");
const unicode     = @import("unicode.zig");

const builders = @import("types/builders.zig");
const funcs    = @import("types/funcs.zig");
const sigs     = @import("types/sigs.zig");

const stringOrder = @import("helpers.zig").stringOrder;
const totalOrderLess = @import("types/helpers.zig").totalOrderLess;
const recTotalOrderLess = @import("types/helpers.zig").recTotalOrderLess;

pub usingnamespace builders;
pub usingnamespace funcs;
pub usingnamespace sigs;

/// a type or prototype constructor.
pub const Constructor = struct {
  /// contains the signature of the constructor when called.
  /// has kind set to .@"type" if it's a type, .prototype if it's a prototype.
  /// initially null, will be set during loading of system.ny
  callable: ?*model.Type.Callable = null,
  /// index of the constructor's implementation. Initially undefined, will be
  /// set during loading of system.ny.
  impl_index: usize = undefined,
};

/// calculates what to do with inner types for various structural types.
const InnerIntend = enum {
  /// the given type is allowed as inner type
  allowed,
  /// trying to build the outer type will collapse into the given inner type
  collapse,
  /// type-specific exaltation must take place:
  ///  * when given an Optional type and the outer type is Concat, the outer
  ///    type must use the Optional's inner type.
  ///  * when given .every and the outer type is Optional, .void is the result.
  exalt,
  /// the given type is outright forbidden as inner type.
  forbidden,

  fn concat(t: model.Type) InnerIntend {
    return switch (t) {
      .structural => |s| switch (s.*) {
        .optional => InnerIntend.exalt,
        .concat   => InnerIntend.collapse,
        .sequence => InnerIntend.forbidden,
        else => InnerIntend.allowed,
      },
      .instantiated => |ins| switch (ins.data) {
        .textual, .space, .literal, .raw, .void, .poison =>
          InnerIntend.collapse,
        .record, .@"type", .location, .definition, .backend, .every =>
          InnerIntend.allowed,
        else => InnerIntend.forbidden,
      },
    };
  }

  fn optional(t: model.Type) InnerIntend {
    return switch (t) {
      .structural => |s| switch (s.*) {
        .optional, .concat, .sequence => InnerIntend.collapse,
        else => InnerIntend.allowed,
      },
      .instantiated => |inst| switch (inst.data) {
        .every => InnerIntend.exalt,
        .void => InnerIntend.collapse,
        .prototype, .schema, .extension => InnerIntend.forbidden,
        else => InnerIntend.allowed,
      },
    };
  }
};

const HalfOrder = enum {
  lt, eq, gt, dj, // less than, equal, greater than, disjoint

  fn push(self: *HalfOrder, value: std.math.Order) void {
    self.* = switch (value) {
      .lt => switch (self.*) {
        .lt, .eq => HalfOrder.lt,
        .gt, .dj => HalfOrder.dj,
      },
      .eq => return,
      .gt => switch (self.*) {
        .gt, .eq => HalfOrder.gt,
        .lt, .dj => HalfOrder.dj,
      },
    };
  }
};

/// This is Nyarna's type lattice. It calculates type intersections, checks type
/// compatibility, and owns all data of structural and unique types.
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
  /// This node is used to efficiently store and search for structural types
  /// that are instantiated with a list of types.
  /// see doc on the prefix_trees field.
  pub fn TreeNode(comptime Flag: type) type {
    return struct {
      key: model.Type = undefined,
      value: ?*model.Type.Structural = null,
      next: ?*TreeNode(Flag) = null,
      children: ?*TreeNode(Flag) = null,
      flag: Flag = undefined,

      /// This type is used to navigate the intersections field. Given a node,
      /// it will descend into its children and search the node matching the
      /// given type, or create and insert a node for it if none exists.
      pub const Iter = struct {
        cur: *TreeNode(Flag),
        lattice: *Lattice,

        pub fn descend(self: *Iter, t: model.Type, flag: Flag) !void {
          var next = &self.cur.children;
          // TODO: can be made faster with linear search but not sure whether that
          // is necessary.
          while (next.*) |next_node| : (next = &next_node.next) {
            if (next_node.flag == flag)
              if (!totalOrderLess(undefined, next_node.key, t)) break;
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

  const StructuralHashMap = std.HashMapUnmanaged(
    model.Type, *model.Type.Structural, model.Type.HashContext,
    std.hash_map.default_max_load_percentage);

  /// allocator used for data of structural types
  allocator: std.mem.Allocator,
  optionals: StructuralHashMap,
  concats  : StructuralHashMap,
  lists    : StructuralHashMap,
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
  /// For intersections and sequences, the prefixes are the list of contained
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
  /// iff the parameter is borrowed. On the return type, this flag is true iff
  /// the Callable is a type.
  ///
  /// For sequences, the first item is the direct type, or .every if they have
  /// no direct type. Sequences with auto types are not contained herein, they
  /// have a representant type that is used for type calculations.
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
    sequence    : TreeNode(void),
    callable    : TreeNode(bool),
  },
  /// Constructors for all unique types and prototypes that have constructors.
  /// These are to be queried via typeConstructor() and prototypeConstructor().
  ///
  /// constructors of non-unique types are stored in PrototypeFuncs.
  constructors: struct {
    raw       : Constructor = .{},
    location  : Constructor = .{},
    definition: Constructor = .{},

    /// Prototype implementations that generate types.
    prototypes: struct {
      concat      : Constructor = .{},
      @"enum"     : Constructor = .{},
      float       : Constructor = .{},
      intersection: Constructor = .{},
      list        : Constructor = .{},
      map         : Constructor = .{},
      numeric     : Constructor = .{},
      optional    : Constructor = .{},
      sequence    : Constructor = .{},
      record      : Constructor = .{},
      textual     : Constructor = .{},
    } = .{},
  },
  predefined: struct {
    ast         : model.Type.Instantiated,
    block_header: model.Type.Instantiated,
    definition  : model.Type.Instantiated,
    every       : model.Type.Instantiated,
    frame_root  : model.Type.Instantiated,
    literal     : model.Type.Instantiated,
    location    : model.Type.Instantiated,
    poison      : model.Type.Instantiated,
    prototype   : model.Type.Instantiated,
    raw         : model.Type.Instantiated,
    space       : model.Type.Instantiated,
    @"type"     : model.Type.Instantiated,
    void        : model.Type.Instantiated,
  },
  /// types defined in system.ny. these are available as soon as system.ny has
  /// been loaded and must not be accessed earlier.
  system: struct {
    boolean         : model.Type,
    identifier      : model.Type,
    integer         : model.Type,
    natural         : model.Type,
    unicode_category: model.Type,
  },
  /// prototype functions defined on every type of a prototype.
  prototype_funcs: struct {
    concat      : funcs.PrototypeFuncs = .{},
    @"enum"     : funcs.PrototypeFuncs = .{},
    float       : funcs.PrototypeFuncs = .{},
    intersection: funcs.PrototypeFuncs = .{},
    list        : funcs.PrototypeFuncs = .{},
    map         : funcs.PrototypeFuncs = .{},
    numeric     : funcs.PrototypeFuncs = .{},
    optional    : funcs.PrototypeFuncs = .{},
    sequence    : funcs.PrototypeFuncs = .{},
    record      : funcs.PrototypeFuncs = .{},
    textual     : funcs.PrototypeFuncs = .{},
  } = .{},
  /// holds instance functions for every non-unique type. These are instances
  /// of the functions that are defined on the prototype of the subject type.
  instance_funcs: std.HashMapUnmanaged(
    model.Type, funcs.InstanceFuncs, model.Type.HashContext,
    std.hash_map.default_max_load_percentage,
  ) = .{},
  /// set to true if we're currently instantiating instance funcs.
  /// while we're doing this, no other instance funcs will be instantiated.
  /// this leads to types with constructors having the .type type instead of the
  /// .callable type corresponding to their constructor.
  ///
  /// we do this to prevent self-referential logic during instantiation.
  instantiating_instance_funcs: bool = false,

  pub fn init(ctx: nyarna.Context) !Lattice {
    var ret = Lattice{
      .allocator = ctx.global(),
      .optionals = .{},
      .concats = .{},
      .lists = .{},
      .self_ref_list = try ctx.global().create(model.Type.Structural),
      .prefix_trees = .{
        .intersection = .{},
        .sequence     = .{},
        .callable     = .{},
      },
      .constructors = .{}, // set later by loading the intrinsic lib
      .predefined = undefined,
      .system = undefined,
    };
    inline for (@typeInfo(@TypeOf(ret.predefined)).Struct.fields) |field| {
      const val = &@field(ret.predefined, field.name);
      val.* = .{
        .at = model.Position.intrinsic(),
        .name = null,
        .data = @unionInit(@TypeOf(val.data), field.name, .{}),
      };
    }

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

  pub inline fn literal(self: *Self) model.Type {
    return self.predefined.literal.typedef();
  }

  pub inline fn raw(self: *Self) model.Type {
    return self.predefined.raw.typedef();
  }

  pub inline fn @"void"(self: *Self) model.Type {
    return self.predefined.void.typedef();
  }

  pub inline fn @"type"(self: *Self) model.Type {
    return self.predefined.@"type".typedef();
  }

  pub inline fn poison(self: *Self) model.Type {
    return self.predefined.poison.typedef();
  }

  pub inline fn location(self: *Self) model.Type {
    return self.predefined.location.typedef();
  }

  pub inline fn definition(self: *Self) model.Type {
    return self.predefined.definition.typedef();
  }

  pub inline fn every(self: *Self) model.Type {
    return self.predefined.every.typedef();
  }

  pub inline fn space(self: *Self) model.Type {
    return self.predefined.space.typedef();
  }

  pub inline fn prototype(self: *Self) model.Type {
    return self.predefined.prototype.typedef();
  }

  pub inline fn ast(self: *Self) model.Type {
    return self.predefined.ast.typedef();
  }

  pub inline fn frameRoot(self: *Self) model.Type {
    return self.predefined.frame_root.typedef();
  }

  pub inline fn blockHeader(self: *Self) model.Type {
    return self.predefined.block_header.typedef();
  }

  fn constructorOf(self: *Self, t: model.Type) !?*model.Type.Callable {
    const instance_funcs = (try self.instanceFuncsOf(t)) orelse return null;
    return instance_funcs.constructor;
  }

  /// may only be called on types that do have constructors
  pub fn typeConstructor(self: *Self, t: model.Type) !Constructor {
    return switch (t) {
      .instantiated => |inst| switch (inst.data) {
        .textual    => Constructor{
          .callable = (try self.constructorOf(t)).?,
          .impl_index = self.prototype_funcs.textual.constructor.?.impl_index,
        },
        .numeric    => Constructor{
          .callable = (try self.constructorOf(t)).?,
          .impl_index = self.prototype_funcs.numeric.constructor.?.impl_index,
        },
        .float      => Constructor{
          .callable = (try self.constructorOf(t)).?,
          .impl_index = self.prototype_funcs.float.constructor.?.impl_index,
        },
        .tenum      => Constructor{
          .callable = (try self.constructorOf(t)).?,
          .impl_index = self.prototype_funcs.@"enum".constructor.?.impl_index,
        },
        .location   => self.constructors.location,
        .definition => self.constructors.definition,
        .raw,       => self.constructors.raw,
        else => unreachable,
      },
      .structural => |strct| switch (strct.*) {
        .list => Constructor{
          .callable = (try self.constructorOf(t)).?,
          .impl_index = self.prototype_funcs.list.constructor.?.impl_index,
        },
        else => unreachable,
      },
    };
  }

  pub fn prototypeConstructor(
    self: *const Self,
    pt: model.Prototype,
  ) Constructor {
    return switch (pt) {
      .optional     => self.constructors.prototypes.optional,
      .concat       => self.constructors.prototypes.concat,
      .list         => self.constructors.prototypes.list,
      .sequence     => self.constructors.prototypes.sequence,
      .map          => self.constructors.prototypes.map,
      .record       => self.constructors.prototypes.record,
      .intersection => self.constructors.prototypes.intersection,
      .textual      => self.constructors.prototypes.textual,
      .numeric      => self.constructors.prototypes.numeric,
      .float        => self.constructors.prototypes.float,
      .@"enum"      => self.constructors.prototypes.@"enum",
    };
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

  pub fn sup(
    self: *Self,
    t1: model.Type,
    t2: model.Type,
  ) std.mem.Allocator.Error!model.Type {
    if (t1.eql(t2)) return t1;
    // defer structural and intrinsic cases to their respective functions
    const types = [_]model.Type{t1, t2};
    for (types) |t, i| switch (t) {
      .structural => |struc|
        return try self.supWithStructure(struc, types[(i + 1) % 2]),
      else => {},
    };
    for (types) |t, i| switch (t) {
      .instantiated => |inst| switch (inst.data) {
        .textual, .numeric, .float, .tenum, .record => {},
        else => return try self.supWithIntrinsic(inst, types[(i + 1) % 2]),
      },
      .structural => {},
    };
    const inst_types =
      [_]*model.Type.Instantiated{t1.instantiated, t2.instantiated};
    for (inst_types) |t| switch (t.data) {
      .record => return try
        builders.IntersectionBuilder.calcFrom(self, .{&t1, &t2}),
      else => {},
    };
    for (inst_types) |t, i| switch (t.data) {
      .numeric => |_| {
        const other = inst_types[(i + 1) % 2];
        return switch (other.data) {
          .float => if (i == 0) t2 else t1,
          .numeric => |_| unreachable, // TODO
          else => self.raw(),
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
          else => self.raw(),
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
    return self.raw();
  }

  pub fn registerSequence(
    self: *Self,
    direct: ?model.Type,
    inner: []*model.Type.Record,
    t: *model.Type.Sequence,
  ) !void {
    std.sort.sort(*model.Type.Record, inner, {}, recTotalOrderLess);
    var iter = TreeNode(void).Iter{
      .cur = &self.prefix_trees.sequence, .lattice = self,
    };
    try iter.descend(if (direct) |d| d else self.every(), {});
    for (inner) |it| try iter.descend(it.typedef(), {});
    std.debug.assert(iter.cur.value == null);
    iter.cur.value = t.typedef().structural;
    t.* = .{
      .direct = direct,
      .inner = inner,
      .auto = null,
    };
  }

  pub fn calcSequence(
    self: *Self,
    direct: ?model.Type,
    inner: []*model.Type.Record,
  ) !model.Type {
    std.sort.sort(*model.Type.Record, inner, {}, recTotalOrderLess);
    var iter = TreeNode(void).Iter{
      .cur = &self.prefix_trees.sequence, .lattice = self,
    };
    try iter.descend(if (direct) |d| d else self.every(), {});
    for (inner) |t| try iter.descend(t.typedef(), {});
    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try self.allocator.create(model.Type.Structural);
      new.* = .{
        .sequence = .{
          .direct = direct,
          .inner = inner,
          .auto = null,
        },
      };
      iter.cur.value = new;
      break :blk new;
    }};
  }

  fn concatFromParagraphs(
    self: *Self,
    p: *model.Type.Structural.Paragraphs,
  ) !model.Type {
    var res = self.space();
    for (p.inner) |t| res = try self.sup(res, t);
    return res;
  }

  fn supWithStructure(
    self: *Self,
    struc: *model.Type.Structural,
    other: model.Type,
  ) std.mem.Allocator.Error!model.Type {
    switch (other) {
      // we're handling some special cases here, but most are handled by the
      // switch below.
      .structural => |other_struc| switch (struc.*) {
        .concat => |*con| switch (other_struc.*) {
          .optional => |*op| return
            (try self.concat(try self.sup(op.inner, con.inner))) orelse
              self.poison(),
          .concat => |*other_con| return
            (try self.concat(try self.sup(other_con.inner, con.inner))) orelse
              self.poison(),
          else => {},
        },
        .intersection => |*inter| switch (other_struc.*) {
          .intersection => |*other_inter| {
            const scalar_type = if (inter.scalar) |inter_scalar|
              if (other_inter.scalar) |other_scalar| try
                self.sup(inter_scalar, other_scalar)
              else inter_scalar
            else other_inter.scalar;

            return if (scalar_type) |st| builders.IntersectionBuilder.calcFrom(
              self, .{&st, inter.types, other_inter.types})
            else builders.IntersectionBuilder.calcFrom(
              self, .{inter.types, other_inter.types});
          },
          else => {},
        },
        .list => |*lst| switch (other_struc.*) {
          .list => |*other_lst| return (
            try (self.list(try self.sup(lst.inner, other_lst.inner)))
          ) orelse self.poison(),
          else => {},
        },
        .optional => |*op| switch (other_struc.*) {
          .optional => |*other_op| return
            (try self.optional(try self.sup(other_op.inner, op.inner))) orelse
              self.poison(),
          .concat => |*other_con| return
            (try self.concat(try self.sup(other_con.inner, op.inner))) orelse
              self.poison(),
          else => {},
        },
        else => {},
      },
      .instantiated => |inst| switch (inst.data) {
        .every => return struc.typedef(),
        .void => return switch (struc.*) {
          .concat => model.Type{.structural = struc},
          else => (try self.optional(struc.typedef())) orelse self.poison(),
        },
        .space, .literal, .raw => {},
        .@"type" => return switch (struc.*) {
          .callable => |*clb|
            if (clb.kind == .@"type") other else self.poison(),
          else => self.poison(),
        },
        else => return self.poison(),
      },
    }
    return switch (struc.*) {
      .optional => |*o|
        (try self.optional(try self.sup(o.inner, other))) orelse self.poison(),
      .concat => |*c|
        (try self.concat(try self.sup(c.inner, other))) orelse self.poison(),
      .sequence => |*s| switch (other) {
        .structural => |other_struc| switch (other_struc.*) {
          .sequence => |*other_s| {
            var order = HalfOrder.eq;
            order.push(std.math.order(s.inner.len, other_s.inner.len));

            if (s.direct) |direct| {
              if (other_s.direct) |other_direct| {
                if (!direct.eql(other_direct)) {
                  if (self.lesser(direct, other_direct)) order.push(.lt)
                  else if (self.lesser(other_direct, direct)) order.push(.gt)
                  else order = .dj;
                }
              } else order.push(.gt);
            } else if (other_s.direct != null) order.push(.lt);
            switch (order) {
              .eq, .lt => for (s.inner) |inner| {
                var found = for (other_s.inner) |other_inner| {
                  if (inner == other_inner) break true;
                } else false;
                if (!found) {
                  // obvious for .lt. in case of .eq, we are sure that both
                  // sets have the same size. Therefore, if one record in
                  // p.inner doesn't have an equal in other_p.inner, there
                  // must be a record in other_p.inner that doesn't have an
                  // equal in p.inner. thus there is no relation between the
                  // sets.
                  order = .dj;
                  break;
                }
              },
              .gt => for (other_s.inner) |other_inner| {
                var found = for (s.inner) |inner| {
                  if (inner == other_inner) break true;
                } else false;
                if (!found) {
                  order = .dj;
                  break;
                }
              },
              .dj => {},
            }
            switch (order) {
              .eq, .lt => return other,
              .gt => return struc.typedef(),
              .dj => {
                var builder =
                  builders.SequenceBuilder.init(self, self.allocator, true);
                for ([_]?model.Type{s.direct, other_s.direct}) |item| {
                  if (item) |t| switch (try builder.push(t.predef(), true)) {
                    .success => {},
                    else => unreachable,
                  };
                }
                for ([_][]*model.Type.Record{s.inner, other_s.inner}) |l| {
                  for (l) |rec| {
                    switch (try builder.push(rec.typedef().predef(), false)) {
                      .success => {},
                      .not_disjoint => {
                        const res =
                          try builder.push(rec.typedef().predef(), true);
                        std.debug.assert(res == .success);
                      },
                      else => unreachable,
                    }
                  }
                }
                return (try builder.finish(null, null)).t;
              }
            }
          },
          .concat => {
            if (s.direct) |direct| {
              const res = try self.supWithStructure(other_struc, direct);
              if (res.eql(direct)) return struc.typedef();
              unreachable; // TODO
            } else unreachable; // TODO
          },
          else => self.poison(),
        },
        .instantiated => |inst| switch (inst.data) {
          .void => return struc.typedef(),
          .literal, .space, .raw, .numeric, .textual, .tenum, .float => {
            if (s.direct) |direct| {
              const res = try self.sup(other, direct);
              if (res.eql(direct)) return struc.typedef();
              return try self.calcSequence(res, s.inner);
            } else return try self.calcSequence(other, s.inner);
          },
          .record => |*rec| {
            if (s.direct) |direct| {
              if (self.lesserEqual(other, direct)) return struc.typedef();
              for (s.inner) |inner| {
                if (inner == rec) return struc.typedef();
              }
              unreachable; // TODO
            } else unreachable; // TODO
          },
          else => return self.poison(),
        }
      },
      .list => |*l|
        (try self.list(try self.sup(l.inner, other))) orelse self.poison(),
      .map => {
        unreachable; // TODO
      },
      .callable => |*c| {
        switch (other) {
          .structural => |os| switch (os.*) {
            .callable => |*oc| {
              if (oc == c) return c.typedef();
              if (oc.repr == c.repr) return c.repr.typedef();
            },
            else => {},
          },
          else => {},
        }
        return self.poison();
      },
      .intersection => |*inter| blk: {
        if (other.isScalar()) {
          const scalar_type = if (inter.scalar) |inter_scalar|
            try self.sup(other, inter_scalar) else other;
          break :blk try builders.IntersectionBuilder.calcFrom(
            self, .{&scalar_type, inter.types});
        } else switch (other) {
          .instantiated => |other_inst| if (other_inst.data == .record) {
            break :blk try if (inter.scalar) |inter_scalar|
              builders.IntersectionBuilder.calcFrom(
                self, .{&inter_scalar, &other, inter.types})
            else builders.IntersectionBuilder.calcFrom(
              self, .{&other, inter.types});
          },
          else => {},
        }
        break :blk self.poison();
      }
    };
  }

  fn supWithIntrinsic(
    self: *Self,
    intr: *model.Type.Instantiated,
    other: model.Type,
  ) !model.Type {
    return switch (intr.data) {
      .tenum, .float, .numeric, .record, .textual => unreachable,
      .void =>
        (try self.optional(other)) orelse self.poison(),
      .prototype, .schema, .extension, .ast, .frame_root => self.poison(),
      .space, .literal, .raw => switch (other) {
        .structural => unreachable, // case is handled in supWithStructural.
        .instantiated => |inst| switch (inst.data) {
          .textual, .numeric, .float, .tenum => self.raw(),
          .record => self.poison(),
          .every => intr.typedef(),
          .void => (try self.optional(intr.typedef())).?,
          .space => intr.typedef(),
          .literal => if (intr.data == .raw) intr.typedef() else other,
          .raw => other,
          else => self.poison(),
        },
      },
      .every => other,
      else => self.poison(),
    };
  }

  pub fn supAll(self: *Self, types: anytype) !model.Type {
    var res: model.Type = .every;
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

  pub fn optional(self: *Self, t: model.Type) !?model.Type {
    switch (InnerIntend.optional(t)) {
      .forbidden => return null,
      .exalt => return self.void(),
      .collapse => return t,
      .allowed => {},
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

  pub fn registerOptional(self: *Self, t: *model.Type.Optional) !bool {
    if (InnerIntend.optional(t.inner) != .allowed) return false;
    const res = try self.optionals.getOrPut(self.allocator, t.inner);
    std.debug.assert(!res.found_existing);
    res.value_ptr.* = t.typedef().structural;
    return true;
  }

  pub fn concat(
    self: *Self,
    t: model.Type,
  ) std.mem.Allocator.Error!?model.Type {
    switch (InnerIntend.concat(t)) {
      .forbidden => return null,
      .exalt => return try self.concat(t.structural.optional.inner),
      .collapse => return t,
      .allowed => {},
    }
    const res = try self.concats.getOrPut(self.allocator, t);
    if (!res.found_existing) {
      res.value_ptr.* = try self.allocator.create(model.Type.Structural);
      res.value_ptr.*.* = .{.concat = .{.inner = t}};
    }
    return model.Type{.structural = res.value_ptr.*};
  }

  pub fn registerConcat(self: *Self, t: *model.Type.Concat) !bool {
    if (InnerIntend.concat(t.inner) != .allowed) return false;
    const res = try self.concats.getOrPut(self.allocator, t.inner);
    std.debug.assert(!res.found_existing);
    res.value_ptr.* = t.typedef().structural;
    return true;
  }

  pub fn registerList(self: *Self, t: *model.Type.List) !bool {
    switch (t.inner) {
      .instantiated => |inst| switch (inst.data) {
        .void, .prototype, .schema, .extension => return false,
        else => {},
      },
      .structural => {},
    }
    const res = try self.lists.getOrPut(self.allocator, t.inner);
    std.debug.assert(!res.found_existing);
    res.value_ptr.* = t.typedef().structural;
    return true;
  }

  pub fn list(self: *Self, t: model.Type) std.mem.Allocator.Error!?model.Type {
    switch (t) {
      .instantiated => |inst| switch (inst.data) {
        .void, .schema, .extension => return null,
        else => {},
      },
      .structural => {},
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
    return res.value_ptr.*.typedef();
  }

  /// returns the type of the given type if it was a Value.
  pub fn typeType(self: *Lattice, t: model.Type) !model.Type {
    return switch (t) {
      .structural => |struc| switch (struc.*) {
        .list => blk: {
          const constructor = (
            try self.constructorOf(t)
          ) orelse break :blk self.@"type"(); // workaround for system.ny
          break :blk constructor.typedef();
        },
        else => self.@"type"(), // TODO
      },
      .instantiated => |inst| switch (inst.data) {
        .numeric, .tenum, .textual => {
          const constructor = (
            try self.constructorOf(t)
          ) orelse return self.@"type"();
          return constructor.typedef();
        },
        .record  => |*rec| rec.constructor.typedef(),
        .location, .definition, .literal, .space, .raw =>
          // callable may be null if currently processing system.ny. In that
          // case, the type is not callable.
          if ((try self.typeConstructor(t)).callable) |c| c.typedef()
          else self.@"type"(),
        else     => self.@"type"(), // TODO
      },
    };
  }

  pub fn valueType(self: *Lattice, v: *model.Value) !model.Type {
    return switch (v.data) {
      .text         => |*txt|  txt.t,
      .number       => |*num|  num.t.typedef(),
      .float        => |*fl|   fl.t.typedef(),
      .@"enum"      => |*en|   en.t.typedef(),
      .record       => |*rec|  rec.t.typedef(),
      .concat       => |*con|  con.t.typedef(),
      .seq          => |*seq|  seq.t.typedef(),
      .list         => |*list| list.t.typedef(),
      .map          => |*map|  map.t.typedef(),
      .@"type"      => |tv|    try self.typeType(tv.t),
      .prototype    => |pv|
        self.prototypeConstructor(pv.pt).callable.?.typedef(),
      .funcref      => |*fr| fr.func.callable.typedef(),
      .location     => self.location(),
      .definition   => self.definition(),
      .ast          => |ast| if (ast.container == null)
        self.ast() else self.frameRoot(),
      .block_header => self.blockHeader(),
      .void         => self.void(),
      .poison       => self.poison(),
    };
  }

  pub inline fn valueSpecType(self: *Lattice, v: *model.Value) !model.SpecType {
    return (try self.valueType(v)).at(v.origin);
  }

  fn valForType(self: Lattice, t: model.Type) !*model.Value.TypeVal {
    const ret = try self.allocator.create(model.Value);
    ret.* = .{
      .origin = model.Position.intrinsic(),
      .data = .{.@"type" = .{.t = t}},
    };
    return &ret.data.@"type";
  }

  fn typeArr(self: Lattice, types: []model.Type) ![]*model.Value.TypeVal {
    const ret = try self.allocator.alloc(*model.Value.TypeVal, types.len);
    for (types) |t, i| {
      ret[i] = try self.valForType(t);
    }
    return ret;
  }

  fn instanceArgs(self: Lattice, t: model.Type) ![]*model.Value.TypeVal {
    return try switch (t) {
      .structural => |struc| switch (struc.*) {
        .callable     => self.typeArr(&.{t}),
        .concat       => |*con| self.typeArr(&.{t, con.inner}),
        .intersection => self.typeArr(&.{t}),
        .list         => |*lst| self.typeArr(&.{t, lst.inner}),
        .map          => |*map| self.typeArr(&.{t, map.key, map.value}),
        .optional     => |*opt| self.typeArr(&.{t, opt.inner}),
        .sequence     => self.typeArr(&.{t}), // TODO
      },
      .instantiated => self.typeArr(&.{t}),
    };
  }

  pub fn instanceFuncsOf(self: *Lattice, t: model.Type) !?*funcs.InstanceFuncs {
    if (self.instantiating_instance_funcs) return null;
    const pt = switch (t) {
      .structural => |struc| switch (struc.*) {
        .callable => return null,
        .concat => &self.prototype_funcs.concat,
        .intersection => &self.prototype_funcs.intersection,
        .list => &self.prototype_funcs.list,
        .map => &self.prototype_funcs.map,
        .optional => &self.prototype_funcs.optional,
        .sequence => &self.prototype_funcs.sequence,
      },
      .instantiated => |inst| switch (inst.data) {
        .textual => &self.prototype_funcs.textual,
        .numeric => &self.prototype_funcs.numeric,
        .float => &self.prototype_funcs.float,
        .tenum => &self.prototype_funcs.@"enum",
        .record => &self.prototype_funcs.record,
        else => return null,
      },
    };
    const res = try self.instance_funcs.getOrPut(self.allocator, t);
    if (!res.found_existing) {
      self.instantiating_instance_funcs = true;
      defer self.instantiating_instance_funcs = false;
      res.value_ptr.* = try funcs.InstanceFuncs.init(
        pt, self.allocator, try self.instanceArgs(t));
    }
    return res.value_ptr;
  }

  /// given the actual type of a value and the target type of an expression,
  /// calculate the expected type in E_(target) to which the value is to be
  /// coerced [8.3].
  pub fn expectedType(
    self: *Lattice,
    actual: model.Type,
    target: model.Type,
  ) model.Type {
    if (actual.eql(target)) return target;
    return switch (target) {
      // no instantiated types are virtual.
      .instantiated => |inst| switch (inst.data) {
        // only subtypes are Callables with .kind == .@"type", and type checking
        // guarantees we get one of these.
        .@"type" => actual,
        // can never be used for a target type.
        .every => unreachable,
        // if a poison value is expected, it will never be used for anything,
        // and therefore we don't need to modify the value.
        .poison => actual,
        // all other instantiated types are non-virtual.
        else => target,
      },
      .structural => |strct| switch (strct.*) {
        .optional => |*opt|
          if (actual.isInst(.void) or actual.isInst(.every)) actual
          else self.expectedType(actual, opt.inner),
        .concat, .sequence, .list, .map => target,
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

  pub inline fn litType(self: *Lattice, lit: *model.Node.Literal) model.Type {
    return if (lit.kind == .text) self.literal() else self.space();
  }

  /// returns whether there exists a semantic conversion from `from` to `to`.
  pub fn convertible(self: *Lattice, from: model.Type, to: model.Type) bool {
    if (self.lesserEqual(from, to)) return true;
    const to_scalar = containedScalar(to);
    return switch (from) {
      .instantiated => |from_inst| switch (from_inst.data) {
        .void => if (to_scalar) |scalar| switch (scalar.instantiated.data) {
          .literal, .space, .raw, .textual => true,
          else => false,
        } else false,
        .space => to.isStruc(.concat) or to.isStruc(.sequence),
        .literal => to_scalar != null,
        else => false,
      },
      .structural => |from_struc| switch (from_struc.*) {
        .concat => |*con| switch (to) {
          .structural => |to_struc| switch (to_struc.*) {
            .concat   => |*to_con| self.convertible(con.inner, to_con.inner),
            .sequence => |*to_seq|
              if (to_seq.direct) |dir| self.convertible(from, dir) else false,
            else => false,
          },
          .instantiated => false,
        },
        .intersection => |*int|
          (if (int.scalar) |s| self.convertible(s, to) else true) and
          (for (int.types) |t| {
            if (!self.lesserEqual(t, to)) break false;
           } else true),
        .optional => |*opt|
          self.convertible(self.void(), to) and self.convertible(opt.inner, to),
        .sequence => |*seq| {
          switch (to) {
            .instantiated => |to_inst| switch (to_inst.data) {
              .space, .literal, .numeric, .textual, .tenum, .float, .raw => {},
              else => return false,
            },
            .structural => |to_struc| switch (to_struc.*) {
              .concat, .sequence => {},
              else => return false,
            }
          }
          if (seq.direct) |d| if (!self.convertible(d, to)) return false;
          for (seq.inner) |item| {
            if (!self.lesserEqual(item.typedef(), to)) return false;
          }
          return true;
        },
        else => false,
      },
    };
  }
};

/// searches direct scalar types as well as scalar types in concatenation,
/// optional and sequence types.
pub fn containedScalar(t: model.Type) ?model.Type {
  return switch (t) {
    .structural => |strct| switch (strct.*) {
      .optional => |*opt| containedScalar(opt.inner),
      .concat   => |*con| containedScalar(con.inner),
      .sequence => |*seq| blk: {
        if (seq.direct) |direct| {
          if (containedScalar(direct)) |ret| break :blk ret;
        }
        break :blk null;
      },
      .intersection => |*inter| inter.scalar,
      else => null,
    },
    .instantiated => |inst| switch (inst.data) {
      .textual, .numeric, .float, .tenum, .space, .literal, .raw => t,
      else => null
    },
  };
}

pub inline fn allowedAsConcatInner(t: model.Type) bool {
  return InnerIntend.concat(t) == .allowed;
}

pub inline fn allowedAsOptionalInner(t: model.Type) bool {
  return InnerIntend.optional(t) == .allowed;
}

pub fn descend(t: model.Type, index: usize) model.Type {
  // update this if we ever allow descending into other types.
  return t.instantiated.data.record.constructor.sig.parameters[index].spec.t;
}