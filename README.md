# Virtual Network Switch (P2P Relay & Crossplay) for Godot 4.x

A modular, zero-configuration P2P networking and WebSocket VPN switch for Godot 4.x multiplayer games.
Allows seamless multiplayer across PC, Android, iOS, and Web with zero port forwarding required.

## Features

- **LAN / Hotspot UDP Discovery**: Broadcasts on port `7776` with immediate room teardown notifications (`NET_BYE`).
- **Cloud WebSocket Relay**: Packages raw ENet UDP packets with 4-byte Virtual IP headers (`10.66.0.1` Host, `10.66.0.2+` Clients).
- **Public & Private Rooms**: Support for 6-digit room codes or room name lobbies.
- **Automatic Host Migration**: Seamlessly transfers host authority to the next connected client without disconnecting remaining players.
- **Instant Room Lifecycle**: Real-time room list updating and immediate removal of closed rooms.

## Installation into any Godot 4 project

1. Copy `addons/virtual_net_switch` to your project's `addons/` folder.
2. In Godot, go to **Project -> Project Settings -> Plugins** and enable **Virtual Network Switch**.
3. Add `VirtualNetClient` as an Autoload or instantiate it in your Network Manager scene.

## Relay Server Deployment

Deploy `relay_server.py` on any cloud host (Render.com, Koyeb, Docker, VPS):

```bash
pip install websockets
python relay_server.py
```

## ⚖️ Licencia y Uso Comercial
Este proyecto utiliza un esquema de licenciamiento dual por componente, propiedad de **Estudio Eclipse**:

1. **Addon Cliente para Godot (`virtual_net_switch.gd`, `VirtualNetClient.gd`):** Licenciado bajo **Mozilla Public License 2.0 (MPL-2.0)**.
   * **¿Puedo integrarlo en un juego comercial cerrado?** **SÍ.** Puedes incluir el cliente en tu juego comercial (Steam, Consolas, Móviles) sin abrir el código de tu juego. Solo debes compartir las modificaciones directas que hagas a los archivos del plugin.
2. **Servidor de Retransmisión (`relay_server.py`):** Licenciado bajo **GNU Affero General Public License v3.0 (AGPL-3.0)**.
   * Puedes alojar tu propio servidor gratuitamente para tus juegos, pero si modificas `relay_server.py` y lo ejecutas en red para terceros, debes liberar el código fuente de esas mejoras bajo AGPL-3.0.
