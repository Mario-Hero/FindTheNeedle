extends Node3D

## 大海捞针 —— 在完全物理模拟的稻草堆里找到那根针。三关逐级加大。

# 三关配置：稻草数量与草堆半径递增
const LEVELS := [
	{"name": "第一关", "count": 1500, "radius": 0.26},
	{"name": "第二关", "count": 5000, "radius": 0.32},
	{"name": "第三关", "count": 10000, "radius": 0.36},
	{"name": "第四关", "count": 50000, "radius": 1.0},
]

const BOX_SIZE := Vector3(14.0, 3.0, 14.0)

const STRAW_RADIUS := 0.008
const STRAW_LENGTH := 0.15
const STRAW_MASS := 0.005
const NEEDLE_RADIUS := 0.012
const NEEDLE_LENGTH := 0.12
const NEEDLE_MASS := 0.03

const PILE_LAYER_HEIGHT := 0.022  # 交叉层叠层高：须大于稻草直径(0.016)，保证层间不重叠

const MAX_WAKE_PER_TICK := 250     # 每个物理帧最多唤醒的稻草数，防止一次扰动引发全堆苏醒

const HOLD_REPEAT_INTERVAL := 0.33  # 左键长按连发间隔：每秒 3 次
const AIRCANNON_COOLDOWN := 0.33    # 空气炮充能时间：发射后 0.33 秒内无法再次发射

const CONTAINER_INNER := 0.8   # 小盒子内径边长
const CONTAINER_HEIGHT := 0.3  # 小盒子墙高
const CONTAINER_WALL_T := 0.04 # 小盒子壁厚

# 空气炮（右键）：射线命中点处产生球形向外的冲量
const AIRCANNON_RADIUS := 0.25    # 作用半径（须小：草堆密度极高，半径大会一次唤醒上千根）
const AIRCANNON_IMPULSE := 0.056  # 中心最大冲量（稻草仅轻微移动）

const LAYER_WORLD := 1
const LAYER_STRAW := 2
const LAYER_NEEDLE := 4
const LAYER_PLAYER := 8

var level_index := 0
var pile_radius := 0.26
var straw_left := 0
var start_ticks := 0
var won := false
var paused_menu := false
var total_time := 0.0          # 各关用时之和（只在顺序通关时累计）
var total_time_valid := true   # 重试或选关后禁用总用时，防止靠反复重试刷新记录
var _menu_opened_ticks := 0

var player: CharacterBody3D
var player_cam: Camera3D
var pile_root: Node3D

var straw_mesh: CapsuleMesh
var straw_shape: CapsuleShape3D
var straw_material: StandardMaterial3D
var straw_materials: Array[StandardMaterial3D] = []  # 几种干草色材质变体，随机分配
var straw_bodies: Array[RigidBody3D] = []
var active_straw: Dictionary = {}  # 正在模拟（未冻结）的稻草下标；_freeze_settled 据此回收
var needle_mesh: CapsuleMesh
var needle_shape: CapsuleShape3D
var needle_material: StandardMaterial3D
var physics_material: PhysicsMaterial

const GameUI := preload("res://scripts/game_ui.gd")
var ui: GameUI
var fps_timer := 0.0
var _time_timer := 0.0
var _freeze_timer := 0.0
var mouse_captured := true  # 捕获意图标志，每帧据此重新断言鼠标模式
var _held_left := false
var _held_right := false
var _click_cooldown := 0.0      # 左键冷却，同时也是长按连发间隔 0.2s
var _aircannon_cooldown := 0.0  # 右键充能冷却 0.5s
var _last_click_pos := Vector2.ZERO


func _ready() -> void:
	randomize()
	# 暂停（开场介绍）时也要能响应 F11，必须始终处理输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_environment()
	_build_box()
	# _build_container()
	_setup_shared_resources()
	_build_player()
	_build_ui()
	_start_level(0)
	# 首关启动后先展示目标说明，点击继续才进入游戏
	_show_intro()
	_apply_capture()
	# 窗口初始化可能重置鼠标模式，进树后再兜底设一次
	call_deferred("_apply_capture")


## 展示开场介绍：暂停游戏、捕获鼠标隐藏，点击屏幕继续
func _show_intro() -> void:
	get_tree().paused = true
	_set_player_active(false)
	mouse_captured = false
	_apply_capture()
	ui.intro_overlay.visible = true


