extends Node
class_name BenchmarkRoute

## 固定路線效能測試
## - 按 UI 左下角的「Run Benchmark」或鍵盤 B 開始；跑的時候再按一次會中止
## - 相機沿固定路線以固定速度移動（總時長固定，與 FPS 無關），最後回到原點
## - 結束後把玩家放回原點，並顯示 Avg FPS / 1% Low / 0.1% Low / 幀時間等
## - 每次結果會存到 user://benchmarks/（逐幀 CSV + summary.csv 彙總）
##
## 自訂路線（可選）：
##   F7 = 在玩家目前位置加一個路線點（第一點就是原點）
##   F8 = 存成 user://benchmark_route.json，之後就用這條路線
##   F9 = 刪除自訂路線，回到內建路線

@export var run_button: Button
@export var result_panel: Control
@export var result_label: Label
@export var copy_button: Button
@export var close_button: Button
@export var result_separator: Control

@export_category("Route")
@export var speed: float = 3.5            ## 公尺/秒
@export var eye_height: float = 1.65
@export var warmup_time: float = 1.5      ## 開跑前在原點停留的秒數（不計入統計）
@export var look_ahead: float = 6.0       ## 相機看向路線前方幾公尺
@export var turn_smoothing: float = 3.5   ## 轉頭平滑度，越大轉越快
## 地面座標 (y=0)。第一點 = 原點，路線會自動接回第一點形成迴圈。
@export var waypoints: PackedVector3Array = PackedVector3Array([
	Vector3(-3.0, 0, 5.1),      # 原點（玩家出生點）
	Vector3(-1.5, 0, -4.0),     # 往南走主街
	Vector3(1.0, 0, -12.5),
	Vector3(0.0, 0, -25.0),
	Vector3(-1.0, 0, -39.0),
	Vector3(-3.0, 0, -51.0),
	Vector3(-9.0, 0, -59.0),    # 南端廣場繞一圈
	Vector3(-3.0, 0, -63.5),
	Vector3(3.0, 0, -59.0),
	Vector3(2.0, 0, -48.0),     # 走回北邊
	Vector3(0.5, 0, -32.0),
	Vector3(1.0, 0, -18.0),
	Vector3(-1.5, 0, -5.0),
	Vector3(-9.0, 0, 0.5),      # 轉進西側街道
	Vector3(-25.0, 0, 2.0),
	Vector3(-35.0, 0, 2.0),
	Vector3(-37.0, 0, -0.5),
	Vector3(-25.0, 0, -0.5),    # 折返
	Vector3(-12.0, 0, 1.5),
	Vector3(-7.0, 0, 9.0),      # 往北邊小廣場
	Vector3(-6.0, 0, 15.0),
	Vector3(-3.5, 0, 10.0),     # 回原點
])

const CUSTOM_ROUTE_PATH := "user://benchmark_route.json"
const RESULT_DIR := "user://benchmarks"

enum State { IDLE, WARMUP, RUNNING }

var state := State.IDLE
var player: Node3D
var player_camera: Camera3D
var bench_camera: Camera3D
var curve: Curve3D
var route_length := 0.0
var route_points: PackedVector3Array

var frame_times_ms := PackedFloat32Array()
var start_usec := 0
var last_usec := 0
var warmup_end_usec := 0
var live_fps_accum := 0.0
var live_fps_frames := 0
var live_fps_text := ""
var last_report := ""

var player_prev_process_mode := Node.PROCESS_MODE_INHERIT
var player_prev_visible := true
var recorded_points := PackedVector3Array()


func _ready() -> void:
	if run_button:
		run_button.pressed.connect(_on_run_pressed)
	if copy_button:
		copy_button.pressed.connect(func(): DisplayServer.clipboard_set(last_report))
	if close_button:
		close_button.pressed.connect(_hide_results)
	_hide_results()

	bench_camera = Camera3D.new()
	bench_camera.name = "BenchmarkCamera"
	bench_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	bench_camera.top_level = true
	add_child(bench_camera)

	_load_custom_route()


