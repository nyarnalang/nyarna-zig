//! Locations can be both given in <syntax locations> where they may contain
//! initially unresolved references, and as Locations values. Keywords that
//! take either use the types defined herein to store those.

const model = @import("../model.zig");

const Expression = model.Expression;
const Node       = model.Node;
const Value      = model.Value;

/// reference to a location given either as node, expression or value
pub const Ref = union(enum) {
  node: *Node.Location,
  expr: *Expression,
  value: *Value.Location,
  /// marks that previous processing determined that this location has errors
  /// and is to be ignored.
  poison,
};

/// a list of locations. Apart from a a chunk of unresolved or a chunk of
/// resolved nodes, some contexts require a third representation, which is a
/// partly generated entity that contains the locations. In such use cases, that
/// representation is to be given as `Pregen` (which can be `void` otherwise).
pub fn List(comptime Pregen: type) type {
  return union(enum) {
    /// This is whatever the input gave, with no checking whether it is a
    /// structure that can be associated to Concat(Location). That check only
    /// happens when interpreting the Funcgen Node, either directly or
    /// step-by-step within \declare.
    unresolved: *Node,
    /// the result of associating the original node with Concat(Location).
    /// the association is made at Node level, allowing unresolved nodes in
    /// the locations' default values.
    resolved: struct {
      locations: []Ref,
    },
    /// during \declare resolution, the target entity constructed from the
    /// location list will at some point be generated and contain the
    /// locations. at that point, the locations will be available in here.
    pregen: *Pregen,
  };
}