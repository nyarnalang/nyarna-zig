const std = @import("std");

const nyarna = @import("../nyarna.zig");
const model = nyarna.model;

/// Used for resolution of cyclical references inside \declare and templates.
/// If given to Interpreter.probeType, probeSibling will be called on unresolved
/// calls and symbol references.
pub const ResolutionContext = struct {
  pub const Result = union(enum) {
    preliminary_type: model.Type,
    known: ?u21,
    unfinished_type, resolved, failed,
  };
  pub const StrippedResult = union(enum) {
    preliminary_type: model.Type,
    known, unknown, unfinished_type, resolved, failed,
  };

  /// must only be called on unresolved calls or symbol references. returns
  ///   .resolved
  ///     if the item has been modified (e.g. resolved to a symbol). The
  ///     modified item is guaranteed to be of a kind for which a type can be
  ///     calculated.
  ///   .preliminary_type
  ///     during type inference for calls that form cycles back to the currently
  ///     processed function body. Implies that the returned type should be used
  ///     to calculate the containing entity's type. The returned index is the
  ///     index of the called entity, used for building the dependency graph.
  ///   .unfinished_type
  ///     if the node has been resolved to a type which has not yet been
  ///     finalized. The node now contains a type literal. The type may be used
  ///     as inner type to construct another type, but must not be used for
  ///     anything else since it is unfinished.
  ///   .known
  ///     if the reference's name can be resolved to a sibling symbol but no
  ///     type information is currently available. The value is the index of the
  ///     target sibling node, or null in case of unresolved_call. It is used
  ///     when building up a dependency graph between items in a \declare
  ///     command, it creates a dependency edge between the current node and the
  ///     node at the given index.
  ///   .failed
  ///     when the referenced symbol is unknown altogether and the caller must
  ///     assume this reference cannot be resolved in future steps.
  resolveInSiblingDefinitions: fn(ctx: *ResolutionContext, item: *model.Node)
                                 nyarna.Error!Result,
  /// registers all links to sibling nodes that are encountered.
  /// will be set during graph processing and is not to be set by the caller.
  dependencies: std.ArrayListUnmanaged(usize) = undefined,
  /// the namespace in which all symbols declared via this context reside.
  ns: u15,

  fn addDep(ctx: *ResolutionContext, index: usize) !void {
    for (ctx.dependencies.items) |item| if (item == index) return;
    try ctx.dependencies.append(index);
  }

  pub fn probeSibling(ctx: *ResolutionContext, item: *model.Node)
      !StrippedResult {
    const res = try ctx.resolveInSiblingDefinitions(ctx, item);
    return switch (res) {
      .preliminary_type => |t| StrippedResult{.preliminary_type = t},
      .known => |value| blk: {
        if (value) |index| try addDep(index);
        break :blk .known;
      },
      .unfinished_type => .unfinished_type,
      .failed => .failed,
      .resolved => .resolved,
    };
  }
};

/// Graph must be a struct containing the following:
///   .context => a ResolutionContext field
///   fn length() usize => returns the number of nodes in the graph
///   fn swap(left: usize, right: usize) void
///     => swaps the two nodes with the given indexes
pub fn GraphProcessor(comptime Graph: type) type {
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

    pub fn init(allocator: *std.mem.Allocator, graph: Graph) !Self {
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

      fn init(allocator: *std.mem.Allocator, proc: *Self) !Tarjan {
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
          try self.components.append(self.first_unsorted);
        }
      }
    };

    // second step: compute strongly connected components using Tarjan's
    // algorithm ( https://epubs.siam.org/doi/10.1137/0201010 )
    // this will also sort the graph's node list so that all nodes of one
    // component occur after each other and the components are sorted by
    // reverse topological order.
    pub fn secondStep(self: *Self, allocator: *std.mem.Allocator) !void {
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