func _find_player() -> void:
	if is_instance_valid(player):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	player = scene.get_node_or_null("Human-For-Scale") as Node3D
	if player == null:
		# 後備：找第一個 CharacterBody3D
		var found := scene.find_children("*", "CharacterBody3D", true, false)
		if found.size() > 0:
			player = found[0]
	if player:
		player_camera = player.get_node_or_null("CameraPivot/SpringArm/Camera") as Camera3D


# ---------------------------------------------------------------- 路線

func _active_points() -> PackedVector3Array:
	if recorded_points.size() >= 2:
		return recorded_points
	return waypoints


func _build_curve() -> void:
	var pts := _active_points().duplicate()
	pts.append(pts[0])  # 接回原點
	route_points = pts
	curve = Curve3D.new()
	curve.bake_interval = 0.1
	var n := pts.size()
	for i in n:
		var p := pts[i] + Vector3.UP * eye_height
		var prev := pts[i - 1] if i > 0 else pts[n - 2]  # 迴圈：起點的前一點 = 倒數第二點
		var next := pts[i + 1] if i < n - 1 else pts[1]
		# Catmull-Rom 轉成 Bezier 控制點，讓轉彎平滑
		var tangent := (next - prev) / 6.0
		curve.add_point(p, -tangent, tangent)
	route_length = curve.get_baked_length()


func _load_custom_route() -> void:
	if not FileAccess.file_exists(CUSTOM_ROUTE_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(CUSTOM_ROUTE_PATH))
	if typeof(data) != TYPE_ARRAY:
		return
	recorded_points = PackedVector3Array()
	for p in data:
		if typeof(p) == TYPE_ARRAY and p.size() >= 3:
			recorded_points.append(Vector3(p[0], p[1], p[2]))
	print("[Benchmark] Loaded custom route with %d points" % recorded_points.size())


func _save_custom_route() -> void:
	var arr := []
	for p in recorded_points:
		arr.append([p.x, p.y, p.z])
	var f := FileAccess.open(CUSTOM_ROUTE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(arr))
		f.close()
	print("[Benchmark] Saved %d points to %s" % [recorded_points.size(), ProjectSettings.globalize_path(CUSTOM_ROUTE_PATH)])


# ---------------------------------------------------------------- 流程

func _on_run_pressed() -> void:
	if state == State.IDLE:
		start_benchmark()
	else:
		stop_benchmark(true)


func start_benchmark() -> void:
	_find_player()
	_build_curve()
	if route_length < 1.0:
		push_warning("[Benchmark] Route too short")
		return

	# 停用玩家控制並隱藏模型
	if player:
		player_prev_process_mode = player.process_mode
		player_prev_visible = player.visible
		player.process_mode = Node.PROCESS_MODE_DISABLED
		player.visible = false

	# 複製玩家相機設定，讓畫面品質一致
	if player_camera:
		bench_camera.fov = player_camera.fov
		bench_camera.near = player_camera.near
		bench_camera.far = player_camera.far
		bench_camera.attributes = player_camera.attributes
		bench_camera.environment = player_camera.environment
		bench_camera.cull_mask = player_camera.cull_mask
	else:
		bench_camera.fov = 75.0

	var start_pos := curve.sample_baked(0.0)
	var look := curve.sample_baked(min(look_ahead, route_length))
	bench_camera.global_transform = Transform3D(_look_basis(start_pos, look, Basis.IDENTITY), start_pos)
	bench_camera.make_current()

	frame_times_ms = PackedFloat32Array()
	live_fps_accum = 0.0
	live_fps_frames = 0
	live_fps_text = ""
	state = State.WARMUP
	warmup_end_usec = Time.get_ticks_usec() + int(warmup_time * 1_000_000.0)
	if run_button:
		run_button.text = "Stop Benchmark"
	_show_results("Benchmark: warming up...")
	print("[Benchmark] Start. Route length %.1f m, expected %.1f s" % [route_length, route_length / speed])