func _dismiss_intro() -> void:
	ui.intro_overlay.visible = false
	get_tree().paused = false
	_set_player_active(true)
	mouse_captured = true
	_apply_capture()


## 载入指定关卡：重建草堆、重置计时与玩家位置
func _start_level(idx: int) -> void:
	level_index = clampi(idx, 0, LEVELS.size() - 1)
	var cfg: Dictionary = LEVELS[level_index]
	straw_left = cfg.count
	pile_radius = cfg.radius
	won = false
	paused_menu = false
	_held_left = false
	_click_cooldown = 0.0
	_aircannon_cooldown = 0.0
	ui.pause_overlay.visible = false
	ui.win_overlay.visible = false
	ui.intro_overlay.visible = false
	get_tree().paused = false

	if pile_root != null and is_instance_valid(pile_root):
		pile_root.free()
	straw_bodies.clear()

	_build_pile()

	ui.level_label.text = "%s（稻草 %d 根）" % [cfg.name, cfg.count]
	ui.straw_label.text = "剩余稻草: %d" % straw_left
	ui.time_label.text = "用时 0.00 秒"
	_update_total_time_label()
	player.global_position = Vector3(0, 0.2, 2.2)
	player.rotation = Vector3.ZERO
	player_cam.rotation = Vector3.ZERO
	_set_player_active(true)
	start_ticks = Time.get_ticks_msec()
	mouse_captured = true
	_apply_capture()


func _set_player_active(active: bool) -> void:
	if player == null:
		return
	player.set_physics_process(active)
	player.set_process_input(active)


func _process(delta: float) -> void:
	fps_timer += delta
	if fps_timer >= 0.5:
		fps_timer = 0.0
		ui.fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	# 计时器：0.01 秒精度需高频刷新；暂停时冻结显示，胜利后停在最终用时
	_time_timer += delta
	if _time_timer >= 0.03:
		_time_timer = 0.0
		if not won and not paused_menu:
			ui.time_label.text = "用时 %.2f 秒" % _elapsed_seconds()
			# 总用时实时显示 = 已完成关卡用时之和 + 本关当前用时
			if total_time_valid:
				ui.total_time_label.text = "总用时 %.2f 秒" % (total_time + _elapsed_seconds())
	# 左键/空气炮充能冷却：暂停/胜利时不计时
	if not won and not paused_menu:
		_click_cooldown = maxf(0.0, _click_cooldown - delta)
		if _aircannon_cooldown > 0.0:
			_aircannon_cooldown = maxf(0.0, _aircannon_cooldown - delta)
			if ui.aircannon_bar != null:
				ui.aircannon_bar.value = 1.0 - _aircannon_cooldown / AIRCANNON_COOLDOWN
				ui.aircannon_bar.modulate.a = 1.0
		elif ui.aircannon_bar != null:
			ui.aircannon_bar.modulate.a = 0.5
	# 捕获意图为真但实际模式不符时（Windows 下启动瞬间偶发被重置），重新捕获
	if mouse_captured and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		_apply_capture()
	_update_hold_repeat(delta)


func _physics_process(_delta: float) -> void:
	_freeze_timer += _delta
	if _freeze_timer >= 0.1:
		_freeze_timer = 0.0
		_freeze_settled()


## 每 0.1 秒把引擎已睡着的活跃稻草转成冻结（静态体）：
## 零模拟开销，同时隔断接触岛，防止下一次扰动引发级联唤醒
func _freeze_settled() -> void:
	if active_straw.is_empty():
		return
	var done: Array = []
	for idx: int in active_straw:
		var body: RigidBody3D = straw_bodies[idx]
		if body == null or not is_instance_valid(body):
			done.append(idx)
			continue
		if body.freeze:
			done.append(idx)
			continue
		if body.sleeping:
			body.freeze = true
			done.append(idx)
	for idx in done:
		active_straw.erase(idx)


## 本局已用时长（秒），暂停时长在关闭菜单时已从 start_ticks 中扣除
func _elapsed_seconds() -> float:
	return (Time.get_ticks_msec() - start_ticks) / 1000.0


## 总用时只在顺序通关时累计；重试/选关后直接隐藏（不显示任何数值，杜绝刷新记录）
func _update_total_time_label() -> void:
	ui.total_time_label.visible = total_time_valid
	ui.total_time_label.text = "总用时 %.2f 秒" % total_time


