return function()
-- bloodless_surrender_core_v8_4_1_presentation.lua
-- Rome II / DEI: standalone campaign module
--
-- Surrender = Tactical OR Strategic.
--
-- Tactical:
--   ally_bar / enemy_bar >= Clementia-adjusted threshold / 219
--   Clementia -100 / 0 / +100 -> threshold 205 / 180 / 170
--
-- Strategic (all clauses are OR):
--   1) current effective field strength <= 1/3 of the max over last 7 snapshots
--   2) current effective field strength <= 1/5 of the max over last 15 snapshots
--   3) from campaign turn 6:
--        4+ regions : current < 10 effective cards
--        2-3 regions: current <  6
--        1 region   : current <  4
--
-- Strength history is sampled at FactionTurnStart and persisted in saves.
-- V8 adds a second native-payload-marker dilemma after accepted surrender.

local scripting = require "lua_scripts.EpisodicScripting"

local PREFIX = "[BLOODLESS CORE V8.7.7] "
local GATE_DILEMMA_KEY = "dei_bloodless_surrender_gate_v74"
local DISPOSITION_DILEMMA_KEY = "dei_bloodless_surrender_disposition_v8"
local SAVE_KEY = "dei_bloodless_surrender_strength_history_v2"
local CLEMENTIA_SAVE_KEY = "dei_bloodless_surrender_clementia_v1"
local LOOT_UNREST_SAVE_KEY = "dei_bloodless_surrender_loot_unrest_v1"

local NATIVE_TRIGGER = "dei_bs_v871_native_continue"
local REQUEST_BUTTON = "dei_bs_recommend_surrender_probe"
local FLEET_BUTTON = "dei_bs_recommend_surrender_fleet"
local request_fleet = false
local request_closed, request_turn = false, nil
local evaluation_complete, request_refused = false, false
local CHECK_TRIGGER   = "bloodless_v76b_check"
local OFFER_TRIGGER   = "bloodless_v76b_offer"
local DETECT_TRIGGER  = "bloodless_v76b_poll_choice"
local ACCEPT_TRIGGER  = "bloodless_v76b_accept_transfer"
local VERIFY_TRIGGER  = "bloodless_v76b_verify_transfer"

local DISP_SHOW_TRIGGER     = "bloodless_v8_disposition_show"
local DISP_DETECT_TRIGGER   = "bloodless_v8_disposition_detect"
local DISP_APPLY_TRIGGER    = "bloodless_v8_disposition_apply"
local LOOT_BUILDING_TRIGGER = "bloodless_v8_loot_building"

local TACTICAL_AT_ZERO = 180
local TACTICAL_AT_PLUS_100 = 170
local TACTICAL_AT_MINUS_100 = 205

-- Clementia: faction-wide reputation for treatment of surrendering enemies.
-- Range: -100 .. +100
--
-- Local-threat threshold for Strategic Capitulation is piecewise linear:
--   Clementia +100 -> 40 / 219
--   Clementia  +50 -> 56.5 / 219
--   Clementia    0 -> 73 / 219
--   Clementia  -50 -> 111.5 / 219
--   Clementia -100 -> 150 / 219
--
-- Tactical Surrender uses a separate, narrower Clementia adjustment.
local CLEMENTIA_MIN = -100
local CLEMENTIA_MAX = 100
local CLEMENTIA_DECAY_PER_HUMAN_TURN = 1

local LOCAL_THREAT_AT_ZERO = 73
local LOCAL_THREAT_AT_PLUS_100 = 40
local LOCAL_THREAT_AT_MINUS_100 = 150

local CLEMENTIA_RELEASE_DELTA = 8
local CLEMENTIA_ENSLAVE_DELTA = -5
local CLEMENTIA_SLAUGHTER_DELTA = -15
local CLEMENTIA_PEACEFUL_SURRENDER_DELTA = 10
local CLEMENTIA_LOOTED_SURRENDER_DELTA = -20

local WINDOW_7 = 7
local WINDOW_15 = 15
local ABSOLUTE_FIRST_TURN = 6

local OFFER_DELAY = 0.75
-- Do NOT wait for PanelClosedCampaign:event_dilemma.
-- Rome II custom dilemmas do not reliably report that closure callback.
-- Poll the distinct native decision expenses instead.
local DETECT_DELAY = 0.20
local ACCEPT_DELAY = 0.90
local VERIFY_DELAY = 0.50
local MAX_VERIFY_RETRIES = 8 -- up to 2 additional seconds at RETRY_DELAY=0.25
local RETRY_DELAY = 0.25
local CHECK_DELAY = 0.12

-- Actual, non-refundable decision expenses; distinct native deltas also
-- identify the choice without observing its UI.
local ACCEPT_COST_DELTA = -100
local REJECT_COST_DELTA = -10

-- Second dilemma choice is identified by its ACTUAL native money payload.
-- This both gives the player the income and leaves a treasury delta that Lua
-- can poll safely, with no click interception and no reimbursement step.
local DISP_SHOW_DELAY = 0.20
local DISP_DETECT_DELAY = 0.20
local DISP_APPLY_DELAY = 0.90
local LOOT_BUILDING_STEP_DELAY = 0.20

-- DEI values supplied from the user's current campaign_variables_tables.
local OCCUPY_BASE_INCOME = 500
local OCCUPY_CONQUEST_PO = 15
local OCCUPY_SAME_CULTURE_PO = 5
local OCCUPY_DIFFERENT_CULTURE_PO = 10

local LOOT_BUILDING_DAMAGE_PERCENT = 50
local LOOT_BUILDING_DAMAGE_SPREAD_PERCENT = 15
local LOOT_CONQUEST_PO = 40
-- Custom final payout: 5000 + pre-transfer wealth * 5; no extra +20%.
local LOOT_INCOME_PERCENTAGE_MODIFIER = 0

local SETTLEMENT_LOOTING_BASE_LOOT = 5000
-- Trial balance coefficient, NOT the native DEI campaign-variable value.
-- Native loot parity is unverified; compare several settlements before release.
local SURRENDER_LOOT_WEALTH_FACTOR = 5
local SETTLEMENT_LOOTING_PCT_REGION_GDP_REDUCTION = 0.8
local SETTLEMENT_LOOTING_PUBLIC_ORDER_REDUCTION = 12
local SETTLEMENT_LOOTING_SURRENDER_PUBLIC_ORDER_REDUCTION = 15
local BAR_RETRY_DELAY = 0.10
local MAX_RETRIES = 20
local MAX_BAR_RETRIES = 10

local history = {}
local clementia = {}
local loot_unrest = {}

local disposition = {
    active = false,
    clementia_applied = false,
    treasury_before = nil,
    detected_choice = nil,
    region_key = nil,
    attacker_key = nil,
    defender_key = nil,
    attacker_culture = "",
    defender_culture = "",
    region_wealth = 0,
    peace_income = 0,
    loot_income = 0,
    retries = 0,
    building_keys = nil,
    building_index = 1
}

local state = {
    eligible = false,
    tactical = false,
    strategic = false,
    local_threat = false,
    offer_pending = false,
    dilemma_active = false,
    treasury_before = nil,
    detected_choice = nil,
    region_key = nil,
    attacker_key = nil,
    defender_key = nil,
    attacker_culture = "",
    defender_culture = "",
    region_wealth = 0,
    retries = 0,
    bar_retries = 0
}

local diagnostic_buffer = {}
local diagnostic_live = false
local diagnostic_opened = false
local function log(msg)
    -- Distribution build: diagnostic output disabled.
end

-- Each campaign script execution starts fresh state. Old callback closures
-- become inert if the engine retains them across a campaign reload.
_G.BLOODLESS_STANDALONE_GENERATION = (_G.BLOODLESS_STANDALONE_GENERATION or 0) + 1
local generation = _G.BLOODLESS_STANDALONE_GENERATION
_G.BLOODLESS_CORE_V81_INSTALLED = true
local function register(event, callback)
    scripting.AddEventCallBack(event, function(context)
        if generation == _G.BLOODLESS_STANDALONE_GENERATION then
            callback(context)
        end
    end)
end

local function find_readonly(id)
    local ok, component = pcall(function()
        local root = scripting.m_root
        if not root then return nil end
        local address = root:Find(id)
        if not address then return nil end
        return UIComponent(address)
    end)
    if ok then return component end
    return nil
end

local function cstring(context)
    if not context then return "" end
    local ok, v = pcall(function() return context.string end)
    if ok and v ~= nil then return tostring(v) end
    return ""
end

local function gi()
    if scripting and scripting.game_interface then return scripting.game_interface end
    return nil
end

local function trigger(name, delay)
    local g = gi()
    if g then g:add_time_trigger(name, delay) end
end

local function campaign_turn()
    local g = gi()
    if not g then return 1 end
    local ok, n = pcall(function() return g:model():turn_number() end)
    if ok and n then return tonumber(n) or 1 end
    return 1
end

local function pending_battle()
    local g = gi()
    if not g then return nil end
    local ok, pb = pcall(function() return g:model():pending_battle() end)
    if ok then return pb end
    return nil
end

local function pending_active()
    local pb = pending_battle()
    if not pb then return false end
    local ok, v = pcall(function() return pb:is_active() end)
    return ok and v
end

local function region_by_key(key)
    local g = gi()
    if not g or not key then return nil end
    local ok, r = pcall(function()
        return g:model():world():region_manager():region_by_key(key)
    end)
    if ok then return r end
    return nil
end

local function reset_battle_state()
    state.verify_retries=0
    state.attacker_cqi=nil
    request_closed, request_turn = false, nil
    evaluation_complete, request_refused = false, false
    state.eligible = false
    state.tactical = false
    state.strategic = false
    state.local_threat = false
    state.offer_pending = false
    state.dilemma_active = false
    state.treasury_before = nil
    state.detected_choice = nil
    state.region_key = nil
    state.attacker_key = nil
    state.defender_key = nil
    state.attacker_culture = ""
    state.defender_culture = ""
    state.region_wealth = 0
    state.retries = 0
    state.bar_retries = 0
