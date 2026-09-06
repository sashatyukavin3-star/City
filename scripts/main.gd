extends Node3D

## CityForge 0.6 — free-form 3D city builder.
##
## Roads are true 3D curves (straight, diagonal, curved, circular) built from a
## Curve3D and sampled into geometry. Zones are painted on a grid and mature into
## procedurally generated buildings that feed the city economy. Traffic follows
## the baked road curves. Everything is generated in code, so the project has no
## binary asset dependencies and stays tiny.

# --- Tunables -----------------------------------------------------------------
const ROAD_WIDTH: float = 4.6
const ROAD_Y: float = 0.08
const SAMPLE_STEP: float = 2.2
const MAX_DRAW_DISTANCE: float = 400.0
const GRID_SIZE: float = 8.0
const WORLD_EXTENT: float = 120.0

const CAMERA_MIN_ZOOM: float = 22.0
const CAMERA_MAX_ZOOM: float = 130.0
const CAMERA_PITCH_DEG: float = -52.0

# Economy tick (seconds between income/upkeep updates).
const ECONOMY_INTERVAL: float = 2.5
const SAVE_PATH: String = "user://cityforge_save.json"

# --- Tools --------------------------------------------------------------------
enum Tool { ROAD, ZONE, BULLDOZE, CAMERA }

# Zone types: label, tint, cost, jobs/residents, income per tick.
const ZONE_TYPES: Array[Dictionary] = [
	{"id": "residential", "name": "ЖИЛАЯ",   "color": Color(0.30, 0.62, 0.95, 0.62), "cost": 60,  "people": 24, "income": 14},
	{"id": "commercial",  "name": "ТОРГ.",   "color": Color(0.96, 0.74, 0.22, 0.62), "cost": 90,  "people": 8,  "income": 34},
	{"id": "industrial",  "name": "ПРОМ.",   "color": Color(0.86, 0.44, 0.30, 0.62), "cost": 120, "people": 6,  "income": 52},
	{"id": "park",        "name": "ПАРК",    "color": Color(0.32, 0.72, 0.42, 0.62), "cost": 40,  "people": 0,  "income": -6},
]

# --- State --------------------------------------------------------------------
var roads: Array[Dictionary] = []
var zones: Dictionary = {}            # key "x:z" -> zone dictionary
var current_points: Array[Vector3] = []
var drawing: bool = false
var active_tool: int = Tool.ROAD
var active_zone: int = 0

var population: int = 0
var money: int = 250000
var happiness: int = 78

var _economy_accum: float = 0.0

# --- Camera control state -----------------------------------------------------
var cam_target: Vector3 = Vector3.ZERO
var cam_zoom: float = 62.0
var cam_yaw: float = 0.0
var _panning: bool = false
var _last_pan_pos: Vector2 = Vector2.ZERO
var _touch_points: Dictionary = {}    # index -> position, for pinch zoom
var _pinch_last_dist: float = -1.0

# --- Nodes --------------------------------------------------------------------
var camera: Camera3D
var camera_rig: Node3D
var road_root: Node3D
var traffic_root: Node3D
var building_root: Node3D
var zone_root: Node3D
var preview: MeshInstance3D
var status_label: Label
var stats_label: Label
var tool_buttons: Array[Button] = []
var zone_buttons: Array[Button] = []
var zone_bar: HBoxContainer

# Shared material cache to avoid allocating thousands of materials.
var _mat_cache: Dictionary = {}

# Loaded textures (see _load_textures).
var tex_asphalt: Texture2D
var tex_grass: Texture2D
var tex_water: Texture2D
var tex_facades: Array[Texture2D] = []


func _ready() -> void:
	randomize()
	_load_textures()
	_build_environment()
	_build_world()
	_build_ui()
	if not _load_city():
		_spawn_demo_city()
	_refresh_stats()
	_refresh_tool_buttons()


# --- Textures -----------------------------------------------------------------
func _load_textures() -> void:
	tex_asphalt = _load_tex("res://textures/asphalt.png")
	tex_grass = _load_tex("res://textures/grass.png")
	tex_water = _load_tex("res://textures/water.png")
	for path: String in [
		"res://textures/facade_residential.png",
		"res://textures/facade_commercial.png",
		"res://textures/facade_industrial.png",
	]:
		var t: Texture2D = _load_tex(path)
		if t != null:
			tex_facades.append(t)


func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


# --- Environment & world ------------------------------------------------------
func _build_environment() -> void:
	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#0d1520")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#b7c9dc")
	e.ambient_light_energy = 0.85
	e.fog_enabled = true
	e.fog_light_color = Color("#0d1520")
	e.fog_density = 0.0012
	env.environment = e
	add_child(env)

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	# Camera rig: a yaw pivot with a pitched camera, so panning/zooming/rotation
	# are all easy to reason about.
	camera_rig = Node3D.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)

	camera = Camera3D.new()
	camera.current = true
	camera.fov = 50.0
	camera_rig.add_child(camera)
	_update_camera()


