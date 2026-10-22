extends CharacterBody3D

## 第一人称玩家控制器：WASD 移动、鼠标视角、空格跳跃、Shift 疾跑。
## 玩家不可被其他物体推动或阻挡（碰撞只作用于地面/墙），
## 每帧主动把身体附近的稻草和针沿径向排开。

const LAYER_STRAW := 2
const LAYER_NEEDLE := 4
const LAYER_PLAYER := 8

const WALK_SPEED := 4.0
const SPRINT_SPEED := 7.5
const GROUND_ACCEL := 14.0
const AIR_ACCEL := 4.0
const JUMP_VELOCITY := 4.6
const GRAVITY := 12.5
const MOUSE_SENSITIVITY := 0.0022

# 排开查询用的胶囊（比身体略大一圈）
const PUSH_RADIUS := 0.32
const MAX_WAKE_PER_TICK := 8
const PUSH_HEIGHT := 1.75
const PUSH_BASE_IMPULSE := 0.0015   # 静止时的轻推
const PUSH_SPEED_SCALE := 0.0025    # 移动速度越快排开力越大

@onready var camera: Camera3D = $Camera3D

var _push_params := PhysicsShapeQueryParameters3D.new()


func _ready() -> void:
	_ensure_input_actions()
	_setup_push_query()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _setup_push_query() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = PUSH_RADIUS
	capsule.height = PUSH_HEIGHT
	_push_params.shape = capsule
	_push_params.collision_mask = LAYER_STRAW | LAYER_NEEDLE
	_push_params.collide_with_bodies = true   # Jolt 里冻结刚体默认不参与查询，必须显式打开


func _input(event: InputEvent) -> void:
	# 用 _input 而非 _unhandled_input：确保不被任何 UI 控件拦截
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.55, 1.55)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# 不移动时把碰撞层归零：稻草/针检测的是玩家层，层关掉后与它们完全零接触，
	# 稻草不会搁在玩家身上；一恢复输入立即还原，走动时重新排开稻草
	collision_layer = LAYER_PLAYER if input_dir.length_squared() > 0.01 else 0
	var direction := transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	if direction.length_squared() > 1.0:
		direction = direction.normalized()
	var target_speed := SPRINT_SPEED if Input.is_action_pressed("sprint") else WALK_SPEED
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL
	velocity.x = lerpf(velocity.x, direction.x * target_speed, accel * delta)
	velocity.z = lerpf(velocity.z, direction.z * target_speed, accel * delta)

	move_and_slide()
	_push_away_bodies()


## 只有玩家主动移动时才排开稻草：静止、以及松开按键后的减速阶段都不施力
func _push_away_bodies() -> void:
	if Input.get_vector("move_left", "move_right", "move_forward", "move_back").length_squared() < 0.01:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.5:
		return
	var center := global_position + Vector3(0, 0.85, 0)
	_push_params.transform = Transform3D(Basis(), center)
	var space := get_world_3d().direct_space_state
	var main := get_parent()
	var bodies: Array[RigidBody3D] = []
	for result in space.intersect_shape(_push_params, 512):
		var b := result.collider as RigidBody3D
		if b != null:
			bodies.append(b)
	# 只处理最近的若干根：整堆稻草互相接触，无限制唤醒会瞬间拖垮物理
	bodies.sort_custom(func(a: RigidBody3D, c: RigidBody3D) -> bool:
		return a.global_position.distance_squared_to(center) < c.global_position.distance_squared_to(center))
	for i in mini(bodies.size(), MAX_WAKE_PER_TICK):
		var body: RigidBody3D = bodies[i]
		# 交给 Main 统一解冻登记，否则 MultiMesh 视觉不会跟着动
		if main.has_method("wake_straw"):
			main.wake_straw(body)
		else:
			body.freeze = false
			body.sleeping = false
		var dir: Vector3 = body.global_position - center
		dir.y *= 0.4  # 以水平排开为主
		if dir.length_squared() < 0.0001:
			dir = Vector3(randf() - 0.5, 0.1, randf() - 0.5)
		dir = dir.normalized()
		# 已经动起来的稻草不再加速：否则持续推挤会像搅拌机一样把整堆稻草甩飞
		if body.linear_velocity.length_squared() < 0.2:
			body.apply_central_impulse(dir * (PUSH_BASE_IMPULSE + speed * PUSH_SPEED_SCALE))


func _ensure_input_actions() -> void:
	_add_action("move_forward", [KEY_W, KEY_UP])
	_add_action("move_back", [KEY_S, KEY_DOWN])
	_add_action("move_left", [KEY_A, KEY_LEFT])
	_add_action("move_right", [KEY_D, KEY_RIGHT])
	_add_action("jump", [KEY_SPACE])
	_add_action("sprint", [KEY_SHIFT])


func _add_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for key in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event(action, ev)
