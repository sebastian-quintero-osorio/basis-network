/// Binary tree structure for N-proof aggregation.
///
/// Organizes proofs into a binary tree where:
///   - Leaves are individual enterprise proofs (halo2-KZG)
///   - Internal nodes represent folded instances (ProtoGalaxy accumulation)
///   - Root represents the final folded instance (input to Groth16 decider)
///
/// The tree is balanced: for N proofs, depth = ceil(log2(N)).
/// Odd-count levels promote the unpaired element to the next level.
///
/// This models the "Binary tree accumulation pipeline" from the research findings
/// (Section 3.4) and the ProtoGalaxy folding hierarchy.
///
/// [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]
/// [Source: implementation-history/prover-aggregation/research/findings.md, Section 3.4]

use std::collections::BTreeSet;

use crate::types::{FoldedInstance, ProofId};

// ---------------------------------------------------------------------------
// Tree node
// ---------------------------------------------------------------------------

/// Content of a tree node: either a leaf (raw proof) or an internal node (folded).
#[derive(Debug, Clone)]
pub enum NodeContent {
    /// Leaf node: an individual enterprise proof.
    Leaf {
        proof_id: ProofId,
        valid: bool,
    },
    /// Internal node: result of folding two children.
    Folded(FoldedInstance),
}

/// A node in the aggregation tree.
#[derive(Debug, Clone)]
pub struct TreeNode {
    /// Node content (leaf or folded result).
    pub content: NodeContent,
    /// Index of the left child (None for leaves).
    pub left: Option<usize>,
    /// Index of the right child (None for leaves).
    pub right: Option<usize>,
    /// Tree level (0 = leaves, increases toward root).
    pub level: usize,
}

impl TreeNode {
    /// Whether this node represents a valid proof/accumulation.
    pub fn is_valid(&self) -> bool {
        match &self.content {
            NodeContent::Leaf { valid, .. } => *valid,
            NodeContent::Folded(fi) => fi.satisfiable,
        }
    }
}

// ---------------------------------------------------------------------------
// ProofTree
// ---------------------------------------------------------------------------

/// Binary tree for structured proof aggregation.
///
/// Builds a balanced binary tree from a set of proofs, where each level
/// represents a round of ProtoGalaxy folding. The tree structure enables:
///   1. Parallelism: independent pairs can be folded concurrently
///   2. Incremental aggregation: new proofs extend the tree
///   3. Deterministic ordering: BTreeSet input ensures canonical tree shape
///
/// For N=8 proofs, the tree has 3 levels (log2(8) = 3):
///   Level 0: 8 leaves (individual proofs)
///   Level 1: 4 nodes (4 fold operations)
///   Level 2: 2 nodes (2 fold operations)
///   Level 3: 1 root  (1 fold operation) -> Groth16 decider input
pub struct ProofTree {
    /// All nodes stored in a flat arena (indices reference this vec).
    nodes: Vec<TreeNode>,
    /// Indices of leaf nodes (level 0).
    leaf_indices: Vec<usize>,
    /// Indices of nodes at each level, grouped for batch processing.
    levels: Vec<Vec<usize>>,
    /// Number of folding levels (depth of the tree).
    depth: usize,
}

