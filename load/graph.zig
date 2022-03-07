const std = @import("std");

const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const interpret = @import("interpret.zig");
const Interpreter = interpret.Interpreter;

/// Used for resolution of cyclical references inside \declare and templates.
/// If given to Interpreter.probeType, probeSibling will be called on unresolved
/// calls and symbol references.
pub const ResolutionContext = struct {
  pub const Result = union(enum) {
    /// The symbol resolves to an unfinished function. The returned type may be
    /// used to calculate the type of calls to this function.
    unfinished_function: model.Type,
    /// The symbol has been resolved to a type which has not yet been finalized.
    /// The returned type may be used as inner type to construct another type,
    /// but must not be used for anything else since it is unfinished.
    unfinished_type: model.Type,
    /// The symbol's name has been resolved to the given variable.
    variable: *model.Symbol.Variable,
    /// The symbol's name can be resolved to a sibling symbol but no type
    /// information is currently available. The value is the index of the
    /// target sibling node. It is used when building up a dependency graph
    /// between items in a \declare command, it creates a dependency edge
    /// between the current node and the node at the given index.
    known: u21,
    /// return this if the name cannot be resolved but may be later. This is
    /// used when discovering cross-function references because there may be
    /// variables yet unresolved that should not lead to an error.
    unknown,
    /// The referenced symbol is unknown altogether and the caller must assume
    /// this reference cannot be resolved in future steps. Returning .failed
    /// implies that an appropriate error has been logged.
    failed,
  };
  pub const StrippedResult = union(enum) {
    unfinished_function: model.Type,
    unfinished_type: model.Type,
    variable: *model.Symbol.Variable,
    /// subject *may* be resolvable in the future but currently isn't.
    unknown,
    /// subject is guaranteed to be poison and an error message has been logged.
    poison,
  };
  pub const AccessData = struct {
    result: StrippedResult,
    is_prefix: bool,
  };

  pub const Target = union(enum) {
    ns: u15,
    t: model.Type,
  };

  /// try to resolve an unresolved name in the current context.
  /// this function is called when the name originates in a symref in the
  /// correct namespace (if context is namespace-based) or in an access on the
  /// correct type or an expression of the correct type
  /// (if context is type-based).
  resolveNameFn: fn(
    ctx: *ResolutionContext,
    name: []const u8,
    name_pos: model.Position,
  ) nyarna.Error!Result,

  /// registers all links to sibling nodes that are encountered.
  /// will be set during graph processing and is not to be set by the caller.
  dependencies: std.ArrayListUnmanaged(usize) = undefined,
  /// the target in whose namespace all symbols declared via this context
  /// reside. either a command character namespace or a type.
  target: Target,

  fn strip(
    ctx: *ResolutionContext,
    local: std.mem.Allocator,
    res: Result
  ) !StrippedResult {
    return switch (res) {
      .unfinished_function => |t| StrippedResult{.unfinished_function = t},
      .unfinished_type => |t| StrippedResult{.unfinished_type = t},
      .variable => |v| StrippedResult{.variable = v},
      .known => |index| {
        for (ctx.dependencies.items) |item| {
          if (item == index) return StrippedResult.unknown;
        }
        try ctx.dependencies.append(local, index);
        return StrippedResult.unknown;
      },
      .unknown => StrippedResult.unknown,
      .failed => StrippedResult.poison,
    };
  }

  /// try to resolve an unresolved symbol reference in the context.
  pub fn resolveSymbol(
    ctx: *ResolutionContext,
    intpr: *Interpreter,
    item: *model.Node.UnresolvedSymref,
  ) !StrippedResult {
    switch (ctx.target) {
      .ns => |ns| if (ns == item.ns) {
        const res = try ctx.resolveNameFn(ctx, item.name, item.node().pos);
        return try ctx.strip(intpr.allocator, res);
      },
      .t => {},
    }
    return StrippedResult.unknown;
  }

  /// try to resolve an unresolved access node in the context.
  pub fn resolveAccess(
    ctx: *ResolutionContext,
    intpr: *Interpreter,
    item: *model.Node.UnresolvedAccess,
    stage: interpret.Stage,
  ) !AccessData {
    switch (ctx.target) {
      .ns => {},
      .t => |t| {
        switch (item.subject.data) {
          .resolved_symref => |*rsym| switch (rsym.sym.data) {
            .@"type" => |st| if (t.eql(st)) return AccessData{
              .result = try ctx.strip(intpr.allocator,
                try ctx.resolveNameFn(ctx, item.id, item.id_pos)),
              .is_prefix = false,
            },
            else => {},
          },
          else => {},
        }
        const pt = (try intpr.probeType(item.subject, stage)) orelse {
          // typically means that we hit a variable in a function body. If so,
          // we just assume that this variable has the \declare type.
          // This means we'll resolve the name of this access in our defs to
          // discover dependencies.
          // This will overreach but we accept that for now.
          // we ignore the result and return .unknown to avoid linking to a
          // possibly wrong function.
          _ = try ctx.strip(
            intpr.allocator, try ctx.resolveNameFn(ctx, item.id, item.id_pos));
          return AccessData{.result = .unknown, .is_prefix = true};
        };
        if (t.eql(pt)) return AccessData{
          .result = try ctx.strip(
            intpr.allocator, try ctx.resolveNameFn(ctx, item.id, item.id_pos)),
          .is_prefix = true,
        };
      }
    }
    return AccessData{.result = .unknown, .is_prefix = false};
  }
};