func _disable_total_time() -> void:
	total_time_valid = false
	total_time = 0.0
	_update_total_time_label()


func _apply_capture() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE)


func _input(event: InputEvent) -> void:
	# F11 切换全屏：任何时候都可用
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		_toggle_fullscreen()
		get_viewport().set_input_as_handled()
		return
	# 开场介绍期间屏蔽游戏输入（但 F11 在前面已经处理完了）
	if ui.intro_overlay != null and ui.intro_overlay.visible:
		return
	# 用 _input 处理点击：不被任何 UI 控件/事件链拦截
	if event is InputEventMouseButton and event.pressed:
		if won or paused_menu:
			return
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			mouse_captured = true
			_apply_capture()
			return
		_last_click_pos = event.position
		if event.button_index == MOUSE_BUTTON_LEFT:
			_held_left = true
			# 冷却未就绪时禁止瞬时发射，长按期间冷却归零会自动再射
			if _click_cooldown <= 0.0:
				_handle_click(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_held_right = true
			# 充能未就绪时禁止瞬时发射，长按期间冷却到 0 会自动再射
			if _aircannon_cooldown <= 0.0:
				_fire_air_cannon(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_held_left = false
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_held_right = false
	elif event.is_action_pressed("ui_cancel"):
		_toggle_pause_menu()
		get_viewport().set_input_as_handled()


## 长按：冷却制，和右键完全一致——按下时若冷却归零就触发一次，之后冷却归零自动再触发
func _update_hold_repeat(delta: float) -> void:
	if won or paused_menu or Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		_held_left = false
		_held_right = false
		return
	# 左键长按：冷却一归零就再射一发
	if _held_left and _click_cooldown <= 0.0:
		_handle_click(_last_click_pos)
	# 右键长按：冷却一归零就再射一发
	if _held_right and _aircannon_cooldown <= 0.0:
		_fire_air_cannon(_last_click_pos)


# ---------------- 显示设置 ----------------

func _toggle_fullscreen() -> void:
	var win := get_window()
	if win.mode == Window.MODE_FULLSCREEN:
		win.mode = Window.MODE_WINDOWED
	else:
		win.mode = Window.MODE_FULLSCREEN


## 渲染分辨率比例（0.2~1.0）：直接改 3D 渲染缩放，界面保持清晰
func _on_render_scale_changed(value: float) -> void:
	get_viewport().scaling_3d_scale = value
	ui.render_scale_label.text = "渲染分辨率：%d%%" % roundi(value * 100.0)


# ---------------- 暂停菜单 ----------------

func _toggle_pause_menu() -> void:
	if won:
		return
	if paused_menu:
		_close_pause_menu()
	else:
		_open_pause_menu()


func _open_pause_menu() -> void:
	paused_menu = true
	_held_left = false
	_held_right = false
	_menu_opened_ticks = Time.get_ticks_msec()
	ui.show_menu_section("main")
	ui.pause_overlay.visible = true
	_set_player_active(false)
	mouse_captured = false
	_apply_capture()


func _close_pause_menu() -> void:
	paused_menu = false
	ui.pause_overlay.visible = false
	_set_player_active(true)
	# 菜单不计入通关用时
	start_ticks += Time.get_ticks_msec() - _menu_opened_ticks
	mouse_captured = true
	_apply_capture()


# ---------------- 点击交互 ----------------

func _handle_click(screen_pos: Vector2) -> void:
	if _click_cooldown > 0.0:
		return
	_click_cooldown = HOLD_REPEAT_INTERVAL
	var from := player_cam.project_ray_origin(screen_pos)
	var dir := player_cam.project_ray_normal(screen_pos)
	var max_dist := 800.0
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * max_dist)
	query.collision_mask = LAYER_WORLD | LAYER_STRAW | LAYER_NEEDLE
	query.hit_from_inside = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var target: Object = null
	if not hit.is_empty():
		var c: Object = hit.collider
		if c is RigidBody3D:
			target = c
		else:
			max_dist = maxf(from.distance_to(hit.position) - 0.05, 0.0)
	if target == null:
		target = _forgiving_pick(from, dir, max_dist)
	if target == null:
		return
	var body := target as RigidBody3D
	if not is_instance_valid(body):
		return
	if body.is_in_group("needle"):
		_win()
	elif body.is_in_group("straw"):
		var mm_idx: int = body.get_meta("mm", -1)
		if mm_idx >= 0 and straw_bodies[mm_idx] == null:
			return  # 已被标记移除，跳过
		else:
			_remove_straw(body)


## 稻草只有 8mm 粗，纯射线很难点中：沿视线做细球扫掠，允许约 6cm 的瞄准误差
func _forgiving_pick(from: Vector3, dir: Vector3, max_dist: float) -> Object:
	if max_dist <= 0.0:
		return null
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.06
	params.shape = sphere
	params.transform = Transform3D(Basis(), from)
	params.motion = dir * max_dist
	params.collision_mask = LAYER_STRAW | LAYER_NEEDLE
	params.collide_with_bodies = true
	var fractions := space.cast_motion(params)
	if fractions.is_empty() or fractions[0] >= 1.0:
		return null
	var contact := from + dir * max_dist * fractions[0]
	params.transform = Transform3D(Basis(), contact)
	params.motion = Vector3.ZERO
	var best: Object = null
	var best_d := INF
	for result in space.intersect_shape(params, 16):
		var body := result.collider as RigidBody3D
		if body == null:
			continue
		var d: float = from.distance_to(body.global_position)
		if d < best_d:
			best_d = d
			best = body
	return best


## 右键空气炮：射线命中点处产生球形向外的力，把附近稻草轻微吹开；发射后进入充能
func _fire_air_cannon(screen_pos: Vector2) -> void:
	var from := player_cam.project_ray_origin(screen_pos)
	var dir := player_cam.project_ray_normal(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 600.0)
	query.collision_mask = LAYER_WORLD | LAYER_STRAW | LAYER_NEEDLE
	query.hit_from_inside = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var center: Vector3 = hit.position
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = AIRCANNON_RADIUS
	params.shape = sphere
	params.transform = Transform3D(Basis(), center)
	params.collision_mask = LAYER_STRAW | LAYER_NEEDLE
	params.collide_with_bodies = true
	var bodies: Array[RigidBody3D] = []
	for result in get_world_3d().direct_space_state.intersect_shape(params, 512):
		var b := result.collider as RigidBody3D
		if b != null:
			bodies.append(b)
	# 只唤醒最近的若干根：草堆密度极高，不设上限会整堆苏醒
	bodies.sort_custom(func(a: RigidBody3D, b: RigidBody3D) -> bool:
		return a.global_position.distance_squared_to(center) < b.global_position.distance_squared_to(center))
	for i in mini(bodies.size(), MAX_WAKE_PER_TICK):
		var body: RigidBody3D = bodies[i]
		wake_straw(body)
		var offset: Vector3 = body.global_position - center
		var dist := offset.length()
		if dist < 0.001:
			offset = Vector3(randf() - 0.5, 0.5, randf() - 0.5)
			dist = offset.length()
		# 冲量随距离线性衰减：中心最强，边缘为零
		var falloff := 1.0 - clampf(dist / AIRCANNON_RADIUS, 0.0, 1.0)
		body.apply_central_impulse(offset / dist * AIRCANNON_IMPULSE * falloff)
	# 发射即进入充能冷却，防止人手快速连点把物理拖垮
	_aircannon_cooldown = AIRCANNON_COOLDOWN
	if ui.aircannon_bar != null:
		ui.aircannon_bar.value = 0.0
		ui.aircannon_bar.modulate.a = 1.0


func _remove_straw(body: RigidBody3D) -> void:
	_wake_nearby(body.global_position, 0.12)
	straw_left -= 1
	ui.straw_label.text = "剩余稻草: %d" % straw_left
	# 从索引表移除（queue_free 会连同 MeshInstance 一起释放）
	var idx: int = body.get_meta("mm", -1)
	if idx >= 0:
		active_straw.erase(idx)
		straw_bodies[idx] = null
	body.queue_free()


## 移除稻草后唤醒周围刚体，让它们塌进空缺里
func _wake_nearby(pos: Vector3, radius: float) -> void:
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	params.shape = sphere
	params.transform = Transform3D(Basis(), pos)
	params.collision_mask = LAYER_STRAW | LAYER_NEEDLE
	params.collide_with_bodies = true
	var space_state := get_world_3d().direct_space_state
	var bodies: Array[RigidBody3D] = []
	for result in space_state.intersect_shape(params, 256):
		var b := result.collider as RigidBody3D
		if b != null:
			bodies.append(b)
	
	bodies.sort_custom(func(a: RigidBody3D, b: RigidBody3D) -> bool:
		return a.global_position.distance_squared_to(pos) < b.global_position.distance_squared_to(pos))
	for i in mini(bodies.size(), MAX_WAKE_PER_TICK):
		wake_straw(bodies[i])


func _win() -> void:
	won = true
	_held_left = false
	_held_right = false
	var elapsed: float = _elapsed_seconds()
	var cfg: Dictionary = LEVELS[level_index]
	ui.win_time_label.text = "本关用时 %.2f 秒 · 移除 %d 根稻草" % [elapsed, cfg.count - straw_left]
	ui.time_label.text = "用时 %.2f 秒" % elapsed
	# 总用时 = 已完成关卡的用时之和，通关这一刻把本关用时累加进去
	if total_time_valid:
		total_time += elapsed
		_update_total_time_label()
		ui.win_total_label.visible = true
		ui.win_total_label.text = "总用时 %.2f 秒" % total_time
	else:
		ui.win_total_label.visible = false
	var is_last := level_index >= LEVELS.size() - 1
	ui.win_title.text = "全部通关！" if is_last else "你找到针了！"
	ui.win_next_button.visible = not is_last
	ui.win_overlay.visible = true
	_set_player_active(false)
	mouse_captured = false
	_apply_capture()


func _on_retry() -> void:
	# 重试会让本局成绩作废：禁用总用时显示
	_disable_total_time()
	_start_level(level_index)


func _on_select_level(idx: int) -> void:
	# 跳关同样视为非顺序通关：禁用总用时显示
	_disable_total_time()
	_start_level(idx)


func _on_next_level() -> void:
	_start_level(level_index + 1)


# ---------------- 场景搭建 ----------------

func _setup_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.75, 0.82, 0.9)
	sky_mat.ground_bottom_color = Color(0.3, 0.28, 0.25)
	sky_mat.ground_horizon_color = Color(0.7, 0.72, 0.7)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -30.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = false
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)


