# Payload Contracts

Victory Garden treats the node, Python controller, and Rails backend as one MQTT contract.

Current canonical payload versions:

- `node-state/v1`
- `node-command/v1`
- `node-command-ack/v1`
- `node-config/v1`
- `node-config-ack/v1`

The example payloads in `contracts/examples/` are the shared reference fixtures for tests, docs, and live debugging.
If the firmware payload changes, update these fixtures first and then update the code that consumes them.

Topic classes:

- `greenhouse/zones/{zone_id}/state`: retained node state
- `greenhouse/zones/{zone_id}/command`: retained node commands such as `request_reading`
- `greenhouse/zones/{zone_id}/command_ack`: node command acknowledgements
- `greenhouse/zones/{zone_id}/actuator/command`: actuator commands published by Rails
- `greenhouse/zones/{zone_id}/actuator/status`: actuator completion/fault reports
- `greenhouse/nodes/{node_id}/config`: retained node configuration
- `greenhouse/nodes/{node_id}/config_ack`: node config acknowledgements
- `greenhouse/system/config/current`: published global crop/zone snapshot
