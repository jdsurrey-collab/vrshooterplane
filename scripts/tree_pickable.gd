extends XRToolsPickable

## Maps FBX surface names (Quaternius "Textured Stylized Trees" pack convention)
## to their texture files, so any tree in the pack gets correctly textured
## without per-tree material authoring.
const TEXTURE_MAP := {
	"Bark": "res://Assets/Trees2/Textures/Tree_Bark.jpg",
	"Tree_Leaves": "res://Assets/Trees2/Textures/Tree_Leaves.png",
	"Pine_Leaves": "res://Assets/Trees2/Textures/Pine_Leaves.png",
	"Birch_Bark": "res://Assets/Trees2/Textures/Birch_Bark.png",
	"Birch_Leaves": "res://Assets/Trees2/Textures/Birch_Leaves_Green.png",
}


func _ready() -> void:
	super()
	_apply_textures(self)


func _apply_textures(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		var mesh: Mesh = node.mesh
		for i in mesh.get_surface_count():
			var surf_name: String = mesh.surface_get_name(i)
			if TEXTURE_MAP.has(surf_name):
				var mat := StandardMaterial3D.new()
				mat.albedo_texture = load(TEXTURE_MAP[surf_name])
				node.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_textures(child)