func _build_world() -> void:
	var world_root: Node3D = Node3D.new()
	world_root.name = "World"
	add_child(world_root)

	road_root = Node3D.new()
	road_root.name = "RoadNetwork"
	world_root.add_child(road_root)

	traffic_root = Node3D.new()
	traffic_root.name = "Traffic"
	world_root.add_child(traffic_root)

	building_root = Node3D.new()
	building_root.name = "Buildings"
	world_root.add_child(building_root)

	zone_root = Node3D.new()
	zone_root.name = "Zones"
	world_root.add_child(zone_root)

	var ground: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(WORLD_EXTENT * 2.4, WORLD_EXTENT * 2.4)
	ground.mesh = plane
	ground.position.y = -0.12
	ground.material_override = _textured_mat(tex_grass, Color("#3f6b4c"), 24.0)
	world_root.add_child(ground)

	_create_water(world_root)
	_create_grid(world_root)


func _create_water(parent: Node3D) -> void:
	var water: MeshInstance3D = MeshInstance3D.new()
	var mesh: PlaneMesh = PlaneMesh.new()
	mesh.size = Vector2(70.0, 150.0)
	water.mesh = mesh
	water.position = Vector3(96.0, -0.04, -5.0)
	var m: StandardMaterial3D = _textured_mat(tex_water, Color("#20546a"), 4.0)
	m.metallic = 0.2
	m.roughness = 0.35
	water.material_override = m
	parent.add_child(water)


func _create_grid(parent: Node3D) -> void:
	var grid: ImmediateMesh = ImmediateMesh.new()
	grid.surface_begin(Mesh.PRIMITIVE_LINES)
	var extent: float = WORLD_EXTENT
	var step: float = GRID_SIZE
	var x: float = -extent
	while x <= extent:
		grid.surface_add_vertex(Vector3(x, 0.005, -extent))
		grid.surface_add_vertex(Vector3(x, 0.005, extent))
		x += step
	var z: float = -extent
	while z <= extent:
		grid.surface_add_vertex(Vector3(-extent, 0.005, z))
		grid.surface_add_vertex(Vector3(extent, 0.005, z))
		z += step
	grid.surface_end()
	var lines: MeshInstance3D = MeshInstance3D.new()
	lines.mesh = grid
	lines.material_override = _mat(Color(0.34, 0.48, 0.40, 0.10))
	parent.add_child(lines)


func _spawn_demo_city() -> void:
	_create_road([Vector3(-76.0, ROAD_Y, 34.0), Vector3(-42.0, ROAD_Y, 27.0), Vector3(-10.0, ROAD_Y, 10.0), Vector3(22.0, ROAD_Y, -4.0), Vector3(60.0, ROAD_Y, -28.0)])
	_create_road([Vector3(-60.0, ROAD_Y, -48.0), Vector3(-32.0, ROAD_Y, -23.0), Vector3(0.0, ROAD_Y, 1.0), Vector3(30.0, ROAD_Y, 26.0), Vector3(67.0, ROAD_Y, 56.0)])
	var ring: Array[Vector3] = []
	for i: int in range(33):
		var angle: float = TAU * float(i) / 32.0
		ring.append(Vector3(cos(angle) * 25.0, ROAD_Y, sin(angle) * 25.0))
	_create_road(ring, true)

	# Seed a few mature zones so the city looks alive on first launch.
	var seeds: Array[Dictionary] = [
		{"p": Vector3(-56.0, 0.0, 8.0), "t": 0}, {"p": Vector3(-40.0, 0.0, -8.0), "t": 0},
		{"p": Vector3(-24.0, 0.0, 16.0), "t": 1}, {"p": Vector3(8.0, 0.0, -16.0), "t": 2},
		{"p": Vector3(40.0, 0.0, 8.0), "t": 1}, {"p": Vector3(48.0, 0.0, -16.0), "t": 2},
		{"p": Vector3(8.0, 0.0, 40.0), "t": 3}, {"p": Vector3(-64.0, 0.0, -40.0), "t": 0},
	]
	for s: Dictionary in seeds:
		_paint_zone(s["p"] as Vector3, s["t"] as int, true)

	for p: Vector3 in [Vector3(-4.0, 0.0, 42.0), Vector3(31.0, 0.0, 38.0), Vector3(-72.0, 0.0, -18.0), Vector3(58.0, 0.0, 30.0)]:
		_spawn_tree_cluster(p)