func _build_box() -> void:
	var wall_color := Color(0.42, 0.3, 0.19)
	var t := 0.3
	var w := BOX_SIZE.x
	var d := BOX_SIZE.z
	var h := BOX_SIZE.y
	# 地板
	_add_static_box(Vector3(0, -0.1, 0), Vector3(w + 2 * t, 0.2, d + 2 * t), Color(0.5, 0.37, 0.24))
	# 四面围墙（顶部开放）
	_add_static_box(Vector3(0, h * 0.5, -d * 0.5 - t * 0.5), Vector3(w + 2 * t, h, t), wall_color)
	_add_static_box(Vector3(0, h * 0.5, d * 0.5 + t * 0.5), Vector3(w + 2 * t, h, t), wall_color)
	_add_static_box(Vector3(-w * 0.5 - t * 0.5, h * 0.5, 0), Vector3(t, h, d), wall_color)
	_add_static_box(Vector3(w * 0.5 + t * 0.5, h * 0.5, 0), Vector3(t, h, d), wall_color)


## 边长 0.8 的敞口小盒子（四壁无盖），稻草堆和针都放在里面
func _build_container() -> void:
	var c := Color(0.55, 0.38, 0.2)
	var inner := CONTAINER_INNER
	var h := CONTAINER_HEIGHT
	var t := CONTAINER_WALL_T
	var half := inner * 0.5
	_add_static_box(Vector3(0, h * 0.5, -half - t * 0.5), Vector3(inner + 2 * t, h, t), c)
	_add_static_box(Vector3(0, h * 0.5, half + t * 0.5), Vector3(inner + 2 * t, h, t), c)
	_add_static_box(Vector3(-half - t * 0.5, h * 0.5, 0), Vector3(t, h, inner), c)
	_add_static_box(Vector3(half + t * 0.5, h * 0.5, 0), Vector3(t, h, inner), c)


