const std = @import("std");

const nyarna    = @import("../../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;

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
      proc          : *Self,
      index         : u21,
      stack         : []*NodeRef,
      stack_top     : usize,
      first_unsorted: usize,
      components    : std.ArrayList(usize),

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

      fn strongConnect(
        self: *Tarjan,
        v   : *NodeRef,
      ) std.mem.Allocator.Error!void {
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