# --- Buildings ----------------------------------------------------------------
func _spawn_building_for_zone(zone: Dictionary) -> void:
	var type_idx: int = zone["type"] as int
	if type_idx == 3:
		# Parks get trees, not buildings.
		_spawn_tree_cluster(zone["pos"] as Vector3, 3.0)
		return
	var pos: Vector3 = zone["pos"] as Vector3
	var palettes: Array = [
		[Color("#aeb8c2"), Color("#8eabbc"), Color("#7f91a8")],  # residential
		[Color("#c7a77b"), Color("#e0c56b"), Color("#b58b65")],  # commercial
		[Color("#9a7d70"), Color("#7c8a92"), Color("#8a6f60")],  # industrial
	]
	var palette: Array = palettes[type_idx]
	var color: Color = palette[randi() % palette.size()]
	var height: float = randf_range(6.0, 20.0) if type_idx != 2 else randf_range(5.0, 9.0)
	var footprint: float = 6.4
	var size: Vector3 = Vector3(footprint, height, footprint)
	var facade: Texture2D = null
	if type_idx < tex_facades.size():
		facade = tex_facades[type_idx]
	var node: Node3D = _spawn_building(pos, size, color, facade)
	zone["building"] = node


func _spawn_building(pos: Vector3, size: Vector3, color: Color, facade: Texture2D = null) -> Node3D:
	var root: Node3D = Node3D.new()
	root.position = pos
	building_root.add_child(root)

	var body: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	body.mesh = box
	body.position.y = size.y * 0.5
	if facade != null:
		var fm: StandardMaterial3D = _textured_mat(facade, color, 1.0)
		# Repeat the facade roughly once per floor vertically.
		fm.uv1_scale = Vector3(1.0, maxf(1.0, round(size.y / 3.0)), 1.0)
		fm.albedo_color = Color.WHITE
		body.material_override = fm
	else:
		body.material_override = _mat(color)
	root.add_child(body)

	var roof: MeshInstance3D = MeshInstance3D.new()
	var roof_mesh: BoxMesh = BoxMesh.new()
	roof_mesh.size = Vector3(size.x * 0.92, 0.55, size.z * 0.92)
	roof.mesh = roof_mesh
	roof.position.y = size.y + 0.28
	roof.material_override = _mat(Color("#354452"))
	root.add_child(roof)

	# Floor bands add detail only when there is no facade texture supplying it.
	if facade == null:
		var floor_count: int = maxi(1, int(size.y / 3.0))
		for i: int in range(floor_count):
			var band: MeshInstance3D = MeshInstance3D.new()
			var bm: BoxMesh = BoxMesh.new()
			bm.size = Vector3(size.x * 1.01, 0.10, size.z * 0.92)
			band.mesh = bm
			band.position.y = 1.7 + float(i) * 3.0
			band.material_override = _mat(Color("#d7e1e5"))
			root.add_child(band)

	# Grow-in animation.
	root.scale = Vector3(1.0, 0.02, 1.0)
	var tween: Tween = create_tween()
	tween.tween_property(root, "scale", Vector3.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return root


func _spawn_tree_cluster(center: Vector3, count_scale: float = 8.0) -> void:
	var n: int = int(count_scale)
	for i: int in range(n):
		var angle: float = TAU * float(i) / float(maxi(1, n))
		var radius: float = 2.4 + float(i % 3) * 1.6
		var p: Vector3 = center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)

		var trunk: MeshInstance3D = MeshInstance3D.new()
		var cyl: CylinderMesh = CylinderMesh.new()
		cyl.height = 2.2
		cyl.top_radius = 0.18
		cyl.bottom_radius = 0.28
		trunk.mesh = cyl
		trunk.position = p + Vector3(0.0, 1.1, 0.0)
		trunk.material_override = _mat(Color("#5a4030"))
		building_root.add_child(trunk)

		var crown: MeshInstance3D = MeshInstance3D.new()
		var sph: SphereMesh = SphereMesh.new()
		sph.radius = 1.5
		sph.height = 2.8
		crown.mesh = sph
		crown.position = p + Vector3(0.0, 2.9, 0.0)
		crown.material_override = _mat(Color("#39714a"))
		building_root.add_child(crown)


# --- Roads --------------------------------------------------------------------
func _create_road(points: Array[Vector3], closed: bool = false) -> void:
	if points.size() < 2:
		return
	var curve: Curve3D = Curve3D.new()
	curve.bake_interval = 0.6
	curve.closed = closed
	for p: Vector3 in points:
		curve.add_point(p)

	var road_mesh_instance: MeshInstance3D = MeshInstance3D.new()
	road_mesh_instance.name = "Road"
	road_mesh_instance.mesh = _road_mesh(curve)
	road_mesh_instance.material_override = _textured_mat(tex_asphalt, Color("#3a3f45"), 1.0)
	road_root.add_child(road_mesh_instance)

	var lane: MeshInstance3D = MeshInstance3D.new()
	lane.mesh = _line_mesh(curve)
	lane.material_override = _mat(Color("#e6df9d"))
	road_root.add_child(lane)

	var length: float = curve.get_baked_length()
	var record: Dictionary = {"curve": curve, "length": length, "closed": closed, "points": points.duplicate()}
	roads.append(record)
	_spawn_car(record)
	if length > 40.0:
		_spawn_car(record)


