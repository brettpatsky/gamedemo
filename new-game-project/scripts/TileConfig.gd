extends Resource
class_name TileConfig

@export var tileset_source_id: int     = 4

@export_group("Terrain Atlas Coords")
@export var water:  Vector2i = Vector2i(18, 0)
@export var grass:  Vector2i = Vector2i(16, 0)
@export var dirt:   Vector2i = Vector2i(13, 0)
@export var rock:   Vector2i = Vector2i(20, 8)