func stop_benchmark(aborted: bool) -> void:
	var was_running := state == State.RUNNING
	state = State.IDLE
	if run_button:
		run_button.text = "Run Benchmark"

	# 玩家回到原點並恢復控制
	if player:
		var origin := route_points[0] if route_points.size() > 0 else player.global_position
		player.global_position = Vector3(origin.x, origin.y, origin.z)
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO
		player.process_mode = player_prev_process_mode
		player.visible = player_prev_visible
		player.reset_physics_interpolation()
	if player_camera:
		player_camera.make_current()

	if aborted or not was_running or frame_times_ms.size() < 10:
		_show_results("Benchmark aborted.")
		return
	_finish_report()


func _process(delta: float) -> void:
	if state == State.IDLE:
		return

	var now := Time.get_ticks_usec()

	if state == State.WARMUP:
		if now >= warmup_end_usec:
			state = State.RUNNING
			start_usec = now
			last_usec = now
		return

	# 記錄幀時間（實際牆鐘時間）
	var ft_ms := float(now - last_usec) / 1000.0
	last_usec = now
	if ft_ms > 0.0:
		frame_times_ms.append(ft_ms)

	var elapsed := float(now - start_usec) / 1_000_000.0
	var offset := elapsed * speed
	if offset >= route_length:
		bench_camera.global_position = curve.sample_baked(route_length)
		stop_benchmark(false)
		return

	var pos := curve.sample_baked(offset)
	var target := curve.sample_baked(min(offset + look_ahead, route_length))
	if offset + look_ahead > route_length:
		# 接近終點時看向路線起點方向，避免方向退化
		target = curve.sample_baked(fmod(offset + look_ahead, route_length))
	var desired := _look_basis(pos, target, bench_camera.global_basis)
	var w := 1.0 - exp(-turn_smoothing * delta)
	var q := bench_camera.global_basis.get_rotation_quaternion().slerp(desired.get_rotation_quaternion(), w)
	bench_camera.global_transform = Transform3D(Basis(q), pos)

	# 即時顯示（每 0.25 秒更新）
	live_fps_accum += ft_ms
	live_fps_frames += 1
	if live_fps_accum >= 250.0:
		live_fps_text = "%.0f" % (1000.0 * live_fps_frames / live_fps_accum)
		live_fps_accum = 0.0
		live_fps_frames = 0
		_show_results("Benchmark running  %d%%\nFPS: %s" % [int(100.0 * offset / route_length), live_fps_text])


func _look_basis(from: Vector3, to: Vector3, fallback: Basis) -> Basis:
	var dir := to - from
	dir.y = 0.0  # 保持水平視角
	if dir.length() < 0.05:
		return fallback
	return Basis.looking_at(dir.normalized(), Vector3.UP)


# ---------------------------------------------------------------- 統計

func _finish_report() -> void:
	var count := frame_times_ms.size()
	var total_ms := 0.0
	for ft in frame_times_ms:
		total_ms += ft
	var sorted := frame_times_ms.duplicate()
	sorted.sort()  # 小 -> 大

	var avg_fps := 1000.0 * count / total_ms
	var avg_ft := total_ms / count
	var low1 := _low_fps(sorted, 0.01)
	var low01 := _low_fps(sorted, 0.001)
	var p99_ft := _percentile(sorted, 0.99)
	var p50_ft := _percentile(sorted, 0.50)
	var max_ft := sorted[count - 1]
	var min_ft := sorted[0]
	var stutters := 0
	for ft in frame_times_ms:
		if ft > p50_ft * 2.0:
			stutters += 1

	var vp := get_viewport()
	var scale_3d := vp.scaling_3d_scale
	var win := vp.get_visible_rect().size
	var gpu := RenderingServer.get_video_adapter_name()

	var lines := PackedStringArray()
	lines.append("=== Benchmark Result ===")
	lines.append("Avg FPS:      %.1f" % avg_fps)
	lines.append("1%% Low:       %.1f" % low1)
	lines.append("0.1%% Low:     %.1f" % low01)
	lines.append("Min FPS:      %.1f" % (1000.0 / max_ft))
	lines.append("Max FPS:      %.1f" % (1000.0 / min_ft))
	lines.append("Frame time:   avg %.2f / p50 %.2f / p99 %.2f / max %.2f ms" % [avg_ft, p50_ft, p99_ft, max_ft])
	lines.append("Stutters (>2x median): %d" % stutters)
	lines.append("Frames: %d   Duration: %.1f s" % [count, total_ms / 1000.0])
	lines.append("Viewport: %dx%d  3D scale: %.2f" % [int(win.x), int(win.y), scale_3d])
	lines.append("GPU: %s" % gpu)
	lines.append("Godot %s" % Engine.get_version_info().string)
	var saved := _save_results(avg_fps, low1, low01, avg_ft, p99_ft, max_ft, count, total_ms)
	if saved != "":
		lines.append("Saved: %s" % saved)

	last_report = "\n".join(lines)
	print(last_report)
	_show_results(last_report)