func _road_mesh(curve: Curve3D) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length: float = curve.get_baked_length()
	var count: int = maxi(2, int(length / SAMPLE_STEP))
	# V runs along the road length so the asphalt repeats naturally; U spans the
	# road width. Scale V by road width to keep the texture roughly square.
	for i: int in range(count):
		var d0: float = length * float(i) / float(count)
		var d1: float = length * float(i + 1) / float(count)
		var v0: float = d0 / ROAD_WIDTH
		var v1: float = d1 / ROAD_WIDTH
		var p0: Vector3 = curve.sample_baked(d0)
		var p1: Vector3 = curve.sample_baked(d1)
		var dir: Vector3 = (p1 - p0).normalized()
		var side: Vector3 = Vector3(-dir.z, 0.0, dir.x)
		var a: Vector3 = p0 + side * ROAD_WIDTH * 0.5
		var b: Vector3 = p0 - side * ROAD_WIDTH * 0.5
		var c: Vector3 = p1 + side * ROAD_WIDTH * 0.5
		var d: Vector3 = p1 - side * ROAD_WIDTH * 0.5
		st.set_uv(Vector2(0.0, v0)); st.add_vertex(a)
		st.set_uv(Vector2(1.0, v0)); st.add_vertex(b)
		st.set_uv(Vector2(0.0, v1)); st.add_vertex(c)
		st.set_uv(Vector2(1.0, v0)); st.add_vertex(b)
		st.set_uv(Vector2(1.0, v1)); st.add_vertex(d)
		st.set_uv(Vector2(0.0, v1)); st.add_vertex(c)
	st.generate_normals()
	return st.commit()


func _line_mesh(curve: Curve3D) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length: float = curve.get_baked_length()
	var count: int = maxi(2, int(length / SAMPLE_STEP))
	for i: int in range(count):
		var d0: float = length * float(i) / float(count)
		var d1: float = length * float(i + 1) / float(count)
		var p0: Vector3 = curve.sample_baked(d0) + Vector3(0.0, 0.05, 0.0)
		var p1: Vector3 = curve.sample_baked(d1) + Vector3(0.0, 0.05, 0.0)
		var dir: Vector3 = (p1 - p0).normalized()
		var side: Vector3 = Vector3(-dir.z, 0.0, dir.x)
		var w: float = 0.09
		st.add_vertex(p0 + side * w); st.add_vertex(p0 - side * w); st.add_vertex(p1 + side * w)
		st.add_vertex(p0 - side * w); st.add_vertex(p1 - side * w); st.add_vertex(p1 + side * w)
	st.generate_normals()
	return st.commit()


func _spawn_car(road: Dictionary) -> void:
	var car: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(1.45, 0.7, 2.6)
	car.mesh = box
	var palette: Array[Color] = [Color("#e85c4a"), Color("#e4b63e"), Color("#5a9fe6"), Color("#eeeeee")]
	car.material_override = _mat(palette[randi() % palette.size()])
	car.set_meta("road", road)
	car.set_meta("distance", randf_range(0.0, float(road["length"])))
	car.set_meta("speed", randf_range(6.0, 11.0))
	traffic_root.add_child(car)


# --- Per-frame update ---------------------------------------------------------
func _process(delta: float) -> void:
	_update_cars(delta)
	if drawing and active_tool == Tool.ROAD:
		_update_preview()

	_economy_accum += delta
	if _economy_accum >= ECONOMY_INTERVAL:
		_economy_accum = 0.0
		_economy_tick()


func _economy_tick() -> void:
	var income: int = 0
	for key: String in zones:
		var z: Dictionary = zones[key]
		var t: Dictionary = ZONE_TYPES[z["type"] as int]
		income += t["income"] as int
	# Idle upkeep grows slightly with the road network.
	var upkeep: int = roads.size() * 3
	money = maxi(0, money + income - upkeep)
	_refresh_stats()


func _update_cars(delta: float) -> void:
	for node: Node in traffic_root.get_children():
		var car: MeshInstance3D = node as MeshInstance3D
		if car == null:
			continue
		var road_variant: Variant = car.get_meta("road")
		if not (road_variant is Dictionary):
			continue
		var road: Dictionary = road_variant as Dictionary
		var curve_variant: Variant = road.get("curve")
		if not (curve_variant is Curve3D):
			continue
		var curve: Curve3D = curve_variant as Curve3D
		var distance: float = float(car.get_meta("distance")) + float(car.get_meta("speed")) * delta
		var length: float = float(road["length"])
		if length <= 0.1:
			continue
		if distance >= length:
			distance = fmod(distance, length)
		var p: Vector3 = curve.sample_baked(distance)
		var ahead: Vector3 = curve.sample_baked(min(distance + 0.9, length))
		car.position = p + Vector3(0.0, 0.45, 0.0)
		if p.distance_to(ahead) > 0.001:
			car.look_at(Vector3(ahead.x, car.position.y, ahead.z), Vector3.UP)
		car.set_meta("distance", distance)


