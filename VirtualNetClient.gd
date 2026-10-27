# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Estudio Eclipse. All rights reserved.

extends Node
class_name VirtualNetClient

## VirtualNetClient
## Componente genérico y modular de red para Godot 4.x.
## Permite partidas multijugador P2P y Crossplay sin apertura de puertos (Port Forwarding):
## 1. Descubrimiento local automático por difusión UDP (LAN/Hotspot).
## 2. Conexión WAN a través de un servidor Relay WebSocket con IPs virtuales (10.66.0.X).
## 3. Notificación inmediata de salas abiertas y cerradas (NET_BYE y ROOM_CLOSED).
## 4. Migración transparente de anfitrión (Host Migration).

signal connection_succeeded()
signal connection_failed(reason: String)
signal server_disconnected()
signal lan_rooms_updated(rooms: Array)
signal room_list_received(rooms: Array)
signal room_closed_received(room_code: String)
signal host_migrated(new_host_vip: String)

@export var default_port: int = 7777
@export var discovery_udp_port: int = 7776
@export var relay_ws_url: String = "ws://127.0.0.1:8080"
@export var room_code_length: int = 6

var peer: ENetMultiplayerPeer = null
var is_host: bool = false
var room_code: String = ""
var room_name: String = "Lobby"
var is_private: bool = false

var vpn_ws: WebSocketPeer = null
var my_virtual_ip: String = ""
var is_vpn_connected: bool = false
var vpn_local_relays: Dictionary = {}
var client_vpn_udp: PacketPeerUDP = null
var client_vpn_active: bool = false
var client_vpn_enet_port: int = 0

var _discovery_udp: PacketPeerUDP = null
var _discovery_timer: float = 0.0
var _discovered_rooms: Dictionary = {}
var _lobby_ws: WebSocketPeer = null


func _ready() -> void:
	_setup_discovery_udp()


func _exit_tree() -> void:
	close_session()
	if _discovery_udp:
		_discovery_udp.close()
		_discovery_udp = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if is_host:
			_broadcast_lan_bye()
			_notify_relay_close_room()


# ==============================================================================
# GESTIÓN DE SALA (HOST / JOIN / CLOSE)
# ==============================================================================

func host_room(code: String, name: String = "Lobby", private: bool = false) -> Error:
	close_session()
	is_host = true
	room_code = code
	room_name = name
	is_private = private

	peer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(default_port, 4)
	if err != OK:
		is_host = false
		push_error("[VirtualNetClient] Error al crear servidor ENet: %s" % error_string(err))
		return err

	if peer.get_host():
		peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer

	_start_vpn_tunnel(true)
	_broadcast_lan_beacon()
	return OK


func join_room(code: String) -> void:
	close_session()
	is_host = false
	room_code = code
	_start_vpn_tunnel(false)


func close_session() -> void:
	if is_host:
		_broadcast_lan_bye()
		_notify_relay_close_room()

	is_host = false
	is_vpn_connected = false
	client_vpn_active = false
	client_vpn_enet_port = 0

	if client_vpn_udp:
		client_vpn_udp.close()
		client_vpn_udp = null

	for vip in vpn_local_relays.keys():
		var r: PacketPeerUDP = vpn_local_relays[vip]
		if r:
			r.close()
	vpn_local_relays.clear()

	if vpn_ws:
		if vpn_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			vpn_ws.close()
		vpn_ws = null

	if peer:
		peer.close()
		peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


# ==============================================================================
# DESCUBRIMIENTO LOCAL UDP (LAN / HOTSPOT)
# ==============================================================================

func _setup_discovery_udp() -> void:
	_discovery_udp = PacketPeerUDP.new()
	var err: Error = _discovery_udp.bind(discovery_udp_port, "0.0.0.0")
	if err != OK:
		err = _discovery_udp.bind(0, "0.0.0.0")
	if err == OK:
		_discovery_udp.set_broadcast_enabled(true)