func _low_fps(sorted_asc: PackedFloat32Array, fraction: float) -> float:
	# 「x% low」= 最慢的 x% 幀的平均幀時間換算成 FPS
	var n := sorted_asc.size()
	var k := maxi(1, int(ceil(n * fraction)))
	var sum := 0.0
	for i in range(n - k, n):
		sum += sorted_asc[i]
	return 1000.0 / (sum / k)


func _percentile(sorted_asc: PackedFloat32Array, p: float) -> float:
	var idx := clampi(int(round(p * (sorted_asc.size() - 1))), 0, sorted_asc.size() - 1)
	return sorted_asc[idx]


func _save_results(avg_fps: float, low1: float, low01: float, avg_ft: float, p99_ft: float, max_ft: float, count: int, total_ms: float) -> String:
	DirAccess.make_dir_recursive_absolute(RESULT_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/bench_%s.csv" % [RESULT_DIR, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_line("frame,frametime_ms")
	for i in frame_times_ms.size():
		f.store_line("%d,%.3f" % [i, frame_times_ms[i]])
	f.close()

	var summary_path := RESULT_DIR + "/summary.csv"
	var new_file := not FileAccess.file_exists(summary_path)
	var s := FileAccess.open(summary_path, FileAccess.READ_WRITE if not new_file else FileAccess.WRITE)
	if s:
		s.seek_end()
		if new_file:
			s.store_line("time,avg_fps,low_1pct,low_0_1pct,avg_ft_ms,p99_ft_ms,max_ft_ms,frames,duration_s,scale_3d,gpu")
		s.store_line("%s,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%d,%.2f,%.2f,\"%s\"" % [
			stamp, avg_fps, low1, low01, avg_ft, p99_ft, max_ft, count, total_ms / 1000.0,
			get_viewport().scaling_3d_scale, RenderingServer.get_video_adapter_name()])
		s.close()
	return ProjectSettings.globalize_path(path)


# ---------------------------------------------------------------- UI

func _show_results(text: String) -> void:
	if result_label:
		result_label.text = text
	if result_panel:
		result_panel.visible = true
	if result_separator:
		result_separator.visible = true
	var done := state == State.IDLE
	if copy_button:
		copy_button.visible = done and last_report != ""
	if close_button:
		close_button.visible = done


func _hide_results() -> void:
	if result_panel:
		result_panel.visible = false
	if result_separator:
		result_separator.visible = false


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_B:
			_on_run_pressed()
		KEY_F7:
			if state == State.IDLE:
				_find_player()
				if player:
					var p := player.global_position
					recorded_points.append(Vector3(p.x, p.y, p.z))
					print("[Benchmark] Recorded point %d: %s" % [recorded_points.size(), p])
		KEY_F8:
			if recorded_points.size() >= 2:
				_save_custom_route()
		KEY_F9:
			recorded_points = PackedVector3Array()
			if FileAccess.file_exists(CUSTOM_ROUTE_PATH):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(CUSTOM_ROUTE_PATH))
			print("[Benchmark] Custom route cleared, using built-in route")