# --- Camera -------------------------------------------------------------------
func _update_camera() -> void:
	cam_zoom = clampf(cam_zoom, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM)
	cam_target.x = clampf(cam_target.x, -WORLD_EXTENT, WORLD_EXTENT)
	cam_target.z = clampf(cam_target.z, -WORLD_EXTENT, WORLD_EXTENT)
	camera_rig.position = cam_target
	camera_rig.rotation_degrees = Vector3(0.0, cam_yaw, 0.0)
	var pitch: float = deg_to_rad(CAMERA_PITCH_DEG)
	var back: float = cos(pitch) * cam_zoom
	var up: float = -sin(pitch) * cam_zoom
	camera.position = Vector3(0.0, up, back)
	camera.rotation_degrees = Vector3(CAMERA_PITCH_DEG, 0.0, 0.0)


func _pan_camera(screen_delta: Vector2) -> void:
	# Convert screen-space drag into world movement on the ground plane,
	# scaled by zoom so panning feels consistent at any distance.
	var scale: float = cam_zoom * 0.0016
	var yaw: float = deg_to_rad(cam_yaw)
	var forward: Vector3 = Vector3(sin(yaw), 0.0, cos(yaw))
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	cam_target += (-right * screen_delta.x + forward * screen_delta.y) * scale
	_update_camera()


# --- Input --------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_handle_key(event as InputEventKey)


func _handle_touch(touch: InputEventScreenTouch) -> void:
	if touch.pressed:
		_touch_points[touch.index] = touch.position
	else:
		_touch_points.erase(touch.index)
		_pinch_last_dist = -1.0

	if _touch_points.size() >= 2:
		# Two fingers -> stop drawing, pinch to zoom.
		if drawing:
			drawing = false
			current_points.clear()
			_clear_preview()
		return

	if touch.pressed:
		if active_tool == Tool.CAMERA:
			_panning = true
			_last_pan_pos = touch.position
		else:
			_start_action(touch.position)
	else:
		_panning = false
		_finish_action()


func _handle_drag(drag: InputEventScreenDrag) -> void:
	_touch_points[drag.index] = drag.position

	if _touch_points.size() >= 2:
		_handle_pinch()
		return

	if active_tool == Tool.CAMERA or _panning:
		_pan_camera(drag.relative)
	elif drawing:
		_add_draw_point(drag.position)


func _handle_pinch() -> void:
	var pts: Array = _touch_points.values()
	if pts.size() < 2:
		return
	var dist: float = (pts[0] as Vector2).distance_to(pts[1] as Vector2)
	if _pinch_last_dist > 0.0:
		var factor: float = _pinch_last_dist / maxf(1.0, dist)
		cam_zoom *= factor
		_update_camera()
	_pinch_last_dist = dist


func _handle_mouse_button(mouse: InputEventMouseButton) -> void:
	if mouse.button_index == MOUSE_BUTTON_WHEEL_UP:
		cam_zoom -= 6.0
		_update_camera()
	elif mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		cam_zoom += 6.0
		_update_camera()
	elif mouse.button_index == MOUSE_BUTTON_RIGHT or mouse.button_index == MOUSE_BUTTON_MIDDLE:
		# Right / middle mouse always pans the camera.
		_panning = mouse.pressed
		_last_pan_pos = mouse.position
	elif mouse.button_index == MOUSE_BUTTON_LEFT:
		if mouse.pressed:
			if active_tool == Tool.CAMERA:
				_panning = true
				_last_pan_pos = mouse.position
			else:
				_start_action(mouse.position)
		else:
			_panning = false
			_finish_action()


func _handle_mouse_motion(motion: InputEventMouseMotion) -> void:
	if _panning:
		_pan_camera(motion.relative)
	elif drawing:
		_add_draw_point(motion.position)


func _handle_key(key: InputEventKey) -> void:
	if not key.pressed:
		return
	match key.keycode:
		KEY_ESCAPE:
			drawing = false
			current_points.clear()
			_clear_preview()
		KEY_1:
			_select_tool(Tool.ROAD)
		KEY_2:
			_select_tool(Tool.ZONE)
		KEY_3:
			_select_tool(Tool.BULLDOZE)
		KEY_4:
			_select_tool(Tool.CAMERA)
		KEY_Q:
			cam_yaw += 15.0
			_update_camera()
		KEY_E:
			cam_yaw -= 15.0
			_update_camera()


