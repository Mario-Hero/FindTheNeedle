extends CanvasLayer

## 全部 UI：HUD（稻草数/关卡/FPS/用时/充能条/准星）、开场介绍、胜利面板、
## 暂停菜单（主面板/选关/设置）。由 main.gd 创建并调用 build()；
## 按钮回调通过 main 引用转回游戏逻辑。

var main: Node3D  # main.gd，用于按钮回调与读取 LEVELS 配置

var straw_label: Label
var level_label: Label
var fps_label: Label
var time_label: Label
var total_time_label: Label
var aircannon_bar: ProgressBar
var intro_overlay: Button
var win_overlay: ColorRect
var win_time_label: Label
var win_total_label: Label
var win_title: Label
var win_next_button: Button
var pause_overlay: ColorRect
var pause_main_box: VBoxContainer
var pause_level_box: VBoxContainer
var pause_settings_box: VBoxContainer
var render_scale_label: Label
var ui_font: SystemFont


func build() -> void:
	_setup_font()

	straw_label = _make_label(22)
	straw_label.position = Vector2(16, 12)
	straw_label.text = "剩余稻草: 0"
	add_child(straw_label)

	level_label = _make_label(22)
	level_label.position = Vector2(16, 44)
	level_label.modulate = Color(1.0, 0.9, 0.55)
	add_child(level_label)

	fps_label = _make_label(14)
	fps_label.position = Vector2(16, 78)
	fps_label.modulate = Color(1, 1, 1, 0.75)
	add_child(fps_label)

	# 右上角：本局用时
	time_label = _make_label(22)
	time_label.text = "用时 0.00 秒"
	time_label.modulate = Color(1.0, 0.9, 0.55)
	time_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN  # 数字变长时向左扩展，右边缘固定
	time_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	add_child(time_label)

	# 右上角第二行：总用时（顺序通关累计；重试/选关后隐藏）
	total_time_label = _make_label(18)
	total_time_label.text = "总用时 0.00 秒"
	total_time_label.modulate = Color(1.0, 0.78, 0.35)
	total_time_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	total_time_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	total_time_label.offset_top += 34.0
	total_time_label.offset_bottom += 34.0
	add_child(total_time_label)

	var hint := _make_label(16)
	hint.text = "WASD 移动 · 空格跳跃 · Shift 疾跑 · 左键移除稻草 · 右键空气炮 · 找到银色的针并点击即可获胜 · Esc 菜单 · F11 全屏"
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 20)
	add_child(hint)

	# 右下角：空气炮充能进度条
	aircannon_bar = ProgressBar.new()
	aircannon_bar.max_value = 1.0
	aircannon_bar.value = 1.0
	aircannon_bar.custom_minimum_size = Vector2(240, 18)
	aircannon_bar.show_percentage = false
	aircannon_bar.modulate.a = 0.5   # 满充能时半透明，正在充能时高亮
	aircannon_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 32)
	add_child(aircannon_bar)

	var cross := ColorRect.new()
	cross.color = Color(1, 1, 1, 0.85)
	cross.custom_minimum_size = Vector2(6, 6)
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	add_child(cross)

	_build_intro_overlay()
	_build_win_overlay()
	_build_pause_overlay()


func _setup_font() -> void:
	ui_font = SystemFont.new()
	ui_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "Noto Sans CJK SC"])


func _build_intro_overlay() -> void:
	intro_overlay = Button.new()
	intro_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	intro_overlay.visible = false
	intro_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	intro_overlay.flat = true   # 去掉按钮默认外观
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 0
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	intro_overlay.add_theme_stylebox_override("normal", sb)
	intro_overlay.add_theme_stylebox_override("hover", sb)
	intro_overlay.add_theme_stylebox_override("pressed", sb)
	intro_overlay.add_theme_stylebox_override("focus", sb)
	intro_overlay.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed:
			main._dismiss_intro()
	)
	add_child(intro_overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	intro_overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 22)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.custom_minimum_size = Vector2(720, 0)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	var title := _make_label(48)
	title.text = "大海捞针"
	title.modulate = Color(1.0, 0.85, 0.3)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title)

	var objective := _make_label(22)
	objective.text = "在稻草堆里找到那根银色的针\n左键点击稻草可以移除它\n右键发射空气炮把稻草吹开\n找到针并点击即可获胜"
	objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(objective)

	var controls := _make_label(16)
	controls.text = "WASD 移动　空格 跳跃　Shift 疾跑　Esc 菜单　F11 全屏"
	controls.modulate = Color(1, 1, 1, 0.8)
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(controls)

	var prompt := _make_label(20)
	prompt.text = "点击屏幕开始"
	prompt.modulate = Color(1.0, 0.85, 0.3, 0.9)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(prompt)


