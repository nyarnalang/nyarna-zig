const std = @import("std");
const model = @import("model.zig");
const nyarna = @import("nyarna.zig");
const unicode = @import("unicode.zig");
const stringOrder = @import("helpers.zig").stringOrder;

const LiteralNumber = @import("parse.zig").LiteralNumber;

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
        .concat => InnerIntend.collapse,
        .paragraphs => InnerIntend.forbidden,
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
        .optional, .concat, .paragraphs => InnerIntend.collapse,
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

/// PrototypeFuncs contains function definitions belonging to a prototype.
/// Those functions are to be instantiated for each instance of that prototype.
///
/// The functions are instantiated lazily to avoid lots of superfluous
/// instantiations for every instance of e.g. Concat (which are often implicitly
/// created). This type holds the function definitions and implements this
/// instantiation.
pub const PrototypeFuncs = struct {
  pub const Item = struct {
    name: *model.Value.TextScalar,
    params: []*model.Value.Location,
    returns: *model.Value.TypeVal,
    impl_index: usize,
  };
  defs: []Item = &.{},

  fn lessThan(
    context: u0,
    lhs: Item,
    rhs: Item,
  ) bool {
    _ = context;
    return stringOrder(lhs.name.content, rhs.name.content) == .lt;
  }

  /// given list will be consumed.
  pub fn set(self: *PrototypeFuncs, defs: []Item) void {
    std.sort.sort(Item, defs, @as(u0, 0), lessThan);
    self.defs = defs;
  }

  fn find(self: *PrototypeFuncs, name: []const u8) ?usize {
    var defs = self.defs;
    var offset: usize = 0;
    while (defs.len > 0) {
      const i = @divTrunc(defs.len, 2);
      const def = defs[i];
      switch (stringOrder(name, def.name.content)) {
        .lt => defs = defs[0..i],
        .eq => return offset + i,
        .gt => {
          defs = defs[i+1..];
          offset += i+1;
        },
      }
    } else return null;
  }
};

pub const InstanceFuncs = struct {
  pt: *PrototypeFuncs,
  syms: []?*model.Symbol,
  instance: model.Type,

  fn init(
    pt: *PrototypeFuncs,
    allocator: std.mem.Allocator,
    instance: model.Type,
  ) !InstanceFuncs {
    var ret = InstanceFuncs{
      .pt = pt,
      .syms = try allocator.alloc(?*model.Symbol, pt.defs.len),
      .instance = instance,
    };
    std.mem.set(?*model.Symbol, ret.syms, null);
    return ret;
  }

  fn replacePrototypeWith(
    pos: model.Position,
    t: model.Type,
    ctx: nyarna.Context,
    instance: model.Type,
  ) std.mem.Allocator.Error!?model.Type {
    switch (t) {
      .structural => |struc| switch (struc.*) {
        .callable => unreachable,
        .concat => |*con| {
          if (try replacePrototypeWith(pos, con.inner, ctx, instance)) |inner| {
            if (try ctx.types().concat(inner)) |ret| return ret;
            if (!inner.isInst(.poison)) {
              ctx.logger.InvalidInnerConcatType(pos, &[_]model.Type{inner});
            }
            return ctx.types().poison();
          } else return null;
        },
        .intersection => unreachable,
        .list => |*lst| {
          if (try replacePrototypeWith(pos, lst.inner, ctx, instance)) |inner| {
            if (try ctx.types().list(inner)) |ret| return ret;
            if (!inner.isInst(.poison)) {
              ctx.logger.InvalidInnerListType(pos, &[_]model.Type{inner});
            }
            return ctx.types().poison();
          } else return null;
        },
        .map => |*map| {
          var something_changed = false;
          var inners: [2]model.Type = undefined;
          inline for (.{.key, .value}) |f, index| {
            if (
              try replacePrototypeWith(
                pos, @field(map, @tagName(f)), ctx, instance)
            ) |replacement| {
              inners[index] = replacement;
              something_changed = true;
            }
          }
          if (!something_changed) return null;
          unreachable; // TODO: ctx.map(…,…)
        },
        .optional => |*opt| {
          if (try replacePrototypeWith(pos, opt.inner, ctx, instance)) |inner| {
            if (try ctx.types().optional(inner)) |ret| return ret;
            if (!inner.isInst(.poison)) {
              ctx.logger.InvalidInnerOptionalType(pos, &[_]model.Type{inner});
            }
            return ctx.types().poison();
          } else return null;
        },
        .paragraphs => unreachable, // TODO
      },
      .instantiated => |inst| switch (inst.data) {
        .record => unreachable,
        else => return null,
      },
    }
  }

  pub fn find(
    self: *InstanceFuncs,
    ctx: nyarna.Context,
    name: []const u8,
  ) !?*model.Symbol {
    const index = self.pt.find(name) orelse return null;
    if (self.syms[index]) |sym| return sym;
    const def = self.pt.defs[index];
    const ret_type = if (
      try replacePrototypeWith(
        def.returns.value().origin, def.returns.t, ctx, self.instance)
    ) |t| t else def.returns.t;
    var finder = nyarna.types.CallableReprFinder.init(ctx.types());
    for (def.params) |param| try finder.push(param);
    const finder_res = try finder.finish(ret_type, false);
    var builder = try nyarna.types.SigBuilder.init(
      ctx, def.params.len, ret_type, finder_res.needs_different_repr
    );
    for (def.params) |param| try builder.push(param);
    const builder_res = builder.finish();
    const sym = try ctx.global().create(model.Symbol);
    sym.* = .{
      .defined_at = def.name.value().origin,
      .name = def.name.content,
      .data = undefined,
      .parent_type = self.instance,
    };

    const container = try ctx.global().create(model.VariableContainer);
    container.* =
      .{.num_values = @intCast(u15, builder_res.sig.parameters.len)};
    const func = try ctx.global().create(model.Function);
    func.* = .{
      .callable = try builder_res.createCallable(ctx.global(), .function),
      .defined_at = def.name.value().origin,
      .data = .{
        .ext = .{
          .ns_dependent = false,
          .impl_index = def.impl_index,
        },
      },
      .name = sym,
      .variables = container,
    };
    sym.data = .{.func = func};
    self.syms[index] = sym;
    return sym;
  }
};