# --- Actions ------------------------------------------------------------------
func _start_action(screen: Vector2) -> void:
	var p: Vector3 = _screen_to_ground(screen)
	match active_tool:
		Tool.ROAD:
			drawing = true
			current_points.clear()
			current_points.append(Vector3(p.x, ROAD_Y, p.z))
		Tool.ZONE:
			drawing = true
			_paint_zone(p, active_zone)
		Tool.BULLDOZE:
			drawing = true
			_bulldoze(p)


func _add_draw_point(screen: Vector2) -> void:
	var p: Vector3 = _screen_to_ground(screen)
	match active_tool:
		Tool.ZONE:
			_paint_zone(p, active_zone)
		Tool.BULLDOZE:
			_bulldoze(p)
		Tool.ROAD:
			if current_points.is_empty() or current_points[current_points.size() - 1].distance_to(p) > 1.0:
				current_points.append(Vector3(p.x, ROAD_Y, p.z))


func _finish_action() -> void:
	if not drawing:
		return
	drawing = false
	if active_tool == Tool.ROAD and current_points.size() >= 2:
		var cost: int = current_points.size() * 8
		if money >= cost:
			_create_road(current_points.duplicate())
			money -= cost
			status_label.text = "ДОРОГА ПОСТРОЕНА"
		else:
			status_label.text = "НЕ ХВАТАЕТ СРЕДСТВ"
		_refresh_stats()
	current_points.clear()
	_clear_preview()


func _paint_zone(p: Vector3, type_idx: int, force: bool = false) -> void:
	if p == Vector3.ZERO and not force:
		return
	var snapped: Vector3 = Vector3(round(p.x / GRID_SIZE) * GRID_SIZE, 0.02, round(p.z / GRID_SIZE) * GRID_SIZE)
	var key: String = "%d:%d" % [int(snapped.x), int(snapped.z)]
	if zones.has(key):
		return
	var type_def: Dictionary = ZONE_TYPES[type_idx]
	var cost: int = type_def["cost"] as int
	if not force and money < cost:
		status_label.text = "НЕ ХВАТАЕТ СРЕДСТВ"
		return

	var tile: MeshInstance3D = MeshInstance3D.new()
	tile.name = key
	var plane: BoxMesh = BoxMesh.new()
	plane.size = Vector3(7.4, 0.08, 7.4)
	tile.mesh = plane
	tile.position = snapped
	tile.material_override = _mat(type_def["color"] as Color)
	zone_root.add_child(tile)

	var zone: Dictionary = {"type": type_idx, "pos": snapped, "tile": tile, "building": null}
	zones[key] = zone
	population += type_def["people"] as int
	if not force:
		money = maxi(0, money - cost)
	_spawn_building_for_zone(zone)
	_refresh_stats()


func _bulldoze(p: Vector3) -> void:
	if p == Vector3.ZERO:
		return
	var snapped_x: int = int(round(p.x / GRID_SIZE) * GRID_SIZE)
	var snapped_z: int = int(round(p.z / GRID_SIZE) * GRID_SIZE)
	var key: String = "%d:%d" % [snapped_x, snapped_z]
	if zones.has(key):
		var zone: Dictionary = zones[key]
		var t: Dictionary = ZONE_TYPES[zone["type"] as int]
		population = maxi(0, population - (t["people"] as int))
		money += int((t["cost"] as int) * 0.4)
		var tile: Variant = zone.get("tile")
		if tile is Node:
			(tile as Node).queue_free()
		var building: Variant = zone.get("building")
		if building is Node:
			(building as Node).queue_free()
		zones.erase(key)
		status_label.text = "СНЕСЕНО"
		_refresh_stats()
		return

	# Otherwise remove the nearest road within reach.
	var best_idx: int = -1
	var best_dist: float = 9.0
	for i: int in range(roads.size()):
		var curve: Curve3D = roads[i]["curve"] as Curve3D
		var closest: Vector3 = curve.get_closest_point(Vector3(p.x, ROAD_Y, p.z))
		var d: float = closest.distance_to(Vector3(p.x, ROAD_Y, p.z))
		if d < best_dist:
			best_dist = d
			best_idx = i
	if best_idx >= 0:
		_remove_road(best_idx)
		status_label.text = "ДОРОГА СНЕСЕНА"
		money += 60
		_refresh_stats()


func _remove_road(idx: int) -> void:
	if idx < 0 or idx >= roads.size():
		return
	var road: Dictionary = roads[idx]
	# Road + its lane share consecutive slots; rebuild the whole road_root is
	# simplest and avoids index bookkeeping bugs. Cheap because meshes are light.
	roads.remove_at(idx)
	for c: Node in road_root.get_children():
		c.queue_free()
	for c: Node in traffic_root.get_children():
		c.queue_free()
	# Recreate meshes and cars for remaining roads.
	var remaining: Array[Dictionary] = roads.duplicate()
	roads.clear()
	for r: Dictionary in remaining:
		var pts: Array[Vector3] = []
		for v: Variant in r["points"]:
			pts.append(v as Vector3)
		_create_road(pts, r["closed"] as bool)


