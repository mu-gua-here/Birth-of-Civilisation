extends Resource
class_name BuildingInstance

## Tracks occupancy for a single placed structure. Post-GridMap: identified
## by `id` (a generated String, see Builder.placed_structures) instead of a
## gridmap cell.

@export var id: String               # matches a key in Builder.placed_structures
@export var structure_index: int     # index into builder.structures

@export var residents: Array[String] = []  # citizen ids currently housed here
@export var workers: Array[String] = []    # citizen ids currently employed here