/// this function implements the artificial total order. The total order's
/// constraint is satisfied by ordering all intrinsic types (which do not have
/// allocated information) before all other types, and ordering the other
/// types according to the pointers to their allocated memory.
///
/// The first argument exists so that this fn can be used for std.sort.sort.
fn total_order_less(_: void, a: model.Type, b: model.Type) bool {
  const a_int = switch (a) {
    .structural => |sa| @ptrToInt(sa),
    .instantiated => |ia| @ptrToInt(ia),
  };
  const b_int = switch (b) {
    .structural => |sb| @ptrToInt(sb),
    .instantiated => |ib| @ptrToInt(ib),
  };
  return a_int < b_int;
}

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
  /// iff the parameter is borrowed. On the return type, this flag is true iff
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
    paragraphs  : TreeNode(void),
    callable    : TreeNode(bool),
  },
  /// Constructors for all types that have constructors.
  /// These are to be queried via typeConstructor() and prototypeConstructor().
  constructors: struct {
    raw       : Constructor = .{},
    location  : Constructor = .{},
    definition: Constructor = .{},

    // the signature of instantiated types' constructors differ per type.
    // they use the same implementation though. Those implementations' indexes
    // are given here.
    generic: struct {
      textual: usize,
      numeric: usize,
      float  : usize,
      @"enum": usize,
    } = undefined,

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
      paragraphs  : Constructor = .{},
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
    integer         : model.Type,
    natural         : model.Type,
    unicode_category: model.Type,
  },
  /// prototype functions defined on every type of a prototype.
  prototype_funcs: struct {
    concat      : PrototypeFuncs = .{},
    @"enum"     : PrototypeFuncs = .{},
    float       : PrototypeFuncs = .{},
    intersection: PrototypeFuncs = .{},
    list        : PrototypeFuncs = .{},
    map         : PrototypeFuncs = .{},
    numeric     : PrototypeFuncs = .{},
    optional    : PrototypeFuncs = .{},
    paragraphs  : PrototypeFuncs = .{},
    record      : PrototypeFuncs = .{},
    textual     : PrototypeFuncs = .{},
  } = .{},
  /// holds instance functions for every non-unique type. These are instances
  /// of the functions that are defined on the prototype of the subject type.
  instance_funcs: std.HashMapUnmanaged(model.Type, InstanceFuncs,
    model.Type.HashContext, std.hash_map.default_max_load_percentage) = .{},

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

  /// may only be called on types that do have constructors
  pub fn typeConstructor(self: *const Self, t: model.Type) Constructor {
    return switch (t) {
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
        .location   => self.constructors.location,
        .definition => self.constructors.definition,
        .raw,       => self.constructors.raw,
        else => unreachable,
      },
      .structural => unreachable,
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
      .record => return try IntersectionTypeBuilder.calcFrom(self, .{&t1, &t2}),
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
  ) !model.Type {
    switch (other) {
      // we're handling some special cases here, but most are handled by the
      // switch below.
      .structural => |other_struc| switch (struc.*) {
        .optional => |*op| switch (other_struc.*) {
          .optional => |*other_op| return
            (try self.optional(try self.sup(other_op.inner, op.inner))) orelse
              self.poison(),
          .concat => |*other_con| return
            (try self.concat(try self.sup(other_con.inner, op.inner))) orelse
              self.poison(),
          else => {},
        },
        .concat => |*other_con| switch (struc.*) {
          .optional => |*op| return
            (try self.concat(try self.sup(op.inner, other_con.inner))) orelse
              self.poison(),
          .concat => |*con| return
            (try self.concat(try self.sup(other_con.inner, con.inner))) orelse
              self.poison(),
          else => {},
        },
        .intersection => |*other_inter| switch (struc.*) {
          .intersection => |*inter| {
            const scalar_type = if (inter.scalar) |inter_scalar|
              if (other_inter.scalar) |other_scalar| try
                self.sup(inter_scalar, other_scalar)
              else inter_scalar
            else other_inter.scalar;

            return if (scalar_type) |st| IntersectionTypeBuilder.calcFrom(
              self, .{&st, inter.types, other_inter.types})
            else IntersectionTypeBuilder.calcFrom(
              self, .{inter.types, other_inter.types});
          },
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
      .paragraphs => {
        unreachable; // TODO
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
          break :blk try IntersectionTypeBuilder.calcFrom(
            self, .{&scalar_type, inter.types});
        } else switch (other) {
          .instantiated => |other_inst| if (other_inst.data == .record) {
            break :blk try if (inter.scalar) |inter_scalar|
              IntersectionTypeBuilder.calcFrom(
                self, .{&inter_scalar, &other, inter.types})
            else IntersectionTypeBuilder.calcFrom(self, .{&other, inter.types});
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
        .void, .prototype, .schema, .extension => return null,
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
  pub fn typeType(self: *Lattice, t: model.Type) model.Type {
    return switch (t) {
      .structural => self.@"type"(), // TODO
      .instantiated => |inst| switch (inst.data) {
        .numeric => |*num| num.constructor.typedef(),
        .tenum   => |*enu| enu.constructor.typedef(),
        .record  => |*rec| rec.constructor.typedef(),
        .location, .definition, .literal, .space, .raw =>
          // callable may be null if currently processing system.ny. In that
          // case, the type is not callable.
          if (self.typeConstructor(t).callable) |c| c.typedef()
          else self.@"type"(),
        else     => self.@"type"(), // TODO
      },
    };
  }

  pub fn valueType(self: *Lattice, v: *model.Value) model.Type {
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
      .@"type" => |tv| return self.typeType(tv.t),
      .prototype => |pv| self.prototypeConstructor(pv.pt).callable.?.typedef(),
      .funcref => |*fr| fr.func.callable.typedef(),
      .location => self.location(),
      .definition => self.definition(),
      .ast => |ast| if (ast.container == null)
        self.ast() else self.frameRoot(),
      .block_header => self.blockHeader(),
      .void => self.void(),
      .poison => self.poison(),
    };
  }

  pub fn instanceFuncsOf(self: *Lattice, t: model.Type) !?*InstanceFuncs {
    const pt = switch (t) {
      .structural => |struc| switch (struc.*) {
        .callable => return null,
        .concat => &self.prototype_funcs.concat,
        .intersection => &self.prototype_funcs.intersection,
        .list => &self.prototype_funcs.list,
        .map => &self.prototype_funcs.map,
        .optional => &self.prototype_funcs.optional,
        .paragraphs => &self.prototype_funcs.paragraphs,
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
      res.value_ptr.* = try InstanceFuncs.init(pt, self.allocator, t);
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
  return t.instantiated.data.record.constructor.sig.parameters[index].ptype;
}

pub const SigBuilderResult = struct {
  /// the built signature
  sig: *model.Signature,
  /// if build_repr has been set in init(), the representative signature
  /// for the type lattice. else null.
  repr: ?*model.Signature,

  pub fn createCallable(
    self: *const @This(),
    allocator: std.mem.Allocator,
    kind: model.Type.Callable.Kind,
  ) !*model.Type.Callable {
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

  val: *model.Signature,
  repr: ?*model.Signature,
  ctx: nyarna.Context,
  next_param: u21,

  const Self = @This();

  /// if returns type is yet to be determined, give .every.
  /// the returns type is given early to know whether this is a keyword.
  ///
  /// if build_repr is true, a second signature will be built to be the
  /// signature of the repr Callable in the type lattice.
  pub fn init(
    ctx: nyarna.Context,
    num_params: usize,
    returns: model.Type,
    build_repr: bool,
  ) !Self {
    var ret = Self{
      .val = try ctx.global().create(model.Signature),
      .repr = if (build_repr)
          try ctx.global().create(model.Signature)
        else null,
      .ctx = ctx,
      .next_param = 0,
    };
    ret.val.* = .{
      .parameters = try ctx.global().alloc(
        model.Signature.Parameter, num_params),
      .primary = null,
      .varmap = null,
      .auto_swallow = null,
      .returns = returns,
    };
    if (ret.repr) |sig| {
      sig.* = .{
        .parameters = try ctx.global().alloc(
          model.Signature.Parameter, num_params),
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
      .capture = if (loc.varargs) |_| .varargs else if (loc.borrow) |_|
        @as(@TypeOf(param.capture), .borrow) else .default,
      .default = loc.default,
      .config = if (loc.header) |bh| bh.config else null,
    };
    // TODO: use contains(.ast_node) instead (?)
    const t: model.Type =
      if (!self.val.isKeyword() and loc.tloc.isInst(.ast)) blk: {
        self.ctx.logger.AstNodeInNonKeyword(loc.value().origin);
        break :blk self.ctx.types().poison();
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
    num_items: usize,
  };
  const Self = @This();

  iter: Lattice.TreeNode(bool).Iter,
  needs_different_repr: bool,
  count: usize,

  pub fn init(lattice: *Lattice) CallableReprFinder {
    return .{
      .iter = .{
        .cur = &lattice.prefix_trees.callable,
        .lattice = lattice,
      },
      .needs_different_repr = false,
      .count = 0,
    };
  }

  pub fn push(self: *Self, loc: *model.Value.Location) !void {
    self.count += 1;
    try self.iter.descend(loc.tloc, loc.borrow != null);
    if (loc.default != null or loc.primary != null or loc.varargs != null or
        loc.varmap != null or loc.header != null)
      self.needs_different_repr = true;
  }

  pub fn finish(self: *Self, returns: model.Type, is_type: bool) !Result {
    try self.iter.descend(returns, is_type);
    return Result{
      .found = &self.iter.cur.value,
      .needs_different_repr = self.needs_different_repr,
      .num_items = self.count,
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
      .cur_scalar = types.every(),
      .non_voids = if (force_paragraphs) 2 else 0,
      .poison = false,
    };
  }

  pub fn push(self: *ParagraphTypeBuilder, t: model.Type) !void {
    if (t.isInst(.void)) return;
    if (t.isInst(.poison)) {
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
      .resulting_type = self.types.poison(),
    } else switch (self.non_voids) {
      0 => Result{
        .scalar_type_sup = self.cur_scalar,
        .resulting_type = self.types.void(),
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

  pub inline fn add(self: *Self, value: []const u8, pos: model.Position) !void {
    try self.ret.values.put(self.ctx.global(), value, pos);
  }

  pub fn finish(self: *Self) !*model.Type.Enum {
    var sb = try SigBuilder.init(
      self.ctx, 1, self.ret.typedef(), true);
    try sb.push((try self.ctx.values.location(
      self.ret.instantiated().at, try self.ctx.values.textScalar(
        model.Position.intrinsic(), self.ctx.types().raw(),
        "input"
      ), self.ret.typedef())).withPrimary(model.Position.intrinsic()));
    self.ret.constructor =
      try sb.finish().createCallable(self.ctx.global(), .type);
    return self.ret;
  }
};

pub const NumericTypeBuilder = struct {
  const Self = @This();

  ctx: nyarna.Context,
  ret: *model.Type.Numeric,
  pos: model.Position,

  pub fn init(ctx: nyarna.Context, pos: model.Position) !Self {
    const inst = try ctx.global().create(model.Type.Instantiated);
    inst.* = .{
      .at = pos,
      .name = null,
      .data = .{.numeric = .{
        .constructor = undefined,
        .min = std.math.minInt(i64),
        .max = std.math.maxInt(i64),
        // can be maximal 32. set to 33 to indicate errors during construction.
        .decimals = 0,
      }},
    };
    return Self{.ctx = ctx, .ret = &inst.data.numeric, .pos = pos};
  }

  pub fn min(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.decimals > self.ret.decimals) {
      self.ctx.logger.TooManyDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (
      @mulWithOverflow(i64, num.value,
      std.math.pow(i64, 10, @intCast(i64, self.ret.decimals - num.decimals)),
        &self.ret.min)
    ) {
      self.ctx.logger.NumberTooLarge(pos, num.repr);
      self.ret.decimals = 33;
    }
  }

  pub fn max(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.decimals > self.ret.decimals) {
      self.ctx.logger.TooManyDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (
      @mulWithOverflow(i64, num.value,
        std.math.pow(i64, 10, @intCast(i64, self.ret.decimals - num.decimals)),
        &self.ret.max)
    ) {
      self.ctx.logger.NumberTooLarge(pos, num.repr);
      self.ret.decimals = 33;
    }
  }

  pub fn decimals(self: *Self, num: LiteralNumber, pos: model.Position) void {
    if (num.value > 32 or num.value < 0 or num.decimals > 0) {
      self.ctx.logger.InvalidDecimals(pos, num.repr);
      self.ret.decimals = 33;
    } else if (self.ret.decimals != 33) {
      self.ret.decimals = @intCast(u8, num.value);
    }
  }

  pub fn finish(self: *Self) !?*model.Type.Numeric {
    if (self.ret.min > self.ret.max) {
      self.ctx.logger.IllegalNumericInterval(self.pos);
      self.ret.decimals = 33;
    }
    if (self.ret.decimals > 32) {
      self.abort();
      return null;
    }
    var sb = try SigBuilder.init(
      self.ctx, 1, self.ret.typedef(), true);
    try sb.push((try self.ctx.values.location(
      self.ret.instantiated().at, try self.ctx.values.textScalar(
        model.Position.intrinsic(), self.ctx.types().raw(), "input"
      ), self.ret.typedef())).withPrimary(model.Position.intrinsic()));
    self.ret.constructor =
      try sb.finish().createCallable(self.ctx.global(), .type);
    return self.ret;
  }

  pub fn abort(self: *Self) void {
    self.ctx.global().destroy(self.ret.instantiated());
  }
};

/// Offers facilities to generate Intersection types. Assumes all given types
/// are either Record or Scalar types, and at most one Scalar type is given.
///
/// Types are to be given as list of `[]const model.Type`, where the types in
/// each slices are ordered according to the artificial type order. This API is
/// designed so that Record and Scalar types can be put in as single-value
/// slice, while referred Intersections will get the scalar part figured out
/// externally while the non-scalar part is a slice that fulfills our
/// precondition and can therefore be put in directly.
pub const IntersectionTypeBuilder = struct {
  const Self = @This();

  fn Static(comptime size: usize) type {
    return struct {
      sources: [size][]const model.Type,
      indexes: [size]usize,

      pub fn init(sources: anytype) @This() {
        var ret: @This() = undefined;
        inline for (std.meta.fields(@TypeOf(sources))) |field, index| {
          const value = @field(sources, field.name);
          switch (@typeInfo(@TypeOf(value)).Pointer.size) {
            .One =>
              ret.sources[index] = @ptrCast([*]const model.Type, value)[0..1],
            .Slice => ret.sources[index] = value,
            else => unreachable,
          }
          ret.indexes[index] = 0;
        }
        return ret;
      }
    };
  }

  pub inline fn staticSources(sources: anytype) Static(sources.len) {
    return Static(sources.len).init(sources);
  }

  sources: [][]const model.Type,
  indexes: []usize,
  filled: usize,
  allocator: ?std.mem.Allocator,

  pub fn init(
    max_sources: usize,
    allocator: std.mem.Allocator,
  ) !IntersectionTypeBuilder {
    return IntersectionTypeBuilder{
      .sources = try allocator.alloc([]const model.Type, max_sources),
      .indexes = try allocator.alloc(usize, max_sources),
      .filled = 0,
      .allocator = allocator,
    };
  }

  pub fn calcFrom(lattice: *Lattice, input: anytype) !model.Type {
    var static = Static(input.len).init(input);
    var self = IntersectionTypeBuilder.initStatic(&static);
    return self.finish(lattice);
  }

  fn initStatic(static: anytype) IntersectionTypeBuilder {
    return IntersectionTypeBuilder{
      .sources = &static.sources,
      .indexes = &static.indexes,
      .filled = static.sources.len,
      .allocator = null,
    };
  }

  pub fn push(self: *Self, item: []const model.Type) void {
    for (item) |t| std.debug.assert(t.isScalar() or t.isInst(.record));
    self.sources[self.filled] = item;
    self.indexes[self.filled] = 0;
    self.filled += 1;
  }

  pub fn finish(self: *Self, lattice: *Lattice) !model.Type {
    var iter = Lattice.TreeNode(void).Iter{
      .cur = &lattice.prefix_trees.intersection, .lattice = lattice,
    };
    var tcount = @as(usize, 0);
    var scalar: ?model.Type = null;
    var input = self.sources[0..self.filled];
    while (true) {
      var cur_type: ?model.Type = null;
      for (input) |list, index| {
        if (list.len > self.indexes[index]) {
          const next = list[self.indexes[index]];
          if (cur_type) |previous| {
            if (total_order_less(undefined, next, previous)) cur_type = next;
          } else cur_type = next;
        }
      }
      if (cur_type) |next_type| {
        for (input) |list, index| {
          const list_index = self.indexes[index];
          if (list_index < list.len and list[list_index].eql(next_type)) {
            self.indexes[index] += 1;
          }
        }
        try iter.descend(next_type, {});
        if (next_type.isScalar()) {
          std.debug.assert(scalar == null);
          scalar = next_type;
        } else tcount += 1;
      } else break;
    }

    defer if (self.allocator) |allocator| {
      allocator.free(self.sources);
      allocator.free(self.indexes);
    };

    return model.Type{.structural = iter.cur.value orelse blk: {
      var new = try lattice.allocator.create(model.Type.Structural);
      new.* = .{.intersection = undefined};
      const new_in = &new.intersection;
      new_in.* = .{
        .scalar = scalar,
        .types = try lattice.allocator.alloc(model.Type, tcount),
      };
      var target_index = @as(usize, 0);
      for (input) |_, index| self.indexes[index] = 0;
      while (true) {
        var cur_type: ?model.Type = null;
        for (input) |vals, index| {
          if (self.indexes[index] < vals.len) {
            const next_in_list = vals[self.indexes[index]];
            if (cur_type) |previous| {
              if (total_order_less(undefined, next_in_list, previous))
                cur_type = next_in_list;
            } else cur_type = next_in_list;
          }
        }
        if (cur_type) |next_type| {
          for (self.sources) |vals, index| {
            const list_index = self.indexes[index];
            if (list_index < vals.len and vals[list_index].eql(next_type)) {
              self.indexes[index] += 1;
            }
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
};