func _screen_to_ground(screen: Vector2) -> Vector3:
	var from: Vector3 = camera.project_ray_origin(screen)
	var dir: Vector3 = camera.project_ray_normal(screen)
	if absf(dir.y) < 0.001:
		return Vector3.ZERO
	var t: float = -from.y / dir.y
	if t < 0.0 or t > MAX_DRAW_DISTANCE:
		return Vector3.ZERO
	return from + dir * t


# --- Preview ------------------------------------------------------------------
func _update_preview() -> void:
	if current_points.size() < 2:
		return
	var mesh: ImmediateMesh = ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i: int in range(current_points.size() - 1):
		mesh.surface_add_vertex(current_points[i] + Vector3(0.0, 0.12, 0.0))
		mesh.surface_add_vertex(current_points[i + 1] + Vector3(0.0, 0.12, 0.0))
	mesh.surface_end()
	if preview == null:
		preview = MeshInstance3D.new()
		add_child(preview)
		preview.material_override = _mat(Color("#f4d35e"))
	preview.mesh = mesh


func _clear_preview() -> void:
	if preview != null:
		preview.mesh = null


# --- UI -----------------------------------------------------------------------
func _build_ui() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)

	# Top-left info panel (anchored to top-left, scales with content).
	var top: PanelContainer = PanelContainer.new()
	top.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.055, 0.075, 0.94), 18.0))
	top.position = Vector2(18.0, 18.0)
	layer.add_child(top)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	top.add_child(vb)

	var pad: MarginContainer = MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 22)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 14)
	top.remove_child(vb)
	pad.add_child(vb)
	top.add_child(pad)

	var title: Label = Label.new()
	title.text = "CITYFORGE"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#e9f0f6"))
	vb.add_child(title)

	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 17)
	stats_label.add_theme_color_override("font_color", Color("#a9c2d6"))
	vb.add_child(stats_label)

	# Status text (top-right).
	status_label = Label.new()
	status_label.text = "V0.6  •  СВОБОДНЫЕ ДОРОГИ"
	status_label.add_theme_font_size_override("font_size", 15)
	status_label.add_theme_color_override("font_color", Color("#8fb0c8"))
	status_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.offset_left = -360.0
	status_label.offset_top = 24.0
	status_label.offset_right = -22.0
	layer.add_child(status_label)

	# Zone-type selector bar (hidden unless the zone tool is active).
	zone_bar = HBoxContainer.new()
	zone_bar.add_theme_constant_override("separation", 8)
	zone_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	zone_bar.offset_left = 22.0
	zone_bar.offset_bottom = -96.0
	zone_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(zone_bar)
	for i: int in range(ZONE_TYPES.size()):
		var zt: Dictionary = ZONE_TYPES[i]
		var b: Button = _make_button(zt["name"] as String, Vector2.ZERO, Vector2(96.0, 46.0))
		b.toggle_mode = true
		var idx: int = i
		b.pressed.connect(func() -> void: _select_zone(idx))
		zone_buttons.append(b)
		zone_bar.add_child(b)
	zone_bar.visible = false

	# Main tool bar, anchored to the bottom-left, laid out in an HBox so it
	# adapts to any screen width.
	var bar: HBoxContainer = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = 22.0
	bar.offset_bottom = -22.0
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(bar)

	var defs: Array = [
		{"t": "🛣 ДОРОГИ", "tool": Tool.ROAD},
		{"t": "▦ ЗОНЫ", "tool": Tool.ZONE},
		{"t": "🧨 СНОС", "tool": Tool.BULLDOZE},
		{"t": "✥ КАМЕРА", "tool": Tool.CAMERA},
	]
	for d: Dictionary in defs:
		var btn: Button = _make_button(d["t"] as String, Vector2.ZERO, Vector2(150.0, 58.0))
		btn.toggle_mode = true
		var tool_id: int = d["tool"] as int
		btn.pressed.connect(func() -> void: _select_tool(tool_id))
		tool_buttons.append(btn)
		bar.add_child(btn)

	# Save button, bottom-right.
	var save_btn: Button = _make_button("💾 СОХРАНИТЬ", Vector2.ZERO, Vector2(180.0, 58.0))
	save_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	save_btn.offset_left = -202.0
	save_btn.offset_right = -22.0
	save_btn.offset_bottom = -22.0
	save_btn.offset_top = -80.0
	save_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	save_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	save_btn.pressed.connect(_save_city)
	layer.add_child(save_btn)