func _add_static_box(center: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.position = center
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)


func _setup_shared_resources() -> void:
	physics_material = PhysicsMaterial.new()
	physics_material.friction = 5.0  # 高摩擦：稻草落在堆上/地上不滑
	physics_material.bounce = 0.0    # 零弹性：杜绝接触抖动，利于整岛尽快入睡

	straw_mesh = CapsuleMesh.new()
	straw_mesh.radius = STRAW_RADIUS
	straw_mesh.height = STRAW_LENGTH
	straw_mesh.radial_segments = 6
	straw_mesh.rings = 2
	straw_shape = CapsuleShape3D.new()
	straw_shape.radius = STRAW_RADIUS
	straw_shape.height = STRAW_LENGTH
	# 每根稻草自带 MeshInstance，用几个共享材质变体随机上色，保持干草色差
	straw_material = StandardMaterial3D.new()
	straw_material.roughness = 0.9
	straw_materials = []
	for shade: Color in [Color(0.496, 0.412, 0.141), Color(0.37, 0.306, 0.103), Color(0.315, 0.243, 0.065), Color(0.343, 0.284, 0.092)]:
		var m := StandardMaterial3D.new()
		m.albedo_color = shade
		m.roughness = 0.9
		straw_materials.append(m)

	needle_mesh = CapsuleMesh.new()
	needle_mesh.radius = NEEDLE_RADIUS
	needle_mesh.height = NEEDLE_LENGTH
	needle_mesh.radial_segments = 8
	needle_mesh.rings = 2
	needle_shape = CapsuleShape3D.new()
	needle_shape.radius = NEEDLE_RADIUS
	needle_shape.height = NEEDLE_LENGTH
	needle_material = StandardMaterial3D.new()
	needle_material.albedo_color = Color(0.78, 0.8, 0.84)
	needle_material.metallic = 1.0
	needle_material.roughness = 0.25


