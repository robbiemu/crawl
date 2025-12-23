--------------------------------------------------------------------------
-- resonance_forge.lua
--
-- Support code for the Resonance Forge portal branch.
--------------------------------------------------------------------------

crawl_require('dlua/util.lua')
crawl_require('dlua/vault.lua')
crawl_require('dlua/lm_trig.lua')
crawl_require('dlua/resonance_forge_spec.lua')
local RESONANCE_SPEC = get_resonance_forge_spec()

local TARGETS = { "weapon", "ranged", "armour", "shield", "offhand", "thrown" }

local resonance_forge_populate

local BUCKETS = {
    early = { name = "early_dungeon", depth = {3, 7} },
    mid   = { name = "mid_dungeon",   depth = {8, 13} },
    late  = { name = "late_dungeon",  depth = {14, 15} },
}

local DEFAULT_GUARDS = {
    "human",
    "dwarf"
}

local FAILURE_CLOUD_TYPES = {
    "noxious fumes",
    "seething chaos",
}

local HAZARD_STATUE_CHOICES = {
    "orange crystal statue",
    "obsidian statue",
    "lightning spire",
}

local ENTRY_GUARD_SPEC = RESONANCE_SPEC.entry_guards or {}
local ENTRY_GUARD_DEFAULT = ENTRY_GUARD_SPEC.default_guard_pool or DEFAULT_GUARDS
local ENTRY_GUARD_BUCKETS = {}
if ENTRY_GUARD_SPEC.bucket then
    for _, bucket in ipairs(ENTRY_GUARD_SPEC.bucket) do
        ENTRY_GUARD_BUCKETS[bucket.name] = bucket
    end
end

local FORGEWRIGHT_SPEC = RESONANCE_SPEC.forgewright or {}
local FORGEWRIGHT_SPELLBOOKS = {}
if FORGEWRIGHT_SPEC.spellbook then
    for _, entry in ipairs(FORGEWRIGHT_SPEC.spellbook) do
        if entry.name and entry.spells then
            FORGEWRIGHT_SPELLBOOKS[entry.name] = entry.spells
        end
    end
end

local SPELL_NAME_MAP = {
    ["Kinetic Grapnel"] = "kinetic_grapnel",
    ["Launch Clockwork Bee"] = "launch_clockwork_bee",
    ["Iskenderun's Battlesphere"] = "battlesphere",
    ["Forge Blazeheart Golem"] = "forge_blazeheart_golem",
    ["Forge Lightning Spire"] = "forge_lightning_spire",
    ["Alistair's Walking Alembic"] = "walking_alembic",
    ["Hoarfrost Cannonade"] = "hoarfrost_cannonade",
    ["Nazja's Percussive Tempering"] = "percussive_tempering",
    ["Forge Phalanx Beetle"] = "forge_phalanx_beetle",
    ["Hellfire Mortar"] = "hellfire_mortar",
    ["Spellspark Servitor"] = "spellspark_servitor",
}

local function slug_spell_name(name)
    if not name then
        return nil
    end
    if SPELL_NAME_MAP[name] then
        return SPELL_NAME_MAP[name]
    end
    local slug = name:lower()
    slug = slug:gsub("[^%w%s]", "")
    slug = slug:gsub("%s+", "_")
    return slug
end