end

local function safe_faction_culture(faction)
    if not faction then return "" end
    local ok, value = pcall(function() return faction:culture() end)
    if ok and value ~= nil then return tostring(value) end
    return ""
end

local function safe_region_wealth(region)
    if not region then return 0 end
    local ok, value = pcall(function() return region:region_wealth() end)
    if ok and value ~= nil then return tonumber(value) or 0 end
    return 0
end

local function round_nearest(value)
    local n = tonumber(value) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function clamp_public_order(value)
    local n = tonumber(value) or 0
    if n < -100 then n = -100 end
    if n > 100 then n = 100 end
    return n
end

local function modify_public_order(region_key, delta, reason)
    local region = region_by_key(region_key)
    if not region then
        log("PUBLIC ORDER skipped: region unavailable.")
        return false
    end

    local before = nil
    pcall(function() before = tonumber(region:public_order()) end)

    if before == nil then
        log("PUBLIC ORDER skipped: current value unavailable.")
        return false
    end

    local after = clamp_public_order(before + (tonumber(delta) or 0))

    local ok, err = pcall(function()
        gi():set_public_order_of_province_for_region(region_key, after)
    end)

    if not ok then
        log("PUBLIC ORDER ERROR: " .. tostring(err))
        return false
    end

    local verify = nil
    pcall(function() verify = tonumber(region:public_order()) end)

    log("PUBLIC ORDER " .. tostring(reason or "")
        .. " delta=" .. string.format("%+.1f", tonumber(delta) or 0)
        .. " " .. tostring(before) .. " -> " .. tostring(after)
        .. " verify=" .. tostring(verify))

    return true
end

local function add_treasury_verified(faction_key, amount, label)
    local faction = nil
    local factions = gi():model():world():faction_list()

    if factions then
        for i = 0, factions:num_items() - 1 do
            local f = factions:item_at(i)
            if f and f:name() == faction_key then
                faction = f
                break
            end
        end
    end

    local before = nil
    if faction then
        pcall(function() before = tonumber(faction:treasury()) end)
    end

    local ok, err = pcall(function()
        gi():treasury_mod(faction_key, amount)
    end)

    if not ok then
        log("TREASURY ERROR " .. tostring(label) .. ": " .. tostring(err))
        return false
    end

    local after = nil
    if faction then
        pcall(function() after = tonumber(faction:treasury()) end)
    end

    log("TREASURY " .. tostring(label)
        .. " +" .. tostring(amount)
        .. " before=" .. tostring(before)
        .. " after=" .. tostring(after))

    if before ~= nil and after ~= nil and after ~= before + amount then
        log("TREASURY VERIFY FAILED " .. tostring(label))
        return false
    end

    return true
end

local function reset_disposition()
    disposition.active = false
    disposition.clementia_applied = false
    disposition.treasury_before = nil
    disposition.detected_choice = nil
    disposition.region_key = nil
    disposition.attacker_key = nil
    disposition.defender_key = nil
    disposition.attacker_culture = ""
    disposition.defender_culture = ""
    disposition.region_wealth = 0
    disposition.peace_income = 0
    disposition.loot_income = 0
    disposition.retries = 0
    disposition.building_keys = nil
    disposition.building_index = 1
end

-- One full-strength land card = 1.0; 50%-strength card = 0.5.
local function unit_strength(unit)
    local ok, v = pcall(function()
        return unit:percentage_proportion_of_full_strength()
    end)
    if not ok or v == nil then return 1.0 end

    v = tonumber(v) or 100
    if v > 1 then v = v / 100 end
    if v < 0 then v = 0 end
    if v > 1 then v = 1 end
    return v
end

local function effective_field_strength(faction)
    if not faction then return 0, 0, 0 end

    local forces = faction:military_force_list()
    if not forces then return 0, 0, 0 end

    local total = 0
    local counted_forces = 0
    local counted_units = 0

    for i = 0, forces:num_items() - 1 do
        local force = forces:item_at(i)

        local is_army = false
        local has_general = false
        local has_garrison_residence = false
        local upkeep = nil

        pcall(function() is_army = force:is_army() end)
        pcall(function() has_general = force:has_general() end)
        pcall(function() has_garrison_residence = force:has_garrison_residence() end)
        pcall(function() upkeep = tonumber(force:upkeep()) end)

        -- Empirically verified in DEI:
        --   real army outside settlement:
        --      is_army=true, has_general=true, garrison_residence=false, upkeep>0
        --   real army stationed inside settlement:
        --      is_army=true, has_general=true, garrison_residence=true, upkeep>0
        --   free settlement garrison:
        --      is_army=true, has_general=true, garrison_residence=true, upkeep=0
        --
        -- Therefore exclude only the zero-upkeep garrison-residence force.
        -- Navies are already excluded by is_army=false.
        local free_settlement_garrison =
            has_garrison_residence == true
            and upkeep ~= nil
            and upkeep <= 0

        if is_army and has_general and not free_settlement_garrison then
            counted_forces = counted_forces + 1

            local units = force:unit_list()

            if units then
                for j = 0, units:num_items() - 1 do
                    local unit = units:item_at(j)
                    local is_land = true
                    pcall(function() is_land = unit:is_land_unit() end)

                    if is_land then
                        counted_units = counted_units + 1
                        total = total + unit_strength(unit)
                    end
                end
            end
        end
    end

    return total, counted_forces, counted_units
end

local function region_count(faction)
    if not faction then return 0 end
    local regions = faction:region_list()
    if not regions then return 0 end
    return regions:num_items()
end

local function history_for(key)
    if not history[key] then history[key] = {} end
    return history[key]
end

