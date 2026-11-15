-- @author 0x
-- @uid 0

-- ============================================================================
--  0x resolver  ·  v2.1
--  Neverlose CS2 Lua  ·  API: github.com/PbLJk/neverlose-lua-api
--
--  Layered yaw/pitch resolver:
--    1. per-netupdate yaw history  -> AA classification (static / jitter / spin / random)
--    2. body-yaw hint              -> model geometry from hitboxes (legs / shoulders)
--    3. freestanding hint          -> cover traces around the enemy head
--    4. movement memory            -> last movement yaw after the enemy stops
--    5. shot feedback              -> weapon_fire + player_hurt => hit / miss learning
--    6. brute-force cycling        -> deterministic multiplier table, locked on hit
--    7. persistence                -> learned side per SteamID (db.*)
--
--  Memory override (m_angEyeAngles) requires "Allow Insecure". Without it the
--  script runs in tracking-only mode (overlay + stats still work).
-- ============================================================================

local META = {
    name    = "0x resolver",
    version = "2.1",
    db      = "0x_resolver_v21",
}

-- ----------------------------------------------------------------------------
-- Locals / fast paths
-- ----------------------------------------------------------------------------
local floor, abs, sqrt, atan2, sin, cos, rad, deg = math.floor, math.abs, math.sqrt, math.atan2, math.sin, math.cos, math.rad, math.deg
local max, min = math.max, math.min
local normalize, clamp = math.normalize_angle, math.clamp
local calc_angle = math.calc_angle
local pcall, ipairs, pairs, type, tostring, format = pcall, ipairs, pairs, type, tostring, string.format
local tremove = table.remove

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------
local C = {
    HISTORY          = 12,     -- yaw samples kept per player (~190 ms @ 64 tick)
    JITTER_MIN_DELTA = 12,     -- deg; a delta counts as "big" above this
    SPIN_MIN_RATE    = 20,     -- deg/update mean signed drift to classify as spin
    STATIC_MAX_DELTA = 3,      -- deg mean |delta| below this = static
    RANDOM_CENTER_AT = 25,     -- deg mean |delta| above this -> use circular mean as base
    MOVE_SPEED       = 4,      -- u/s 2D; above = moving
    MOVE_MEM_TIME    = 1.0,    -- s; movement memory validity after stopping
    BODY_MAX_DELTA   = 35,     -- deg; body hint saturates here
    BODY_MIN_DELTA   = 8,      -- deg; below = no hint
    BODY_SANE_DELTA  = 110,    -- deg; model yaw further than this from eye yaw = invalid sample
    FS_OFFSET        = 26,     -- u; lateral offset for freestanding traces
    PURGE_AFTER      = 90,     -- s; drop records not seen for this long
    PENDING_MAX      = 32,     -- max outstanding shots
    DB_MAX           = 64,     -- persisted players
    W_LEARNED        = 1.00,
    W_BODY           = 0.55,
    W_FREESTAND      = 0.40,
    W_MOVE           = 0.30,
    SIDE_DEADZONE    = 0.15,
    HIT_CONF_GAIN    = 0.30,
    MISS_CONF_LOSS   = 0.20,
    ROUND_CONF_DECAY = 0.85,
}

-- Brute multipliers applied to (side * desync). Index 1 is the "trusted" prediction.
local BRUTE = { 1.0, -1.0, 0.5, -0.5, 0.0, 0.75, -0.75 }
local BRUTE_N = #BRUTE

local MODE_ADAPTIVE, MODE_STATIC, MODE_BRUTE = 1, 2, 3
local BASE_AUTO, BASE_EYE, BASE_TARGET = 1, 2, 3
local PITCH_OFF, PITCH_CLAMP, PITCH_AUTO = 1, 2, 3

local STAGE_LAGCOMP = (stage and stage.lagcomp) or 6
local STAGE_NET_END = (stage and stage.net_update_end) or 7
local MASK_VISIBLE  = (trace and trace.mask and trace.mask.visible) or 1847299

local EYE_CLASSES = { "C_CSPlayerPawn", "C_CSPlayerPawnBase", "CCSPlayerPawn" }

local MODE_LABEL = { static = "STATIC", jitter = "JITTER", spin = "SPIN", random = "RANDOM" }

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------
local UI = {}
local COMBO_BASE = nil -- 0 or 1, detected at runtime

-- Creates a combo with a 1-based default and records whether :get() is 0- or 1-based.
local function make_combo(group, name, items, default1)
    local ctrl = group:combo(name, items)
    local v = ctrl:get()
    if COMBO_BASE == nil and type(v) == "number" then
        COMBO_BASE = (v == 0) and 0 or 1
    end
    if default1 and default1 > 1 then
        if type(v) == "number" then
            safe(ctrl.set, ctrl, (COMBO_BASE or 0) + default1 - 1)
        else
            safe(ctrl.set, ctrl, items[default1])
        end
    end
    return ctrl