impl ProofTree {
    /// Build a binary tree from a set of proof IDs with their validity flags.
    ///
    /// The input BTreeSet ensures deterministic ordering, which structurally
    /// enforces OrderIndependence (S3): same set of proofs always produces
    /// the same tree topology.
    ///
    /// [Spec: ProofAggregation.tla, lines 269-281 -- OrderIndependence]
    pub fn from_proofs(proofs: &BTreeSet<ProofId>, validity: &dyn Fn(&ProofId) -> bool) -> Self {
        let n = proofs.len();
        if n == 0 {
            return Self {
                nodes: Vec::new(),
                leaf_indices: Vec::new(),
                levels: Vec::new(),
                depth: 0,
            };
        }

        let mut nodes = Vec::new();
        let mut leaf_indices = Vec::new();

        // Level 0: create leaf nodes
        for pid in proofs {
            let idx = nodes.len();
            nodes.push(TreeNode {
                content: NodeContent::Leaf {
                    proof_id: *pid,
                    valid: validity(pid),
                },
                left: None,
                right: None,
                level: 0,
            });
            leaf_indices.push(idx);
        }

        // Build levels bottom-up
        let mut levels = vec![leaf_indices.clone()];
        let mut current_level_indices = leaf_indices.clone();
        let mut level = 1;

        while current_level_indices.len() > 1 {
            let mut next_level_indices = Vec::new();
            let mut i = 0;

            while i < current_level_indices.len() {
                if i + 1 < current_level_indices.len() {
                    // Pair two nodes
                    let left_idx = current_level_indices[i];
                    let right_idx = current_level_indices[i + 1];

                    let left_valid = nodes[left_idx].is_valid();
                    let right_valid = nodes[right_idx].is_valid();

                    // Folding soundness: result is valid iff BOTH children are valid
                    let folded = FoldedInstance {
                        satisfiable: left_valid && right_valid,
                        num_components: count_leaves(&nodes, left_idx)
                            + count_leaves(&nodes, right_idx),
                        state: Vec::new(), // Placeholder for actual folded state
                    };

                    let new_idx = nodes.len();
                    nodes.push(TreeNode {
                        content: NodeContent::Folded(folded),
                        left: Some(left_idx),
                        right: Some(right_idx),
                        level,
                    });
                    next_level_indices.push(new_idx);
                    i += 2;
                } else {
                    // Odd element: promote to next level
                    next_level_indices.push(current_level_indices[i]);
                    i += 1;
                }
            }

            levels.push(next_level_indices.clone());
            current_level_indices = next_level_indices;
            level += 1;
        }

        let depth = levels.len().saturating_sub(1);

        Self {
            nodes,
            leaf_indices,
            levels,
            depth,
        }
    }

    /// Get the root node of the tree (the final folded instance).
    pub fn root(&self) -> Option<&TreeNode> {
        self.levels.last().and_then(|l| l.first()).map(|&idx| &self.nodes[idx])
    }

    /// Whether the root represents a valid aggregation (all leaves valid).
    ///
    /// This is the tree-level enforcement of AggregationSoundness (S1):
    /// the root is valid iff ALL leaf proofs are valid.
    pub fn is_valid(&self) -> bool {
        self.root().map_or(false, |n| n.is_valid())
    }

    /// Get the depth of the tree (number of folding levels).
    pub fn depth(&self) -> usize {
        self.depth
    }

    /// Get the number of leaf proofs.
    pub fn num_leaves(&self) -> usize {
        self.leaf_indices.len()
    }

    /// Get all leaf proof IDs.
    pub fn leaf_proof_ids(&self) -> Vec<ProofId> {
        self.leaf_indices
            .iter()
            .filter_map(|&idx| match &self.nodes[idx].content {
                NodeContent::Leaf { proof_id, .. } => Some(*proof_id),
                _ => None,
            })
            .collect()
    }

    /// Get the folding pairs at a given level (for parallel execution).
    ///
    /// Returns pairs of (left_index, right_index) that can be folded in parallel.
    pub fn pairs_at_level(&self, level: usize) -> Vec<(usize, usize)> {
        if level == 0 || level >= self.levels.len() {
            return Vec::new();
        }

        self.levels[level]
            .iter()
            .filter_map(|&idx| {
                let node = &self.nodes[idx];
                match (node.left, node.right) {
                    (Some(l), Some(r)) => Some((l, r)),
                    _ => None,
                }
            })
            .collect()
    }

    /// Get a node by index.
    pub fn node(&self, idx: usize) -> Option<&TreeNode> {
        self.nodes.get(idx)
    }
}

/// Count the number of leaves in the subtree rooted at `idx`.
fn count_leaves(nodes: &[TreeNode], idx: usize) -> usize {
    match &nodes[idx].content {
        NodeContent::Leaf { .. } => 1,
        NodeContent::Folded(_) => {
            let left = nodes[idx].left.map_or(0, |l| count_leaves(nodes, l));
            let right = nodes[idx].right.map_or(0, |r| count_leaves(nodes, r));
            left + right
        }
    }
}