/// Graph must be a struct containing the following:
///   .context => a ResolutionContext field
///   fn length() usize => returns the number of nodes in the graph
///   fn swap(left: usize, right: usize) void
///     => swaps the two nodes with the given indexes
pub fn Processor(comptime Graph: type) type {
  return struct {
    const Self = @This();
    /// holds bookkeeping information necessary for computing the strongly
    /// connected components via Tarjan's algorithm.
    const NodeRef = struct {
      index_in_graph: usize,
      assigned_index: ?u21 = null,
      lowlink: u21 = undefined,
      /// outgoing edges. calculated in the first step. contains indexes into
      /// node_model.
      edges: []usize = undefined,
      on_stack: bool = false,
      /// this is a reference so that
      ///   forall i: node_data[i].reverse_lookup.index_in_graph == i.
      /// initially, this links to the NodeRef itself and is used while sorting
      /// the nodes during component computation.
      reverse_lookup: *NodeRef,
    };
    /// length equals number of nodes in graph.
    node_data: []NodeRef,
    /// strongly connected components in a graph. len is the number of
    /// components. each component is identified by the index of its first
    /// member's index in the graph. The graph is to be sorted by component.
    /// filled in the second step.
    components: []usize,
    /// the graph that is being processed.
    graph: Graph,

    pub fn init(allocator: std.mem.Allocator, graph: Graph) !Self {
      var ret = Self{
        .graph = graph,
        .node_data = try allocator.alloc(NodeRef, graph.length()),
        .components = undefined,
      };
      for (ret.node_data) |*data, i| data.* =
        .{.index_in_graph = i, .reverse_lookup = data};
      return ret;
    }

    // first step: collect dependencies of nodes.
    pub fn firstStep(self: *Self) !void {
      for (self.node_data) |*data, i| {
        try self.graph.collectDeps(i, &data.edges);
      }
    }

    const Tarjan = struct {
      proc: *Self,
      index: u21,
      stack: []*NodeRef,
      stack_top: usize,
      first_unsorted: usize,
      components: std.ArrayList(usize),

      fn init(allocator: std.mem.Allocator, proc: *Self) !Tarjan {
        return Tarjan{
          .proc = proc,
          .index = 0,
          .stack = try allocator.alloc(*NodeRef, proc.node_data.len),
          .stack_top = 0,
          .first_unsorted = 0,
          .components = std.ArrayList(usize).init(allocator),
        };
      }

      fn deinit(self: *Tarjan) void {
        self.components.allocator.free(self.stack);
        self.components.deinit();
      }

      fn strongConnect(self: *Tarjan, v: *NodeRef)
          std.mem.Allocator.Error!void {
        v.assigned_index = self.index;
        v.lowlink = self.index;
        self.index += 1;
        self.stack[self.stack_top] = v;
        self.stack_top += 1;
        v.on_stack = true;
        defer v.on_stack = false;

        for (v.edges) |w_graph_index| {
          const w = self.proc.node_data[w_graph_index].reverse_lookup;
          if (w.assigned_index) |w_index| {
            if (w.on_stack) {
              v.lowlink = std.math.min(v.lowlink, w_index);
            }
          } else {
            try self.strongConnect(w);
            v.lowlink = std.math.min(v.lowlink, w.lowlink);
          }
        }

        if (v.lowlink == v.assigned_index.?) {
          const start_index = self.first_unsorted;
          while (true) {
            const w = self.stack[self.stack_top - 1];
            self.stack_top -= 1;
            const target_position =
              self.proc.node_data[self.first_unsorted].reverse_lookup;
            const w_old_index = w.index_in_graph;
            self.proc.graph.swap(w.index_in_graph, self.first_unsorted);
            w.index_in_graph = self.first_unsorted;
            target_position.index_in_graph = w_old_index;
            self.proc.node_data[w_old_index].reverse_lookup = target_position;
            self.proc.node_data[self.first_unsorted].reverse_lookup = w;
            self.first_unsorted += 1;
            if (w == v) break;
          }
          try self.components.append(start_index);
        }
      }
    };

    // second step: compute strongly connected components using Tarjan's
    // algorithm ( https://epubs.siam.org/doi/10.1137/0201010 )
    // this will also sort the graph's node list so that all nodes of one
    // component occur after each other and the components are sorted by
    // reverse topological order.
    pub fn secondStep(self: *Self, allocator: std.mem.Allocator) !void {
      var tarjan = try Tarjan.init(allocator, self);
      for (self.node_data) |*v| {
        if (v.assigned_index == null) {
          try tarjan.strongConnect(v);
        }
      }
      self.components = tarjan.components.items;
    }

    // the third step would be to process the circular dependencies in each
    // strongly connected component. This depends on the particular entities
    // that are processed and is therefore not implemented here.
  };
}