end

local function combo_index(ctrl, items)
    local v = ctrl:get()
    if type(v) == "number" then
        return clamp(v - (COMBO_BASE or 0) + 1, 1, #items)
    elseif type(v) == "string" then
        for i = 1, #items do
            if items[i] == v then return i end
        end
    end
    return 1
end

local MODE_ITEMS  = { "Adaptive", "Static side", "Bruteforce" }
local BASE_ITEMS  = { "Auto", "Eye yaw", "At target" }
local PITCH_ITEMS = { "Off", "Clamp", "Auto" }

local reset_all -- forward declaration (defined in Lifecycle)

do
    local tab = ui.tab("0x Resolver")

    local g = tab:group("Core")
    UI.enable  = g:checkbox("Enable resolver", true)
    UI.apply   = g:checkbox("Override eye angles", true)
        :tooltip("Writes the resolved angles into m_angEyeAngles every net update.\nRequires Allow Insecure.")
        :depends(UI.enable)
    UI.mode    = make_combo(g, "Mode", MODE_ITEMS, MODE_ADAPTIVE):depends(UI.enable)
    UI.desync  = g:slider_int("Max desync", 0, 90, 58, "%d°"):depends(UI.enable)
    UI.base    = make_combo(g, "Yaw base", BASE_ITEMS, BASE_AUTO):depends(UI.enable)
    UI.pitch   = make_combo(g, "Pitch", PITCH_ITEMS, PITCH_AUTO):depends(UI.enable)
    UI.move_sc = g:slider_int("Moving correction", 0, 100, 35, "%d%%"):depends(UI.enable)
    UI.jit_sc  = g:slider_int("Jitter correction", 0, 100, 50, "%d%%"):depends(UI.enable)

    local gi = tab:group("Intelligence")
    UI.body      = gi:checkbox("Body yaw hint", true):tooltip("Estimates lower/upper body yaw from hitbox geometry."):depends(UI.enable)
    UI.freestand = gi:checkbox("Freestanding hint", true):tooltip("Traces cover left/right of the head; freestanding AA hides toward cover."):depends(UI.enable)
    UI.move_mem  = gi:checkbox("Movement memory", true):depends(UI.enable)
    UI.feedback  = gi:checkbox("Hit / miss learning", true):depends(UI.enable)
    UI.miss_win  = gi:slider_int("Miss window", 150, 1000, 350, "%d ms"):depends(UI.feedback)
    UI.miss_tol  = gi:slider_int("Misses before step", 1, 3, 1):depends(UI.feedback)
    UI.persist   = gi:checkbox("Persist learning (db)", true):depends(UI.feedback)

    local gv = tab:group("Visuals")
    UI.overlay = gv:checkbox("Player overlay", true):depends(UI.enable)
    UI.debug   = gv:checkbox("Debug panel", false):depends(UI.enable)
    UI.color   = gv:color("Overlay color", color(235, 235, 235, 255), true):depends(UI.enable)

    local gd = tab:group("Data")
    UI.stats = gd:label("tracked 0 · hits 0 · misses 0")
    UI.reset = gd:button("Clear learned data", function()
        if reset_all then reset_all() end
    end)
end

-- Snapshot of UI values, refreshed once per net update / paint.
local CFG = {}
local function refresh_config()
    CFG.enable    = UI.enable:get() == true
    CFG.apply     = UI.apply:get() == true
    CFG.mode      = combo_index(UI.mode, MODE_ITEMS)
    CFG.desync    = UI.desync:get()
    CFG.base      = combo_index(UI.base, BASE_ITEMS)
    CFG.pitch     = combo_index(UI.pitch, PITCH_ITEMS)
    CFG.move_sc   = UI.move_sc:get() / 100
    CFG.jit_sc    = UI.jit_sc:get() / 100
    CFG.body      = UI.body:get() == true
    CFG.freestand = UI.freestand:get() == true
    CFG.move_mem  = UI.move_mem:get() == true
    CFG.feedback  = UI.feedback:get() == true
    CFG.miss_win  = UI.miss_win:get() / 1000
    CFG.miss_tol  = UI.miss_tol:get()
    CFG.persist   = UI.persist:get() == true
    CFG.overlay   = UI.overlay:get() == true
    CFG.debug     = UI.debug:get() == true
end

-- ----------------------------------------------------------------------------
-- State
-- ----------------------------------------------------------------------------
local RECORDS = {}   -- key -> record
local BY_PAWN = {}   -- pawn address -> record
local PENDING = {}   -- outstanding shots
local STORE   = {}   -- persisted learning (steamid -> {side, conf, hits, misses, t})

local STATE = {
    insecure     = false,
    cmd_angles   = nil,
    simtime_ok   = true,
    body_ok      = true,
    body_good    = 0,
    body_bad     = 0,
    last_purge   = 0,
    last_label   = 0,
    total_hits   = 0,
    total_misses = 0,
    write_cls    = nil,
    write_ok     = nil,   -- nil unknown, true working, false disabled
    write_fails  = 0,
}

-- ----------------------------------------------------------------------------
-- Records
-- ----------------------------------------------------------------------------
local function player_key(ctrl, pawn)
    if ctrl then
        local sid = safe(ctrl.steam_id, ctrl)
        if type(sid) == "string" and sid ~= "" and sid ~= "0" then
            return sid, true
        end
    end
    return "p" .. tostring(pawn:address()), false
end

local function new_record(key, is_sid)
    local rec = {
        key = key, is_sid = is_sid, name = "?",
        -- history ring buffers
        yaws = {}, pitches = {}, deltas = {},
        head = 0, n = 0, dhead = 0, dn = 0,
        pitch_jit = 0,
        -- classification
        mode = "static", mode_conf = 0, center = 0, amp = 0, spin_rate = 0,
        -- hints
        body_delta = 0, fs_hint = 0, mv_hint = 0, score = 0,
        last_move_yaw = nil, last_move_t = 0, moving = false,
        -- learning
        side = 1, conf = 0.3, pred_side = 1, brute_idx = 1,
        shots = 0, hits = 0, misses = 0, hit_streak = 0, miss_streak = 0,
        last_hit_t = 0, last_miss_t = 0,
        -- output
        at_target = 0, raw_yaw = 0, raw_pitch = 0,
        resolved_yaw = 0, resolved_pitch = 0, resolved = false, applied = false,
        -- bookkeeping
        sim_time = nil, last_tick = -1, seen_rt = 0, pawn = nil, pawn_addr = nil,
    }
    local saved = (is_sid and CFG.persist) and STORE[key] or nil
    if type(saved) == "table" then
        rec.side   = (saved.side == -1) and -1 or 1
        rec.conf   = clamp((tonumber(saved.conf) or 0) * 0.6, 0, 0.6)
        rec.hits   = tonumber(saved.hits) or 0
        rec.misses = tonumber(saved.misses) or 0
    end
    return rec
end

local function get_record(ctrl, pawn)
    local key, is_sid = player_key(ctrl, pawn)
    local rec = RECORDS[key]
    if not rec then
        rec = new_record(key, is_sid)
        rec.name = (ctrl and safe(ctrl.name, ctrl)) or safe(pawn.name, pawn) or "?"
        RECORDS[key] = rec
    end
    local addr = pawn:address()
    if rec.pawn_addr ~= addr then
        if rec.pawn_addr and BY_PAWN[rec.pawn_addr] == rec then BY_PAWN[rec.pawn_addr] = nil end
        rec.pawn_addr = addr
        BY_PAWN[addr] = rec
    end
    rec.pawn = pawn
    return rec
end

local function record_by_pawn(pawn)
    if not pawn then return nil end
    local addr = safe(pawn.address, pawn)
    return addr and BY_PAWN[addr] or nil
end

local function remember(rec)
    if not rec.is_sid then return end
    STORE[rec.key] = { side = rec.side, conf = rec.conf, hits = rec.hits, misses = rec.misses, t = os.time() }
end

-- ----------------------------------------------------------------------------
-- Persistence
-- ----------------------------------------------------------------------------
local function store_load()
    local data = safe(db.load, META.db, {})
    STORE = (type(data) == "table") and data or {}
end

local function store_save()
    if not CFG.persist then return end
    -- prune to newest DB_MAX entries
    local list = {}
    for k, v in pairs(STORE) do
        if type(v) == "table" then list[#list + 1] = { k = k, t = tonumber(v.t) or 0 } end
    end
    if #list > C.DB_MAX then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = C.DB_MAX + 1, #list do STORE[list[i].k] = nil end
    end
    safe(db.save, META.db, STORE)
end

-- ----------------------------------------------------------------------------
-- History + classification
-- ----------------------------------------------------------------------------
local H = C.HISTORY

local function push_history(rec, yaw, pitch)
    if rec.n > 0 then
        local prev_yaw = rec.yaws[rec.head]
        local prev_pitch = rec.pitches[rec.head]
        rec.dhead = rec.dhead % H + 1
        rec.deltas[rec.dhead] = normalize(yaw - prev_yaw)
        rec.dn = min(H, rec.dn + 1)
        if abs(pitch - prev_pitch) > 45 then
            rec.pitch_jit = min(6, rec.pitch_jit + 1)
        else
            rec.pitch_jit = max(0, rec.pitch_jit - 0.5)
        end
    end
    rec.head = rec.head % H + 1
    rec.yaws[rec.head] = yaw
    rec.pitches[rec.head] = pitch
    rec.n = min(H, rec.n + 1)
end

local function circular_mean(rec)
    local sx, sy = 0, 0
    for i = 1, rec.n do
        local a = rad(rec.yaws[i])
        sx = sx + cos(a)
        sy = sy + sin(a)
    end
    if sx == 0 and sy == 0 then return rec.yaws[rec.head] end
    return normalize(deg(atan2(sy, sx)))
end

local function classify(rec)
    local dn = rec.dn
    if dn < 3 then
        rec.mode, rec.mode_conf = "static", 0
        return
    end

    local sum_abs, sum_signed, flips, big, prev_sign = 0, 0, 0, 0, 0
    local idx = (dn == H) and (rec.dhead % H + 1) or 1
    for _ = 1, dn do
        local d = rec.deltas[idx]
        local ad = abs(d)
        sum_abs = sum_abs + ad
        sum_signed = sum_signed + d
        if ad > C.JITTER_MIN_DELTA then
            big = big + 1
            local s = (d > 0) and 1 or -1
            if prev_sign ~= 0 and s ~= prev_sign then flips = flips + 1 end
            prev_sign = s
        end
        idx = idx % H + 1
    end

    local mean_abs = sum_abs / dn
    local mean_signed = sum_signed / dn
    rec.mean_abs = mean_abs

    if abs(mean_signed) > C.SPIN_MIN_RATE and big >= dn * 0.6 and flips <= 1 then
        rec.mode = "spin"
        rec.spin_rate = mean_signed
        rec.mode_conf = min(1, big / dn)
    elseif big >= dn * 0.4 and flips >= max(2, floor(big * 0.5)) then
        rec.mode = "jitter"
        rec.center = circular_mean(rec)
        local amp = 0
        for i = 1, rec.n do amp = amp + abs(normalize(rec.yaws[i] - rec.center)) end
        rec.amp = amp / rec.n
        rec.mode_conf = min(1, flips / max(1, big - 1))
    elseif mean_abs < C.STATIC_MAX_DELTA then
        rec.mode = "static"
        rec.mode_conf = 1 - mean_abs / C.STATIC_MAX_DELTA
    else
        rec.mode = "random"
        rec.center = circular_mean(rec)
        rec.mode_conf = 0.5
    end
end

-- ----------------------------------------------------------------------------
-- Hints
-- ----------------------------------------------------------------------------
local function hb_kind(h)
    local g = h.group
    if g == 4 then return "la" elseif g == 5 then return "ra"
    elseif g == 6 then return "ll" elseif g == 7 then return "rl" end
    local n = h.group_name
    if type(n) == "string" then
        n = n:lower()
        local left = n:find("left", 1, true) ~= nil
        local right = n:find("right", 1, true) ~= nil
        if n:find("arm", 1, true) then
            if left then return "la" elseif right then return "ra" end
        elseif n:find("leg", 1, true) then
            if left then return "ll" elseif right then return "rl" end
        end
    end
    return nil
end

-- Returns body yaw from a left/right hitbox pair (highest hitbox of each group).
local function pair_yaw(hbs, lk, rk)
    local L, R
    for i = 1, #hbs do
        local h = hbs[i]
        local c = h.center
        if c then
            local k = hb_kind(h)
            if k == lk then
                if not L or c.z > L.z then L = c end
            elseif k == rk then
                if not R or c.z > R.z then R = c end
            end
        end
    end
    if not L or not R then return nil end
    local dx, dy = L.x - R.x, L.y - R.y
    if dx * dx + dy * dy < 4 then return nil end
    -- (L - R) is the body's left vector => body yaw = atan2(dy, dx) - 90
    return normalize(deg(atan2(dy, dx)) - 90)
end

local function body_hint(rec, pawn, yaw)
    if not STATE.body_ok then return 0 end
    local hbs = safe(pawn.hitboxes, pawn)
    if type(hbs) ~= "table" then
        STATE.body_bad = STATE.body_bad + 1
        if STATE.body_bad > 40 then STATE.body_ok = false end
        return 0
    end
    local ref = pair_yaw(hbs, "ll", "rl") or pair_yaw(hbs, "la", "ra")
    if not ref then return 0 end
    local d = normalize(ref - yaw)
    if abs(d) > C.BODY_SANE_DELTA then
        STATE.body_bad = STATE.body_bad + 1
        if STATE.body_bad > 40 and STATE.body_good < STATE.body_bad / 8 then
            STATE.body_ok = false
            safe(client.notify, "Body yaw hint disabled (hitbox data not usable)", META.name)
        end
        return 0
    end
    STATE.body_good = STATE.body_good + 1
    rec.body_delta = d
    if abs(d) < C.BODY_MIN_DELTA then return 0 end
    return clamp(d / C.BODY_MAX_DELTA, -1, 1)
end

-- Freestanding: which side of the enemy head is covered from our point of view.
-- Derivation: side +1 (CCW) moves the head toward OUR right, so right cover => +1.
local function freestand_hint(lp, pawn, lp_eye, en_eye)
    local yaw = rad((en_eye - lp_eye):angles().y)
    local right = vector(sin(yaw), -cos(yaw), 0)
    local opts = { skip = { lp, pawn }, mask = MASK_VISIBLE }
    local tl = safe(trace.line, lp_eye, en_eye - right * C.FS_OFFSET, opts)
    local tr = safe(trace.line, lp_eye, en_eye + right * C.FS_OFFSET, opts)
    if type(tl) ~= "table" or type(tr) ~= "table" then return 0 end
    local fl, fr = tonumber(tl.fraction) or 1, tonumber(tr.fraction) or 1
    local bl, br = fl < 0.98, fr < 0.98
    if bl == br then return 0 end
    return br and 1 or -1
end

local function movement_hint(rec, yaw, now)
    if rec.moving or not rec.last_move_yaw then return 0 end
    local age = now - rec.last_move_t
    if age < 0 or age > C.MOVE_MEM_TIME then return 0 end
    local d = normalize(rec.last_move_yaw - yaw)
    if abs(d) < 20 then return 0 end
    return sign(d) * (1 - age / C.MOVE_MEM_TIME)
end

-- ----------------------------------------------------------------------------
-- Decision + resolution
-- ----------------------------------------------------------------------------
local function decide_side(rec, b, fs, mv)
    rec.fs_hint, rec.mv_hint = fs, mv
    if CFG.mode == MODE_BRUTE then
        rec.score = rec.side
        rec.pred_side = rec.side
        return
    end
    local score = rec.side * rec.conf * C.W_LEARNED
    if CFG.body then score = score + b * C.W_BODY end
    if CFG.freestand then score = score + fs * C.W_FREESTAND end
    if CFG.move_mem then score = score + mv * C.W_MOVE end
    rec.score = score
    if abs(score) >= C.SIDE_DEADZONE then
        rec.pred_side = (score > 0) and 1 or -1
    end
end

local function resolve_pitch(rec, pitch)
    if CFG.pitch == PITCH_OFF then return pitch end
    if CFG.pitch == PITCH_CLAMP then return clamp(pitch, -89, 89) end
    -- auto
    if pitch > 89.5 then return 89 end
    if pitch < -89.5 then return -89 end
    if rec.pitch_jit >= 3 then return 89 end -- fake-pitch flicker: assume looking down
    return clamp(pitch, -89, 89)
end

local function compute_resolved(rec, yaw, pitch)
    local mode = rec.mode
    local desync = CFG.desync
    local mult = (CFG.mode == MODE_STATIC) and 1 or BRUTE[rec.brute_idx]

    -- base yaw
    local base
    if CFG.base == BASE_TARGET then
        base = rec.at_target
    elseif CFG.base == BASE_EYE then
        base = yaw
    else -- auto
        if mode == "spin" then
            base = rec.at_target
        elseif mode == "jitter" then
            base = rec.center
        elseif mode == "random" and rec.mean_abs > C.RANDOM_CENTER_AT then
            base = rec.center
        else
            base = yaw
        end
    end

    -- amount
    local amount = desync * mult
    if mode == "jitter" then
        amount = amount * CFG.jit_sc
    elseif mode == "random" then
        amount = amount * 0.75
    end
    if rec.moving then amount = amount * CFG.move_sc end

    rec.resolved_yaw = normalize(base + rec.pred_side * amount)
    rec.resolved_pitch = resolve_pitch(rec, pitch)
    rec.resolved = true
end

-- ----------------------------------------------------------------------------
-- Memory write
-- ----------------------------------------------------------------------------
local function apply(pawn, rec)
    rec.applied = false
    if not CFG.apply or not STATE.insecure or STATE.write_ok == false then return end
    local ang = vector(rec.resolved_pitch, rec.resolved_yaw, 0)

    if STATE.write_cls then
        if pcall(pawn.set, pawn, STATE.write_cls, "m_angEyeAngles", "vector", ang) then
            rec.applied = true
            STATE.write_fails = 0
        else
            STATE.write_fails = STATE.write_fails + 1
            if STATE.write_fails > 20 then
                STATE.write_ok = false
                safe(client.notify, "Eye angle override failing; switched to tracking only", META.name)
            end
        end
        return
    end

    for i = 1, #EYE_CLASSES do
        if pcall(pawn.set, pawn, EYE_CLASSES[i], "m_angEyeAngles", "vector", ang) then
            STATE.write_cls = EYE_CLASSES[i]
            STATE.write_ok = true
            rec.applied = true
            return
        end
    end
    STATE.write_ok = false
    safe(client.notify, "m_angEyeAngles not found in schema; tracking only", META.name)
end

-- ----------------------------------------------------------------------------
-- Per-player update
-- ----------------------------------------------------------------------------
local function read_simtime(pawn)
    if not STATE.simtime_ok then return nil end
    local ok, v = pcall(pawn.get, pawn, "C_BaseEntity", "m_flSimulationTime", "float")
    if ok and type(v) == "number" then return v end
    STATE.simtime_ok = false
    return nil
end

local function process(pawn, ctrl, lp, lp_alive, lp_eye, now, tick, rt)
    local rec = get_record(ctrl, pawn)
    rec.seen_rt = rt

    local eye = pawn:eye_angles()
    local yaw = normalize(eye.y)
    local pitch = eye.x

    -- Freshness gate: only analyse genuinely new network data.
    local simt = read_simtime(pawn)
    local fresh
    if simt then
        fresh = (simt ~= rec.sim_time)
        rec.sim_time = simt
    else
        fresh = (tick ~= rec.last_tick)
        -- Echo guard: without simulation time we could read back our own write.
        if fresh and rec.applied
            and abs(normalize(yaw - rec.resolved_yaw)) < 0.01
            and abs(pitch - rec.resolved_pitch) < 0.01 then
            fresh = false
        end
    end
    rec.last_tick = tick

    if not fresh then
        if rec.resolved then apply(pawn, rec) end
        return
    end

    local vel = pawn:velocity()
    local speed = vel:length2d()

    rec.raw_yaw, rec.raw_pitch = yaw, pitch
    push_history(rec, yaw, pitch)
    classify(rec)

    if speed > C.MOVE_SPEED then
        rec.moving = true
        rec.last_move_yaw = normalize(vel:angles().y)
        rec.last_move_t = now
    else
        rec.moving = false
    end

    local en_eye = pawn:eye_position()
    rec.at_target = normalize(calc_angle(en_eye, lp_eye).y)

    local b  = CFG.body and body_hint(rec, pawn, yaw) or 0
    local fs = (CFG.freestand and lp_alive) and freestand_hint(lp, pawn, lp_eye, en_eye) or 0
    local mv = CFG.move_mem and movement_hint(rec, yaw, now) or 0

    decide_side(rec, b, fs, mv)
    compute_resolved(rec, yaw, pitch)
    apply(pawn, rec)
end

-- ----------------------------------------------------------------------------
-- Shot feedback
-- ----------------------------------------------------------------------------
local function on_hit(rec, hitgroup)
    for i = #PENDING, 1, -1 do
        if PENDING[i].key == rec.key then tremove(PENDING, i) end
    end
    rec.hits = rec.hits + 1
    rec.hit_streak = rec.hit_streak + 1
    rec.miss_streak = 0
    rec.last_hit_t = globals.curtime()
    STATE.total_hits = STATE.total_hits + 1

    local m = (CFG.mode == MODE_STATIC) and 1 or BRUTE[rec.brute_idx]
    if m ~= 0 then
        rec.side = sign(rec.pred_side * m)
        if abs(m) == 1 then rec.brute_idx = 1 end
    end
    rec.conf = min(1, rec.conf + C.HIT_CONF_GAIN * (hitgroup == 1 and 1.25 or 1))
    remember(rec)
end

local function on_miss(shot, rec)
    rec.misses = rec.misses + 1
    rec.hit_streak = 0
    rec.last_miss_t = globals.curtime()
    STATE.total_misses = STATE.total_misses + 1
    rec.conf = max(0, rec.conf - C.MISS_CONF_LOSS)
    if shot.moving then
        -- moving targets miss for many reasons; do not step the brute table
        remember(rec)
        return
    end
    rec.miss_streak = rec.miss_streak + 1
    if rec.miss_streak >= CFG.miss_tol then
        rec.miss_streak = 0
        if CFG.mode ~= MODE_STATIC then
            rec.brute_idx = rec.brute_idx % BRUTE_N + 1
        else
            rec.side = -rec.side
        end
    end
    remember(rec)
end

local function check_pending(now)
    for i = #PENDING, 1, -1 do
        local s = PENDING[i]
        if now - s.t > CFG.miss_win then
            tremove(PENDING, i)
            local rec = RECORDS[s.key]
            if rec then on_miss(s, rec) end
        elseif now < s.t then
            tremove(PENDING, i) -- clock went backwards (map change)
        end
    end
end

local function find_shot_target(lp)
    local from = lp:eye_position()
    local angs = { safe(engine.view_angles), STATE.cmd_angles }
    for i = 1, 2 do
        local a = angs[i]
        if a then
            local r = safe(trace.bullet, from, from + a:forward() * 8192)
            if type(r) == "table" and r.hit and r.entity then
                local rec = record_by_pawn(r.entity)
                if rec then return rec end
            end
        end
    end
    -- fallback: closest tracked enemy to the crosshair within 12 degrees
    local va = angs[1]
    if not va then return nil end
    local best, best_fov = nil, 12
    local rt = globals.realtime()
    for _, rec in pairs(RECORDS) do
        if rec.pawn and rt - rec.seen_rt < 0.2 then
            local ep = safe(rec.pawn.eye_position, rec.pawn)
            if ep then
                local want = calc_angle(from, ep)
                local dy = abs(normalize(want.y - va.y))
                local dp = abs(want.x - va.x)
                local fov = sqrt(dy * dy + dp * dp)
                if fov < best_fov then best, best_fov = rec, fov end
            end
        end
    end
    return best
end

local function is_local_controller(ctrl)
    if not ctrl then return false end
    local lc = entity.local_controller()
    if not lc then return false end
    return ctrl:address() == lc:address()
end

local function on_weapon_fire(ev)
    if not CFG.enable or not CFG.feedback then return end
    local ctrl = safe(ev.get_controller, ev, "userid")
    if not is_local_controller(ctrl) then return end
    local lp = entity.local_pawn()
    if not lp then return end
    local info = safe(lp.weapon_info, lp)
    if type(info) == "table" and info.gun == false then return end

    local rec = find_shot_target(lp)
    if not rec then return end
    rec.shots = rec.shots + 1
    PENDING[#PENDING + 1] = {
        key = rec.key, t = globals.curtime(),
        side = rec.pred_side, idx = rec.brute_idx, mode = rec.mode, moving = rec.moving,
    }
    if #PENDING > C.PENDING_MAX then tremove(PENDING, 1) end
end

local function on_player_hurt(ev)
    if not CFG.enable or not CFG.feedback then return end
    local att = safe(ev.get_controller, ev, "attacker")
    if not is_local_controller(att) then return end

    local rec = record_by_pawn(safe(ev.get_pawn, ev, "userid"))
    if not rec then
        local vc = safe(ev.get_controller, ev, "userid")
        if vc then
            local sid = safe(vc.steam_id, vc)
            if sid then rec = RECORDS[sid] end
            if not rec then rec = record_by_pawn(safe(vc.pawn, vc)) end
        end
    end
    if not rec then return end
    on_hit(rec, safe(ev.get_int, ev, "hitgroup") or 0)
end

-- ----------------------------------------------------------------------------
-- Frame stage
-- ----------------------------------------------------------------------------
local function reapply_all()
    local players = safe(entity.players)
    if type(players) ~= "table" then return end
    for i = 1, #players do
        local pawn = players[i].pawn
        if pawn then
            local rec = BY_PAWN[pawn:address()]
            if rec and rec.resolved and safe(pawn.alive, pawn) then apply(pawn, rec) end
        end
    end
end

local function purge(rt)
    if rt - STATE.last_purge < 5 then return end
    STATE.last_purge = rt
    for key, rec in pairs(RECORDS) do
        if rt - rec.seen_rt > C.PURGE_AFTER then
            if rec.pawn_addr and BY_PAWN[rec.pawn_addr] == rec then BY_PAWN[rec.pawn_addr] = nil end
            RECORDS[key] = nil
        end
    end
end

local function on_frame_stage(st)
    if st ~= STAGE_NET_END and st ~= STAGE_LAGCOMP then return end
    refresh_config()
    if not CFG.enable or not engine.in_game() then return end
    STATE.insecure = safe(client.insecure) == true

    if st == STAGE_LAGCOMP then
        reapply_all()
        return
    end

    local lp = entity.local_pawn()
    if not lp then return end
    local lp_alive = safe(lp.alive, lp) == true
    local lp_eye = safe(lp.eye_position, lp)
    if not lp_eye then return end

    local now, tick, rt = globals.curtime(), globals.tickcount(), globals.realtime()
    local players = entity.players()
    for i = 1, #players do
        local p = players[i]
        local pawn = p.pawn
        if pawn and pawn:alive() and pawn:is_enemy() then
            local ok, err = pcall(process, pawn, p.controller, lp, lp_alive, lp_eye, now, tick, rt)
            if not ok and CFG.debug then print("[0x] process error: " .. tostring(err)) end
        end
    end

    if CFG.feedback then check_pending(now) end
    purge(rt)
end

-- ----------------------------------------------------------------------------
-- Createmove: capture the angles actually sent (silent aim aware)
-- ----------------------------------------------------------------------------
local function on_createmove(cmd)
    local a = safe(cmd.view_angles, cmd)
    if a then STATE.cmd_angles = vector(a.x, a.y, 0) end
end

-- ----------------------------------------------------------------------------
-- Paint
-- ----------------------------------------------------------------------------
local function side_label(rec)
    return (rec.pred_side > 0) and "L" or "R"
end

local function on_paint()
    refresh_config()

    -- stats label (1 Hz)
    local rt = globals.realtime()
    if rt - STATE.last_label > 1 then
        STATE.last_label = rt
        local tracked = 0
        for _, rec in pairs(RECORDS) do
            if rt - rec.seen_rt < 1 then tracked = tracked + 1 end
        end
        safe(UI.stats.set, UI.stats, format("tracked %d · hits %d · misses %d · write %s",
            tracked, STATE.total_hits, STATE.total_misses,
            STATE.write_ok == true and "on" or (STATE.write_ok == false and "off" or "n/a")))
    end

    if not CFG.enable or not engine.in_game() then return end
    local col = UI.color:get()
    if type(col) ~= "table" then col = color(235, 235, 235, 255) end
    local dim = col:alpha(floor(col.a * 0.6))

    if CFG.overlay then
        for _, rec in pairs(RECORDS) do
            if rec.pawn and rec.resolved and rt - rec.seen_rt < 0.1 then
                local l, t, r = safe(rec.pawn.bbox, rec.pawn)
                if l and t and r then
                    local dlt = normalize(rec.resolved_yaw - rec.raw_yaw)
                    local txt = format("%s %s %d°  %d/%d", MODE_LABEL[rec.mode] or "?", side_label(rec), floor(abs(dlt) + 0.5), rec.hits, rec.misses)
                    local w = render.text_size(txt)
                    local x = (l + r) * 0.5 - w * 0.5
                    render.text(x, t - 16, rec.applied and col or dim, txt)
                end
            end
        end
    end

    if CFG.debug then
        local x, y = 24, 120
        local rows = {}
        rows[#rows + 1] = format("%s v%s  insecure=%s write=%s simtime=%s body=%s pending=%d",
            META.name, META.version,
            tostring(STATE.insecure),
            tostring(STATE.write_ok), tostring(STATE.simtime_ok), tostring(STATE.body_ok), #PENDING)
        for _, rec in pairs(RECORDS) do
            if rt - rec.seen_rt < 1 then
                rows[#rows + 1] = format(
                    "%-14s %-6s side=%s conf=%.2f score=%+.2f brute=%d(%+.2f) body=%+d fs=%+d mv=%+.1f res=%d raw=%d h/m=%d/%d%s",
                    tostring(rec.name):sub(1, 14), MODE_LABEL[rec.mode] or "?", side_label(rec), rec.conf, rec.score,
                    rec.brute_idx, BRUTE[rec.brute_idx], floor(rec.body_delta + 0.5), rec.fs_hint, rec.mv_hint,
                    floor(rec.resolved_yaw + 0.5), floor(rec.raw_yaw + 0.5), rec.hits, rec.misses,
                    rec.applied and "" or " [track]")
            end
        end
        local wmax = 0
        for i = 1, #rows do
            local w = render.text_size(rows[i])
            if w > wmax then wmax = w end
        end
        render.rect_filled(x - 8, y - 6, wmax + 16, #rows * 15 + 12, color(12, 12, 14, 200), 4)
        for i = 1, #rows do
            render.text(x, y + (i - 1) * 15, i == 1 and col or dim, rows[i])
        end
    end
end

-- ----------------------------------------------------------------------------
-- Lifecycle
-- ----------------------------------------------------------------------------
local function reset_volatile()
    PENDING = {}
    for _, rec in pairs(RECORDS) do
        rec.n, rec.dn, rec.head, rec.dhead = 0, 0, 0, 0
        rec.pitch_jit = 0
        rec.mode, rec.mode_conf = "static", 0
        rec.resolved = false
        rec.sim_time = nil
        rec.last_move_yaw = nil
        rec.conf = rec.conf * C.ROUND_CONF_DECAY
    end
end

reset_all = function()
    RECORDS, BY_PAWN, PENDING, STORE = {}, {}, {}, {}
    STATE.total_hits, STATE.total_misses = 0, 0
    safe(db.save, META.db, {})
    safe(client.notify, "Learned data cleared", META.name)
end

local function on_round_start()
    reset_volatile()
    store_save()
end

local function on_level_init()
    RECORDS, BY_PAWN, PENDING = {}, {}, {}
    STATE.body_good, STATE.body_bad, STATE.body_ok = 0, 0, true
    STATE.simtime_ok = true
    STATE.write_fails = 0
    if STATE.write_ok == false then STATE.write_ok, STATE.write_cls = nil, nil end
end

local function on_level_shutdown()
    store_save()
    RECORDS, BY_PAWN, PENDING = {}, {}, {}
end

-- ----------------------------------------------------------------------------
-- Wiring
-- ----------------------------------------------------------------------------
local EVENTS = {}
local function hook(name, fn)
    EVENTS[#EVENTS + 1] = events.on(name, function(...)
        local ok, err = pcall(fn, ...)
        if not ok then print("[0x] " .. name .. ": " .. tostring(err)) end
    end)
end

refresh_config()
store_load()
STATE.insecure = safe(client.insecure) == true

hook("frame_stage",     on_frame_stage)
hook("createmove",      on_createmove)
hook("paint",           on_paint)
hook("weapon_fire",     on_weapon_fire)
hook("player_hurt",     on_player_hurt)
hook("round_start",     on_round_start)
hook("level_init",      on_level_init)
hook("level_shutdown",  on_level_shutdown)

events.on("unload", function()
    safe(store_save)
    for i = 1, #EVENTS do safe(events.off, EVENTS[i]) end
end)

print(format("[%s] v%s loaded · insecure=%s", META.name, META.version, tostring(STATE.insecure)))