## 十字交叉层叠铺设稻草堆：相邻层互相垂直，同层砖缝错开，
## 保证初始摆放零重叠，全部休眠，性能稳定。
func _build_pile() -> void:
	pile_root = Node3D.new()
	pile_root.name = "HayPile"
	add_child(pile_root)

	var placed := 0
	var layer_idx := 0
	var y := STRAW_RADIUS
	var needle_y := -1.0
	var needle_along_x := true
	var along_step := STRAW_LENGTH + 0.01  # 稻草轴向间距（留端缝）
	var cross_step := 0.022                # 垂直稻草方向的行距：须大于直径(0.016)，保证同层不重叠
	var half_len_offset := along_step * 0.5

	# 先算出每层能放多少根，由此确定总层数与堆高，用来随机针的高度
	var per_layer := _layer_capacity(along_step, cross_step, half_len_offset)
	var total_layers := maxi(1, ceili(float(straw_left) / float(per_layer)))
	# 针的高度随机落在整堆高度的 1/5 ~ 4/5 之间
	var target_frac := randf_range(0.2, 0.8)
	var target_layer := clampi(int(round(target_frac * float(total_layers - 1))), 0, total_layers - 1)

	while placed < straw_left:
		var along_x := (layer_idx % 2) == 0
		if layer_idx == target_layer and needle_y < 0.0:
			needle_y = y
			needle_along_x = along_x
		var row := 0
		var b := -pile_radius
		while b <= pile_radius:
			var a := -pile_radius + (half_len_offset if row % 2 == 0 else 0.0)
			while a <= pile_radius:
				var x := a if along_x else b
				var z := b if along_x else a
				var edge := pile_radius + STRAW_LENGTH * 0.5
				if placed < straw_left and x * x + z * z <= edge * edge:
					# 密铺下容错极小：位置/旋转抖动必须远小于层间缝隙，否则出生即重叠
					var pos := Vector3(x + randf_range(-0.0005, 0.0005), y + randf_range(-0.0005, 0.0005), z + randf_range(-0.0005, 0.0005))
					var flat := Basis(Vector3.BACK, PI / 2.0) if along_x else Basis(Vector3.RIGHT, PI / 2.0)
					var basis := flat.rotated(Vector3.UP, randf_range(-0.005, 0.005))
					var tilt_axis := Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
					basis = basis.rotated(tilt_axis, randf_range(-0.005, 0.005))
					_spawn_straw(pile_root, pos, basis)
					placed += 1
				a += along_step
			b += cross_step
			row += 1
		y += PILE_LAYER_HEIGHT
		layer_idx += 1

	# 把针埋进稻草堆中部：放在层顶而非嵌入层内，避免与稻草出生重叠
	if needle_y < 0.0:
		needle_y = y
	var angle := randf() * TAU
	var r := randf_range(0.0, pile_radius * 0.55)  # 保持在草堆内
	var needle_pos := Vector3(cos(angle) * r, needle_y + STRAW_RADIUS + NEEDLE_RADIUS + 0.001, sin(angle) * r)
	var needle_flat := Basis(Vector3.BACK, PI / 2.0) if needle_along_x else Basis(Vector3.RIGHT, PI / 2.0)
	var needle_basis := needle_flat.rotated(Vector3.UP, randf_range(-0.005, 0.005))
	_spawn_capsule(pile_root, needle_pos, needle_basis, needle_mesh, needle_shape, needle_material, LAYER_NEEDLE, "needle", NEEDLE_MASS)