func _broadcast_lan_beacon() -> void:
	if not _discovery_udp or not is_host:
		return
	var priv_str: String = "1" if is_private else "0"
	var beacon: String = "NET_HERE:%s:%d:%s:%s" % [room_code, default_port, room_name, priv_str]
	var buf: PackedByteArray = beacon.to_utf8_buffer()
	_discovery_udp.set_dest_address("255.255.255.255", discovery_udp_port)
	_discovery_udp.put_packet(buf)
	_discovery_udp.set_dest_address("127.0.0.1", discovery_udp_port)
	_discovery_udp.put_packet(buf)


func _broadcast_lan_bye() -> void:
	if not _discovery_udp or not is_host:
		return
	var bye: String = "NET_BYE:%s" % room_code
	var buf: PackedByteArray = bye.to_utf8_buffer()
	_discovery_udp.set_dest_address("255.255.255.255", discovery_udp_port)
	_discovery_udp.put_packet(buf)
	_discovery_udp.set_dest_address("127.0.0.1", discovery_udp_port)
	_discovery_udp.put_packet(buf)


func _poll_discovery_udp(delta: float) -> void:
	if not _discovery_udp:
		return

	if is_host:
		_discovery_timer += delta
		if _discovery_timer >= 0.8:
			_discovery_timer = 0.0
			_broadcast_lan_beacon()

	while _discovery_udp.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _discovery_udp.get_packet()
		var s_ip: String = _discovery_udp.get_packet_ip()
		var msg: String = pkt.get_string_from_utf8().strip_edges()

		if msg.begins_with("NET_HERE:"):
			var parts: PackedStringArray = msg.split(":")
			if parts.size() >= 3:
				var c_code: String = parts[1]
				var c_port: int = parts[2].to_int()
				var c_name: String = parts[3] if parts.size() > 3 else "Room"
				var c_priv: bool = (parts[4] == "1") if parts.size() > 4 else false
				_discovered_rooms[c_code] = {
					"code": c_code,
					"ip": s_ip,
					"port": c_port,
					"name": c_name,
					"is_private": c_priv,
					"last_seen": Time.get_ticks_msec() / 1000.0
				}
				lan_rooms_updated.emit(_discovered_rooms.values())

		elif msg.begins_with("NET_BYE:"):
			var bye_code: String = msg.trim_prefix("NET_BYE:").strip_edges()
			if _discovered_rooms.has(bye_code):
				_discovered_rooms.erase(bye_code)
				lan_rooms_updated.emit(_discovered_rooms.values())


# ==============================================================================
# TÚNEL RELAY WEBSOCKET (CROSSPLAY WAN)
# ==============================================================================

func _start_vpn_tunnel(as_host: bool) -> void:
	vpn_ws = WebSocketPeer.new()
	vpn_ws.inbound_buffer_size = 1048576
	vpn_ws.outbound_buffer_size = 1048576
	vpn_ws.max_queued_packets = 4096
	var err: Error = vpn_ws.connect_to_url(relay_ws_url)
	if err != OK:
		push_warning("[VirtualNetClient] Error conectando al Relay WebSocket: %s" % error_string(err))


func _notify_relay_close_room() -> void:
	if vpn_ws and vpn_ws.get_ready_state() == WebSocketPeer.STATE_OPEN and is_host:
		var cmd: Dictionary = {"cmd": "CLOSE_ROOM", "room": room_code}
		vpn_ws.send_text(JSON.stringify(cmd))
		vpn_ws.poll()


func _process(delta: float) -> void:
	_poll_discovery_udp(delta)
	_process_vpn_tunnel()


