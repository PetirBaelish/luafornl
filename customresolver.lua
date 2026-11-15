-- ============================================================
--  CUSTOM RESOLVER
-- ============================================================
local RESOLVER = {
    records = {},
    mem_disabled = false,
    schema_pair = nil,
}

local function reset_resolver_data()
    RESOLVER.records = {}
end

local function player_key(ctrl, pawn)
    if ctrl then
        local sid = safe(function() return ctrl:steam_id() end)
        if sid and sid ~= "" and sid ~= "0" then return sid end
    end
    return tostring(pawn:address())
end

local function apply_resolved_angles(pawn, ang)
    if not CFG.res_apply_mem or RESOLVER.mem_disabled then return end
    if safe(client.insecure) ~= true then return end

    if RESOLVER.schema_pair then
        local ok = safe(function()
            pawn:set(RESOLVER.schema_pair[1], RESOLVER.schema_pair[2], "vector", ang)
            return true
        end)
        if not ok then
            RESOLVER.mem_disabled = true
        end
        return
    end

    local candidates = {
        { "C_CSPlayerPawn", "m_angEyeAngles" },
        { "CCSPlayerPawn", "m_angEyeAngles" },
    }
    for _, pair in ipairs(candidates) do
        local ok = safe(function()
            pawn:set(pair[1], pair[2], "vector", ang)
            return true
        end)
        if ok then
            RESOLVER.schema_pair = pair
            return
        end
    end

    RESOLVER.mem_disabled = true
    client.notify("m_angEyeAngles schema unavailable; tracking only", META.name)
end

local function update_resolver()
    if not CFG.res_enable or not safe(engine.in_game) then return end
    local lp = safe(entity.local_pawn)
    if not lp then return end

    local lp_origin = lp:origin()
    local now = globals.realtime()
    local players = safe(entity.players) or {}

    for _, p in ipairs(players) do
        local pawn = p.pawn
        local ctrl = p.controller
        if pawn and pawn:alive() and pawn:is_enemy() then
            local key = player_key(ctrl, pawn)
            local rec = RESOLVER.records[key]
            if not rec then
                rec = {
                    last_yaw = nil,
                    jitter_switches = 0,
                    last_delta = 0,
                    spin_rate = 0,
                    side = 1,
                    brute_index = 0,
                    last_hit_t = 0,
                    resolved = vector(0, 0, 0),
                }
                RESOLVER.records[key] = rec
            end

            local eye = pawn:eye_angles()
            local origin = pawn:origin()
            local vel = pawn:velocity()
            local speed2d = vel:length2d()

            -- Учёт дельт углов между апдейтами
            local delta = 0
            if rec.last_yaw ~= nil then
                delta = math.normalize_angle(eye.y - rec.last_yaw)
                if math.abs(delta) > 25 then
                    if (delta > 0 and rec.last_delta < -25) or (delta < 0 and rec.last_delta > 25) then
                        rec.jitter_switches = math.min(12, rec.jitter_switches + 1)
                    else
                        rec.jitter_switches = math.max(0, rec.jitter_switches - 0.25)
                    end
                    rec.spin_rate = math.lerp(rec.spin_rate, delta, 0.35)
                else
                    rec.jitter_switches = math.max(0, rec.jitter_switches - 0.15)
                    rec.spin_rate = math.lerp(rec.spin_rate, 0, 0.2)
                end
                rec.last_delta = delta
            end
            rec.last_yaw = eye.y

            -- Базовый угол от врага на локального игрока
            local base_to_local = math.calc_angle(origin, lp_origin).y
            local target_yaw = eye.y

            if CFG.res_mode == 0 then
                -- Adaptive: джиттер -> центр, спин -> компенсация скорости вращения, статика -> сторона
                if CFG.res_jitter and rec.jitter_switches >= 3 then
                    target_yaw = math.normalize_angle(eye.y - delta * 0.5)
                elseif math.abs(rec.spin_rate) > 15 then
                    target_yaw = math.normalize_angle(eye.y + rec.spin_rate * 0.5)
                elseif speed2d > 45 then
                    local move_yaw = vel:angles().y
                    local move_diff = math.normalize_angle(move_yaw - base_to_local)
                    rec.side = (move_diff >= 0) and 1 or -1
                    target_yaw = math.normalize_angle(base_to_local + rec.side * (CFG.res_yaw_offset * 0.6))
                else
                    local brute_add = CFG.res_bruteforce and (rec.brute_index * CFG.res_brute_step * rec.side) or 0
                    target_yaw = math.normalize_angle(base_to_local + rec.side * CFG.res_yaw_offset + brute_add)
                end
            elseif CFG.res_mode == 1 then
                -- Jitter / Spin
                if rec.jitter_switches >= 2 then
                    target_yaw = math.normalize_angle(eye.y - delta * 0.5)
                else
                    target_yaw = math.normalize_angle(eye.y - rec.spin_rate * 0.5)
                end
            elseif CFG.res_mode == 2 then
                -- Bruteforce
                local sequence = { 0, 1, -1, 2, -2 }
                local mult = sequence[(rec.brute_index % #sequence) + 1]
                target_yaw = math.normalize_angle(base_to_local + mult * CFG.res_brute_step)
            else
                -- Static
                target_yaw = math.normalize_angle(base_to_local + CFG.res_yaw_offset)
            end

            -- Питч-коррекция
            local target_pitch = eye.x
            if CFG.res_pitch_mode == 0 then
                target_pitch = math.clamp(eye.x, -89, 89)
            elseif CFG.res_pitch_mode == 1 then
                target_pitch = 89
            elseif CFG.res_pitch_mode == 2 then
                target_pitch = 0
            end

            rec.resolved = vector(target_pitch, target_yaw, 0)
            rec.updated_t = now
            apply_resolved_angles(pawn, rec.resolved)
        end
    end
end

local function on_resolver_combat_feedback(attacker_ctrl, victim_ctrl, hitgroup)
    if not CFG.res_enable or not CFG.res_bruteforce then return end
    local local_ctrl = safe(entity.local_controller)
    if not local_ctrl then return end

    if attacker_ctrl and victim_ctrl and attacker_ctrl:address() == local_ctrl:address() then
        local v_pawn = victim_ctrl:pawn()
        if v_pawn then
            local key = player_key(victim_ctrl, v_pawn)
            local rec = RESOLVER.records[key]
            if rec then
                if hitgroup ~= 1 then
                    rec.brute_index = (rec.brute_index + 1) % 6
                    rec.side = -rec.side
                else
                    rec.last_hit_t = globals.realtime()
                end
            end
        end
    elseif attacker_ctrl and victim_ctrl and victim_ctrl:address() == local_ctrl:address() then
        local a_pawn = attacker_ctrl:pawn()
        if a_pawn then
            local key = player_key(attacker_ctrl, a_pawn)
            local rec = RESOLVER.records[key]
            if rec then
                rec.side = -rec.side
            end
        end
    end
end
