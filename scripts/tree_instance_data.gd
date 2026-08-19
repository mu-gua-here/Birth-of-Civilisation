class_name TreeInstanceData
extends Resource

## Per-tree gameplay state. Rendering/transform for display lives in the
## MultiMesh; this resource is the source of truth for interaction logic
## (chopping, respawn, etc).

@export var transform: Transform3D
@export var variant_path: String  # which tree PackedScene/mesh this came from
@export var wood_amount: int = 5
@export var chopped: bool = false