local function record_snapshot(faction)
    if not faction or region_count(faction) <= 0 then return end

    local key = faction:name()
    local value = effective_field_strength(faction)
    local h = history_for(key)

    h[#h + 1] = value
    while #h > WINDOW_15 do table.remove(h, 1) end

    log("SNAPSHOT " .. key
        .. " turn=" .. tostring(campaign_turn())
        .. " strength=" .. string.format("%.2f", value)
        .. " history=" .. tostring(#h))
end

local function max_last(h, n)
    if not h or #h < n then return nil end

    local m = 0
    for i = #h - n + 1, #h do
        local v = tonumber(h[i]) or 0
        if v > m then m = v end
    end
    return m
end

-- Persistence format:
-- faction=v1,v2,...;faction=v1,v2,...
local function serialize_history()
    local blocks = {}

    for key, h in pairs(history) do
        local vals = {}
        for i = 1, #h do
            vals[#vals + 1] = string.format("%.4f", tonumber(h[i]) or 0)
        end
        blocks[#blocks + 1] = key .. "=" .. table.concat(vals, ",")
    end

    return table.concat(blocks, ";")
end

local function deserialize_history(s)
    history = {}
    if type(s) ~= "string" or s == "" then return end

    for block in string.gmatch(s, "([^;]+)") do
        local key, vals = string.match(block, "^([^=]+)=(.*)$")

        if key and vals then
            local h = {}
            for token in string.gmatch(vals, "([^,]+)") do
                local n = tonumber(token)
                if n then h[#h + 1] = n end
            end
            while #h > WINDOW_15 do table.remove(h, 1) end
            history[key] = h
        end
    end
end


-- ---------------------------------------------------------------------------
-- Clementia
-- ---------------------------------------------------------------------------

local function clamp_clementia(value)
    local n = tonumber(value) or 0

    if n < CLEMENTIA_MIN then n = CLEMENTIA_MIN end
    if n > CLEMENTIA_MAX then n = CLEMENTIA_MAX end

    return n
end

local function get_clementia(faction_key)
    if not faction_key then return 0 end
    return clamp_clementia(clementia[faction_key] or 0)
end

local function set_clementia(faction_key, value)
    if not faction_key or faction_key == "" then return 0 end

    local n = clamp_clementia(value)
    clementia[faction_key] = n

    log("CLEMENTIA set " .. tostring(faction_key)
        .. " = " .. string.format("%.1f", n))

    return n
end

local function adjust_clementia(faction_key, delta, reason)
    if not faction_key or faction_key == "" then
        log("CLEMENTIA change ignored: no faction key.")
        return nil
    end

    local before = get_clementia(faction_key)
    local after = set_clementia(faction_key, before + (tonumber(delta) or 0))

    log("CLEMENTIA action " .. tostring(reason or "<unknown>")
        .. " faction=" .. tostring(faction_key)
        .. " delta=" .. string.format("%+.1f", tonumber(delta) or 0)
        .. " " .. string.format("%.1f", before)
        .. " -> " .. string.format("%.1f", after))

    return after
end

local function postbattle_event_faction(context)
    local character = nil

    pcall(function()
        character = context:character()
    end)

    if character then
        local faction = nil
        pcall(function()
            faction = character:faction()
        end)

        if faction then
            return faction
        end
    end

    local faction = nil
    pcall(function()
        faction = context:faction()
    end)

    return faction
end

local function apply_prisoner_clementia(context, delta, reason)
    local faction = postbattle_event_faction(context)

    if not faction then
        log("CLEMENTIA " .. tostring(reason)
            .. " event fired, but faction context was unavailable.")
        return
    end

    if not faction:is_human() then
        log("CLEMENTIA " .. tostring(reason)
            .. " ignored for non-human faction " .. tostring(faction:name()))
        return
    end

    adjust_clementia(faction:name(), delta, reason)
end

local function OnCharacterPostBattleRelease(context)
    apply_prisoner_clementia(context, CLEMENTIA_RELEASE_DELTA, "release_prisoners")
end

local function OnCharacterPostBattleEnslave(context)
    apply_prisoner_clementia(context, CLEMENTIA_ENSLAVE_DELTA, "enslave_prisoners")
end

local function OnCharacterPostBattleSlaughter(context)
    apply_prisoner_clementia(context, CLEMENTIA_SLAUGHTER_DELTA, "slaughter_prisoners")
end

local function decay_clementia(faction)
    if not faction or not faction:is_human() then
        return
    end

    local key = faction:name()
    local before = get_clementia(key)
    local after = before

    if before > 0 then
        after = math.max(0, before - CLEMENTIA_DECAY_PER_HUMAN_TURN)
    elseif before < 0 then
        after = math.min(0, before + CLEMENTIA_DECAY_PER_HUMAN_TURN)
    end

    clementia[key] = after

    if after ~= before then
        log("CLEMENTIA decay " .. tostring(key)
            .. " " .. string.format("%.1f", before)
            .. " -> " .. string.format("%.1f", after))
    else
        log("CLEMENTIA " .. tostring(key)
            .. " remains " .. string.format("%.1f", after))
    end
end

local function clementia_local_threshold_normalized(score)
    local c = clamp_clementia(score)
    local threshold

    if c >= 0 then
        -- 0 -> 73, +100 -> 40
        local span = LOCAL_THREAT_AT_ZERO - LOCAL_THREAT_AT_PLUS_100
        threshold = LOCAL_THREAT_AT_ZERO - span * (c / 100)
    else
        -- 0 -> 73, -100 -> 150
        local span = LOCAL_THREAT_AT_MINUS_100 - LOCAL_THREAT_AT_ZERO
        threshold = LOCAL_THREAT_AT_ZERO + span * ((-c) / 100)
    end

    if threshold < LOCAL_THREAT_AT_PLUS_100 then
        threshold = LOCAL_THREAT_AT_PLUS_100
    end

    if threshold > LOCAL_THREAT_AT_MINUS_100 then
        threshold = LOCAL_THREAT_AT_MINUS_100
    end

    return threshold
end

local function clementia_local_threshold_ratio(score)
    return clementia_local_threshold_normalized(score) / 219
end

local function serialize_clementia()
    local blocks = {}

    for key, value in pairs(clementia) do
        blocks[#blocks + 1] =
            tostring(key) .. "=" .. string.format("%.4f", clamp_clementia(value))
    end

    return table.concat(blocks, ";")
end

local function deserialize_clementia(serialized)
    clementia = {}

    if type(serialized) ~= "string" or serialized == "" then
        return
    end

    for block in string.gmatch(serialized, "([^;]+)") do
        local key, value = string.match(block, "^([^=]+)=([^=]+)$")

        if key and value then
            local n = tonumber(value)
            if n then
                clementia[key] = clamp_clementia(n)
            end
        end
    end
end

-- Temporary debug API for calibration.
-- It does not itself award Clementia for gameplay actions.
-- Example helper scripts can call these while V5 is installed.
_G.BLOODLESS_CLEMENTIA_SET = function(faction_key, value)
    return set_clementia(faction_key, value)
end

_G.BLOODLESS_CLEMENTIA_GET = function(faction_key)
    return get_clementia(faction_key)
end

_G.BLOODLESS_CLEMENTIA_ADJUST = function(faction_key, delta, reason)
    return adjust_clementia(faction_key, delta, reason or "debug/manual")
end

local function strategic_collapse(faction)
    local key = faction:name()
    local current, field_forces, field_units = effective_field_strength(faction)
    local regions = region_count(faction)
    local h = history[key] or {}

    local max7 = max_last(h, 7)
    local max15 = max_last(h, 15)

    local c7 = false
    local c15 = false
    local cabs = false

    if max7 and max7 > 0.01 then
        c7 = current <= (max7 / 3)
    end

    if max15 and max15 > 0.01 then
        c15 = current <= (max15 / 5)
    end

    local turn = campaign_turn()

    if turn >= ABSOLUTE_FIRST_TURN then
        if regions >= 4 then
            cabs = current < 10
        elseif regions >= 2 then
            cabs = current < 6
        elseif regions == 1 then
            cabs = current < 4
        end
    end

    log("STRATEGIC " .. key
        .. " turn=" .. tostring(turn)
        .. " regions=" .. tostring(regions)
        .. " field_forces=" .. tostring(field_forces)
        .. " field_units=" .. tostring(field_units)
        .. " current=" .. string.format("%.2f", current))

    if max7 then
        log("  7T max=" .. string.format("%.2f", max7)
            .. " threshold=" .. string.format("%.2f", max7 / 3)
            .. " collapse=" .. tostring(c7))
    else
        log("  7T unavailable: " .. tostring(#h) .. "/7 snapshots")
    end

    if max15 then
        log("  15T max=" .. string.format("%.2f", max15)
            .. " threshold=" .. string.format("%.2f", max15 / 5)
            .. " collapse=" .. tostring(c15))
    else
        log("  15T unavailable: " .. tostring(#h) .. "/15 snapshots")
    end

    if turn < ABSOLUTE_FIRST_TURN then
        log("  ABS exempt through campaign turn 5")
    else
        local threshold = regions >= 4 and 10 or (regions >= 2 and 6 or (regions == 1 and 4 or 0))
        log("  ABS threshold=<" .. tostring(threshold)
            .. " collapse=" .. tostring(cabs))
    end

    local result = c7 or c15 or cabs
    log("  STRATEGIC COLLAPSE=" .. tostring(result))

    return result
end

local function width(uic)
    if not uic then return nil end
    local ok, w = pcall(function()
        local a, b = uic:Dimensions()
        return a
    end)
    if ok then return tonumber(w) end
    return nil
end

local function clementia_tactical_threshold_normalized(score)
    local c = clamp_clementia(score)
    if c >= 0 then
        return TACTICAL_AT_ZERO
            - (TACTICAL_AT_ZERO - TACTICAL_AT_PLUS_100) * (c / 100)
    end
    return TACTICAL_AT_ZERO
        + (TACTICAL_AT_MINUS_100 - TACTICAL_AT_ZERO) * ((-c) / 100)
end

local function tactical_surrender(attacker_clementia)
    local ally = find_readonly("ally_bar")
    local full = find_readonly("enemy_bar")
    local aw, fw = width(ally), width(full)

    if not aw or not fw or fw <= 0 then
        return nil, nil
    end

    local ratio = aw / fw
    local threshold = clementia_tactical_threshold_normalized(attacker_clementia)
    local result = ratio >= threshold / 219

    log("TACTICAL normalized="
        .. string.format("%.1f", ratio * 219)
        .. " clementia=" .. string.format("%.1f", clamp_clementia(attacker_clementia))
        .. " threshold=" .. string.format("%.2f", threshold)
        .. "/219 result=" .. tostring(result))

    return result, ratio
end

local function evaluate_surrender()
    local pb = pending_battle()
    if not pb or not pb:is_active() then return end

    if not pb:has_attacker() or not pb:has_contested_garrison() then
        log("Rejected: not a settlement assault.")
        return
    end

    local attacker = pb:attacker()
    local attacker_faction = attacker:faction()

    if not attacker_faction or not attacker_faction:is_human() then
        log("Rejected: attacker is not human.")
        return
    end

    local region = pb:contested_garrison():region()
    if not region then return end

    local defender = region:owning_faction()
    if not defender then return end

    -- Strategic collapse is faction-wide, but it may only produce surrender
    -- if the attacking army still poses a credible local threat.
    local strategic = strategic_collapse(defender)
    local attacker_clementia = get_clementia(attacker_faction:name())
    local tactical, local_bar_ratio = tactical_surrender(attacker_clementia)

    -- Both Tactical and Strategic now need the ordinary pre-battle bar to be readable:
    -- Tactical uses it directly; Strategic uses it for the minimum-local-threat gate.
    if tactical == nil or local_bar_ratio == nil then
        state.bar_retries = state.bar_retries + 1

        if state.bar_retries <= MAX_BAR_RETRIES then
            log("Balance bar not ready; retry " .. tostring(state.bar_retries))
            trigger(CHECK_TRIGGER, BAR_RETRY_DELAY)
        else
            log("SURRENDER REJECTED: local balance bar unavailable.")
        end

        return
    end

    local local_min_normalized =
        clementia_local_threshold_normalized(attacker_clementia)
    local local_min_ratio =
        clementia_local_threshold_ratio(attacker_clementia)

    local local_threat = local_bar_ratio >= local_min_ratio

    log("CLEMENTIA attacker=" .. tostring(attacker_faction:name())
        .. " score=" .. string.format("%.1f", attacker_clementia))

    log("LOCAL THREAT normalized="
        .. string.format("%.1f", local_bar_ratio * 219)
        .. " minimum=" .. string.format("%.1f", local_min_normalized)
        .. "/219"
        .. " result=" .. tostring(local_threat))

    state.tactical = tactical == true
    state.strategic = strategic == true
    state.local_threat = local_threat == true

    -- Important:
    -- Tactical surrender stands on its own.
    -- Strategic capitulation requires BOTH strategic collapse AND minimum local threat.
    state.eligible =
        state.tactical
        or (state.strategic and state.local_threat)

    state.region_key = region:name()
    state.attacker_key = attacker_faction:name()
    state.defender_key = defender:name()
    state.attacker_culture = safe_faction_culture(attacker_faction)
    state.defender_culture = safe_faction_culture(defender)
    state.region_wealth = safe_region_wealth(region)

    evaluation_complete=true
    if not state.eligible then
        log("SURRENDER REJECTED:"
            .. " tactical=" .. tostring(state.tactical)
            .. " strategic=" .. tostring(state.strategic)
            .. " local_threat=" .. tostring(state.local_threat))
        return
    end

    log("SURRENDER ELIGIBLE region=" .. state.region_key
        .. " tactical=" .. tostring(state.tactical)
        .. " strategic=" .. tostring(state.strategic)
        .. " local_threat=" .. tostring(state.local_threat))
end

local function get_faction_by_key(key)
    if not key or key == "" then return nil end

    local factions = gi():model():world():faction_list()
    if not factions then return nil end

    for i = 0, factions:num_items() - 1 do
        local faction = factions:item_at(i)
        if faction and faction:name() == key then
            return faction
        end
    end

    return nil
end

-- The player's own button request replaces the old accept/reject money marker.
local function show_surrender_offer_when_safe()
    if not state.offer_pending then return end
    if request_turn ~= gi():model():turn_number() then
        log("REQUEST ABORT: turn changed")
        reset_battle_state();return
    end
    local read_ok, active = pcall(function()return gi():model():pending_battle():is_active()end)
    if not request_closed or not read_ok or active ~= false then
        state.retries=state.retries+1
        if state.retries<=MAX_RETRIES then trigger(OFFER_TRIGGER,RETRY_DELAY)
        else
            log("REQUEST ABORT: native continue did not close panel / clear pending battle")
            reset_battle_state()
        end
        return
    end
    if request_refused then
        local region=region_by_key(state.region_key)
        local ok_owner, owner=pcall(function()return region:owning_faction():name()end)
        if not ok_owner or owner~=state.defender_key then
            log("REFUSAL ABORT: region owner changed or unavailable")
            reset_battle_state();return
        end
        local faction=state.attacker_key
        -- Clear first: duplicate timers must never produce a second incident.
        reset_battle_state()
        local ok,err=pcall(function()
            gi():trigger_custom_incident(faction,"dei_bs_v872_surrender_refused")
        end)
        log("REFUSAL INCIDENT REQUEST: "..tostring(ok).." "..tostring(err))
        return
    end
    state.offer_pending=false
    state.detected_choice="accept"
    state.retries=0
    log("REQUEST SAFE: native panel closed and pending battle inactive; direct accept")
    trigger(ACCEPT_TRIGGER,ACCEPT_DELAY)
end

local function detect_native_payload_choice()
    if not state.dilemma_active
        or state.treasury_before == nil
        or not state.attacker_key then
        return
    end

    local attacker = get_faction_by_key(state.attacker_key)
    if not attacker then
        log("CHOICE DETECT abort: attacker unavailable.")
        reset_battle_state()
        return
    end

    local now = nil
    pcall(function() now = tonumber(attacker:treasury()) end)

    if now == nil then
        log("CHOICE DETECT abort: treasury unavailable.")
        reset_battle_state()
        return
    end

    local delta = now - state.treasury_before

    log("CHOICE DETECT treasury_before="
        .. tostring(state.treasury_before)
        .. " now=" .. tostring(now)
        .. " delta=" .. tostring(delta))

    if delta == ACCEPT_COST_DELTA then
        state.detected_choice = "accept"
        state.dilemma_active = false

        log("CHOICE DETECTED = ACCEPT from native -100 expense.")

        log("Surrender negotiation / handover preparation cost paid: 100 (no refund).")
        log("ACCEPT resolved; waiting before transfer.")
        trigger(ACCEPT_TRIGGER, ACCEPT_DELAY)
        return
    end

    if delta == REJECT_COST_DELTA then
        state.detected_choice = "reject"
        state.dilemma_active = false

        log("CHOICE DETECTED = REJECT from native -10 expense.")

        log("Envoy return / siege reorganisation cost paid: 10 (no refund).")

        log("No transfer. Siege remains in native campaign state.")
        reset_battle_state()
        return
    end

    state.retries = state.retries + 1

    -- The dilemma may remain open for an arbitrary amount of real time.
    -- Do not time out after a few tenths of a second; simply keep polling
    -- until the player makes a choice or the state is otherwise reset.
    if state.dilemma_active then
        if state.retries == 1 or state.retries % 10 == 0 then
            log("CHOICE POLL waiting... count=" .. tostring(state.retries))
        end
        trigger(DETECT_TRIGGER, DETECT_DELAY)
    end
end

local BS_POP_DIAGNOSTIC=false
local bs_population_begin,bs_population_apply
do
    local session=nil
    local function note(s)
        if not BS_POP_DIAGNOSTIC then return end
        pcall(function()
            local f=assert(io.open("bloodless_population_integration.log","a"))
            f:write("[POP INTEGRATION] "..tostring(s).."\n");f:close()
        end)
    end
    local function module()
        local m=package.loaded["lua_scripts.population"]
        assert(type(m)=="table","DEI population module unavailable")
        return m
    end
    local function snapshot(phase,key)
        local ok,err=pcall(function()
            local p=module().GetRegionPop(assert(region_by_key(key)))
            note(phase.." region="..key.." population="..table.concat(p,","))
        end)
        if not ok then note(phase.." ERROR "..tostring(err)) end
    end
    bs_population_begin=function(key,owner)
        session={key=key,owner=owner,turn=campaign_turn(),done=false,native=false}
        snapshot("BEFORE_TRANSFER",key)
    end
    -- Observe only native occupation of the exact target. Never synthesize events.
    register("GarrisonOccupiedEvent",function(context)
        local s=session
        if not s or s.done then return end
        local ok,key,owner=pcall(function()
            local c=context:character()
            return c:garrison_residence():region():name(),c:faction():name()
        end)
        if ok and key==s.key and owner==s.owner then
            s.native=true;note("NATIVE_OCCUPATION_OBSERVED; manual conversion will be skipped")
        end
    end)
    bs_population_apply=function(key,owner,choice)
        local s=session
        if not s or s.key~=key or s.owner~=owner or s.done then return end
        if pending_active() or campaign_turn()~=s.turn then
            note("SKIP pending battle/turn changed");return
        end
        if choice~="peace" and choice~="loot" then return end
        -- Mark before entering DEI code: failures cannot cause a second conversion.
        s.done=true
        if s.native then note("SKIP native occupation already observed");return end
        local ok,err=pcall(function()
            local m=module()
            assert(type(m.GetRegionPop)=="function" and type(m.SetRegionPop)=="function","DEI APIs unavailable")
            local r=assert(region_by_key(key))
            assert(r:owning_faction():name()==owner,"owner changed")
            local modifiers=m.population_modifier
            assert(type(modifiers)=="table","DEI modifiers unavailable")
            if modifiers.foreigner_mechanic_on~=true then note("SKIP foreigner mechanic disabled");return end
            local ui=assert(m.UIPopulation,"DEI UI table unavailable")
            local uirow=assert(ui[key],"DEI UI region unavailable")
            local flags=assert(m.rom_region_flag,"DEI flags unavailable")
            local flagrow=assert(flags[key],"DEI flag region unavailable")
            assert(type(uirow)=="table" and type(flagrow)=="table","invalid DEI rows")
            local live=assert(m.GetRegionPop(r))
            local before={}
            for i=1,4 do
                local n=tonumber(live[i])
                assert(n and n==n and n>=0 and n<math.huge,"invalid population")
                before[i]=n
            end
            local same=r:owning_faction():state_religion()==r:majority_religion()
            local total=before[1]+before[2]+before[3]+before[4]
            local out={}
            if choice=="loot" then
                if same then
                    for i=1,3 do out[i]=math.ceil(before[i]/4) end
                    out[4]=math.ceil(total/4)
                else out={1,1,1,math.ceil(total/2)} end
            else
                if same then
                    for i=1,3 do out[i]=math.ceil(before[i]/2) end
                    out[4]=before[4]+out[1]+out[2]+out[3]
                else out={10,20,40,total} end
            end
            note("APPLY choice="..choice.." same_culture="..tostring(same).." before="..table.concat(before,",").." requested="..table.concat(out,","))
            -- Use DEI's public setter (including its own population bounds).
            local success,detail=pcall(function()m.SetRegionPop(key,out[1],out[2],out[3],out[4])end)
            if not success then
                -- Restore the existing row if a setter failed part-way through.
                for i=1,4 do live[i]=before[i] end
                error(detail)
            end
            local after=m.GetRegionPop(r)
            for i=1,4 do uirow[i]=after[i] end
            -- Same growth flags consumed by DEI RegionPopGrowth.
            if choice=="loot" then flagrow[2]=true else flagrow[3]=true end
            note("APPLIED region="..key.." after="..table.concat(after,",").." ui="..table.concat(uirow,","))
            trigger("bs_population_verify",2)
        end)
        if not ok then note("FAILED "..tostring(err)) end
    end
    register("TimeTrigger",function(context)
        if cstring(context)=="bs_population_verify" and session and session.done then
            snapshot("AFTER_2S",session.key)
        end
    end)
    register("LoadingGame",function()session=nil end)
end

local function accept_transfer_when_safe()
    if request_turn ~= gi():model():turn_number() then
        log("TRANSFER ABORT: turn changed");reset_battle_state();return
    end
    if state.detected_choice ~= "accept"
        or not state.region_key
        or not state.attacker_key
        or not state.defender_key then
        return
    end

    if pending_active() then
        state.retries = state.retries + 1

        if state.retries <= MAX_RETRIES then
            trigger(ACCEPT_TRIGGER, RETRY_DELAY)
        else
            log("ABORT: pending battle active before ACCEPT transfer.")
            reset_battle_state()
        end

        return
    end

    local region = region_by_key(state.region_key)
    if not region then
        log("ABORT: region unavailable before ACCEPT transfer.")
        reset_battle_state()
        return
    end

    local owner = region:owning_faction()
    local owner_key = owner and owner:name() or ""

    if owner_key ~= state.defender_key then
        log("ABORT: owner changed before ACCEPT transfer: "
            .. tostring(owner_key))
        reset_battle_state()
        return
    end

    log("Player request accepted; native prebattle closure verified.")
    log("Transferring surrendered region now: " .. tostring(state.region_key))

    bs_population_begin(state.region_key,state.attacker_key)
    local ok, err = pcall(function()
        gi():transfer_region_to_faction(state.region_key, state.attacker_key)
    end)

    if not ok then
        log("TRANSFER ERROR: " .. tostring(err))
        reset_battle_state()
        return
    end

    state.verify_retries = 0
    trigger(VERIFY_TRIGGER, VERIFY_DELAY)
end

-- Exhaust only the commander who initiated this successful surrender.
local function exhaust_surrender_attacker()
    if request_turn ~= gi():model():turn_number() then
        log("MOVEMENT SKIPPED: turn changed after transfer")
        return
    end
    local cqi=state.attacker_cqi
    local ok,err=pcall(function()
        assert(cqi and cqi>0,"requesting commander CQI missing")
        local faction=get_faction_by_key(state.attacker_key)
        assert(faction,"requesting faction missing")
        local list=faction:character_list()
        local commander
        for i=0,list:num_items()-1 do
            local ch=list:item_at(i)
            if ch:cqi()==cqi then commander=ch;break end
        end
        assert(commander and commander:has_military_force(),"requesting commander/force no longer available")
        local result=gi():zero_action_points("character_cqi:"..tostring(cqi))
        assert(result~=false,"zero_action_points returned false")
        local read_ok,remaining=pcall(function()return commander:action_points_remaining_percent()end)
        log("MOVEMENT ZERO REQUEST cqi="..tostring(cqi).." remaining="..tostring(read_ok and remaining or "unavailable"))
        if read_ok and tonumber(remaining)==0 then
            log("MOVEMENT ZERO VERIFIED")
        else
            log("MOVEMENT ZERO NOT YET VERIFIED: inspect remaining movement in game")
        end
    end)
    if not ok then log("MOVEMENT ERROR: "..tostring(err)) end
end

local function verify_accept_transfer()
    if state.detected_choice ~= "accept" or not state.region_key then
        return
    end

    if request_turn ~= gi():model():turn_number() then
        log("VERIFY ABORT: turn changed.")
        reset_battle_state()
        return
    end

    -- Read-only retries: never repeat the region-transfer request.
    local function retry_verification(reason)
        local retries = state.verify_retries or 0
        if retries >= MAX_VERIFY_RETRIES then
            log("VERIFY ABORT: retry limit reached: " .. reason)
            reset_battle_state()
            return
        end
        state.verify_retries = retries + 1
        trigger(VERIFY_TRIGGER, RETRY_DELAY)
    end

    if pending_active() then
        retry_verification("pending battle active")
        return
    end

    local region = region_by_key(state.region_key)
    if not region then
        log("VERIFY ERROR: region unavailable.")
        reset_battle_state()
        return
    end

    local owner = region:owning_faction()
    local owner_key = owner and owner:name() or ""

    if owner_key == state.defender_key and owner_key ~= state.attacker_key then
        retry_verification("original defender still owns region")
        return
    end

    if owner_key ~= state.attacker_key then
        log("VERIFY FAILED: owner=" .. tostring(owner_key)
            .. " expected=" .. tostring(state.attacker_key))
        reset_battle_state()
        return
    end

    log("ACCEPT TRANSFER VERIFIED. New owner=" .. tostring(owner_key))
    exhaust_surrender_attacker()

    -- Copy everything needed by the second dilemma before clearing battle state.
    disposition.region_key = state.region_key
    disposition.attacker_key = state.attacker_key
    disposition.defender_key = state.defender_key
    disposition.attacker_culture = state.attacker_culture
    disposition.defender_culture = state.defender_culture
    disposition.region_wealth = tonumber(state.region_wealth) or 0
    disposition.retries = 0

    reset_battle_state()

    log("Scheduling post-transfer peaceful-occupation / loot dilemma.")
    trigger(DISP_SHOW_TRIGGER, DISP_SHOW_DELAY)
end



-- ---------------------------------------------------------------------------
-- V8: post-transfer disposition dilemma
-- ---------------------------------------------------------------------------

local function show_disposition_dilemma()
    if not disposition.region_key
        or not disposition.attacker_key then
        return
    end

    if pending_active() then
        disposition.retries = disposition.retries + 1
        trigger(DISP_SHOW_TRIGGER, RETRY_DELAY)
        return
    end

    local region = region_by_key(disposition.region_key)
    if not region then
        log("DISPOSITION abort: region unavailable.")
        reset_disposition()
        return
    end

    local owner = region:owning_faction()
    if not owner or owner:name() ~= disposition.attacker_key then
        log("DISPOSITION abort: ownership changed.")
        reset_disposition()
        return
    end

    local attacker = get_faction_by_key(disposition.attacker_key)
    if not attacker then
        log("DISPOSITION abort: attacker faction unavailable.")
        reset_disposition()
        return
    end

    local before = nil
    pcall(function() before = tonumber(attacker:treasury()) end)
    if before == nil then
        log("DISPOSITION abort: treasury baseline unavailable.")
        reset_disposition()
        return
    end

    disposition.active = true
    disposition.treasury_before = before
    disposition.detected_choice = nil
    disposition.retries = 0

    local wealth = tonumber(disposition.region_wealth)
        or safe_region_wealth(region)

    local common_loot =
        SETTLEMENT_LOOTING_BASE_LOOT
        + wealth * SURRENDER_LOOT_WEALTH_FACTOR

    local loot_income =
        round_nearest(
            common_loot
            * (1 + LOOT_INCOME_PERCENTAGE_MODIFIER / 100)
        )

    disposition.peace_income = OCCUPY_BASE_INCOME
    disposition.loot_income = loot_income

    log("Showing post-transfer disposition dilemma.")
    log("Disposition treasury baseline=" .. tostring(before))
    log("FIRST/PEACE native income=+" .. tostring(disposition.peace_income))
    log("SECOND/LOOT native income=+" .. tostring(disposition.loot_income))
    log("LOOT preview: wealth=" .. string.format("%.2f", wealth)
        .. " common_loot=" .. string.format("%.2f", common_loot)
        .. " modifier=+" .. tostring(LOOT_INCOME_PERCENTAGE_MODIFIER) .. "%")

    local ok, err = pcall(function()
        gi():trigger_custom_dilemma(
            disposition.attacker_key,
            DISPOSITION_DILEMMA_KEY,
            "payload { money " .. tostring(disposition.peace_income) .. "; }",
            "payload { money " .. tostring(disposition.loot_income) .. "; }",
            true
        )
    end)

    if not ok then
        log("DISPOSITION DILEMMA ERROR: " .. tostring(err))
        reset_disposition()
        return
    end

    trigger(DISP_DETECT_TRIGGER, DISP_DETECT_DELAY)
end

local function detect_disposition_choice()
    if not disposition.active
        or disposition.treasury_before == nil
        or not disposition.attacker_key then
        return
    end

    local attacker = get_faction_by_key(disposition.attacker_key)
    if not attacker then
        reset_disposition()
        return
    end

    local now = nil
    pcall(function() now = tonumber(attacker:treasury()) end)
    if now == nil then
        reset_disposition()
        return
    end

    local delta = now - disposition.treasury_before

    if delta == disposition.peace_income then
        disposition.detected_choice = "peace"
        disposition.active = false

        log("DISPOSITION DETECTED = PEACEFUL OCCUPATION"
            .. " from native income +" .. tostring(delta) .. ".")

        trigger(DISP_APPLY_TRIGGER, DISP_APPLY_DELAY)
        return
    end

    if delta == disposition.loot_income then
        disposition.detected_choice = "loot"
        disposition.active = false

        log("DISPOSITION DETECTED = LOOT"
            .. " from native income +" .. tostring(delta) .. ".")

        trigger(DISP_APPLY_TRIGGER, DISP_APPLY_DELAY)
        return
    end

    disposition.retries = disposition.retries + 1
    if disposition.active then
        if disposition.retries == 1 or disposition.retries % 10 == 0 then
            log("DISPOSITION POLL waiting... count="
                .. tostring(disposition.retries))
        end
        trigger(DISP_DETECT_TRIGGER, DISP_DETECT_DELAY)
    end
end

-- V8.6.3: native, province-scoped unrest on the settlement's stationary colonel.
-- Entries remain separate so repeated looting adds rather than silently resets.
local unrest_bindings = {}
local UNREST_PREFIX = "dei_bs_v86_unrest_"
local UNREST_SYNC = "dei_bs_v86_unrest_sync"
local unrest_sync_retries = 0
-- UICreated and FactionTurnStart can be delivered while a save is restoring.
-- Only a known native player click unlocks the new native-effect subsystem.
local unrest_runtime_ready = false
local function has_unrest_work()
    return #loot_unrest > 0 or next(unrest_bindings) ~= nil
end

local function unrest_colonel(region)
    local owner, chars, count
    local ok = pcall(function()
        owner = region:owning_faction()
        chars = owner:character_list()
        count = chars:num_items()
    end)
    if not ok then log("UNREST owner/character list unavailable"); return nil, nil end
    local owner_key = owner:name()
    for i = 0, count - 1 do
        -- A character without a valid region must not abort the entire search.
        local found, cqi = pcall(function()
            local ch = chars:item_at(i)
            if not ch:character_type("colonel") then return nil end
            local r = ch:region()
            -- Reference mod uses interface equality; key equality is fallback.
            if r == region or (r and r:name() == region:name()) then
                local cqi = ch:cqi()
                local has_force = ch:has_military_force()
                if not has_force then
                    log("UNREST NO FORCE cqi=" .. tostring(cqi) .. "; will retry, not applied")
                    return nil
                end
                local force = ch:military_force()
                if not force then
                    log("UNREST NULL FORCE cqi=" .. tostring(cqi) .. "; will retry")
                    return nil
                end
                local count_ok, count = pcall(function() return force:unit_list():num_items() end)
                if not count_ok then
                    log("UNREST FORCE QUERY FAILED cqi=" .. tostring(cqi) .. "; will retry")
                    return nil
                end
                log("UNREST FORCE READY cqi=" .. tostring(cqi)
                    .. " units=" .. (count_ok and tostring(count) or "unknown"))
                return cqi
            end
        end)
        if found and tonumber(cqi) and tonumber(cqi) > 0 then
            return tonumber(cqi), owner_key
        end
        if not found then log("UNREST skipped invalid character index=" .. tostring(i)) end
    end
    log("UNREST colonel not found owner=" .. owner_key .. " scanned=" .. tostring(count))
    return nil, owner_key
end

local function clear_unrest_binding(region_key)
    local binding = unrest_bindings[region_key]
    if not binding then return true end
    local ok, result = pcall(function()
        return gi():remove_effect_bundle_from_characters_force(
            UNREST_PREFIX .. tostring(binding.amount), binding.cqi)
    end)
    if not ok or result == false then
        log("UNREST REMOVE FAILED region=" .. region_key .. " cqi=" .. tostring(binding.cqi) .. " detail=" .. tostring(result))
        return false
    end
    unrest_bindings[region_key] = nil
    return true
end

local function sync_loot_unrest()
    if not unrest_runtime_ready or not has_unrest_work() then return true end
    if pending_active() then return false end
    local totals = {}
    for _, e in ipairs(loot_unrest) do
        totals[e.region_key] = (totals[e.region_key] or 0) + e.remaining
    end
    local obsolete = {}
    for key in pairs(unrest_bindings) do
        if not totals[key] then obsolete[#obsolete + 1] = key end
    end
    local complete = true
    for _, key in ipairs(obsolete) do
        if not clear_unrest_binding(key) then complete = false end
    end
    for key, amount in pairs(totals) do
        local region = region_by_key(key)
        local cqi, owner
        if region then cqi, owner = unrest_colonel(region) end
        local old = unrest_bindings[key]
        if old and (old.cqi ~= cqi or old.owner ~= owner or old.amount ~= amount or old.needs_refresh) then
            if clear_unrest_binding(key) then old = nil else complete = false end
        end
        if not old then
            if cqi and amount >= 1 and amount <= 255 then
                local ok, result = pcall(function()
                    return gi():apply_effect_bundle_to_characters_force(
                        UNREST_PREFIX .. tostring(amount), cqi, 5)
                end)
                if ok and result ~= false then
                    unrest_bindings[key] = {cqi=cqi, owner=owner, amount=amount}
                    log("UNREST APPLY REQUESTED region=" .. key .. " cqi=" .. tostring(cqi)
                        .. " owner=" .. tostring(owner) .. " key=" .. UNREST_PREFIX .. tostring(amount)
                        .. " duration=5 result=" .. tostring(result)
                        .. " (call returned; native effect/UI not introspectable)")
                else
                    complete = false
                    log("UNREST APPLY FAILED region=" .. key .. " cqi=" .. tostring(cqi) .. " detail=" .. tostring(result))
                end
            else
                complete = false
                log("UNREST WAIT region=" .. key .. " colonel=" .. tostring(cqi)
                    .. " amount=" .. tostring(amount))
            end
        end
    end
    return complete
end

local function schedule_unrest_sync()
    if not unrest_runtime_ready or not has_unrest_work() then return end
    unrest_sync_retries = 0
    trigger(UNREST_SYNC, 0.5)
end

local function serialize_loot_unrest()
    local blocks = {"V86"}
    for _, e in ipairs(loot_unrest) do
        blocks[#blocks + 1] = table.concat({"R", e.region_key, e.remaining,
            e.started_turn or -1, e.started_owner or "", e.completed_turn or -1}, ",")
    end
    for key, b in pairs(unrest_bindings) do
        blocks[#blocks + 1] = table.concat({"B", key, b.amount, b.cqi, b.owner}, ",")
    end
    return table.concat(blocks, ";")
end

local function deserialize_loot_unrest(serialized)
    unrest_runtime_ready = false
    diagnostic_live = false
    unrest_sync_retries = 0
    loot_unrest = {}
    unrest_bindings = {}
    if type(serialized) ~= "string" then return end
    for block in string.gmatch(serialized, "([^;]+)") do
        local key, n, turn, owner, completed = string.match(block, "^R,([^,]+),(%d+),([%-0-9]+),([^,]*),([%-0-9]+)$")
        if key then
            loot_unrest[#loot_unrest + 1] = {region_key=key, remaining=tonumber(n),
                started_turn=tonumber(turn), started_owner=owner, completed_turn=tonumber(completed)}
        else
            local bkey, amount, cqi, faction = string.match(block, "^B,([^,]+),(%d+),(%d+),([^,]+)$")
            if bkey then
                unrest_bindings[bkey] = {amount=tonumber(amount), cqi=tonumber(cqi), owner=faction, needs_refresh=true}
            else
                -- V8.5 migration: remaining was the NEXT direct deduction.
                local legacy_key, value = string.match(block, "^([^,]+),(%d+)$")
                if legacy_key and tonumber(value) > 0 then
                    loot_unrest[#loot_unrest + 1] = {region_key=legacy_key, remaining=tonumber(value)}
                end
            end
        end
    end
    -- LoadingGame must ONLY restore Lua data. No timers or game-state queries.
end

local function activate_unrest_after_input(context)
    local id = cstring(context)
    if id == "button_end_turn" or id == "button_continue_siege" then
        if not unrest_runtime_ready then
            unrest_runtime_ready = true
            diagnostic_live = true
            log("UNREST runtime enabled by native campaign input: " .. id)
            -- The click is already in the live campaign. Reconcile existing
            -- unrest before an end-turn click advances the campaign.
            sync_loot_unrest()
            schedule_unrest_sync()
        end
    end
end

local function add_loot_unrest(region_key)
    -- This function is reached only after the LIVE disposition money payload
    -- was detected and region ownership verified, never during save loading.
    unrest_runtime_ready = true
    diagnostic_live = true
    log("UNREST new looting region=" .. tostring(region_key))
    loot_unrest[#loot_unrest + 1] = {region_key=region_key,
        remaining=SETTLEMENT_LOOTING_PUBLIC_ORDER_REDUCTION - 1}
    sync_loot_unrest()
    schedule_unrest_sync()
end

local function process_loot_unrest_for_faction(faction)
    if not unrest_runtime_ready or not has_unrest_work() then return end
    if not faction then return end
    -- Mark only a bundle that was already in place before this turn began.
    -- Install/rebind failures never trigger a hidden direct-PO fallback.
    local turn, faction_key = campaign_turn(), faction:name()
    local totals = {}
    for _, e in ipairs(loot_unrest) do
        totals[e.region_key] = (totals[e.region_key] or 0) + e.remaining
    end
    for _, e in ipairs(loot_unrest) do
        local b = unrest_bindings[e.region_key]
        local region = region_by_key(e.region_key)
        local cqi, owner
        if region then cqi, owner = unrest_colonel(region) end
        if b and b.amount == totals[e.region_key]
            and b.cqi == cqi and b.owner == owner and owner == faction_key
            and e.completed_turn ~= turn then
            e.started_turn, e.started_owner = turn, faction_key
            local po_ok, po_value = pcall(function() return region:public_order() end)
            log("UNREST TURN START turn=" .. tostring(turn) .. " region=" .. e.region_key
                .. " stage=" .. tostring(e.remaining) .. " aggregate=" .. tostring(b.amount)
                .. " public_order=" .. (po_ok and tostring(po_value) or "unavailable"))
        end
    end
    sync_loot_unrest()
end

local function finish_loot_unrest_turn(context)
    if not unrest_runtime_ready or not has_unrest_work() then return end
    local faction = context:faction()
    if not faction then return end
    local turn, key = campaign_turn(), faction:name()
    for i = #loot_unrest, 1, -1 do
        local e = loot_unrest[i]
        if e.started_turn == turn and e.started_owner == key then
            e.remaining = e.remaining - 1
            e.completed_turn = turn
            e.started_turn, e.started_owner = nil, nil
            if e.remaining <= 0 then table.remove(loot_unrest, i) end
        end
    end
    sync_loot_unrest()
end

local function unrest_time_trigger(context)
    if not unrest_runtime_ready or not has_unrest_work() then return end
    if cstring(context) == UNREST_SYNC then
        if not sync_loot_unrest() and unrest_sync_retries < 60 then
            unrest_sync_retries = unrest_sync_retries + 1
            trigger(UNREST_SYNC, 0.5)
        elseif unrest_sync_retries >= 60 then
            log("UNREST RETRY LIMIT: inspect colony/owner/character log above")
        end
    end
end

local function collect_region_buildings(region)
    local result = {}
    local seen = {}

    if not region then return result end

    local slots = nil
    pcall(function() slots = region:slot_list() end)

    if not slots then return result end

    for i = 0, slots:num_items() - 1 do
        local slot = slots:item_at(i)
        local has_building = false
        pcall(function() has_building = slot:has_building() end)

        if has_building then
            local building = nil
            pcall(function() building = slot:building() end)

            if building then
                local key = nil
                pcall(function() key = building:name() end)

                if key and key ~= "" and not seen[key] then
                    local health = 100
                    pcall(function()
                        health = tonumber(building:percent_health()) or 100
                    end)

                    seen[key] = true
                    result[#result + 1] = {
                        key = tostring(key),
                        health = health
                    }
                end
            end
        end
    end

    return result
end

-- Award reputation at the existing disposition completion points only.
-- The V81 installation guard is deliberately shared: never install both cores.
local function apply_disposition_clementia_once()
    if disposition.clementia_applied
        or not disposition.region_key
        or not disposition.attacker_key then
        return
    end

    local delta, reason
    if disposition.detected_choice == "peace" then
        delta = CLEMENTIA_PEACEFUL_SURRENDER_DELTA
        reason = "peaceful_surrender"
    elseif disposition.detected_choice == "loot" then
        delta = CLEMENTIA_LOOTED_SURRENDER_DELTA
        reason = "looted_surrender"
    else
        return
    end

    disposition.clementia_applied = true
    adjust_clementia(disposition.attacker_key, delta,
        reason .. " region=" .. tostring(disposition.region_key))
end

-- Region-bound looting damage. Absolute campaign-turn deadline prevents reload
-- or ownership changes from extending the ten-turn recovery period.
local add_loot_economy
do
    local KEY="bs_loot_economy_damage"
    local SAVE="bs_loot_economy_v1"
    local TIMER="bs_loot_economy_sync"
    local entries={}
    local ready=false
    local queued=false
    local retries=0
    local function clear(e)
        if not e.cqi then return true end
        local ok,result=pcall(function()
            return gi():remove_effect_bundle_from_characters_force(KEY,e.cqi)
        end)
        if ok and result~=false then e.cqi=nil;e.owner=nil;return true end
        return false
    end
    local function sync()
        if not ready then return true end
        if pending_active() then return false end
        local now=campaign_turn()
        local complete=true
        for key,e in pairs(entries) do
            if now>=e.expires then
                if clear(e) then entries[key]=nil else complete=false end
            else
                local r=region_by_key(key)
                local cqi,owner
                if r then cqi,owner=unrest_colonel(r) end
                if e.cqi and (e.cqi~=cqi or e.owner~=owner or e.refresh) then
                    if not clear(e) then complete=false end
                end
                if not e.cqi then
                    if cqi then
                        local ok,result=pcall(function()
                            return gi():apply_effect_bundle_to_characters_force(KEY,cqi,e.expires-now)
                        end)
                        if ok and result~=false then
                            e.cqi=cqi;e.owner=owner;e.refresh=false
                        else complete=false end
                    else complete=false end
                end
            end
        end
        return complete
    end
    local function schedule()
        if not ready or not next(entries) or queued then return end
        queued=true
        trigger(TIMER,0.5)
    end
    add_loot_economy=function(key)
        ready=true
        local e=entries[key] or {}
        e.expires=campaign_turn()+10
        e.refresh=true
        entries[key]=e
        retries=0
        sync()
        schedule()
    end
    register("TimeTrigger",function(context)
        if cstring(context)~=TIMER then return end
        queued=false
        if not sync() then
            retries=retries+1
            if retries<60 then schedule() end
        else retries=0 end
    end)
    register("ComponentLClickUp",function()
        -- Native player input is the load-safety barrier.
        ready=true
        retries=0
        schedule()
    end)
    register("FactionTurnStart",function() retries=0;schedule() end)
    register("GarrisonOccupiedEvent",function() retries=0;schedule() end)
    register("RegionSelected",function() schedule() end)
    register("SavingGame",function(context)
        local out={"V1"}
        for key,e in pairs(entries) do
            out[#out+1]=table.concat({key,e.expires,e.cqi or 0,e.owner or ""},",")
        end
        pcall(function()gi():save_named_value(SAVE,table.concat(out,";"),context)end)
    end)
    register("LoadingGame",function(context)
        -- No native calls, timers or model access during loading.
        entries={};ready=false;queued=false;retries=0
        local ok,data=pcall(function()return gi():load_named_value(SAVE,"",context)end)
        if not ok or type(data)~="string" then return end
        for block in data:gmatch("[^;]+") do
            local key,expires,cqi,owner=block:match("^([^,]+),(%d+),(%d+),([^,]*)$")
            if key then
                local id=tonumber(cqi)
                entries[key]={expires=tonumber(expires),cqi=id>0 and id or nil,
                    owner=owner~="" and owner or nil,refresh=true}
            end
        end
    end)
end

local function finish_loot()
    add_loot_economy(disposition.region_key)

    local wealth = tonumber(disposition.region_wealth) or 0
    local intended_loss =
        wealth * SETTLEMENT_LOOTING_PCT_REGION_GDP_REDUCTION

    log("LOOT GDP TARGET="
        .. string.format("%.0f",
            SETTLEMENT_LOOTING_PCT_REGION_GDP_REDUCTION * 100)
        .. "% of pre-transfer region wealth (~"
        .. string.format("%.2f", intended_loss) .. ").")
    log("Rome II script API has no region-wealth setter; V8 leaves this part unapplied.")

    apply_disposition_clementia_once()
    log("DISPOSITION COMPLETE: LOOT.")
    reset_disposition()
end

local function apply_one_loot_building()
    if disposition.detected_choice ~= "loot" then
        return
    end

    local buildings = disposition.building_keys or {}
    local i = tonumber(disposition.building_index) or 1

    if i > #buildings then
        finish_loot()
        return
    end

    local item = buildings[i]
    local min_damage =
        LOOT_BUILDING_DAMAGE_PERCENT - LOOT_BUILDING_DAMAGE_SPREAD_PERCENT
    local max_damage =
        LOOT_BUILDING_DAMAGE_PERCENT + LOOT_BUILDING_DAMAGE_SPREAD_PERCENT

    local damage = LOOT_BUILDING_DAMAGE_PERCENT
    pcall(function()
        damage = gi():model():random_number(min_damage, max_damage)
    end)

    damage = tonumber(damage) or LOOT_BUILDING_DAMAGE_PERCENT
    local current_health = tonumber(item.health) or 100

    -- Treat the DEI value as percentage-points of building health lost.
    -- Clamp to 1% so looting damages rather than deletes the building.
    local target_health = current_health - damage
    if target_health < 1 then target_health = 1 end
    if target_health > 100 then target_health = 100 end

    log("LOOT BUILDING before key=" .. tostring(item.key)
        .. " health=" .. tostring(current_health)
        .. " damage=" .. tostring(damage)
        .. " target=" .. tostring(target_health))

    local ok, err = pcall(function()
        gi():instant_set_building_health_percent(
            disposition.region_key,
            item.key,
            target_health
        )
    end)

    if ok then
        log("LOOT BUILDING applied key=" .. tostring(item.key))
    else
        log("LOOT BUILDING ERROR key=" .. tostring(item.key)
            .. " err=" .. tostring(err))
    end

    disposition.building_index = i + 1
    trigger(LOOT_BUILDING_TRIGGER, LOOT_BUILDING_STEP_DELAY)
end

local function apply_disposition_effects()
    if not disposition.region_key
        or not disposition.attacker_key
        or not disposition.detected_choice then
        return
    end

    local region = region_by_key(disposition.region_key)
    if not region then
        reset_disposition()
        return
    end

    local owner = region:owning_faction()
    if not owner or owner:name() ~= disposition.attacker_key then
        log("DISPOSITION APPLY abort: ownership changed.")
        reset_disposition()
        return
    end

    bs_population_apply(disposition.region_key,disposition.attacker_key,disposition.detected_choice)

    if disposition.detected_choice == "peace" then
        local same_culture =
            disposition.attacker_culture ~= ""
            and disposition.defender_culture ~= ""
            and disposition.attacker_culture == disposition.defender_culture

        local culture_penalty =
            same_culture
            and OCCUPY_SAME_CULTURE_PO
            or OCCUPY_DIFFERENT_CULTURE_PO

        local total_po =
            OCCUPY_CONQUEST_PO + culture_penalty

        log("PEACE income already paid natively: +"
            .. tostring(disposition.peace_income))

        modify_public_order(
            disposition.region_key,
            -total_po,
            same_culture
                and "peaceful_occupy_same_culture"
                or "peaceful_occupy_different_culture"
        )

        apply_disposition_clementia_once()
        log("DISPOSITION COMPLETE: PEACEFUL OCCUPATION."
            .. " native_income=+" .. tostring(disposition.peace_income)
            .. " PO=-" .. tostring(total_po))

        reset_disposition()
        return
    end

    if disposition.detected_choice == "loot" then
        local wealth = tonumber(disposition.region_wealth)
            or safe_region_wealth(region)

        -- Trial surrender-only balance: 5000 + pre-transfer wealth * 5.
        -- This is not a verified reconstruction of native post-battle loot.
        local common_loot =
            SETTLEMENT_LOOTING_BASE_LOOT
            + wealth * SURRENDER_LOOT_WEALTH_FACTOR

        local income =
            round_nearest(
                common_loot
                * (1 + LOOT_INCOME_PERCENTAGE_MODIFIER / 100)
            )

        log("LOOT income already paid natively: +"
            .. tostring(disposition.loot_income))

        local immediate_po =
            LOOT_CONQUEST_PO
            + SETTLEMENT_LOOTING_SURRENDER_PUBLIC_ORDER_REDUCTION
            + SETTLEMENT_LOOTING_PUBLIC_ORDER_REDUCTION

        modify_public_order(
            disposition.region_key,
            -immediate_po,
            "loot_conquest_surrender_initial"
        )

        add_loot_unrest(disposition.region_key)

        disposition.building_keys = collect_region_buildings(region)
        disposition.building_index = 1

        log("LOOT formula: base=" .. tostring(SETTLEMENT_LOOTING_BASE_LOOT)
            .. " wealth=" .. string.format("%.2f", wealth)
            .. " trial_wealth_factor="
            .. tostring(SURRENDER_LOOT_WEALTH_FACTOR)
            .. " modifier=+" .. tostring(LOOT_INCOME_PERCENTAGE_MODIFIER)
            .. "% native_income=" .. tostring(disposition.loot_income))
        log("LOOT immediate PO=-" .. tostring(immediate_po))
        log("LOOT buildings queued=" .. tostring(#disposition.building_keys))

        if #disposition.building_keys > 0 then
            trigger(LOOT_BUILDING_TRIGGER, LOOT_BUILDING_STEP_DELAY)
        else
            finish_loot()
        end
    end
end

local function OnFactionTurnStart(context)
    local faction = nil
    local ok = pcall(function() faction = context:faction() end)

    if ok and faction then
        record_snapshot(faction)
        decay_clementia(faction)
        process_loot_unrest_for_faction(faction)
    end
end

local function OnSavingGame(context)
    local history_data = serialize_history()
    local clementia_data = serialize_clementia()
    local loot_unrest_data = serialize_loot_unrest()

    local ok_history, err_history = pcall(function()
        gi():save_named_value(SAVE_KEY, history_data, context)
    end)

    local ok_clementia, err_clementia = pcall(function()
        gi():save_named_value(CLEMENTIA_SAVE_KEY, clementia_data, context)
    end)

    local ok_loot_unrest, err_loot_unrest = pcall(function()
        gi():save_named_value(LOOT_UNREST_SAVE_KEY, loot_unrest_data, context)
    end)

    if ok_history then
        log("Strength history saved.")
    else
        log("HISTORY SAVE ERROR: " .. tostring(err_history))
    end

    if ok_clementia then
        log("Clementia saved: [" .. tostring(clementia_data) .. "]")
    else
        log("CLEMENTIA SAVE ERROR: " .. tostring(err_clementia))
    end

    if ok_loot_unrest then
        log("Loot unrest saved: [" .. tostring(loot_unrest_data) .. "]")
    else
        log("LOOT UNREST SAVE ERROR: " .. tostring(err_loot_unrest))
    end
end

local function OnLoadingGame(context)
    local ok_history, history_data = pcall(function()
        return gi():load_named_value(SAVE_KEY, "", context)
    end)

    local ok_clementia, clementia_data = pcall(function()
        return gi():load_named_value(CLEMENTIA_SAVE_KEY, "", context)
    end)

    local ok_loot_unrest, loot_unrest_data = pcall(function()
        return gi():load_named_value(LOOT_UNREST_SAVE_KEY, "", context)
    end)

    if ok_history then
        deserialize_history(history_data)
        log("Strength history loaded.")
    else
        log("HISTORY LOAD ERROR: " .. tostring(history_data))
    end

    if ok_clementia then
        deserialize_clementia(clementia_data)
        log("Clementia loaded: [" .. tostring(clementia_data) .. "]")
    else
        log("CLEMENTIA LOAD ERROR: " .. tostring(clementia_data))
    end

    if ok_loot_unrest then
        deserialize_loot_unrest(loot_unrest_data)
        log("Loot unrest loaded: [" .. tostring(loot_unrest_data) .. "]")
    else
        log("LOOT UNREST LOAD ERROR: " .. tostring(loot_unrest_data))
    end
end

local function OnPanelOpened(context)
    if cstring(context) == "popup_pre_battle" then
        reset_battle_state()
        trigger(CHECK_TRIGGER, CHECK_DELAY)
    end
end

local function request_tooltip(text)
    pcall(function()
        local p=scripting.m_root:Find(request_fleet and FLEET_BUTTON or REQUEST_BUTTON)
        if p then UIComponent(p):SetTooltipText("Demand Surrender||"..text) end
    end)
end

local function native_continue_request()
    if not state.offer_pending then return end
    if request_turn ~= gi():model():turn_number() or not pending_active() then
        log("REQUEST ABORT: context changed before native click")
        reset_battle_state();return
    end
    local ok,err=pcall(function()
        local button,selected
        for _,name in ipairs(request_fleet and {"button_maintain_blockade"} or {"button_continue_siege","button_surround"}) do
            local p=scripting.m_root:Find(name)
            if p then
                local candidate=UIComponent(p)
                if candidate:Visible() then button=candidate;selected=name;break end
            end
        end
        assert(button,"neither native siege button is visible")
        log("NATIVE CONTINUE: SimulateClick request target="..selected)
        button:SimulateClick()
    end)
    log("NATIVE CONTINUE RETURN: "..tostring(ok).." "..tostring(err))
    if not ok then
        reset_battle_state()
        request_tooltip("Unable to continue the siege or blockade. Please check the log.")
        return
    end
    -- A returned call is not proof of native success. Require close + inactive.
    trigger(OFFER_TRIGGER,OFFER_DELAY)
end

local function OnClick(context)
    local id=cstring(context)
    if id==REQUEST_BUTTON or id==FLEET_BUTTON then
        diagnostic_live=true
        if state.offer_pending or state.detected_choice or disposition.region_key then return end
        reset_battle_state()
        request_fleet=(id==FLEET_BUTTON)
        evaluate_surrender()
        if not evaluation_complete then
            request_tooltip("The information needed to assess surrender is not yet available. Please try again shortly.")
            log("REQUEST UNAVAILABLE: evaluation incomplete; no refusal notification")
            return
        end
        request_refused=not state.eligible
        if not request_refused then
            local ok,cqi=pcall(function()return pending_battle():attacker():cqi()end)
            cqi=ok and tonumber(cqi) or nil
            if not cqi or cqi<=0 then
                log("REQUEST ABORT: unable to identify the requesting commander for movement cost")
                reset_battle_state()
                return
            end
            state.attacker_cqi=cqi
        end
        state.offer_pending=true
        request_turn=gi():model():turn_number()
        request_closed=false
        request_tooltip("Surrender has been demanded. Waiting for the siege or blockade action to complete.")
        log((request_refused and "REQUEST REFUSED: " or "REQUEST ACCEPTED: ")..tostring(state.region_key))
        -- Defer native UI action until the current custom click callback returns.
        trigger(NATIVE_TRIGGER,0.1)
    elseif state.offer_pending and (id=="button_attack" or id=="button_autoresolve"
        or id=="button_retreat") then
        log("REQUEST CANCELLED: another battle action selected")
        reset_battle_state()
    end
    -- Ordinary continue siege never starts a surrender request.
end

local function OnPanelClosed(context)
    local id = cstring(context)

    if id == "popup_pre_battle" then
        if state.offer_pending then
            request_closed=true
            log("PanelClosedCampaign : popup_pre_battle")
            trigger(OFFER_TRIGGER, OFFER_DELAY)
        else
            reset_battle_state()
        end
        return
    end

    -- Custom dilemma closure is intentionally NOT used as a control signal.
    -- Some Rome II custom dilemmas do not emit a reliable
    -- PanelClosedCampaign:event_dilemma callback.
    if id == "event_dilemma" then
        if state.dilemma_active then
            log("Gate event_dilemma closed (informational only)")
        elseif disposition.active then
            log("Disposition event_dilemma closed (informational only)")
        end
    end
end

local function OnTimeTrigger(context)
    local id = cstring(context)

    if id == NATIVE_TRIGGER then
        native_continue_request()
    elseif id == CHECK_TRIGGER then
        if not state.offer_pending and not state.detected_choice then evaluate_surrender() end
    elseif id == OFFER_TRIGGER then
        show_surrender_offer_when_safe()
    elseif id == DETECT_TRIGGER then
        detect_native_payload_choice()
    elseif id == ACCEPT_TRIGGER then
        accept_transfer_when_safe()
    elseif id == VERIFY_TRIGGER then
        verify_accept_transfer()
    elseif id == DISP_SHOW_TRIGGER then
        show_disposition_dilemma()
    elseif id == DISP_DETECT_TRIGGER then
        detect_disposition_choice()
    elseif id == DISP_APPLY_TRIGGER then
        apply_disposition_effects()
    elseif id == LOOT_BUILDING_TRIGGER then
        apply_one_loot_building()
    end
end

register("FactionTurnStart", OnFactionTurnStart)
register("SavingGame", OnSavingGame)
register("LoadingGame", OnLoadingGame)

register("CharacterPostBattleRelease", OnCharacterPostBattleRelease)
register("CharacterPostBattleEnslave", OnCharacterPostBattleEnslave)
register("CharacterPostBattleSlaughter", OnCharacterPostBattleSlaughter)

register("PanelOpenedCampaign", OnPanelOpened)
register("ComponentLClickUp", OnClick)
register("PanelClosedCampaign", OnPanelClosed)
register("TimeTrigger", OnTimeTrigger)

log("Installed V8.7.2: request button -> safe transfer -> one disposition dilemma.")
log("Accept/reject gate removed; no gate expense.")
log("ACCEPT -> verified transfer -> Stage 2 disposition dilemma.")
log("Stage 2 pays the ACTUAL occupation/loot income directly in native payloads.")
log("Choice is inferred from the positive treasury delta; no marker refund needed.")
log("No dilemma choice button is ever inspected by Lua.")
log("Peace: native +500 income plus occupation public-order penalties.")
log("Loot: native dynamic income plus PO penalties/unrest and staged building damage.")
log("Population remains untouched.")
log("80% region-GDP destruction is logged but not writable through Rome II script API.")
log("Disposition completion: peaceful surrender Clementia +10; looted surrender -20 (once).")
log("Tactical threshold: Clementia -100/0/+100 -> 205/180/170 out of 219.")
log("Strategic collapse and strategic local-threat thresholds unchanged.")

register("FactionTurnEnd", finish_loot_unrest_turn)
register("TimeTrigger", unrest_time_trigger)
register("ComponentLClickUp", activate_unrest_after_input)
register("GarrisonOccupiedEvent", schedule_unrest_sync)
log("V8.6.3 native unrest: next-owner-turn -11 to -1; decay at owner turn END.")

register("RegionSelected", schedule_unrest_sync)

end