## 一层稻草能铺下的根数（与铺设循环同规则，用于推算总层数与堆高）
func _layer_capacity(along_step: float, cross_step: float, half_len_offset: float) -> int:
	var edge := pile_radius + STRAW_LENGTH * 0.5
	var count := 0
	var row := 0
	var b := -pile_radius
	while b <= pile_radius:
		var a := -pile_radius + (half_len_offset if row % 2 == 0 else 0.0)
		while a <= pile_radius:
			if a * a + b * b <= edge * edge:
				count += 1
			a += along_step
		b += cross_step
		row += 1
	return count


## 稻草刚体自带 MeshInstance3D：视觉随物理体自动更新，无需手动同步
func _spawn_straw(parent: Node3D, pos: Vector3, basis: Basis) -> void:
	var body := RigidBody3D.new()
	body.transform = Transform3D(basis, pos)
	body.mass = STRAW_MASS
	body.collision_layer = LAYER_STRAW
	body.collision_mask = LAYER_WORLD | LAYER_STRAW | LAYER_NEEDLE | LAYER_PLAYER
	body.physics_material_override = physics_material
	body.linear_damp = 2.0    # 较大线性阻尼：被推动的稻草很快减速停下
	body.angular_damp = 8.0   # 较大角阻尼：滚动/翻滚迅速衰减
	body.add_to_group("straw")
	var cs := CollisionShape3D.new()
	cs.shape = straw_shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = straw_mesh
	mi.material_override = straw_materials[randi() % straw_materials.size()]
	body.add_child(mi)
	parent.add_child(body)

	var idx := straw_bodies.size()
	straw_bodies.append(body)
	body.set_meta("mm", idx)
	body.freeze = true  # 冻结=静态化，零模拟开销且出生必定生效；被触碰时解冻


func _spawn_capsule(parent: Node3D, pos: Vector3, basis: Basis, mesh: Mesh, shape: Shape3D, mat: Material, layer: int, group: String, mass: float) -> void:
	var body := RigidBody3D.new()
	body.transform = Transform3D(basis, pos)
	body.mass = mass
	body.collision_layer = layer
	body.collision_mask = LAYER_WORLD | LAYER_STRAW | LAYER_NEEDLE | LAYER_PLAYER
	body.physics_material_override = physics_material
	body.linear_damp = 0.1
	body.angular_damp = 0.4
	body.add_to_group(group)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	parent.add_child(body)
	body.freeze = true


## 解冻一根稻草并登记为活跃（_freeze_settled 据此冻结；所有唤醒都必须走这里）
func wake_straw(body: RigidBody3D) -> void:
	if body.freeze:
		body.freeze = false
	if body.sleeping:
		body.sleeping = false
	if body.is_in_group("straw"):
		active_straw[int(body.get_meta("mm", -1))] = true


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.name = "Player"
	player.collision_layer = LAYER_PLAYER
	player.collision_mask = LAYER_WORLD  # 只与地面/墙碰撞；稻草和针由玩家主动排开，不会阻挡玩家
	var cs := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.7
	cs.shape = capsule
	cs.position = Vector3(0, 0.85, 0)
	player.add_child(cs)
	player_cam = Camera3D.new()
	player_cam.name = "Camera3D"  # 代码创建的节点必须显式命名，$Camera3D 才能解析
	player_cam.position = Vector3(0, 1.55, 0)
	player_cam.fov = 75.0
	player.add_child(player_cam)
	player.position = Vector3(0, 0.2, 2.2)  # 出生在 0.8 小盒子正前方
	player.set_script(load("res://scripts/player.gd"))
	add_child(player)


## UI 已拆分到 game_ui.gd：创建、挂载并构建全部界面
func _build_ui() -> void:
	ui = GameUI.new()
	ui.main = self
	add_child(ui)
	ui.build()