func _build_win_overlay() -> void:
	win_overlay = ColorRect.new()
	win_overlay.color = Color(0, 0, 0, 0.6)
	win_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win_overlay.visible = false
	win_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(win_overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	win_overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vbox)

	win_title = _make_label(42)
	win_title.text = "你找到针了！"
	win_title.modulate = Color(1.0, 0.85, 0.3)
	win_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(win_title)

	win_time_label = _make_label(20)
	win_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(win_time_label)

	# 通关面板第二行：总用时（本关用时已在上一行）
	win_total_label = _make_label(20)
	win_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_total_label.modulate = Color(1.0, 0.85, 0.3)
	vbox.add_child(win_total_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	vbox.add_child(row)

	win_next_button = _make_button("下一关", func() -> void: main._on_next_level())
	row.add_child(win_next_button)
	row.add_child(_make_button("重试本关", func() -> void: main._on_retry()))
	row.add_child(_make_button("退出游戏", func() -> void: get_tree().quit()))


func _build_pause_overlay() -> void:
	pause_overlay = ColorRect.new()
	pause_overlay.color = Color(0, 0, 0, 0.65)
	pause_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_overlay.visible = false
	pause_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(pause_overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vbox)

	var title := _make_label(38)
	title.text = "已暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint := _make_label(16)
	hint.text = "再按 Esc 返回游戏"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(hint)

	# 主菜单：重试 / 选关 / 设置 / 退出
	pause_main_box = VBoxContainer.new()
	pause_main_box.add_theme_constant_override("separation", 12)
	vbox.add_child(pause_main_box)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	pause_main_box.add_child(row)
	row.add_child(_make_button("重试", func() -> void: main._on_retry()))
	row.add_child(_make_button("选关", func() -> void: show_menu_section("levels")))
	row.add_child(_make_button("设置", func() -> void: show_menu_section("settings")))
	row.add_child(_make_button("退出", func() -> void: get_tree().quit()))

	# 选关面板：关卡按钮 + 返回
	pause_level_box = VBoxContainer.new()
	pause_level_box.add_theme_constant_override("separation", 12)
	pause_level_box.visible = false
	vbox.add_child(pause_level_box)

	var levels := HBoxContainer.new()
	levels.alignment = BoxContainer.ALIGNMENT_CENTER
	levels.add_theme_constant_override("separation", 16)
	pause_level_box.add_child(levels)
	for i in main.LEVELS.size():
		var idx: int = i
		levels.add_child(_make_button(main.LEVELS[i].name, func() -> void: main._on_select_level(idx)))

	var back := _make_button("返回", func() -> void: show_menu_section("main"))
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pause_level_box.add_child(back)

	# 设置面板：3D 渲染分辨率比例滑块（0.2~1.0，界面 UI 不受影响）
	pause_settings_box = VBoxContainer.new()
	pause_settings_box.add_theme_constant_override("separation", 12)
	pause_settings_box.visible = false
	vbox.add_child(pause_settings_box)

	render_scale_label = _make_label(20)
	render_scale_label.text = "渲染分辨率：%d%%" % roundi(get_viewport().scaling_3d_scale * 100.0)
	render_scale_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_settings_box.add_child(render_scale_label)

	var slider := HSlider.new()
	slider.min_value = 0.2
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = get_viewport().scaling_3d_scale
	slider.custom_minimum_size = Vector2(360, 32)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(main._on_render_scale_changed)
	pause_settings_box.add_child(slider)

	var settings_back := _make_button("返回", func() -> void: show_menu_section("main"))
	settings_back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pause_settings_box.add_child(settings_back)


## 暂停菜单分三块切换：main（主面板）/ levels（选关）/ settings（设置）
func show_menu_section(section: String) -> void:
	pause_main_box.visible = section == "main"
	pause_level_box.visible = section == "levels"
	pause_settings_box.visible = section == "settings"


func _make_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(130, 46)
	btn.add_theme_font_override("font", ui_font)
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(callback)
	return btn


func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_override("font", ui_font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 5)
	return label