func _process_vpn_tunnel() -> void:
	if not vpn_ws:
		return
	vpn_ws.poll()
	var state: WebSocketPeer.State = vpn_ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not is_vpn_connected:
			is_vpn_connected = true
			if is_host:
				var reg := {
					"cmd": "CREATE_ROOM",
					"room": room_code,
					"room_name": room_name,
					"is_private": is_private,
					"platform": OS.get_name()
				}
				vpn_ws.send_text(JSON.stringify(reg))
			else:
				var join_msg := {
					"cmd": "JOIN_ROOM",
					"room": room_code,
					"platform": OS.get_name()
				}
				vpn_ws.send_text(JSON.stringify(join_msg))

		# Leer paquetes desde el Relay
		while vpn_ws.get_available_packet_count() > 0:
			var pkt: PackedByteArray = vpn_ws.get_packet()
			if vpn_ws.was_string_packet():
				var text: String = pkt.get_string_from_utf8().strip_edges()
				var parsed: Variant = JSON.parse_string(text)
				if parsed is Dictionary:
					_handle_vpn_json(parsed)
			else:
				if is_host:
					if pkt.size() >= 5:
						var vip: String = "%d.%d.%d.%d" % [pkt[0], pkt[1], pkt[2], pkt[3]]
						var payload: PackedByteArray = pkt.slice(4)
						if not vpn_local_relays.has(vip):
							var relay := PacketPeerUDP.new()
							if relay.connect_to_host("127.0.0.1", default_port) == OK:
								vpn_local_relays[vip] = relay
						if vpn_local_relays.has(vip):
							vpn_local_relays[vip].put_packet(payload)
				else:
					if client_vpn_active and client_vpn_udp and client_vpn_enet_port > 0:
						client_vpn_udp.set_dest_address("127.0.0.1", client_vpn_enet_port)
						client_vpn_udp.put_packet(pkt)

		# Host: reenviar respuestas locales de ENet hacia clientes WAN
		if is_host:
			for vip in vpn_local_relays.keys():
				var relay: PacketPeerUDP = vpn_local_relays[vip]
				while relay.get_available_packet_count() > 0:
					var resp: PackedByteArray = relay.get_packet()
					var parts: PackedStringArray = vip.split(".")
					if parts.size() == 4:
						var out_pkt := PackedByteArray()
						out_pkt.resize(4 + resp.size())
						out_pkt[0] = parts[0].to_int()
						out_pkt[1] = parts[1].to_int()
						out_pkt[2] = parts[2].to_int()
						out_pkt[3] = parts[3].to_int()
						for b in range(resp.size()):
							out_pkt[4 + b] = resp[b]
						vpn_ws.send(out_pkt, WebSocketPeer.WRITE_MODE_BINARY)

	# Cliente: leer tráfico de ENet local y enviarlo al Relay
	if not is_host and client_vpn_active and client_vpn_udp:
		while client_vpn_udp.get_available_packet_count() > 0:
			var pkt: PackedByteArray = client_vpn_udp.get_packet()
			client_vpn_enet_port = client_vpn_udp.get_packet_port()
			if vpn_ws and vpn_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				vpn_ws.send(pkt, WebSocketPeer.WRITE_MODE_BINARY)


func _handle_vpn_json(data: Dictionary) -> void:
	var evt: String = str(data.get("evt", "")).to_upper()
	match evt:
		"JOIN_OK":
			my_virtual_ip = str(data.get("virtual_ip", ""))
			_activate_client_loopback()
			connection_succeeded.emit()
		"JOIN_ERROR":
			connection_failed.emit(str(data.get("reason", "Error de conexión")))
		"HOST_MIGRATED_SELF":
			is_host = true
			my_virtual_ip = "10.66.0.1"
			_start_migrated_server()
		"HOST_MIGRATED":
			_activate_client_loopback()
			host_migrated.emit("10.66.0.1")
		"HOST_DISCONNECTED":
			server_disconnected.emit()
			close_session()


func _activate_client_loopback() -> void:
	client_vpn_active = true
	if client_vpn_udp:
		client_vpn_udp.close()
	client_vpn_udp = PacketPeerUDP.new()
	if client_vpn_udp.bind(0, "127.0.0.1") != OK:
		return
	var proxy_port: int = client_vpn_udp.get_local_port()
	client_vpn_enet_port = 0

	peer = ENetMultiplayerPeer.new()
	if peer.create_client("127.0.0.1", proxy_port) == OK:
		if peer.get_host():
			peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer


func _start_migrated_server() -> void:
	if client_vpn_udp:
		client_vpn_udp.close()
		client_vpn_udp = null
	client_vpn_active = false
	vpn_local_relays.clear()

	peer = ENetMultiplayerPeer.new()
	if peer.create_server(default_port, 4) == OK:
		if peer.get_host():
			peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer
