UE4SS RUNTIME BRIDGE

This bridge intentionally refuses to guess SCUM-specific weapon/spawn functions.
At runtime it proves NPC discovery, actor location, controller access, reversible BrainComponent StopLogic/restore, and a +200 cm MoveToLocation request whose real movement progress must be observed before movement capability is accepted. Results are written into runtime/probe-report.log and sent to the Node brain as CAPABILITY events.

If a required primitive is unavailable after a SCUM update, the Node world simulation and map remain alive while the SCUM adapter is shown as DEGRADED. This prevents a half-broken takeover from silently controlling NPCs.

Weapon firing, SCUM-specific spawn/despawn, inventory/loadout and exact damage/death hooks require names/signatures from the current SCUM runtime dump. The probe enumerates matching reflected functions/properties so those adapters can be filled without touching the rest of the architecture.
