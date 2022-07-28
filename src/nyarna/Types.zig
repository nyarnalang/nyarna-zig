//! This is Nyarna's type lattice. It calculates type intersections, checks type
//! compatibility, and owns all data of structural and unique types.
//!
//! As it is defined, the type lattice defines only a partial order on types.
//! To simplify processing, the Lattice additionally defines an internal,
//! artificial total order on types. This total order has the single constraint
//! of being stable: Adding new types must not change the relation between
//! existing types. No information about the relation between types as per
//! language specification can thus be extracted from the total order.
//!
//! The total order is used for keeping type lists sorted. By having sorted type
//! lists, operations like calculating the supremum of two intersections will
//! be faster because they will be a single O(n) merge operation. This is also
//! less complex to implement.
//!
//! The lattice owns all allocated type information. Allocated type information
//! exists for structural and named types. The lattice ensures that for
//! every distinct type, only a single data object exists. This makes type
//! calculations fast, as the identity can be calculated as pointer equality.
//!
//! To facilitate type uniqueness, the Lattice provides idempotent functions for
//! obtaining structural types: optional(self, t) for example will, when called
//! on some distinct t for the first time, allocate that type and return it, and
//! any subsequent call with the same t will return that allocated type.

const std = @import("std");

const nyarna  = @import("../nyarna.zig");
const unicode = @import("unicode.zig");

const model   = nyarna.model;

const builders = @import("Types/builders.zig");
const funcs    = @import("Types/funcs.zig");
const sigs     = @import("Types/sigs.zig");