func _make_button(text: String, pos: Vector2, size: Vector2) -> Button:
	var button: Button = Button.new()
	button.text = text
	if pos != Vector2.ZERO:
		button.position = pos
	button.custom_minimum_size = size
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.09, 0.13, 0.18, 0.95), 12.0))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.14, 0.20, 0.27, 0.98), 12.0))
	button.add_theme_stylebox_override("pressed", _panel_style(Color(0.20, 0.42, 0.58, 1.0), 12.0))
	button.add_theme_color_override("font_color", Color("#cfe0ee"))
	return button


func _select_tool(tool_id: int) -> void:
	active_tool = tool_id
	drawing = false
	current_points.clear()
	_clear_preview()
	zone_bar.visible = tool_id == Tool.ZONE
	var names: Dictionary = {
		Tool.ROAD: "РЕЖИМ: ДОРОГИ",
		Tool.ZONE: "РЕЖИМ: ЗОНЫ",
		Tool.BULLDOZE: "РЕЖИМ: СНОС",
		Tool.CAMERA: "РЕЖИМ: КАМЕРА",
	}
	status_label.text = names.get(tool_id, "")
	_refresh_tool_buttons()


func _select_zone(idx: int) -> void:
	active_zone = idx
	active_tool = Tool.ZONE
	zone_bar.visible = true
	status_label.text = "ЗОНА: %s" % [ZONE_TYPES[idx]["name"]]
	_refresh_tool_buttons()
	for i: int in range(zone_buttons.size()):
		zone_buttons[i].button_pressed = i == idx


func _refresh_tool_buttons() -> void:
	for i: int in range(tool_buttons.size()):
		tool_buttons[i].button_pressed = i == active_tool


func _refresh_stats() -> void:
	if stats_label != null:
		stats_label.text = "НАСЕЛЕНИЕ  %s     КАЗНА  €%s     НАСТРОЕНИЕ  %d%%" % [
			_group_number(population), _group_number(money), happiness
		]


func _group_number(value: int) -> String:
	var s: String = String.num_int64(absi(value))
	var out: String = ""
	var count: int = 0
	for i: int in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = " " + out
	return ("-" if value < 0 else "") + out


func _panel_style(color: Color, radius: float) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = int(radius)
	style.corner_radius_top_right = int(radius)
	style.corner_radius_bottom_left = int(radius)
	style.corner_radius_bottom_right = int(radius)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style


func _mat(color: Color, roughness: float = 0.9) -> StandardMaterial3D:
	# Cache opaque materials by color; transparent ones need fresh instances so
	# their blend mode survives.
	var key: String = "%s_%.2f" % [color.to_html(true), roughness]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_cache[key] = material
	return material


func _textured_mat(tex: Texture2D, fallback: Color, uv_scale: float = 1.0) -> StandardMaterial3D:
	# Textured materials are unique instances (each may have a different UV
	# scale), so they are intentionally not cached.
	var material: StandardMaterial3D = StandardMaterial3D.new()
	if tex != null:
		material.albedo_texture = tex
		material.albedo_color = Color.WHITE
		material.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
	else:
		material.albedo_color = fallback
	material.roughness = 0.9
	return material


# --- Save / load --------------------------------------------------------------
func _save_city() -> void:
	var data: Dictionary = {
		"version": 6,
		"money": money,
		"population": population,
		"happiness": happiness,
		"roads": [],
		"zones": [],
	}
	for r: Dictionary in roads:
		var pts: Array = []
		for v: Variant in r["points"]:
			var p: Vector3 = v as Vector3
			pts.append([p.x, p.y, p.z])
		data["roads"].append({"points": pts, "closed": r["closed"]})
	for key: String in zones:
		var z: Dictionary = zones[key]
		var pos: Vector3 = z["pos"] as Vector3
		data["zones"].append({"type": z["type"], "x": pos.x, "z": pos.z})

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()
		status_label.text = "ГОРОД СОХРАНЁН"
	else:
		status_label.text = "ОШИБКА СОХРАНЕНИЯ"


func _load_city() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var data: Dictionary = parsed as Dictionary

	money = int(data.get("money", money))
	population = int(data.get("population", 0))
	happiness = int(data.get("happiness", happiness))

	for rv: Variant in data.get("roads", []):
		var r: Dictionary = rv as Dictionary
		var pts: Array[Vector3] = []
		for pv: Variant in r.get("points", []):
			var arr: Array = pv as Array
			pts.append(Vector3(arr[0], arr[1], arr[2]))
		if pts.size() >= 2:
			_create_road(pts, bool(r.get("closed", false)))

	for zv: Variant in data.get("zones", []):
		var z: Dictionary = zv as Dictionary
		var pos: Vector3 = Vector3(float(z.get("x", 0.0)), 0.0, float(z.get("z", 0.0)))
		_paint_zone(pos, int(z.get("type", 0)), true)

	# _paint_zone re-adds population; reset to the saved authoritative value.
	population = int(data.get("population", population))
	status_label.text = "ГОРОД ЗАГРУЖЕН"
	return true
