# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Estudio Eclipse. All rights reserved.

@tool
extends EditorPlugin
## Virtual Network Switch Plugin for Godot 4.x
## Allows seamless P2P crossplay, local network discovery, and WebSocket-relayed NAT traversal.

func _enter_tree() -> void:
	add_custom_type("VirtualNetClient", "Node", preload("VirtualNetClient.gd"), null)
	print("[VirtualNetSwitch] Plugin activado.")


func _exit_tree() -> void:
	remove_custom_type("VirtualNetClient")
	print("[VirtualNetSwitch] Plugin desactivado.")