local function choose_weighted_entry(entries)
    local total = 0
    for _, data in ipairs(entries) do
        total = total + (data.weight or 1)
    end
    if total <= 0 then
        return entries[crawl.random2(#entries) + 1]
    end
    local roll = crawl.random2(total)
    for _, data in ipairs(entries) do
        local weight = data.weight or 1
        if roll < weight then
            return data
        end
        roll = roll - weight
    end
    return entries[#entries]
end

local function select_spell_from_group(group)
    if type(group) == "string" then
        return slug_spell_name(group)
    end
    if type(group) ~= "table" or #group == 0 then
        return nil
    end
    if type(group[1]) == "string" then
        local pick = group[crawl.random2(#group) + 1]
        return slug_spell_name(pick)
    end
    if type(group[1]) == "table" then
        local chosen = choose_weighted_entry(group)
        if chosen and chosen.spell then
            return slug_spell_name(chosen.spell)
        end
    end
    return nil
end

local function build_spell_spec(spell_names)
    if not spell_names or #spell_names == 0 then
        return nil
    end
    local chances = {}
    local base = math.floor(100 / #spell_names)
    local remainder = 100 - base * #spell_names
    for i = 1, #spell_names do
        chances[i] = base + (i <= remainder and 1 or 0)
    end
    local parts = {}
    for i, name in ipairs(spell_names) do
        table.insert(parts, string.format("%s.%d.wizard", name, chances[i]))
    end
    return "spells:" .. table.concat(parts, ";")
end

local DEFAULT_TARGET_ITEMS = {
    weapon = "hand axe",
    armour = "chain mail",
    shield = "buckler",
    offhand = "short sword",
    ranged = "shortbow",
    thrown = "boomerang",
}

local DRAGON_SCALE_DROPS = {
    ["steam dragon"] = "steam dragon scales",
    ["acid dragon"] = "acid dragon scales",
    ["quicksilver dragon"] = "quicksilver dragon scales",
}

local MAX_GUARD_SPEC_DEPTH = 5
local build_guard_roll
local build_support_guard_roll
local resolve_tier_entry_key
local apply_pairings_to_roll
local last_guard_error
local guard_failure_reported
local WANDER_BEHAVIOUR = mons and mons.behaviour and mons.behaviour("wander") or nil

local FORGE_STRAIN_WARNINGS = {
    "<lightred>The forge's harmonics wobble; misaligned channeling could rupture it.</lightred>",
    "<lightred>Grit sluices from the casing. Another imprecise pass might tear the forge apart.</lightred>",
    "<lightred>Hairline fractures skitter across the dais—pressing the forge further risks collapse.</lightred>",
}

local function forge_debug_enabled()
    return dgn.persist and dgn.persist.resonance_forge_debug
end

if forge_debug_enabled() then
    local keys = {}
    for name in pairs(ENTRY_GUARD_BUCKETS) do
        table.insert(keys, name or "<nil>")
    end
    crawl.mpr(string.format("[forge-debug] guard buckets initialised: %s",
        table.concat(keys, ", ")))
end

local function debug_guard_failure(bucket, target, reason)
    if not forge_debug_enabled() then
        return
    end
    crawl.mpr(string.format("[forge-debug] guard fallback bucket=%s target=%s reason=%s",
        bucket or "?", target or "?", reason or "unknown"))
end

local function trim_string(text)
    if type(text) ~= "string" then
        return text
    end
    return text:match("^%s*(.-)%s*$")
end

local function split_item_list(value)
    if not value then
        return {}
    end
    if type(value) == "table" then
        local out = {}
        for _, v in ipairs(value) do
            table.insert(out, trim_string(v))
        end
        return out
    end
    local str = trim_string(value)
    if not str or str == "" then
        return {}
    end
    local items = {}
    if str:find(",") then
        for part in str:gmatch("[^,]+") do
            table.insert(items, trim_string(part))
        end
    else
        table.insert(items, str)
    end
    return items
end

local function weighted_pick(entries)
    if not entries or #entries == 0 then
        return nil
    end
    local total = 0
    for _, entry in ipairs(entries) do
        local weight = 1
        if type(entry) == "table" and entry.weight then
            weight = entry.weight
        end
        total = total + math.max(weight, 0)
    end
    if total <= 0 then
        local entry = entries[crawl.random2(#entries) + 1]
        if type(entry) ~= "table" then
            entry = { base = entry }
        end
        return entry
    end
    local roll = crawl.random2(total)
    for _, entry in ipairs(entries) do
        local weight = 1
        if type(entry) == "table" and entry.weight then
            weight = entry.weight
        end
        weight = math.max(weight, 0)
        if roll < weight then
            if type(entry) ~= "table" then
                return { base = entry }
            end
            return entry
        end
        roll = roll - weight
    end
    local entry = entries[#entries]
    if type(entry) ~= "table" then
        entry = { base = entry }
    end
    return entry
end

-- Select an entry index using the same weight semantics as weighted_pick,
-- excluding any indexes marked in the optional tried set.
local function weighted_index(entries, tried)
    if not entries or #entries == 0 then
        return nil
    end
    tried = tried or {}
    local candidates = {}
    local total = 0
    for idx, entry in ipairs(entries) do
        if not tried[idx] then
            local weight = 1
            if type(entry) == "table" and entry.weight then
                weight = entry.weight
            end
            weight = math.max(weight, 0)
            table.insert(candidates, { index = idx, weight = weight })
            total = total + weight
        end
    end
    if #candidates == 0 then
        return nil
    end
    if total <= 0 then
        local choice = candidates[crawl.random2(#candidates) + 1]
        return choice and choice.index
    end
    local roll = crawl.random2(total)
    for _, candidate in ipairs(candidates) do
        local weight = candidate.weight
        if roll < weight then
            return candidate.index
        end
        roll = roll - weight
    end
    return candidates[#candidates].index
end

local function awaken_guardian(mon)
    if mon and WANDER_BEHAVIOUR then
        mon.beh = WANDER_BEHAVIOUR
    end
    return mon
end

local function place_guardian(x, y, spec)
    if not spec or spec == "" then
        return nil
    end
    local mon = dgn.create_monster(x, y, spec)
    return awaken_guardian(mon)
end

local function warn_forge_strain()
    if not FORGE_STRAIN_WARNINGS or #FORGE_STRAIN_WARNINGS == 0 then
        return
    end
    local idx = crawl.random2(#FORGE_STRAIN_WARNINGS) + 1
    crawl.mpr(FORGE_STRAIN_WARNINGS[idx])
end

local function pick_pair(pairs)
    if not pairs or #pairs == 0 then
        return {}
    end
    local choice = pairs[crawl.random2(#pairs) + 1]
    if type(choice[1]) == "table" then
        choice = choice[crawl.random2(#choice) + 1]
    end
    local out = {}
    for _, item in ipairs(choice) do
        table.insert(out, trim_string(item))
    end
    return out
end

local function should_apply_tag(rate)
    if rate == nil then
        return true
    end
    if rate >= 1 then
        return true
    end
    return crawl.random_real() < rate
end

local function collect_tags(tag_defs, default_rate)
    if not tag_defs then
        return {}
    end
    local tags = {}
    for _, tag in ipairs(tag_defs) do
        if type(tag) == "table" then
            if tag.tag and should_apply_tag(tag.rate or default_rate) then
                table.insert(tags, tag.tag)
            end
        elseif tag and should_apply_tag(default_rate) then
            table.insert(tags, tag)
        end
    end
    return tags
end

local function merge_tags(list1, list2)
    if not list1 or #list1 == 0 then
        return list2 or {}
    end
    if not list2 or #list2 == 0 then
        return list1
    end
    local out = {}
    for _, tag in ipairs(list1) do
        table.insert(out, tag)
    end
    for _, tag in ipairs(list2) do
        table.insert(out, tag)
    end
    return out
end

local function sanitize_item_tags(tags)
    if not tags or #tags == 0 then
        return {}
    end
    local filtered = {}
    local seen = {}
    local brand_candidates = {}
    for _, tag in ipairs(tags) do
        if tag and tag ~= "" and not seen[tag] then
            if tag:match("^ego:") then
                seen[tag] = true
                table.insert(brand_candidates, tag)
            else
                seen[tag] = true
                table.insert(filtered, tag)
            end
        end
    end
    if #brand_candidates > 0 then
        local choice = brand_candidates[1]
        if crawl and crawl.random2 then
            local idx = crawl.random2(#brand_candidates) + 1
            choice = brand_candidates[idx]
        end
        table.insert(filtered, choice)
    end
    return filtered
end

local function build_item(base, opts)
    opts = opts or {}
    if not base or base == "" then
        return nil
    end
    local entry_tags = collect_tags(opts.entry_tags, opts.entry_tag_rate)
    local tier_tags = collect_tags(opts.tier_tags, opts.tier_tag_rate)
    local extra_tags = opts.extra_tags or {}
    local tags = merge_tags(entry_tags, merge_tags(tier_tags, extra_tags))
    tags = sanitize_item_tags(tags)
    local item = {
        base = trim_string(base),
        qty = opts.qty,
        tags = tags,
    }
    local desc = item.base
    for _, tag in ipairs(tags) do
        desc = desc .. " " .. tag
    end
    if item.qty and item.qty > 0 then
        desc = desc .. " q:" .. item.qty
    end
    item.desc = desc
    return item
end

local function guard_roll_to_string(roll)
    if not roll or not roll.species then
        return nil
    end
    local spec = roll.species
    if roll.main_item then
        spec = spec .. " ; " .. roll.main_item.desc
    else
        spec = spec .. " ; nothing"
    end
    for _, item in ipairs(roll.extra_items or {}) do
        spec = spec .. " . " .. item.desc
    end
    return spec
end

local function guard_roll_items(roll)
    local items = {}
    if not roll then
        return items
    end
    if roll.main_item then
        table.insert(items, roll.main_item)
    end
    for _, item in ipairs(roll.extra_items or {}) do
        table.insert(items, item)
    end
    return items
end

local function parse_category_type(value)
    if type(value) ~= "string" then
        return nil, nil
    end
    local category, tier = value:match("^([^%.]+)%.(.+)$")
    return category, tier
end

local function normalize_creature_key(key)
    if not key then
        return nil
    end
    return key:gsub("_body$", "")
end

local function type_to_species(key)
    if not key then
        return nil
    end
    key = key:gsub("_body$", "")
    return key:gsub("_", " ")
end

local function conditions_match(conditions, roll)
    if not conditions or #conditions == 0 then
        return true
    end
    local creature_key = normalize_creature_key(roll.type or "")
    for _, cond in ipairs(conditions) do
        if cond.for_creature then
            if normalize_creature_key(cond.for_creature) ~= creature_key then
                return false
            end
        end
        if cond.for_target and cond.for_target ~= roll.target then
            return false
        end
    end
    return true
end

local function unique_condition_met(cond, item)
    if not cond or not item then
        return false
    end
    if cond.base and cond.base ~= item.base then
        return false
    end
    if cond.tags then
        local missing = false
        for _, tag in ipairs(cond.tags) do
            local found = false
            for _, applied in ipairs(item.tags or {}) do
                if applied == tag then
                    found = true
                    break
                end
            end
            if not found then
                missing = true
                break
            end
        end
        if missing then
            return false
        end
    end
    return true
end

local function apply_unique_replacements(category_spec, roll)
    if not category_spec or not category_spec.unique_replacements then
        return
    end
    if not roll or not roll.main_item then
        return
    end
    local store = dgn.persist.resonance_forge_uniques
    if not store then
        store = {}
        dgn.persist.resonance_forge_uniques = store
    end
    for _, repl in ipairs(category_spec.unique_replacements) do
        local cond = repl.conditions
        if unique_condition_met(cond, roll.main_item) then
            local key = repl.replace_with or ""
            local rate = repl.rate or 0
            if key ~= "" and not store[key] and crawl.random_real() < rate then
                roll.main_item = {
                    base = key,
                    desc = key,
                    tags = {},
                }
                store[key] = true
                break
            end
        end
    end
end

local function add_item_to_roll(roll, item)
    if not item then
        return
    end
    if not roll.main_item then
        roll.main_item = item
    else
        table.insert(roll.extra_items, item)
    end
end

local function add_entry_items_to_roll(roll, entry, tier_tags, tier_tag_rate)
    if not entry then
        return
    end
    if entry.pairs then
        local pair = pick_pair(entry.pairs)
        for idx, base in ipairs(pair) do
            if base ~= "nothing" then
                local item = build_item(base, {
                    entry_tags = entry.tags,
                    entry_tag_rate = entry.tag_rate,
                    tier_tags = tier_tags,
                    tier_tag_rate = tier_tag_rate,
                    qty = idx == 1 and entry.qty or nil,
                })
                add_item_to_roll(roll, item)
            end
        end
        return
    end

    local bases = split_item_list(entry.primary or entry.base or entry.item)
    for idx, base in ipairs(bases) do
        if base ~= "nothing" then
            local item = build_item(base, {
                entry_tags = entry.tags,
                entry_tag_rate = entry.tag_rate,
                tier_tags = tier_tags,
                tier_tag_rate = tier_tag_rate,
                qty = idx == 1 and entry.qty or nil,
            })
            add_item_to_roll(roll, item)
        end
    end

    if entry.armour then
        local armour_items = split_item_list(entry.armour)
        for _, armour in ipairs(armour_items) do
            if armour ~= "nothing" then
                local armour_item = build_item(armour, {
                    entry_tags = entry.armour_tags or entry.tags,
                    entry_tag_rate = entry.armour_tag_rate or entry.tag_rate,
                    tier_tags = tier_tags,
                    tier_tag_rate = tier_tag_rate,
                })
                if armour_item then
                    table.insert(roll.extra_items, armour_item)
                end
            end
        end
    end
end

local function select_distribution_entry(entries)
    if not entries or #entries == 0 then
        return nil
    end
    local total = 0
    for _, entry in ipairs(entries) do
        total = total + (entry.weight or 1)
    end
    if total <= 0 then
        return entries[crawl.random2(#entries) + 1]
    end
    local roll = crawl.random2(total)
    for _, entry in ipairs(entries) do
        local weight = entry.weight or 1
        if roll < weight then
            return entry
        end
        roll = roll - weight
    end
    return entries[#entries]
end

local function select_tier(bucket_spec)
    if not bucket_spec or not bucket_spec.tier_distribution then
        return "common"
    end
    local choice = select_distribution_entry(bucket_spec.tier_distribution)
    if choice and choice.distribution_type then
        return choice.distribution_type
    end
    return "common"
end

local function select_creature_type(category_spec, tier_data)
    if not category_spec or not category_spec.creature_distribution then
        return nil
    end
    local valid = {}
    local total = 0
    for _, entry in ipairs(category_spec.creature_distribution) do
        if entry.type and tier_data and resolve_tier_entry_key(tier_data, entry.type) then
            local weight = entry.weight or 1
            if weight > 0 then
                total = total + weight
                table.insert(valid, { type = entry.type, weight = weight })
            end
        end
    end
    if total == 0 then
        local choice = select_distribution_entry(category_spec.creature_distribution)
        return choice and choice.type
    end
    local roll = crawl.random2(total)
    for _, entry in ipairs(valid) do
        if roll < entry.weight then
            return entry.type
        end
        roll = roll - entry.weight
    end
    return valid[#valid].type
end

function resonance_forge_debug_select_type(bucket_name, target, forced_tier)
    local bucket_spec = ENTRY_GUARD_BUCKETS[bucket_name]
    if not bucket_spec then
        return nil, "bucket_missing"
    end
    local category_spec = bucket_spec[target]
    if not category_spec then
        return nil, "category_missing"
    end
    local tier_name = forced_tier or select_tier(bucket_spec)
    local tier_data = category_spec[tier_name]
    if not tier_data then
        tier_name = "common"
        tier_data = category_spec[tier_name]
    end
    if not tier_data then
        return nil, "tier_missing"
    end
    local type_key = select_creature_type(category_spec)
    if not type_key then
        return nil, "distribution_missing"
    end
    return type_key, tier_name
end

function resolve_tier_entry_key(tier_data, type_key)
    if not tier_data or not type_key then
        return nil
    end
    if tier_data[type_key] then
        return type_key
    end
    local alt = type_key .. "_body"
    if tier_data[alt] then
        return alt
    end
    return nil
end

local function resolve_support_entries(category_spec, tier_name)
    if not category_spec then
        return nil
    end
    local search = { tier_name or "common" }
    if tier_name ~= "common" then
        table.insert(search, "common")
    end
    for _, name in ipairs(search) do
        local tier = category_spec[name]
        if tier and tier.support_guards and #tier.support_guards > 0 then
            return tier.support_guards, tier, name
        end
    end
    return nil
end

local function build_support_guard_roll(bucket_name, target, tier_name, tier_data,
        category_spec, opts, depth)
    local entries = tier_data and tier_data.support_guards
    if not entries or #entries == 0 then
        entries, tier_data, tier_name = resolve_support_entries(category_spec, tier_name)
        if not entries then
            return nil
        end
    end
    local tried = {}

    while true do
        local idx = weighted_index(entries, tried)
        if not idx then
            break
        end
        tried[idx] = true
        local entry = entries[idx]
        -- Try each support guard option until one yields a valid roll.
        if not (entry.conditions and not conditions_match(entry.conditions, {
            target = target,
            type = entry.type or entry.creature,
            species = entry.species,
        })) then
            if entry.source then
                local category, tier = parse_category_type(entry.source)
                if category then
                    local forced_type = entry.type
                    if not forced_type and entry.species then
                        forced_type = entry.species:gsub(" ", "_")
                    end
                    local roll = build_guard_roll(bucket_name, category, {
                        tier = tier,
                        type = forced_type,
                        species_override = entry.species,
                        skip_unique = opts and opts.skip_unique,
                    }, depth + 1)
                    if roll then
                        return roll
                    end
                end
            else
                local roll = {
                    bucket = bucket_name,
                    target = target,
                    tier = tier_name,
                    type = entry.type or (entry.species and entry.species:gsub(" ", "_")),
                    species = entry.species or type_to_species(entry.type),
                    extra_items = {},
                }
                add_entry_items_to_roll(roll, entry, nil, nil)
                if not roll.main_item then
                    local scale_name = DRAGON_SCALE_DROPS[roll.species]
                    if scale_name then
                        local scale_item = build_item(scale_name, {
                            entry_tags = entry.tags,
                            entry_tag_rate = entry.tag_rate,
                        })
                        if scale_item then
                            table.insert(roll.extra_items, scale_item)
                        end
                        roll.main_item = { base = "nothing", desc = "nothing" }
                    end
                end
                if not roll.main_item then
                    roll.main_item = build_item(DEFAULT_TARGET_ITEMS[target] or "nothing")
                end
                if roll.main_item then
                    return roll
                end
            end
        end
    end

    return nil
end

function apply_pairings_to_roll(roll, tier_data, bucket_name, opts, depth)
    if not tier_data or not tier_data.pairings then
        return
    end
    for _, group in ipairs(tier_data.pairings) do
        local candidates = {}
        for _, entry in ipairs(group) do
            if not entry.conditions or conditions_match(entry.conditions, roll) then
                table.insert(candidates, entry)
            end
        end
        local choice = weighted_pick(candidates)
        if choice then
            if choice.type then
                if choice.type ~= "nothing" then
                    local category, tier = parse_category_type(choice.type)
                    if category and depth < MAX_GUARD_SPEC_DEPTH then
                        local sub_roll = build_guard_roll(roll.bucket, category, {
                            tier = tier,
                            type = roll.type,
                            species_override = roll.species,
                            as_attachment = true,
                            ignore_pairings = true,
                            skip_unique = true,
                        }, depth + 1)
                        if sub_roll then
                            for _, item in ipairs(guard_roll_items(sub_roll)) do
                                if item.base ~= "nothing" then
                                    table.insert(roll.extra_items, item)
                                end
                            end
                        end
                    end
                end
            else
                local bases = split_item_list(choice.base or choice.item)
                for _, base in ipairs(bases) do
                    if base ~= "nothing" then
                        local item = build_item(base, {
                            entry_tags = choice.tags,
                            entry_tag_rate = choice.tag_rate,
                            tier_tags = nil,
                            qty = choice.qty,
                        })
                        if item then
                            table.insert(roll.extra_items, item)
                        end
                    end
                end
            end
        end
    end
end

build_guard_roll = function(bucket_name, target, opts, depth)
    opts = opts or {}
    depth = depth or 0
    if depth == 0 then
        last_guard_error = nil
    end
    if depth > MAX_GUARD_SPEC_DEPTH then
        return nil
    end
    local bucket_spec = ENTRY_GUARD_BUCKETS[bucket_name]
    if not bucket_spec then
        if forge_debug_enabled() then
            local keys = {}
            for name in pairs(ENTRY_GUARD_BUCKETS) do
                table.insert(keys, name or "<nil>")
            end
            crawl.mpr(string.format("[forge-debug] guard bucket lookup failed for '%s'; available buckets: %s",
                bucket_name or "nil", #keys > 0 and table.concat(keys, ", ") or "<none>"))
        end
        if depth == 0 then
            last_guard_error = string.format("bucket %s missing", bucket_name or "nil")
        end
        return nil
    end
    local category_spec = bucket_spec[target]
    if not category_spec then
        if depth == 0 then
            last_guard_error = string.format("category %s missing", target or "nil")
        end
        return nil
    end
    local tier_name = opts.tier or select_tier(bucket_spec)
    local tier_data = category_spec[tier_name]
    if not tier_data then
        tier_name = "common"
        tier_data = category_spec[tier_name]
    end
    if not tier_data then
        if depth == 0 then
            last_guard_error = string.format("tier %s missing", tier_name or "nil")
        end
        return nil
    end
    local type_key = opts.type or select_creature_type(category_spec, tier_data)
    if not type_key then
        if depth == 0 then
            last_guard_error = "creature distribution missing"
        end
        return nil
    end

    if type_key == "support_guards" then
        local roll = build_support_guard_roll(bucket_name, target, tier_name,
            tier_data, category_spec, opts, depth)
        if not roll and depth == 0 then
            last_guard_error = "support guard generation failed"
        end
        return roll
    end

    local entry_key = resolve_tier_entry_key(tier_data, type_key)
    if not entry_key then
        if depth == 0 then
            last_guard_error = string.format("entry key %s missing", type_key)
        end
        return nil
    end
    local entries = tier_data[entry_key]
    if not entries or #entries == 0 then
        if depth == 0 then
            last_guard_error = string.format("entries for %s empty", entry_key)
        end
        return nil
    end
    local entry = weighted_pick(entries)
    if not entry then
        if depth == 0 then
            last_guard_error = "weighted pick failed"
        end
        return nil
    end

    local roll = {
        bucket = bucket_name,
        target = target,
        tier = tier_name,
        type = type_key,
        species = opts.species_override or entry.species or type_to_species(entry_key),
        extra_items = {},
    }

    add_entry_items_to_roll(roll, entry, tier_data.tags, tier_data.tag_rate)
    if not opts.ignore_pairings then
        apply_pairings_to_roll(roll, tier_data, bucket_name, opts, depth)
    end
    if not roll.main_item then
        local fallback = DEFAULT_TARGET_ITEMS[target]
        if fallback then
            roll.main_item = build_item(fallback)
        end
    end
    if not opts.skip_unique then
        apply_unique_replacements(category_spec, roll)
    end
    return roll
end


local GUARDIAN_WAVE_FILL = {}
if RESONANCE_SPEC.guardian_waves and RESONANCE_SPEC.guardian_waves.bucket then
    for _, entry in ipairs(RESONANCE_SPEC.guardian_waves.bucket) do
        GUARDIAN_WAVE_FILL[entry.name] = {
            outer = entry.outer_fill_rate or entry.outer_fill or 1,
            inner = entry.inner_fill_rate or entry.inner_fill or 1,
        }
    end
end

local function guardian_fill_rate(bucket, slot_key)
    local fill = GUARDIAN_WAVE_FILL[bucket]
    if not fill then
        return 1
    end
    if slot_key == "inner" then
        return fill.inner or 1
    end
    return fill.outer or 1
end

local STEAM_BUCKETS = {
    [BUCKETS.early.name] = true,
    [BUCKETS.mid.name] = true,
}

local GARGOYLE_GUARDS = {
    [BUCKETS.mid.name] = { primary = { "gargoyle" }, secondary = { "war gargoyle" } },
    [BUCKETS.late.name] = { primary = { "war gargoyle" }, secondary = { "molten gargoyle" } },
}

local GOLEM_GUARDS = {
    [BUCKETS.mid.name] = { primary = { "peacekeeper" } },
    [BUCKETS.late.name] = { primary = { "peacekeeper" }, secondary = { "toenail golem" } },
}

local GOLEM_CHANCE = 5
local GARGOYLE_CHANCE = 7
local STEAM_CHANCE = 10

local function random_choice(list)
    if not list or #list == 0 then
        return nil
    end
    local idx = crawl.random2(#list) + 1
    return list[idx]
end

local function choose_common_guard(bucket, target, forced_type)
    local opts
    if forced_type then
        opts = { type = forced_type }
    end
    local roll = build_guard_roll(bucket, target, opts)
    if roll then
        local spec = guard_roll_to_string(roll)
        if spec then
            return spec
        end
        debug_guard_failure(bucket, target, "roll_to_string_failed")
    else
        debug_guard_failure(bucket, target, last_guard_error or "roll_failed")
    end
    if not guard_failure_reported then
        local reason = last_guard_error or "unknown"
        crawl.mpr(string.format(
            "<lightred>Forge guard spec failed (%s/%s): %s</lightred>",
            bucket or "?", target or "?", reason))
        guard_failure_reported = true
    end
    local species = random_choice(ENTRY_GUARD_DEFAULT) or "human"
    local item = DEFAULT_TARGET_ITEMS[target] or "hand axe"
    return string.format("%s ; %s", species, item)
end

local function weighted_choice(pools, weights)
    local total = 0
    for _, w in ipairs(weights) do
        total = total + w
    end
    local roll = crawl.random2(total)
    local accum = 0
    for idx, w in ipairs(weights) do
        accum = accum + w
        if roll < accum then
            return random_choice(pools[idx])
        end
    end
    return nil
end

local function choose_gargoyle_guard(bucket)
    local pools = GARGOYLE_GUARDS[bucket]
    if not pools then
        return nil
    end
    local choices = {}
    local weights = {}
    if pools.primary then
        table.insert(choices, pools.primary)
        table.insert(weights, 70)
    end
    if pools.secondary then
        table.insert(choices, pools.secondary)
        table.insert(weights, 25)
    end
    if pools.tertiary then
        table.insert(choices, pools.tertiary)
        table.insert(weights, 5)
    end
    if #choices == 0 then
        return nil
    end
    return weighted_choice(choices, weights)
end

local function choose_golem_guard(bucket, target)
    local pools = GOLEM_GUARDS[bucket]
    if not pools then
        return nil
    end
    local choices = {}
    local weights = {}
    local function add_pool(pool, weight)
        if pool and #pool > 0 then
            table.insert(choices, pool)
            table.insert(weights, weight)
        end
    end
    add_pool(pools.primary, 75)
    add_pool(pools.secondary, 25)
    if #choices == 0 then
        return nil
    end
    return weighted_choice(choices, weights)
end

local function choose_guard_spec(bucket, target)
    if bucket and crawl.random2(100) < GOLEM_CHANCE then
        local golem = choose_golem_guard(bucket, target)
        if golem then
            return golem
        end
    end
    if bucket and GARGOYLE_GUARDS[bucket] and crawl.random2(100) < GARGOYLE_CHANCE then
        return choose_gargoyle_guard(bucket)
    end
    if STEAM_BUCKETS[bucket] and crawl.random2(100) < STEAM_CHANCE then
        return "steam dragon"
    end
    return choose_common_guard(bucket, target)
end

local SpawnMarker = util.subclass(PortalDescriptor)
SpawnMarker.CLASS = "ResonanceForgeSpawnMarker"

function SpawnMarker:new(props)
    return PortalDescriptor.new(self, props or {})
end

function SpawnMarker:property(marker, pname)
    local value = self.props[pname]
    if value ~= nil then
        return value
    end
    return self.super.property(self, marker, pname)
end

function SpawnMarker:event(marker, ev)
    return true
end

local ResonanceForgeMarker = util.subclass(PortalDescriptor)
ResonanceForgeMarker.CLASS = "ResonanceForgeMarker"

function ResonanceForgeMarker:new(props)
    props = props or {}
    if not props.target then
        error("resonance forge marker missing target type")
    end
    props.difficulty = props.difficulty or dgn.persist.resonance_forge_difficulty
    props.branch = props.branch or dgn.persist.resonance_forge_branch
    props.depth = props.depth or dgn.persist.resonance_forge_depth
    props.uses = props.uses or 0
    return PortalDescriptor.new(self, props)
end

function ResonanceForgeMarker:activate(marker)
    local ev = dgn.dgn_event_type('player_climb')
    dgn.register_listener(ev, marker, marker:pos())
end

local function _forgewright_text(target)
    return string.format("This forge can retune an equipped %s. "
        .. "Stand upon the dais and press '>' to channel it. Each use will "
        .. "summon more constructs.", target)
end

local function prompt_forge_use(target)
    if type(target) ~= "string" then
        return false
    end
    return crawl.resonance_forge_prompt(target)
end

function ResonanceForgeMarker:property(marker, pname)
    if pname == "feature_description" then
        return "Stand upon the dais and press '>' to operate the forge."
    end
    if pname == "feature_description_long" then
        return _forgewright_text(self.props.target)
    end
    return self.super.property(self, marker, pname)
end

local function get_spawn_positions(prop, key)
    local pts = dgn.find_marker_positions_by_prop(prop, key) or {}
    return pts
end

local function random_spawn_point(key)
    local pts = get_spawn_positions("resonance_forge_spawn", key)
    if #pts == 0 then
        return nil
    end

    local idx = crawl.random2(#pts) + 1
    return pts[idx]
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = crawl.random2(i) + 1
        list[i], list[j] = list[j], list[i]
    end
end

local function maybe_spawn_failure_cloud(marker)
    if not marker or not crawl.coinflip() then
        return
    end
    local x, y
    local pos = marker:pos()
    if type(pos) == "table" then
        x, y = pos.x, pos.y
    else
        x, y = marker:pos()
    end
    if not x or not y then
        return
    end
    local cloud = FAILURE_CLOUD_TYPES[crawl.random2(#FAILURE_CLOUD_TYPES) + 1]
    dgn.apply_area_cloud(x, y, 8, 12, 1, 1, cloud, "other", -1)
end

local ABYSS_REPLACEMENT_RULES = {
    early_dungeon = { branch = "Abyss", depth = 1, min = 1, max = 2, use_range = true },
    mid_dungeon = { branch = "Abyss", depth = 1, min = 1, fraction = 0.25 },
    late_dungeon = { branch = "Abyss", depth = 2, min = 1, fraction = 0.25 },
}

local function abyss_replacement_count(bucket, total)
    if total <= 0 then
        return 0
    end
    local rule = ABYSS_REPLACEMENT_RULES[bucket]
    if not rule then
        return 0
    end
    local count = 0
    if rule.use_range and rule.min and rule.max then
        count = crawl.random_range(rule.min, rule.max)
    elseif rule.fraction then
        count = math.floor(total * rule.fraction + 0.5)
    end
    if rule.min and count < rule.min then
        count = rule.min
    end
    if rule.max and count > rule.max then
        count = rule.max
    end
    if count > total then
        count = total
    end
    if count < 0 then
        count = 0
    end
    return count, rule
end

local function apply_abyss_replacements(spawns, bucket)
    if not spawns or #spawns == 0 then
        return
    end
    local count, rule = abyss_replacement_count(bucket, #spawns)
    if count == 0 or not rule then
        return
    end
    shuffle(spawns)
    for i = 1, count do
        local spawn = spawns[i]
        if spawn then
            local abyss_mon = crawl.random_monster(rule.branch, rule.depth)
            if not abyss_mon or abyss_mon == "" then
                abyss_mon = choose_common_guard(bucket, "weapon")
            end
            if abyss_mon and abyss_mon ~= "" then
                spawn.monster = abyss_mon
            end
        end
    end
end

local function wave_place(base_depth, uses)
    local depth = base_depth + uses + 1
    local branch = "D"
    local catastrophic = false
    if depth > 15 then
        depth = depth - 15
        branch = "Depths"
        if depth > 5 then
            depth = 5
            catastrophic = true
        end
    end
    if depth < 1 then
        depth = 1
    end
    return branch, depth, catastrophic
end

local function spawn_wave_monsters(branch, depth, bucket, key, opts)
    opts = opts or {}
    local slots = get_spawn_positions("resonance_forge_spawn", key)
    if not slots or #slots == 0 then
        return
    end
    shuffle(slots)
    bucket = bucket or BUCKETS.mid.name
    local fill_rate = guardian_fill_rate(bucket, key)
    if forge_debug_enabled() then
        crawl.mpr(string.format("[forge-debug] wave bucket=%s key=%s slots=%d rate=%.2f",
            bucket or "?", key or "?", #slots, fill_rate or -1))
    end
    local selected = {}
    for _, pos in ipairs(slots) do
        local roll = crawl.random_real()
        local passed = roll <= fill_rate
        if forge_debug_enabled() then
            crawl.mpr(string.format("[forge-debug] wave slot (%d,%d) key=%s roll=%.3f rate=%.3f %s",
                pos.x or -1, pos.y or -1, key or "?", roll, fill_rate or -1,
                passed and "spawn" or "skip"))
        end
        if not passed then
            goto continue
        end
        local mon = crawl.random_monster(branch, depth)
        if not mon or mon == "" then
            mon = choose_common_guard(bucket, "weapon")
        end
        if mon and mon ~= "" then
            table.insert(selected, { pos = pos, monster = mon })
        end
        ::continue::
    end
    if opts.catastrophic and #selected > 0 then
        apply_abyss_replacements(selected, bucket)
    end
    for _, spawn in ipairs(selected) do
        place_guardian(spawn.pos.x, spawn.pos.y, spawn.monster)
    end
end

local function current_branch_depth()
    local branch = "D"
    local depth = BUCKETS.mid.depth[1]
    if you and you.where_are_you then
        branch = you.where_are_you() or branch
    elseif dgn and dgn.branch then
        branch = dgn.branch() or branch
    end
    if you and you.depth then
        depth = you.depth() or depth
    elseif dgn and dgn.depth then
        depth = dgn.depth() or depth
    end
    return branch, depth
end

local function bucket_for_branch_depth(branch, depth)
    depth = depth or 0
    if branch == "D" then
        if depth <= BUCKETS.early.depth[2] then
            return BUCKETS.early.name
        elseif depth <= BUCKETS.mid.depth[2] then
            return BUCKETS.mid.name
        elseif depth <= BUCKETS.late.depth[2] then
            return BUCKETS.late.name
        end
        return BUCKETS.late.name
    end
    return nil
end

local function bucket_name()
    if dgn.persist.resonance_forge_difficulty then
        if not dgn.persist.resonance_forge_branch or not dgn.persist.resonance_forge_depth then
            local br, dp = current_branch_depth()
            dgn.persist.resonance_forge_branch = dgn.persist.resonance_forge_branch or br
            dgn.persist.resonance_forge_depth = dgn.persist.resonance_forge_depth or dp
        end
        return dgn.persist.resonance_forge_difficulty
    end
    local branch, depth = current_branch_depth()
    dgn.persist.resonance_forge_branch = branch
    dgn.persist.resonance_forge_depth = depth
    local bucket = bucket_for_branch_depth(branch, depth)
    dgn.persist.resonance_forge_difficulty = bucket
    return bucket
end

local function roll_forge_target()
    return TARGETS[crawl.random2(#TARGETS) + 1]
end

function resonance_forge_random_target()
    if dgn.persist and dgn.persist.resonance_forge_forced_target then
        local forced = dgn.persist.resonance_forge_forced_target
        dgn.persist.resonance_forge_forced_target = nil
        return forced
    end
    return roll_forge_target()
end

function resonance_forge_spawn_marker(prop)
    return SpawnMarker:new(prop)
end

function resonance_forge_entry_marker()
    local marker = TriggerableFunction:new {
        func = "resonance_forge_position_player",
    }
    marker:add_triggerer(DgnTriggerer:new { type = "entered_level" })
    return marker
end

function resonance_forge_position_player(data, triggerable, triggerer, marker, ev)
    if dgn.persist.resonance_forge_entry_aligned then
        return
    end
    if not you or not you.pos then
        return
    end
    local pos = marker:pos()
    local target_x, target_y
    if type(pos) == "table" then
        target_x, target_y = pos.x, pos.y
    else
        target_x, target_y = marker:pos()
    end
    if not target_x or not target_y then
        return
    end
    local px, py = you.pos()
    if px ~= target_x or py ~= target_y then
        you.moveto(target_x, target_y)
    end
    resonance_forge_populate()
    dgn.persist.resonance_forge_entry_aligned = true
end

function resonance_forge_anchor_marker(prop)
    prop = prop or {}
    prop.resonance_forge_anchor = prop.resonance_forge_anchor or "entry"
    return resonance_forge_spawn_marker(prop)
end

local function spawn_initial_guards(target, bucket)
    local guard_slots = get_spawn_positions("resonance_forge_guard", "slot")
    if not guard_slots or #guard_slots == 0 then
        return
    end
    bucket = bucket or bucket_name() or BUCKETS.mid.name
    shuffle(guard_slots)
    for _, pos in ipairs(guard_slots) do
        local spec = choose_guard_spec(bucket, target)
        if spec then
            dgn.create_monster(pos.x, pos.y, spec)
        end
    end
end

local function select_forgewright_spells(bucket)
    local book = FORGEWRIGHT_SPELLBOOKS[bucket]
    if not book then
        return nil
    end
    local selected = {}
    for _, entry in ipairs(book) do
        local slug = select_spell_from_group(entry)
        if slug then
            table.insert(selected, slug)
        end
    end
    return selected
end

local function spawn_forgewright(bucket)
    local anchor = get_spawn_positions("resonance_forge_anchor", "forge")[1]
    if anchor then
        local spec = "resonance forgewright"
        local spells = select_forgewright_spells(bucket)
        if spells and #spells > 0 then
            local spell_spec = build_spell_spec(spells)
            if spell_spec then
                spec = spec .. " " .. spell_spec
            end
        end
        dgn.create_monster(anchor.x, anchor.y, spec)
    end
end

local function hazard_statue_choice(target, bucket)
    if bucket == BUCKETS.early.name then
        return "iron statue"
    end
    if target == "ranged" or target == "thrown" then
        return "lightning spire"
    end
    return random_choice(HAZARD_STATUE_CHOICES)
end

local function spawn_hazard_statues(target, bucket)
    local hazards = get_spawn_positions("resonance_forge_statue", "hazard")
    if not hazards or #hazards == 0 then
        return
    end
    bucket = bucket or bucket_name() or BUCKETS.mid.name
    for _, pos in ipairs(hazards) do
        local species = hazard_statue_choice(target, bucket)
        if species == "iron statue" then
            dgn.terrain_changed(pos.x, pos.y, "metal statue")
        elseif species then
            dgn.create_monster(pos.x, pos.y, species)
        end
    end
end

local function spawn_conduit_spires(target, bucket)
    if target ~= "ranged" and target ~= "thrown" then
        return
    end
    bucket = bucket or bucket_name() or BUCKETS.mid.name
    local species = bucket == BUCKETS.early.name and "iron statue"
        or "lightning spire"
    local conduits = get_spawn_positions("resonance_forge_conduit", "spire")
    for _, pos in ipairs(conduits) do
        if species == "iron statue" then
            dgn.terrain_changed(pos.x, pos.y, "metal statue")
        else
            dgn.create_monster(pos.x, pos.y, species)
        end
    end
end

resonance_forge_populate = function(target)
    if dgn.persist.resonance_forge_populated then
        return
    end
    target = target or dgn.persist.resonance_forge_target
    if not target then
        return
    end
    local bucket = bucket_name() or BUCKETS.mid.name
    spawn_hazard_statues(target, bucket)
    spawn_forgewright(bucket)
    spawn_initial_guards(target, bucket)
    spawn_conduit_spires(target, bucket)
    dgn.persist.resonance_forge_populated = true
end

function resonance_forge_spawn_wave(marker_obj, forced_branch, forced_depth, opts)
    opts = opts or {}
    local branch = marker_obj.props.branch or dgn.persist.resonance_forge_branch or "D"
    local base_depth = marker_obj.props.depth
        or dgn.persist.resonance_forge_depth or BUCKETS.mid.depth[1]
    local uses = marker_obj.props.uses or 1
    local wave_branch = forced_branch
    local wave_depth = forced_depth
    if not wave_branch or not wave_depth then
        wave_branch, wave_depth = wave_place(base_depth, uses)
    end
    local bucket = marker_obj.props.difficulty
        or bucket_for_branch_depth(branch, base_depth) or BUCKETS.mid.name
    if opts.catastrophic then
        crawl.mpr("<lightred>Abyssal resonance ripples through the guardian ranks!</lightred>")
    else
        crawl.mpr("<lightred>Resonant guardians awaken!</lightred>")
    end
    spawn_wave_monsters(wave_branch, wave_depth, bucket, "outer", opts)
    spawn_wave_monsters(wave_branch, wave_depth, bucket, "inner", opts)
end

function ResonanceForgeMarker:event(marker, ev)
    if ev:type() ~= dgn.dgn_event_type('player_climb') then
        return true
    end
    local x, y = ev:pos()
    if self.props.ruptured then
        crawl.mpr("Fractures lace the forge; it can no longer be used.")
        return true
    end
    local target = self.props.target
    if not prompt_forge_use(target) then
        crawl.mpr("You step away from the forge.")
        return true
    end
    local base_depth = self.props.depth
        or dgn.persist.resonance_forge_depth or BUCKETS.mid.depth[1]
    local next_use = (self.props.uses or 0) + 1
    local preview_branch, preview_depth, depth_catastrophe = wave_place(base_depth, next_use)
    if depth_catastrophe then
        crawl.mpr("<lightred>The forge convulses as it strains past the Depths and ruptures catastrophically!</lightred>")
        self.props.uses = next_use
        self.props.ruptured = true
        resonance_forge_spawn_wave(self, preview_branch, preview_depth, { catastrophic = true })
        maybe_spawn_failure_cloud(marker)
        return true
    end
    local success, msg, spawn_wave = crawl.resonance_forge_apply(target)
    if msg and msg ~= "" then
        crawl.mpr(msg)
    end
    if not success then
        return true
    end
    self.props.uses = next_use
    local rupture_now = crawl.one_chance_in(3)
    if spawn_wave then
        resonance_forge_spawn_wave(self, preview_branch, preview_depth, {
            catastrophic = rupture_now,
        })
    end
    if rupture_now then
        crawl.mpr("<lightred>The forge ruptures under the strain and can no longer be used.</lightred>")
        self.props.ruptured = true
        maybe_spawn_failure_cloud(marker)
    else
        warn_forge_strain()
    end
    return true
end

function resonance_forge_marker(props)
    return ResonanceForgeMarker:new(props)
end

function resonance_forge_clear_persist()
    dgn.persist.resonance_forge_difficulty = nil
    dgn.persist.resonance_forge_branch = nil
    dgn.persist.resonance_forge_depth = nil
    dgn.persist.resonance_forge_target = nil
    dgn.persist.resonance_forge_spawned = nil
    dgn.persist.resonance_forge_populated = nil
    dgn.persist.resonance_forge_entry_aligned = nil
    dgn.persist.resonance_forge_uniques = nil
    dgn.persist.resonance_forge_uses = nil
    dgn.persist.resonance_forge_wave_preview = nil
    dgn.persist.resonance_forge_forced_target = nil
    crawl.mpr("Resonance forge persistent state cleared.")
end

local function portal_timeout()
    return crawl.random_range(600, 800)
end

local function forge_message()
    return timed_msg {
        initmsg = {
            "A dull clang rings in the distance.",
            "You sense a gate to a Resonance Forge nearby. Hurry before it collapses!"
        },
        finalmsg = "The forging gate lets out a dying shriek!",
        verb = 'ringing',
        noisemaker = 'forge',
        ranges = {
            { 6000, 'faint ' },
            { 4000, '' },
            { 2000, 'loud ' },
            { 0, 'ear-splitting ' },
        }
    }
end

local function set_depth_chances(e)
    e.chance(0)
    e.depth_chance("D:5-7", 333)
    e.depth_chance("D:8-13", 333)
    e.depth_chance("D:14-15", 333)
end

function resonance_forge_portal_entry(e)
    if dgn.persist.resonance_forge_spawned then
        e.chance(0)
        return
    end
    if crawl then
        crawl.mpr("<lightred>A resonant clang rings nearby. "
            .. "A forge gate has opened on this floor!</lightred>")
    end

    local bucket = bucket_name()
    if not bucket then
        e.chance(0)
        return
    end

    dgn.persist.resonance_forge_spawned = true

    e.lua_marker('P',
        timed_marker {
            disappear = "The resonant hum dies away as the portal seals shut.",
            entity = 'forge',
            turns = portal_timeout(),
            single_timed = true,
            floor = "expired_portal",
            feat_tile = "dngn_portal_resonance_forge_gone",
            msg = forge_message(),
        })

    e.tags("chance_resonance_forge no_monster_gen no_item_gen")
    e.kfeat("P = enter_forge")
    e.tile("P = dngn_portal_resonance_forge")
    e.tile("c = wall_stone_smooth")
    e.ftile(".Pc = floor_marble")
    set_depth_chances(e)
end

local function loot_weights()
    return {
        ["scroll of enchant weapon"] = 10,
        ["scroll of enchant armour"] = 10,
        ["scroll of brand weapon"] = 8,
        ["hand cannon good_item"] = 6,
        ["arbalest good_item"] = 6,
        ["triple crossbow good_item"] = 6,
        ["manual of forgecraft"] = 4,
        ["randbook disc:forgecraft"] = 4,
        ["steam dragon scales randart"] = 4,
        ["cloak ego:preservation good_item"] = 5,
        ["chain mail ego:ponderousness good_item"] = 4,
        ["longbow ego:electrocution good_item"] = 5,
        ["arbalest ego:penetration good_item"] = 5,
        ["bolt ego:silver"] = 5,
        ["triple crossbow egos:penetration good_item"] = 4,
        ["maxwell's thermic engine"] = 3,
        ["heavy crossbow Sniper"] = 2,
        ["hand cannon Mule"] = 2,
    }
end

function resonance_forge_place_loot(e, glyphs)
    local loot = loot_weights()
    for i = 1, #glyphs do
        local g = glyphs:sub(i, i)
        e.kitem(string.format("%s = %s", g,
            dgn.random_item_def(loot, "", "")))
    end
end

function resonance_forge_setup(e, target)
    dgn.persist.resonance_forge_entry_aligned = nil
    dgn.persist.resonance_forge_populated = nil
    dgn.persist.resonance_forge_target = target
    e.lua_marker("F", resonance_forge_marker {
        target = target,
        difficulty = bucket_name(),
        branch = dgn.persist.resonance_forge_branch,
        depth = dgn.persist.resonance_forge_depth,
    })
end

function resonance_forge_configure_portal(e, target)
    local chosen = target
    if not chosen then
        if dgn.persist then
            dgn.persist.resonance_forge_forced_target = nil
        end
        chosen = roll_forge_target()
        if dgn.persist then
            dgn.persist.resonance_forge_forced_target = chosen
        end
    elseif dgn.persist then
        dgn.persist.resonance_forge_forced_target = chosen
    end
    if e then
        resonance_forge_setup(e, chosen)
    else
        local _ = bucket_name()
        dgn.persist.resonance_forge_entry_aligned = nil
        dgn.persist.resonance_forge_populated = nil
        dgn.persist.resonance_forge_target = chosen
    end
    return chosen
end
