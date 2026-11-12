# Data migrations

`upgrade-<from>-<to>.sh` brings the data on EFS from release `<from>` to the next release `<to>`. A release ships
one only if its data need a one-off change; Flashlight 1.0 has none.

Each migration also goes into the stage 1 `Files` list (as `migrations/upgrade-<from>-<to>.sh`) and stays there
for good: a server several releases behind needs every step in between. The rules for writing one are in
[docs/RELEASING.md](../../docs/RELEASING.md#migrations).
