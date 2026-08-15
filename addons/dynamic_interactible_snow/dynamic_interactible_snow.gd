@tool
extends EditorPlugin

const NAME : StringName = &"The Dynamic Interactible Snow Plugin"
func _enable_plugin() -> void:
	print("Initiating ", NAME, "...")
	add_autoload_singleton("SnowComputeManager", "res://addons/dynamic_interactible_snow/snow/singletons/SnowComputeManager.gd")
	add_autoload_singleton("SnowSurfaceManager", "res://addons/dynamic_interactible_snow/snow/singletons/SnowSurfaceManager.gd")
	add_autoload_singleton("SnowSurfaceThreadManager","res://addons/dynamic_interactible_snow/snow/singletons/SnowSurfaceThreadManager.gd")
	print("In order for ", NAME, " to work, ensure the three globals in 'project settings / globals' are enabled: SnowSurfaceManager, SnowSurfaceThreadManager, and SnowComputeManager.")

func _disable_plugin() -> void:
	print("Unloading ", NAME, "...")
	remove_autoload_singleton("SnowComputeManager")
	remove_autoload_singleton("SnowSurfaceManager")
	remove_autoload_singleton("SnowSurfaceThreadManager")
	print(NAME, " has been successfully removed.")


func _enter_tree() -> void:
	# Initialization of the plugin goes here.
	pass


func _exit_tree() -> void:
	# Clean-up of the plugin goes here.
	pass