const stringOrder       = @import("helpers.zig").stringOrder;
const totalOrderLess    = @import("Types/helpers.zig").totalOrderLess;
const recTotalOrderLess = @import("Types/helpers.zig").recTotalOrderLess;

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
      .named => |ins| switch (ins.data) {
        .textual, .space, .literal, .void, .poison =>
          InnerIntend.collapse,
        .record, .@"type", .location, .definition, .every, .output =>
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
      .named => |named| switch (named.data) {
        .every => InnerIntend.exalt,
        .void  => InnerIntend.collapse,
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

const Self = @This();

/// This node is used to efficiently store and search for structural types
/// that are named with a list of types.
/// see doc on the prefix_trees field.
pub fn TreeNode(comptime Flag: type) type {
  return struct {
    key     : model.Type = undefined,
    value   : ?*model.Type.Structural = null,
    next    : ?*TreeNode(Flag) = null,
    children: ?*TreeNode(Flag) = null,
    flag    : Flag = undefined,

    /// This type is used to navigate the intersections field. Given a node,
    /// it will descend into its children and search the node matching the
    /// given type, or create and insert a node for it if none exists.
    pub const Iter = struct {
      cur  : *TreeNode(Flag),
      types: *Self,

      pub fn descend(self: *Iter, t: model.Type, flag: Flag) !void {
        var next = &self.cur.children;
        // OPPORTUNITY: can be made faster with linear search but not sure
        // whether that is necessary.
        while (next.*) |next_node| : (next = &next_node.next) {
          if (next_node.flag == flag)
            if (!totalOrderLess(undefined, next_node.key, t)) break;
        }
        // inlining this causes a compiler bug :)
        const hit =
          if (next.*) |succ| if (t.eql(succ.key)) succ else null else null;
        self.cur = hit orelse blk: {
          var new = try self.types.allocator.create(TreeNode(Flag));
          new.* = .{
            .key      = t,
            .value    = null,
            .next     = next.*,
            .children = null,
            .flag     = flag,
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
  std.hash_map.default_max_load_percentage,
);
const Entry = struct {
  key  : model.Type,
  value: model.Type,
};
const EntryHashContext = struct {
  pub fn hash(_: EntryHashContext, e: Entry) u64 {
    return model.Type.HashContext.hash(undefined, e.key) +%
      model.Type.HashContext.hash(undefined, e.value);
  }

  pub fn eql(_: EntryHashContext, a: Entry, b: Entry) bool {
    return a.key.eql(b.key) and a.value.eql(b.value);
  }
};
const EntryHashMap = std.HashMapUnmanaged(
  Entry, *model.Type.Structural, EntryHashContext,
  std.hash_map.default_max_load_percentage);

/// allocator used for data of structural types
allocator: std.mem.Allocator,
optionals: StructuralHashMap = .{},
concats  : StructuralHashMap = .{},
lists    : StructuralHashMap = .{},
hashmaps : EntryHashMap      = .{},
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
  intersection: TreeNode(void) = .{},
  sequence    : TreeNode(void) = .{},
  callable    : TreeNode(bool) = .{},
} = .{},
/// Constructors for all unique types and prototypes that have constructors.
/// These are to be queried via typeConstructor() and prototypeConstructor().
///
/// constructors of non-unique types are stored in PrototypeFuncs.
constructors: struct {
  location  : Constructor = .{},
  definition: Constructor = .{},
  output    : Constructor = .{},
  schema_def: Constructor = .{},
  void      : Constructor = .{},

  /// Prototype implementations that generate types.
  prototypes: struct {
    concat      : Constructor = .{},
    @"enum"     : Constructor = .{},
    intersection: Constructor = .{},
    list        : Constructor = .{},
    hashmap     : Constructor = .{},
    numeric     : Constructor = .{},
    optional    : Constructor = .{},
    sequence    : Constructor = .{},
    record      : Constructor = .{},
    textual     : Constructor = .{},
  } = .{},
},
predefined: struct {
  ast         : model.Type.Named,
  block_header: model.Type.Named,
  definition  : model.Type.Named,
  every       : model.Type.Named,
  frame_root  : model.Type.Named,
  literal     : model.Type.Named,
  location    : model.Type.Named,
  output      : model.Type.Named,
  poison      : model.Type.Named,
  prototype   : model.Type.Named,
  schema      : model.Type.Named,
  schema_def  : model.Type.Named,
  space       : model.Type.Named,
  @"type"     : model.Type.Named,
  void        : model.Type.Named,
},
/// types defined in system.ny. these are available as soon as system.ny has
/// been loaded and must not be accessed earlier.
system: struct {
  boolean         : model.Type,
  identifier      : model.Type,
  integer         : model.Type,
  natural         : model.Type,
  output_name     : model.Type,
  positive        : model.Type,
  text            : model.Type,
  unicode_category: model.Type,
  numeric_impl    : model.Type,
},
/// prototype functions defined on every type of a prototype.
prototype_funcs: struct {
  concat      : funcs.PrototypeFuncs = .{},
  @"enum"     : funcs.PrototypeFuncs = .{},
  intersection: funcs.PrototypeFuncs = .{},
  list        : funcs.PrototypeFuncs = .{},
  hashmap     : funcs.PrototypeFuncs = .{},
  numeric     : funcs.PrototypeFuncs = .{},
  optional    : funcs.PrototypeFuncs = .{},
  sequence    : funcs.PrototypeFuncs = .{},
  record      : funcs.PrototypeFuncs = .{},
  textual     : funcs.PrototypeFuncs = .{},
} = .{},
/// holds instance functions for every non-unique type. These are instances
/// of the functions that are defined on the prototype of the subject type.
instance_funcs: std.HashMapUnmanaged(
  model.Type, *funcs.InstanceFuncs, model.Type.HashContext,
  std.hash_map.default_max_load_percentage,
) = .{},
/// set to true if we're currently instantiating instance funcs.
/// while we're doing this, no other instance funcs will be named.
/// this leads to types with constructors having the .type type instead of the
/// .callable type corresponding to their constructor.
///
/// we do this to prevent self-referential logic during instantiation.
instantiating_instance_funcs: bool = false,

pub fn init(ctx: nyarna.Context) !Self {
  var ret = Self{
    .allocator     = ctx.global(),
    .self_ref_list = try ctx.global().create(model.Type.Structural),
    .constructors  = .{}, // set later by loading the intrinsic lib
    .predefined    = undefined,
    .system        = undefined,
  };
  inline for (@typeInfo(@TypeOf(ret.predefined)).Struct.fields) |field| {
    const val = &@field(ret.predefined, field.name);
    val.* = .{
      .at   = model.Position.intrinsic(),
      .name = null,
      .data = @unionInit(@TypeOf(val.data), field.name, .{}),
    };
  }

  ret.self_ref_list.* = .{
    .list = .{
      .inner = .{.structural = ret.self_ref_list},
    },
  };

  return ret;
}

pub fn deinit(_: *Self) void {
  // nothing to do – the supplied ArenaAllocator will take care of freeing
  // the named types.
}

pub fn ast(self: *Self) model.Type {
  return self.predefined.ast.typedef();
}

pub fn blockHeader(self: *Self) model.Type {
  return self.predefined.block_header.typedef();
}

pub fn definition(self: *Self) model.Type {
  return self.predefined.definition.typedef();
}

pub fn every(self: *Self) model.Type {
  return self.predefined.every.typedef();
}

pub fn frameRoot(self: *Self) model.Type {
  return self.predefined.frame_root.typedef();
}

pub fn literal(self: *Self) model.Type {
  return self.predefined.literal.typedef();
}

pub fn location(self: *Self) model.Type {
  return self.predefined.location.typedef();
}

pub fn output(self: *Self) model.Type {
  return self.predefined.output.typedef();
}

pub fn poison(self: *Self) model.Type {
  return self.predefined.poison.typedef();
}

pub fn prototype(self: *Self) model.Type {
  return self.predefined.prototype.typedef();
}

pub fn schema(self: *Self) model.Type {
  return self.predefined.schema.typedef();
}

pub fn schemaDef(self: *Self) model.Type {
  return self.predefined.schema_def.typedef();
}

pub fn space(self: *Self) model.Type {
  return self.predefined.space.typedef();
}

pub fn text(self: *Self) model.Type {
  return self.system.text;
}

pub fn @"type"(self: *Self) model.Type {
  return self.predefined.@"type".typedef();
}

pub fn @"void"(self: *Self) model.Type {
  return self.predefined.void.typedef();
}

fn constructorOf(self: *Self, t: model.Type) !?*model.Type.Callable {
  const instance_funcs = (try self.instanceFuncsOf(t)) orelse return null;
  return instance_funcs.constructor;
}

/// may only be called on types that do have constructors
pub fn typeConstructor(self: *Self, t: model.Type) !Constructor {
  return switch (t) {
    .named => |named| switch (named.data) {
      .definition  => self.constructors.definition,
      .@"enum"     => Constructor{
        .callable   = (try self.constructorOf(t)).?,
        .impl_index = self.prototype_funcs.@"enum".constructor.?.impl_index,
      },
      .float, .int => Constructor{
        .callable   = (try self.constructorOf(t)).?,
        .impl_index = self.prototype_funcs.numeric.constructor.?.impl_index,
      },
      .location    => self.constructors.location,
      .output      => self.constructors.output,
      .schema_def  => self.constructors.schema_def,
      .textual     => Constructor{
        .callable   = (try self.constructorOf(t)).?,
        .impl_index = self.prototype_funcs.textual.constructor.?.impl_index,
      },
      .void        => self.constructors.void,
      else => unreachable,
    },
    .structural => |strct| switch (strct.*) {
      .list => Constructor{
        .callable   = (try self.constructorOf(t)).?,
        .impl_index = self.prototype_funcs.list.constructor.?.impl_index,
      },
      else => unreachable,
    },
  };
}

pub fn prototypeConstructor(
  self: *const Self,
  pt  : model.Prototype,
) Constructor {
  return switch (pt) {
    .concat       => self.constructors.prototypes.concat,
    .@"enum"      => self.constructors.prototypes.@"enum",
    .hashmap      => self.constructors.prototypes.hashmap,
    .intersection => self.constructors.prototypes.intersection,
    .list         => self.constructors.prototypes.list,
    .numeric      => self.constructors.prototypes.numeric,
    .optional     => self.constructors.prototypes.optional,
    .record       => self.constructors.prototypes.record,
    .sequence     => self.constructors.prototypes.sequence,
    .textual      => self.constructors.prototypes.textual,
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
  t1  : model.Type,
  t2  : model.Type,
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
    .named => |named| switch (named.data) {
      .textual, .int, .float, .@"enum", .record => {},
      else => return try self.supWithIntrinsic(named, types[(i + 1) % 2]),
    },
    .structural => {},
  };
  var named_types = [_]*model.Type.Named{t1.named, t2.named};
  for (named_types) |t| switch (t.data) {
    .record => return try
      builders.IntersectionBuilder.calcFrom(self, .{&t1, &t2}),
    else => {},
  };
  for (named_types) |t, i| switch (t.data) {
    .int => |_| {
      const other = named_types[(i + 1) % 2];
      return switch (other.data) {
        .float => |_| unreachable, // TODO
        .int => |_| unreachable, // TODO
        else => self.text(),
      };
    },
    .float => |_| unreachable, // TODO
    else => {},
  };
  for (named_types) |*t, i| switch (t.*.data) {
    .@"enum" => {
      const other = named_types[(i + 1) % 2];
      switch (other.data) {
        .@"enum" => return self.system.identifier,
        .textual => t.* = self.system.identifier.named,
        else => return self.text(),
      }
    },
    else => {},
  };
  if (named_types[0].data == .textual and named_types[1].data == .textual) {
    // to speed up, check for the Text type which allows anything.
    // this is a common case since Text is our base output type.
    for (named_types) |t| if (t == self.text().named) return t.typedef();

    var order = HalfOrder.eq;
    var categories = unicode.CategorySet.empty();
    var ci: u5 = 0; while (ci <= 29) : (ci += 1) {
      const cat = @intToEnum(unicode.Category, ci);
      if (named_types[0].data.textual.include.categories.contains(cat)) {
        if (!named_types[1].data.textual.include.categories.contains(cat)) {
          order.push(.gt);
        }
        categories.include(cat);
      } else if (
        named_types[1].data.textual.include.categories.contains(cat)
      ) {
        order.push(.lt);
        categories.include(cat);
      }
    }
    if (order != .dj) for (named_types) |t, i| {
      const cur = &t.data.textual;
      const other = &named_types[(i + 1) % 2].data.textual;
      var iter = cur.include.chars.keyIterator();
      while (iter.next()) |cp| {
        if (!other.includes(cp.*)) order.push(if (i == 0) .gt else .lt);
      }
      iter = cur.exclude.keyIterator();
      while (iter.next()) |cp| {
        if (other.includes(cp.*)) order.push(if (i == 0) .lt else .gt);
      }
    };
    switch (order) {
      .eq, .lt => return t2,
      .gt => return t1,
      .dj => {
        var include = std.hash_map.AutoHashMapUnmanaged(u21, void){};
        for (named_types) |t| {
          var iter = t.data.textual.include.chars.keyIterator();
          while (iter.next()) |cp| {
            if (!categories.contains(unicode.category(cp.*))) {
              try include.put(self.allocator, cp.*, {});
            }
          }
        }
        var exclude = std.hash_map.AutoHashMapUnmanaged(u21, void){};
        var iter = named_types[0].data.textual.exclude.keyIterator();
        while (iter.next()) |cp| {
          if (named_types[1].data.textual.exclude.get(cp.*) != null) {
            try exclude.put(self.allocator, cp.*, {});
          }
        }
        const ret = try self.allocator.create(model.Type.Named);
        ret.* = .{
          .at   = model.Position.intrinsic(),
          .name = null,
          .data = .{.textual = .{
            .include = .{
              .chars      = include,
              .categories = categories,
            },
            .exclude = exclude,
          }},
        };
        return ret.typedef();
      }
    }
  }

  // at this point, we have two different named types that are not
  // records, nor in any direct relationship with each other. therefore…
  return self.text();
}

pub fn registerSequence(
  self  : *Self,
  direct: ?model.Type,
  inner : []*model.Type.Record,
  t     : *model.Type.Sequence,
) !void {
  std.sort.sort(*model.Type.Record, inner, {}, recTotalOrderLess);
  var iter = TreeNode(void).Iter{
    .cur = &self.prefix_trees.sequence, .types = self,
  };
  try iter.descend(if (direct) |d| d else self.every(), {});
  for (inner) |it| try iter.descend(it.typedef(), {});
  std.debug.assert(iter.cur.value == null);
  iter.cur.value = t.typedef().structural;
  t.* = .{
    .direct = direct,
    .inner  = inner,
    .auto   = null,
  };
}

pub fn calcSequence(
  self  : *Self,
  direct: ?model.Type,
  inner : []*model.Type.Record,
) !model.Type {
  std.sort.sort(*model.Type.Record, inner, {}, recTotalOrderLess);
  var iter = TreeNode(void).Iter{
    .cur = &self.prefix_trees.sequence, .types = self,
  };
  std.debug.assert(direct == null or !direct.?.isStruc(.optional));
  try iter.descend(if (direct) |d| d else self.every(), {});
  for (inner) |t| try iter.descend(t.typedef(), {});
  return model.Type{.structural = iter.cur.value orelse blk: {
    var new = try self.allocator.create(model.Type.Structural);
    new.* = .{.sequence = .{
      .direct = direct,
      .inner  = inner,
      .auto   = null,
    }};
    iter.cur.value = new;
    break :blk new;
  }};
}

fn concatFromParagraphs(
  self: *Self,
  p   : *model.Type.Structural.Paragraphs,
) !model.Type {
  var res = self.space();
  for (p.inner) |t| res = try self.sup(res, t);
  return res;
}

fn supWithStructure(
  self : *Self,
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
            if (other_inter.scalar) |other_scalar|
              try self.sup(inter_scalar, other_scalar)
            else inter_scalar
          else other_inter.scalar;

          return if (scalar_type) |st| try builders.IntersectionBuilder.calcFrom(
            self, .{&st, inter.types, other_inter.types})
          else try builders.IntersectionBuilder.calcFrom(
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
    .named => |named| switch (named.data) {
      .every => return struc.typedef(),
      .void  => return switch (struc.*) {
        .concat => model.Type{.structural = struc},
        else    => (try self.optional(struc.typedef())) orelse self.poison(),
      },
      .space, .literal, .textual, .record => {},
      .@"type" => return switch (struc.*) {
        .callable => |*clb|
          if (clb.kind == .@"type") other else self.poison(),
        .concat => |*con|
          if (con.inner.eql(other)) struc.typedef() else self.poison(),
        .list => |*lst|
          if (lst.inner.eql(other)) struc.typedef() else self.poison(),
        else => self.poison(),
      },
      .location, .definition, .output => return switch (struc.*) {
        .concat => |*con|
          if (con.inner.eql(other)) struc.typedef() else self.poison(),
        .list => |*lst|
          if (lst.inner.eql(other)) struc.typedef() else self.poison(),
        else => self.poison(),
      },
      else => return self.poison(),
    },
  }
  return switch (struc.*) {
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
    .concat => |*c|
      (try self.concat(try self.sup(c.inner, other))) orelse self.poison(),
    .hashmap => {
      unreachable; // TODO
    },
    .intersection => |*inter| blk: {
      if (other.isScalar()) {
        const scalar_type = if (inter.scalar) |inter_scalar|
          try self.sup(other, inter_scalar) else other;
        break :blk try builders.IntersectionBuilder.calcFrom(
          self, .{&scalar_type, inter.types});
      } else switch (other) {
        .named => |other_inst| if (other_inst.data == .record) {
          break :blk try if (inter.scalar) |inter_scalar|
            builders.IntersectionBuilder.calcFrom(
              self, .{&inter_scalar, &other, inter.types})
          else builders.IntersectionBuilder.calcFrom(
            self, .{&other, inter.types});
        },
        else => {},
      }
      break :blk self.poison();
    },
    .list => |*l|
      (try self.list(try self.sup(l.inner, other))) orelse self.poison(),
    .optional => |*o|
      (try self.optional(try self.sup(o.inner, other))) orelse self.poison(),
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
            if (self.lesserEqual(other, direct)) return struc.typedef();
          }
          var builder =
            builders.SequenceBuilder.init(self, self.allocator, true);
          if (s.direct) |direct| {
            const res = try builder.push(direct.predef(), true);
            std.debug.assert(res == .success);
          }
          for (s.inner) |inner| {
            const res = try builder.push(inner.typedef().predef(), false);
            std.debug.assert(res == .success);
          }
          if ((try builder.push(other.predef(), true)) == .success) {
            return (try builder.finish(null, null)).t;
          } else return self.poison();
        },
        else => self.poison(),
      },
      .named => |other_named| switch (other_named.data) {
        .void => return struc.typedef(),
        .literal, .space, .int, .textual, .@"enum", .float => {
          if (s.direct) |direct| {
            const res = try self.sup(other, direct);
            if (res.eql(direct)) return struc.typedef();
            return try self.calcSequence(res, s.inner);
          } else return try self.calcSequence(other, s.inner);
        },
        .record => |*rec| {
          if (s.direct) |direct| {
            if (self.lesserEqual(other, direct)) return struc.typedef();
          }
          for (s.inner) |inner| {
            if (inner == rec) return struc.typedef();
          }
          var builder =
            builders.SequenceBuilder.init(self, self.allocator, true);
          if (s.direct) |direct| {
            const res = try builder.push(direct.predef(), true);
            std.debug.assert(res == .success);
          }
          for (s.inner) |inner| {
            const res = try builder.push(inner.typedef().predef(), false);
            std.debug.assert(res == .success);
          }
          const res = try builder.push(other.predef(), false);
          std.debug.assert(res == .success);
          return (try builder.finish(null, null)).t;
        },
        else => return self.poison(),
      }
    },
  };
}

fn supWithIntrinsic(
  self : *Self,
  intr : *model.Type.Named,
  other: model.Type,
) !model.Type {
  return switch (intr.data) {
    .@"enum", .float, .int, .record, .textual => unreachable, .void =>
      (try self.optional(other)) orelse self.poison(),
    .prototype, .schema, .extension, .ast, .frame_root => self.poison(),
    .space, .literal => switch (other) {
      .structural => unreachable, // case is handled in supWithStructural.
      .named => |named| switch (named.data) {
        .textual, .int, .float, .@"enum" => self.text(),
        .record  => {
          const t1 = intr.typedef();
          return try
            builders.IntersectionBuilder.calcFrom(self, .{&t1, &other});
        },
        .every   => intr.typedef(),
        .void    => (try self.optional(intr.typedef())).?,
        .space   => intr.typedef(),
        .literal => other,
        else     => self.poison(),
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
    .exalt     => return self.void(),
    .collapse  => return t,
    .allowed   => {},
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
  t   : model.Type,
) std.mem.Allocator.Error!?model.Type {
  switch (InnerIntend.concat(t)) {
    .forbidden => return null,
    .exalt     => return try self.concat(t.structural.optional.inner),
    .collapse  => return t,
    .allowed   => {},
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
    .named => |named| switch (named.data) {
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
    .named => |named| switch (named.data) {
      .void, .schema, .extension => return null,
      .poison => return t,
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

pub fn hashMap(
  self : *Self,
  key  : model.Type,
  value: model.Type,
) std.mem.Allocator.Error!?model.Type {
  switch (key) {
    .named => |named| switch (named.data) {
      .literal, .textual, .int, .float, .@"enum", .@"type" => {},
      else => return null,
    },
    .structural => return null,
  }
  const e = Entry{.key = key, .value = value};
  const res = try self.hashmaps.getOrPut(self.allocator, e);
  if (!res.found_existing) {
    const struc = try self.allocator.create(model.Type.Structural);
    struc.* = .{.hashmap = .{
      .key   = key,
      .value = value,
    }};
    res.value_ptr.* = struc;
  }
  return res.value_ptr.*.typedef();
}

pub fn registerHashMap(self: *Self, t: *model.Type.HashMap) !bool {
  switch (t.key) {
    .named => |named| switch (named.data) {
      .literal, .textual, .int, .float, .@"enum", .@"type" => {},
      else => return false,
    },
    .structural => return false,
  }
  const res = try self.hashmaps.getOrPut(
    self.allocator, Entry{.key = t.key, .value = t.value});
  std.debug.assert(!res.found_existing);
  res.value_ptr.* = t.typedef().structural;
  return true;
}

/// returns the type of the given type if it was a Value.
pub fn typeType(self: *Self, t: model.Type) !model.Type {
  return switch (t) {
    .structural => |struc| switch (struc.*) {
      .hashmap => blk: {
        const constructor = (
          try self.constructorOf(t)
        ) orelse break :blk self.@"type"(); // workaround for system.ny
        break :blk constructor.typedef();
      },
      .list => blk: {
        const constructor = (
          try self.constructorOf(t)
        ) orelse break :blk self.@"type"(); // workaround for system.ny
        break :blk constructor.typedef();
      },
      else => self.@"type"(),
    },
    .named => |named| switch (named.data) {
      .int, .@"enum", .textual, .float => {
        const constructor = (
          try self.constructorOf(t)
        ) orelse return self.@"type"();
        return constructor.typedef();
      },
      .record  => |*rec| rec.constructor.typedef(),
      .location, .definition, .schema_def, .void, .output =>
        // callable may be null if currently processing system.ny. In that
        // case, the type is not callable.
        if ((try self.typeConstructor(t)).callable) |c| c.typedef()
        else self.@"type"(),
      else     => self.@"type"(),
    },
  };
}

pub fn valueType(self: *Self, v: *model.Value) !model.Type {
  return switch (v.data) {
    .ast          => |ast| if (ast.container == null)
                              self.ast() else self.frameRoot(),
    .block_header =>         self.blockHeader(),
    .concat       => |*con|  con.t.typedef(),
    .definition   =>         self.definition(),
    .@"enum"      => |*en|   en.t.typedef(),
    .float        => |*fl|   fl.t.typedef(),
    .funcref      => |*fr|   fr.func.callable.typedef(),
    .hashmap      => |*map|  map.t.typedef(),
    .int          => |*int|  int.t.typedef(),
    .list         => |*list| list.t.typedef(),
    .location     =>         self.location(),
    .output       =>         self.output(),
    .prototype    => |pv|
      self.prototypeConstructor(pv.pt).callable.?.typedef(),
    .record       => |*rec|  rec.t.typedef(),
    .schema       => self.schema(),
    .schema_def   => self.schemaDef(),
    .seq          => |*seq|  seq.t.typedef(),
    .text         => |*txt|  txt.t,
    .@"type"      => |tv|    try self.typeType(tv.t),
    .void         => self.void(),
    .poison       => self.poison(),
  };
}

pub fn valueSpecType(self: *Self, v: *model.Value) !model.SpecType {
  return (try self.valueType(v)).at(v.origin);
}

fn valForType(self: Self, t: model.Type) !*model.Value.TypeVal {
  const ret = try self.allocator.create(model.Value);
  ret.* = .{
    .origin = model.Position.intrinsic(),
    .data = .{.@"type" = .{.t = t}},
  };
  return &ret.data.@"type";
}

fn typeArr(self: Self, types: []model.Type) ![]*model.Value.TypeVal {
  const ret = try self.allocator.alloc(*model.Value.TypeVal, types.len);
  for (types) |t, i| {
    ret[i] = try self.valForType(t);
  }
  return ret;
}

fn instanceArgs(self: Self, t: model.Type) ![]*model.Value.TypeVal {
  return try switch (t) {
    .structural => |struc| switch (struc.*) {
      .callable     => self.typeArr(&.{t}),
      .concat       => |*con| self.typeArr(&.{t, con.inner}),
      .hashmap      => |*map| self.typeArr(&.{t, map.key, map.value}),
      .intersection => self.typeArr(&.{t}),
      .list         => |*lst| self.typeArr(&.{t, lst.inner}),
      .optional     => |*opt| self.typeArr(&.{t, opt.inner}),
      .sequence     => self.typeArr(&.{t}), // TODO
    },
    .named => self.typeArr(&.{t}),
  };
}

pub fn instanceFuncsOf(self: *Self, t: model.Type) !?*funcs.InstanceFuncs {
  if (self.instantiating_instance_funcs) return null;
  const pt = switch (t) {
    .structural => |struc| switch (struc.*) {
      .callable     => return null,
      .concat       => &self.prototype_funcs.concat,
      .hashmap      => &self.prototype_funcs.hashmap,
      .intersection => &self.prototype_funcs.intersection,
      .list         => &self.prototype_funcs.list,
      .optional     => &self.prototype_funcs.optional,
      .sequence     => &self.prototype_funcs.sequence,
    },
    .named => |named| switch (named.data) {
      .@"enum"     => &self.prototype_funcs.@"enum",
      .float, .int => &self.prototype_funcs.numeric,
      .record      => &self.prototype_funcs.record,
      .textual     => &self.prototype_funcs.textual,
      else => return null,
    },
  };
  const res = try self.instance_funcs.getOrPut(self.allocator, t);
  if (!res.found_existing) {
    self.instantiating_instance_funcs = true;
    defer self.instantiating_instance_funcs = false;
    res.value_ptr.* = try funcs.InstanceFuncs.create(
      pt, self.allocator, try self.instanceArgs(t));
  }
  return res.value_ptr.*;
}

/// given the actual type of a value and the target type of an expression,
/// calculate the expected type in E_(target) to which the value is to be
/// coerced [8.3].
pub fn expectedType(
  self  : *Self,
  actual: model.Type,
  target: model.Type,
) model.Type {
  if (actual.eql(target)) return target;
  return switch (target) {
    // no named types are virtual.
    .named => |named| switch (named.data) {
      // only subtypes are Callables with .kind == .@"type", and type checking
      // guarantees we get one of these.
      .@"type" => actual,
      // can never be used for a target type.
      .every => unreachable,
      // if a poison value is expected, it will never be used for anything,
      // and therefore we don't need to modify the value.
      .poison => actual,
      // all other named types are non-virtual.
      else => target,
    },
    .structural => |strct| switch (strct.*) {
      .optional => |*opt|
        if (actual.isNamed(.void) or actual.isNamed(.every)) actual
        else self.expectedType(actual, opt.inner),
      .concat, .sequence, .list, .hashmap => target,
      .callable     => unreachable, // TODO
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

pub fn litType(self: *Self, lit: *model.Node.Literal) model.Type {
  return if (lit.kind == .text) self.literal() else self.space();
}

/// returns whether there exists a semantic conversion from `from` to `to`.
pub fn convertible(self: *Self, from: model.Type, to: model.Type) bool {
  if (self.lesserEqual(from, to)) return true;
  const to_scalar = containedScalar(to);
  return switch (from) {
    .named => |from_inst| switch (from_inst.data) {
      .void => if (to_scalar) |scalar| switch (scalar.named.data) {
        .literal, .space, .textual => true,
        else => false,
      } else false,
      .schema_def => return to.isNamed(.schema),
      .space => to.isStruc(.concat) or to.isStruc(.sequence),
      .literal => to_scalar != null,
      .textual => if (to_scalar) |ts| ts.isNamed(.textual) else false,
      .int, .float => if (to_scalar) |ts| (
        ts.isNamed(.int) or ts.isNamed(.float) or ts.eql(self.text())
      ) else false,
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
        .named => false,
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
          .named => |to_inst| switch (to_inst.data) {
            .space, .literal, .int, .textual, .@"enum", .float => {},
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

/// replaces the scalar type in t with scalar_type and returns the resulting
/// type.
///
/// Precondition: containedScalar(t) doesn't return null.
pub fn replaceScalar(
  self       : *Self,
  t          : model.Type,
  scalar_type: model.Type,
) std.mem.Allocator.Error!?model.Type {
  return switch (t) {
    .structural => |strct| switch (strct.*) {
      .optional => |*opt| if (
        try self.replaceScalar(opt.inner, scalar_type)
      ) |inner| try self.optional(inner) else null,
      .concat   => |*con| if (
        try self.replaceScalar(con.inner, scalar_type)
      ) |inner| try self.concat(inner) else null,
      .sequence => |*seq| blk: {
        if (try self.replaceScalar(seq.direct.?, scalar_type)) |direct| {
          var builder =
            builders.SequenceBuilder.init(self, self.allocator, true);
          _ = try builder.push(direct.predef(), true);
          for (seq.inner) |rec| {
            _ = try builder.push(rec.typedef().predef(), false);
          }
          break :blk (try builder.finish(null, null)).t;
        } break :blk null;
      },
      .intersection => |*inter| blk: {
        var builder = try builders.IntersectionBuilder.init(2, self.allocator);
        std.debug.assert(inter.scalar != null);
        _ = builder.pushUnique(&scalar_type, model.Position.intrinsic());
        builder.push(inter.types);
        break :blk try builder.finish(self);
      },
      else => unreachable,
    },
    .named => |named| switch (named.data) {
      .textual, .int, .float, .@"enum", .space, .literal => scalar_type,
      else => unreachable,
    },
  };
}

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
    .named => |named| switch (named.data) {
      .textual, .int, .float, .@"enum", .space, .literal => t,
      else => null
    },
  };
}

pub fn seqInnerType(self: *Self, seq: *model.Type.Sequence) !model.Type {
  var res = self.every();
  for (seq.inner) |rec| res = try self.sup(res, rec.typedef());
  if (seq.direct) |direct| res = try self.sup(res, direct);
  return res;
}

pub fn allowedAsConcatInner(t: model.Type) bool {
  return InnerIntend.concat(t) == .allowed;
}

pub fn allowedAsOptionalInner(t: model.Type) bool {
  return InnerIntend.optional(t) == .allowed;
}

pub fn descend(t: model.Type, index: usize) model.Type {
  // update this if we ever allow descending into other types.
  return t.named.data.record.constructor.sig.parameters[index].spec.t;
}

/// returns true if the given type is .ast, .frame_root or an Optional or List
/// containing such an inner type.
pub fn containsAst(t: model.Type) bool {
  return switch (t) {
    .named => |named| named.data == .ast or named.data == .frame_root,
    .structural => |struc| switch (struc.*) {
      .list     => |*lst| return containsAst(lst.inner),
      .optional => |*opt| return containsAst(opt.inner),
      else => false,
    },
  };
}