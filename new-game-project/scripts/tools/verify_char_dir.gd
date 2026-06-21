extends SceneTree

# Headless verification of a frames_dir character folder using the SAME asset-loading
# logic as Soldier._build_frames_from_dir (which can't be instantiated under --script
# because it references the GameManager autoload). Checks that all 32 strips import as
# valid square-framed PNGs and build into the expected 8-way idle/walk/shoot/die anims.
# Pass the folder via: --script ... -- res://resources/<char>8
# (defaults to siena8 if no arg given).

func _init() -> void:
	var dir := "res://resources/siena8"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		dir = args[0]
	var specs := {
		"idle":  {"loop": true},
		"walk":  {"loop": true},
		"shoot": {"loop": false},
		"die":   {"loop": false},
	}
	var facings := ["down", "up", "left", "right",
			"down_right", "down_left", "up_right", "up_left"]
	var nf := SpriteFrames.new()
	nf.remove_animation(&"default")
	var ok := true
	var added := 0
	var die_added := 0
	for prefix in specs:
		for facing in facings:
			var path: String = dir.path_join("%s_%s.png" % [prefix, facing])
			if not ResourceLoader.exists(path):
				push_error("MISSING strip: " + path)
				ok = false
				continue
			var tex: Texture2D = load(path)
			if tex == null or tex.get_height() <= 0:
				push_error("BAD texture: " + path)
				ok = false
				continue
			var frame_h: int = tex.get_height()
			if tex.get_width() % frame_h != 0:
				push_error("NON-SQUARE frames in " + path)
				ok = false
			var anim: String = "%s_%s" % [prefix, facing]
			nf.add_animation(anim)
			nf.set_animation_loop(anim, specs[prefix]["loop"])
			added += 1
			if prefix == "die":
				die_added += 1
	if added != 32:
		push_error("expected 32 anims, got " + str(added)); ok = false
	if die_added != 8:
		push_error("expected 8-way die, got " + str(die_added)); ok = false
	if nf.has_animation("die_down") and nf.get_animation_loop("die_down"):
		push_error("die_down must not loop"); ok = false
	if not nf.has_animation("walk_up_right"):
		push_error("not 8-way (walk_up_right missing)"); ok = false
	print("VERIFY_RESULT: ", ("PASS" if ok else "FAIL"), "  dir=", dir,
		"  anims=", added, "  die_dirs=", die_added)
	quit()
