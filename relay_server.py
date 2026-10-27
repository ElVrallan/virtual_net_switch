#!/usr/bin/env python3
# relay_server.py - Dedicated Relay Server
# Copyright (c) 2026 Estudio Eclipse.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
"""
================================================================================
Virtual Network Switch - Dedicated Relay Server
================================================================================
Universal asynchronous WebSocket relay for P2P multiplayer crossplay in Godot 4.x.
Features:
- Cloud deployment (Render.com, Koyeb, Docker, Linux VPS).
- HTTP health checks (GET / and GET /health -> 200 OK).
- Public room explorer and 6-digit private rooms.
- 4-byte Virtual IP datagram routing (10.66.0.1 for Host, 10.66.0.2+ for Clients).
- Instant room closure broadcast (ROOM_CLOSED).
- Seamless automatic host migration.
================================================================================
"""

import asyncio
import http
import json
import os
import sys
import time
from typing import Dict, Any, Optional

try:
    import websockets
except ImportError:
    print("[ERROR] 'websockets' package missing. Install via: pip install websockets")
    sys.exit(1)

HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", 8080))

rooms: Dict[str, Dict[str, Any]] = {}
peer_info: Dict[Any, Dict[str, Any]] = {}
lobby_listeners = set()


def log(msg: str) -> None:
    now_str = time.strftime("%H:%M:%S")
    print(f"[{now_str}] {msg}", flush=True)


async def broadcast_room_closed(room_code: str) -> None:
    if not lobby_listeners:
        return
    msg = json.dumps({"evt": "ROOM_CLOSED", "room": room_code})
    dead = set()
    for listener in list(lobby_listeners):
        try:
            await listener.send(msg)
        except Exception:
            dead.add(listener)
    lobby_listeners.difference_update(dead)


def process_http_request(connection, request):
    headers = getattr(request, "headers", None)
    if headers is None and hasattr(connection, "headers"):
        headers = connection.headers

    upgrade = ""
    if headers:
        upgrade = headers.get("Upgrade", "")

    if upgrade.lower() != "websocket":
        if hasattr(connection, "respond"):
            return connection.respond(http.HTTPStatus.OK, "Relay Active\n")
        return (http.HTTPStatus.OK, [("Content-Type", "text/plain"), ("Content-Length", "13")], b"Relay Active\n")
    return None


