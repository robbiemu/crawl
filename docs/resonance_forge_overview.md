# Resonance Forge Portal Overview

The Resonance Forge is a one-off portal branch designed to give players an optional, high-variance equipment upgrade opportunity in the early-to-mid Dungeon. This document captures the intent of the portal, the systems that drive it, and the major data tables so reviewers and maintainers can reason about future changes.

## Where and how the portal appears

* **Spawn depth**: The portal can appear in D:5 or deeper, up through late Lair depth equivalents. The spawn weights are currently split evenly between D:5–7, D:8–13, and D:14–15. This is determined once so it remains an early- to mid-Dungeon feature even if you dive quickly.
* **Portal annoucement**: When the portal spawns it emits a set of timed custom messages (distant clangs) that grow more urgent as the collapse timer advances.
* **Layout**: The portal creates a compact mini-vault containing:
  * The dais with the forge itself (operated with `>` while standing on it).
  * One or more alcoves holding guardian constructs.
  * Hazard statues / conduits tuned to the current target category (in mid/later depths).

## Gameplay loop and intended feel

1. **Scouting / Entry**
   * The player must reach the forge chamber to use the forge, may exit at the spawn entry or past the forge. (one other map is intended.)
   * Guardians are seeded in advance asleep so players can assess the danger before committing to the forge.

2. **Forge operation**
   * While on the dais the player can attune one of six item categories:
     `weapon`, `offhand`, `shield`, `armour`, `ranged`, or `thrown`.
   * Each use retunes the currently equipped item, potentially applying a new ego or upgrading the base item following the rules in the category tables. These uses can break the forge.
   * Artefacts deliberately “resist change”: the attempt consumes a use, can rupture the forge, and emits the failure cloud, but leaves the item intact and does not spawn new guardians.

3. **Escalation / Risk**
   * Uses are tracked per portal. Each successful attunement:
     * Increments the use count (raising the wave difficulty).
     * Has a 1-in-3 chance to rupture the forge immediately, cutting the run
       short and spawning a failure cloud.
     * Spawns a wave of guardians scaled by the current difficulty bucket. These are monsters chosen from the dungeon starting two levels deeper than the entry, and increasing by one level each use thereafter. If it spawned deep enough, it may switch to Depths to go further. 
   * The portal can also catastrophically fail if the preview wave would exceed Depths-level difficulty; this spawns an abyss-tainted wave, possibly also a cloud of chaos, and ends the forge functioning regardless of the player’s choice.

4. **Exit**
   * The portal collapses once the player leaves the level after using the forge.

The overall goal is a short, punchy challenge that trades increasing combat difficulty for a tailored equipment upgrade/alteration path, encouraging players to make calculated risk/reward decisions.

## Guard buckets and entry guard tables

Guard selection is data-driven via TOML (available separately but not in branch
`dat/resonance_forge/resonance_forge.toml`, compiled to
`dat/dlua/resonance_forge_spec.lua`). The key structures are:

* **Buckets**: `early_dungeon`, `mid_dungeon`, `late_dungeon`. The bucket is chosen based on the portal’s depth so encounters stay appropriate.
* **Entry guards**: Each bucket contains tiered definitions (`common`, `uncommon`, etc.) for each forge target. Entries specify:
  * Creature pools per species, with optional item sets, tags, and probabilities.
  * “Support guards” that can reference other buckets to pull in specialist units (e.g. steam dragons for the thrown forge).
* **Pairings**: Additional ancillary items that may spawn alongside the primary guard equipment (e.g. weapon + shield combos).
* **Unique replacements**: Low-probability substitutions that can inject one-off rewards into the guardian gear tables to keep the fights surprising.

These tables exist so designers can tweak guardian loadouts, gear rarities, and target-specific flavour without touching Lua logic.

## Guardian waves

After every successful forge use (except artefacts) the script:

1. Calculates a future branch/depth target for the wave based on the base depth and number of uses (`wave_place`).
2. Selects spawn points for “inner” and “outer” wave rings.
3. Uses the guard tables to roll a mixture of constructs and support units appropriate to the current bucket.
4. Applies an abyssal corruption modifier when a catastrophic rupture is in effect, swapping some spawns for abyssal monsters.

Wave fill rates, forced replacements, and other knobs are defined in the spec.

## Forge logic summary

* The forge is invoked via `crawl.resonance_forge_apply(target)`, which delegates into C++ (`resonance_forge_apply` in `source/resonance-forge.cc`).
* Item retuning attempts perform type checks, apply category-specific ego logic, and emit success or resistance messages.
* Artefacts share the rupture odds and failure cloud but skip guardian spawn, respecting the user’s desire to “try” without losing a unique.

## Implementation touchpoints

* `dat/dlua/resonance_forge.lua` — main controller for guard generation, wave spawning, messaging, and portal markers.
* `source/resonance-forge.cc/.h` — C++ entry points for retuning items.
* (not included in branch, but available) `scripts/resonance_forge_toml_to_lua.py` — pipeline that converts the TOML guard/forge spec into the Lua tables consumed at runtime.
* (not included in branch, but available) `dat/resonance_forge/*.toml` — authoring source for guard distributions, wave fill rates, hazards, and forge tuning probabilities.

## Specific testing functions/settings:

- `dgn.persist.resonance_forge_debug = true` will turn on some debugging messaging
- `crawl.mpt(resonance_forge_configure_portal())` will reset the portal to be depth appropriate for the current level set the object type (which it will indicate)
- `resonance_forge_clear_persist()` will clear the persist values exclusive to teh forge

the portal entry `resonance_forge_portal_entry` should be placed to walk into the portal