async def handle_connection(ws, path=None):
    remote_addr = getattr(ws, "remote_address", ("unknown", 0))
    peer_addr_str = f"{remote_addr[0]}:{remote_addr[1]}" if isinstance(remote_addr, (tuple, list)) else str(remote_addr)

    try:
        async for message in ws:
            if isinstance(message, str):
                try:
                    data = json.loads(message)
                except Exception as e:
                    log(f"[WARN] Invalid JSON from {peer_addr_str}: {e}")
                    continue

                cmd = str(data.get("cmd", "")).upper()
                room_code = str(data.get("room", "")).strip()

                if cmd == "LIST_ROOMS":
                    lobby_listeners.add(ws)
                    public_rooms = []
                    for code, r in rooms.items():
                        if not r.get("is_private", False) and r.get("host") is not None:
                            curr_count = len(r.get("clients", {})) + 1
                            max_p = r.get("max_players", 4)
                            if curr_count < max_p:
                                public_rooms.append({
                                    "room": code,
                                    "name": r.get("room_name", f"Room #{code}"),
                                    "players": curr_count,
                                    "max": max_p,
                                    "platform": r.get("host_platform", "Unknown")
                                })
                    await ws.send(json.dumps({"evt": "ROOM_LIST", "rooms": public_rooms}))
                    continue

                if cmd == "CLOSE_ROOM":
                    if room_code in rooms and rooms[room_code].get("host") == ws:
                        log(f"🛑 [ROOM {room_code}] Host explicitly closed the room.")
                        room_data = rooms.pop(room_code, None)
                        if room_data:
                            for client_ws in room_data.get("clients", {}).values():
                                try:
                                    await client_ws.send(json.dumps({"evt": "HOST_DISCONNECTED"}))
                                except Exception:
                                    pass
                        await broadcast_room_closed(room_code)
                    continue

                if cmd == "CREATE_ROOM":
                    room_name = str(data.get("room_name", f"Room #{room_code}")).strip()[:28]
                    is_private = bool(data.get("is_private", False))
                    platform = str(data.get("platform", "Unknown"))

                    if room_code in rooms:
                        old_host = rooms[room_code].get("host")
                        if old_host and old_host != ws:
                            try:
                                await old_host.close(1000, "New session started")
                            except Exception:
                                pass

                    host_vip = "10.66.0.1"
                    rooms[room_code] = {
                        "host": ws,
                        "clients": {},
                        "next_octet": 2,
                        "room_code": room_code,
                        "room_name": room_name,
                        "is_private": is_private,
                        "host_platform": platform,
                        "max_players": 4
                    }
                    peer_info[ws] = {"room": room_code, "role": "HOST", "virtual_ip": host_vip}
                    await ws.send(json.dumps({
                        "evt": "ROOM_READY",
                        "virtual_ip": host_vip,
                        "room": room_code,
                        "room_name": room_name
                    }))
                    log(f"🟢 [ROOM {room_code}] Created by Host ({platform}) at {host_vip}")

                elif cmd == "JOIN_ROOM":
                    platform = str(data.get("platform", "Unknown"))
                    if room_code not in rooms or rooms[room_code].get("host") is None:
                        await ws.send(json.dumps({"evt": "JOIN_ERROR", "reason": f"Room #{room_code} does not exist."}))
                        continue

                    room_data = rooms[room_code]
                    current_count = len(room_data.get("clients", {})) + 1
                    max_p = room_data.get("max_players", 4)
                    if current_count >= max_p:
                        await ws.send(json.dumps({"evt": "JOIN_ERROR", "reason": f"Room #{room_code} is full."}))
                        continue

                    client_octet = room_data["next_octet"]
                    room_data["next_octet"] += 1
                    client_vip = f"10.66.0.{client_octet}"

                    room_data["clients"][client_vip] = ws
                    peer_info[ws] = {"room": room_code, "role": "CLIENT", "virtual_ip": client_vip}

                    host_ws = room_data["host"]
                    try:
                        await host_ws.send(json.dumps({"evt": "PEER_JOINED", "virtual_ip": client_vip}))
                    except Exception:
                        pass

                    await ws.send(json.dumps({
                        "evt": "JOIN_OK",
                        "virtual_ip": client_vip,
                        "host_virtual_ip": "10.66.0.1",
                        "room": room_code,
                        "room_name": room_data.get("room_name", "")
                    }))
                    log(f"🔵 [ROOM {room_code}] Client joined ({platform}) at {client_vip}")

            elif isinstance(message, (bytes, bytearray)):
                if ws not in peer_info:
                    continue

                info = peer_info[ws]
                room_code = info["room"]
                role = info["role"]

                if room_code not in rooms:
                    continue

                room_data = rooms[room_code]

                if role == "CLIENT":
                    host_ws = room_data.get("host")
                    if host_ws:
                        c_vip = info["virtual_ip"]
                        try:
                            octets = [int(p) for p in c_vip.split(".")]
                            hdr = bytes(octets)
                            await host_ws.send(hdr + message)
                        except Exception:
                            pass

                elif role == "HOST":
                    if len(message) >= 5:
                        dest_vip = f"{message[0]}.{message[1]}.{message[2]}.{message[3]}"
                        raw_payload = message[4:]
                        client_ws = room_data["clients"].get(dest_vip)
                        if client_ws:
                            try:
                                await client_ws.send(raw_payload)
                            except Exception:
                                pass

    except websockets.exceptions.ConnectionClosed:
        pass
    except Exception as e:
        log(f"[WARN] Connection exception: {e}")
    finally:
        lobby_listeners.discard(ws)
        if ws in peer_info:
            info = peer_info.pop(ws)
            room_code = info["room"]
            role = info["role"]
            vip = info["virtual_ip"]

            if room_code in rooms:
                room_data = rooms[room_code]
                if role == "HOST":
                    if room_data.get("clients"):
                        new_host_vip, new_host_ws = next(iter(room_data["clients"].items()))
                        del room_data["clients"][new_host_vip]
                        room_data["host"] = new_host_ws
                        peer_info[new_host_ws]["role"] = "HOST"
                        peer_info[new_host_ws]["virtual_ip"] = "10.66.0.1"
                        log(f"👑 [ROOM {room_code}] Host migrated to {new_host_vip}")
                        try:
                            await new_host_ws.send(json.dumps({
                                "evt": "HOST_MIGRATED_SELF",
                                "virtual_ip": "10.66.0.1",
                                "room": room_code
                            }))
                        except Exception:
                            pass
                        for rem_vip, rem_ws in room_data["clients"].items():
                            try:
                                await rem_ws.send(json.dumps({
                                    "evt": "HOST_MIGRATED",
                                    "new_host_virtual_ip": "10.66.0.1"
                                }))
                            except Exception:
                                pass
                    else:
                        log(f"🔴 [ROOM {room_code}] Host disconnected with no clients left. Closing room.")
                        del rooms[room_code]
                        await broadcast_room_closed(room_code)

                elif role == "CLIENT":
                    log(f"🟠 [ROOM {room_code}] Client {vip} disconnected.")
                    room_data["clients"].pop(vip, None)
                    host_ws = room_data.get("host")
                    if host_ws:
                        try:
                            await host_ws.send(json.dumps({"evt": "PEER_LEFT", "virtual_ip": vip}))
                        except Exception:
                            pass


async def main():
    print(f"[*] Virtual Network Switch Relay listening on {HOST}:{PORT}")
    async with websockets.serve(
        handle_connection,
        HOST,
        PORT,
        process_request=process_http_request,
        max_size=10_000_000,
        ping_interval=20,
        ping_timeout=20
    ):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[INFO] Relay stopped by user.")
