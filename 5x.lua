-- @name 0x Project
-- @author 0x
-- @version 1.1

local META = {
    name = "0x Project",
    short = "0X",
    version = "1.1",
    db_key = "0x_config",
}

-- ============================================================
--  ХЕЛПЕРЫ И МАТЕМАТИКА
-- ============================================================
local function safe(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function clamp255(v)
    return math.floor(math.max(0, math.min(255, v)))
end

local function white(a) return color(255, 255, 255, clamp255(a)) end
local function black(a) return color(0, 0, 0, clamp255(a)) end

local function in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function to_color(v, fallback)
    if type(v) == "table" and v.r and v.g and v.b then
        return color(clamp255(v.r), clamp255(v.g), clamp255(v.b), clamp255(v.a or 255))
    end
    return fallback
end

-- ============================================================
--  КОНФИГУРАЦИЯ И СОХРАНЕНИЕ
-- ============================================================
local DEFAULTS = {
    -- Watermark
    watermark       = true,

    -- Hit Logs
    hl_enable       = true,
    hl_outgoing     = true,
    hl_incoming     = true,
    hl_duration     = 4.0,
    hl_max          = 5,
    hl_y_pct        = 74,

    -- Custom Resolver
    res_enable      = true,
    res_mode        = 0,    -- 0: Adaptive, 1: Jitter/Spin, 2: Bruteforce, 3: Static
    res_pitch_mode  = 0,    -- 0: Auto Clamp, 1: Down (89), 2: Zero (0), 3: Preserve
    res_jitter      = true,
    res_bruteforce  = true,
    res_yaw_offset  = 35,
    res_brute_step  = 30,
    res_apply_mem   = false,

    -- Settings
    sync_theme      = false,
}

local CFG = {}
local COLORS = {
    accent    = color(186, 136, 255, 255),
    secondary = color(155, 220, 70, 255),
    highlight = color(230, 82, 82, 255),
}

local function apply_defaults()
    for k, v in pairs(DEFAULTS) do
        CFG[k] = v
    end
    COLORS.accent    = color(186, 136, 255, 255)
    COLORS.secondary = color(155, 220, 70, 255)
    COLORS.highlight = color(230, 82, 82, 255)
end

local function save_config()
    local payload = { cfg = {}, colors = {} }
    for k, _ in pairs(DEFAULTS) do
        payload.cfg[k] = CFG[k]
    end
    for k, c in pairs(COLORS) do
        payload.colors[k] = { r = c.r, g = c.g, b = c.b, a = c.a }
    end
    return safe(db.save, META.db_key, payload) == true
end

local function load_config()
    apply_defaults()
    local data = safe(db.load, META.db_key, nil)
    if type(data) ~= "table" then return false end
    if type(data.cfg) == "table" then
        for k, def in pairs(DEFAULTS) do
            local v = data.cfg[k]
            if type(v) == type(def) then
                CFG[k] = v
            end
        end
    end
    if type(data.colors) == "table" then
        for k, def in pairs(COLORS) do
            COLORS[k] = to_color(data.colors[k], def)
        end
    end
    return true
end

load_config()

-- ============================================================
--  ШРИФТЫ И СТИЛИ UI
-- ============================================================
local FONT_SIZE = 13
local FONT = nil
do
    local function try_load(name)
        local f = safe(render.font, name, FONT_SIZE)
        if f and safe(function() return f:loaded() end) then return f end
    end
    FONT = try_load("Segoe UI") or try_load("Tahoma") or try_load("Roboto")
end

local function text(x, y, col, str, size)
    render.text(x, y, col, str, "", size or FONT_SIZE, FONT)
end

local function tsize(str, size)
    return render.text_size(str, "", size or FONT_SIZE, FONT)
end

local STYLE = {
    BG       = color(13, 14, 21, 244),
    BORDER   = color(255, 255, 255, 16),
    CARD     = color(20, 21, 31, 255),
    SEP      = color(255, 255, 255, 10),
    FIELD    = color(12, 13, 19, 255),
    LABEL    = color(206, 209, 222, 255),
    SECTION  = color(96, 99, 118, 255),
    VALUE    = color(190, 193, 208, 255),
    SW_OFF   = color(50, 52, 64, 255),
    KNOB_OFF = color(138, 142, 158, 255),
    KNOB     = color(255, 255, 255, 255),
    ACCENT   = COLORS.accent,
    RH       = 36,
    HEADER_H = 60,
}

local TH = nil
local SPACE_W = nil
local function text_h()
    if not TH then
        local _, h = tsize("Ag")
        TH = h or FONT_SIZE
    end
    return TH
end

local function space_w()
    if not SPACE_W then
        local ab = tsize("a b")
        local nosp = tsize("ab")
        SPACE_W = math.max(3, (ab or 8) - (nosp or 4))
    end
    return SPACE_W
end

local function refresh_accent()
    if CFG.sync_theme then
        local c = safe(render.theme, "accent")
        if type(c) == "table" and c.r ~= nil then
            STYLE.ACCENT = color(clamp255(c.r), clamp255(c.g), clamp255(c.b), 255)
            return
        end
    end
    STYLE.ACCENT = color(clamp255(COLORS.accent.r), clamp255(COLORS.accent.g), clamp255(COLORS.accent.b), 255)
end

-- ============================================================
--  СОСТОЯНИЕ ПАНЕЛИ, АНИМАЦИЙ, DROPDOWN И COLOR PICKER
-- ============================================================
local PANEL = {
    DOCK_W = 350,
    DOCK_GAP = 8,
    MIN_H = 480,
    w = 350,
    h = 480,
    x = 0,
    y = 0,
    dock_anim = 0,
    dock_edge = 0,
    cur_tab = 1,
    scroll_y = 0,
    content_h = 0,
    sb_drag = false,
    ds_drag = false,
    ds_y0 = 0,
    ds_s0 = 0,
}

local INPUT_STATE = {
    slider_active = nil,
    mouse_prev = false,
    click_used = false,
}

local anims = {}
local function anim_to(id, target)
    local v = anims[id] or target
    v = v + (target - v) * math.min(1, globals.frametime() * 16)
    if math.abs(v - target) < 0.005 then v = target end
    anims[id] = v
    return v
end

local CP = {
    W = 250,
    H = 276,
    target = "accent",
    h = 0.6,
    s = 1.0,
    v = 1.0,
    a = 1.0,
    open = false,
    drag = nil,
    skip_close = false,
    anim = 0,
    fmt = 0,
}

local DD = {
    open_id = nil,
    items = {},
    setter = nil,
    selected_idx = 0,
    x = 0,
    y = 0,
    btn_y = 0,
    btn_h = 24,
    w = 0,
    anim = 0,
    scroll = 0,
    item_h = 28,
    max_h = 150,
}

local function get_wheel()
    if safe(input.key_down, 0x0E) then return -1 end
    if safe(input.key_down, 0x0F) then return 1 end
    return 0
end

-- ============================================================
--  HIT LOGS (Стиль: [Icon] [ [ ] (dot) text )
-- ============================================================
local HITGROUP_NAMES = {
    [0]  = "generic",
    [1]  = "head",
    [2]  = "chest",
    [3]  = "stomach",
    [4]  = "left arm",
    [5]  = "right arm",
    [6]  = "left leg",
    [7]  = "right leg",
    [8]  = "neck",
    [10] = "gear",
}

local HIT_LOGS = {}
local WM_FPS = 0

local function push_hit_log(kind, target_name, hitgroup_name, dmg)
    local segments
    local dot_col
    if kind == "killed" then
        dot_col = COLORS.secondary
        segments = {
            { str = "Killed", bright = false },
            { str = target_name, bright = true },
            { str = "in", bright = false },
            { str = hitgroup_name, bright = true },
        }
    elseif kind == "hit" then
        dot_col = COLORS.secondary
        segments = {
            { str = "Hit", bright = false },
            { str = target_name, bright = true },
            { str = "in", bright = false },
            { str = hitgroup_name, bright = true },
            { str = "for", bright = false },
            { str = tostring(dmg) .. " hp", bright = true },
        }
    else
        dot_col = COLORS.highlight
        segments = {
            { str = "Harmed by", bright = false },
            { str = target_name, bright = true },
            { str = "in", bright = false },
            { str = hitgroup_name, bright = true },
            { str = "for", bright = false },
            { str = tostring(dmg) .. " hp", bright = true },
        }
    end

    HIT_LOGS[#HIT_LOGS + 1] = {
        segments = segments,
        dot_col = dot_col,
        created = globals.realtime(),
        y_anim = nil,
    }
    while #HIT_LOGS > math.max(1, math.floor(CFG.hl_max)) do
        table.remove(HIT_LOGS, 1)
    end
end

local function draw_hit_logs()
    if not CFG.hl_enable or #HIT_LOGS == 0 then return end

    local now = globals.realtime()
    local dt = globals.frametime()
    local dur = math.max(1.0, CFG.hl_duration)
    local sw, sh = render.screen_size()
    local base_y = sh * (CFG.hl_y_pct / 100)

    local row_h = 28
    local gap = 6
    local icon_sz = 28
    local bracket_gap = 6
    local sp = space_w()

    local i = 1
    while i <= #HIT_LOGS do
        local log = HIT_LOGS[i]
        local age = now - log.created
        if age >= dur then
            table.remove(HIT_LOGS, i)
        else
            local fade_in = math.min(1, age / 0.16)
            local fade_out = (age > dur - 0.35) and math.max(0, (dur - age) / 0.35) or 1
            local alpha = fade_in * fade_out

            local total_text_w = 0
            for idx, seg in ipairs(log.segments) do
                local seg_w = tsize(seg.str, 13) or 0
                total_text_w = total_text_w + seg_w
                if idx < #log.segments then
                    total_text_w = total_text_w + sp
                end
            end

            local box_w = 14 + 10 + total_text_w + 14
            local total_w = icon_sz + bracket_gap + box_w
            local target_y = base_y + (i - 1) * (row_h + gap)
            if not log.y_anim then
                log.y_anim = target_y + 10
            else
                log.y_anim = math.lerp(log.y_anim, target_y, math.min(1, dt * 16))
            end

            local ix = math.floor((sw - total_w) / 2)
            local iy = math.floor(log.y_anim)
            local bx = ix + icon_sz + bracket_gap

            local fill_col = color(18, 19, 23, 236 * alpha)
            local brd_col = color(255, 255, 255, 20 * alpha)
            local shd_col = black(105 * alpha)
            local acc_col = STYLE.ACCENT:alpha(225 * alpha)

            -- Левая квадратная иконка
            render.shadow(ix, iy, icon_sz, icon_sz, shd_col, 14, 6)
            render.rect_filled(ix, iy, icon_sz, icon_sz, fill_col, 6)
            render.rect(ix, iy, icon_sz, icon_sz, brd_col, 6, 1)
            local mw, mh = tsize(META.short, 11)
            text(ix + (icon_sz - mw) / 2, iy + (icon_sz - mh) / 2, acc_col, META.short, 11)

            -- Левая скобка [ перед текстовым блоком
            local br_x = bx - 3
            render.line(br_x, iy + 1, br_x + 4, iy + 1, acc_col, 1.5)
            render.line(br_x, iy + 1, br_x, iy + row_h - 1, acc_col, 1.5)
            render.line(br_x, iy + row_h - 1, br_x + 4, iy + row_h - 1, acc_col, 1.5)

            -- Основной текстовый блок
            render.shadow(bx, iy, box_w, row_h, shd_col, 14, 6)
            render.rect_filled(bx, iy, box_w, row_h, fill_col, 6)
            render.rect(bx, iy, box_w, row_h, brd_col, 6, 1)

            -- Цветная точка статуса
            render.circle_filled(bx + 13, iy + row_h / 2, 3.2, log.dot_col:alpha(255 * alpha), 16)

            -- Текст с выделением ключевых слов
            local cx = bx + 23
            local _, th_m = tsize("Ag", 13)
            local ty = iy + (row_h - (th_m or 13)) / 2
            local col_muted = color(152, 156, 168, 255 * alpha)
            local col_bright = color(240, 242, 248, 255 * alpha)

            for idx, seg in ipairs(log.segments) do
                text(cx, ty, seg.bright and col_bright or col_muted, seg.str, 13)
                local seg_w = tsize(seg.str, 13) or 0
                cx = cx + seg_w + sp
            end

            i = i + 1
        end
    end
end

-- ============================================================
--  WATERMARK
-- ============================================================
local function draw_watermark()
    if not CFG.watermark then return end
    local ft = math.max(0.0001, globals.frametime())
    local inst_fps = 1 / ft
    WM_FPS = (WM_FPS == 0) and inst_fps or math.lerp(WM_FPS, inst_fps, math.min(1, ft * 6))

    local uname = safe(user.name) or "user"
    local parts = { "0x", uname, string.format("%d fps", math.round(WM_FPS)) }

    if safe(engine.in_game) then
        local ctrl = safe(entity.local_controller)
        local ping = ctrl and safe(function() return ctrl:ping() end)
        if ping then
            parts[#parts + 1] = string.format("%d ms", ping)
        end
        local map = safe(game.map)
        if map and map ~= "" then
            parts[#parts + 1] = map
        end
    end
    parts[#parts + 1] = os.date("%H:%M:%S")

    local label = table.concat(parts, "  |  ")
    local tw, th = tsize(label)
    local pad_x, h = 12, 26
    local w = tw + pad_x * 2
    local sw = render.screen_size()
    local x, y = sw - w - 16, 16

    render.shadow(x, y, w, h, black(90), 16, 7)
    render.rect_filled(x, y, w, h, STYLE.BG, 7)
    render.rect(x, y, w, h, STYLE.BORDER, 7, 1)
    render.rect_filled(x + 8, y, w - 16, 2, STYLE.ACCENT, 1)
    text(x + pad_x, y + (h - th) / 2, STYLE.LABEL, label)
end

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

-- ============================================================
--  ВИДЖЕТЫ МЕНЮ
-- ============================================================
local function row_text(x, ry, label)
    text(x + 14, ry + (STYLE.RH - text_h()) / 2, STYLE.LABEL, label)
end

local function widget_toggle(ui_s, id, x, ry, w, label, key)
    row_text(x, ry, label)
    local on = CFG[key] == true
    local t = anim_to(id, on and 1 or 0)
    local sw, sh = 34, 18
    local sx, sy = x + w - 14 - sw, ry + (STYLE.RH - sh) / 2
    render.rect_filled(sx, sy, sw, sh, STYLE.SW_OFF:lerp(STYLE.ACCENT, t), sh / 2)
    render.circle_filled(sx + 9 + (sw - 18) * t, sy + sh / 2, 6, STYLE.KNOB_OFF:lerp(STYLE.KNOB, t), 24)
    if ui_s.menu and not CP.open and ui_s.clicked and in_rect(ui_s.mx, ui_s.my, x, ry, w, STYLE.RH) then
        INPUT_STATE.click_used = true
        CFG[key] = not on
    end
end

local function widget_slider(ui_s, id, x, ry, w, label, key, lo, hi, step, fmt)
    row_text(x, ry, label)
    local val = CFG[key] or lo
    local f = math.max(0, math.min(1, (val - lo) / (hi - lo)))

    local bw, bh = 56, 22
    local bx, by = x + w - 14 - bw, ry + (STYLE.RH - bh) / 2
    render.rect_filled(bx, by, bw, bh, STYLE.FIELD, 6)
    render.rect(bx, by, bw, bh, STYLE.BORDER, 6, 1)
    local vs = fmt(val)
    local vw, vh = tsize(vs)
    text(bx + (bw - vw) / 2, by + (bh - vh) / 2, STYLE.VALUE, vs)

    local tw = 92
    local tx = bx - 12 - tw
    local ty = ry + STYLE.RH / 2
    render.rect_filled(tx, ty - 2, tw, 4, STYLE.SW_OFF, 2)
    if f > 0 then render.rect_filled(tx, ty - 2, tw * f, 4, STYLE.ACCENT, 2) end
    render.circle_filled(tx + tw * f, ty, 6, STYLE.KNOB, 20)

    if ui_s.menu and not CP.open then
        local on_track = in_rect(ui_s.mx, ui_s.my, tx - 8, ty - 10, tw + 16, 20)
        if ui_s.clicked and on_track then INPUT_STATE.click_used = true end
        if ui_s.down and (INPUT_STATE.slider_active == id or (ui_s.clicked and on_track)) then
            INPUT_STATE.slider_active = id
            local nf = math.max(0, math.min(1, (ui_s.mx - tx) / tw))
            local v = lo + nf * (hi - lo)
            v = math.floor(v / step + 0.5) * step
            CFG[key] = math.max(lo, math.min(hi, v))
        end
        if ui_s.released and INPUT_STATE.slider_active == id then
            INPUT_STATE.slider_active = nil
        end
    end
end

local function widget_combo(ui_s, id, x, ry, w, label, key, items)
    row_text(x, ry, label)
    local bw, bh = 134, 24
    local bx, by = x + w - 14 - bw, ry + (STYLE.RH - bh) / 2
    local idx = CFG[key] or 0

    local hover = ui_s.menu and not CP.open and in_rect(ui_s.mx, ui_s.my, bx, by, bw, bh)
    local t = anim_to(id, hover and 1 or 0)
    render.rect_filled(bx, by, bw, bh, STYLE.FIELD:lerp(color(28, 30, 46, 255), t), 6)
    render.rect(bx, by, bw, bh, STYLE.BORDER:lerp(STYLE.ACCENT:alpha(80), t), 6, 1)

    local cur = items[idx + 1] or "?"
    local _, ch = tsize(cur)
    text(bx + 10, by + (bh - ch) / 2, STYLE.LABEL, cur)

    local is_open = (DD.open_id == id)
    local arrow_t = anim_to(id .. "_arrow", is_open and 1 or 0)
    local ccx, ccy = bx + bw - 14, by + bh / 2
    local d = 1 - 2 * arrow_t
    render.line(ccx - 4, ccy - 2 * d, ccx, ccy + 2 * d, STYLE.VALUE, 1.5)
    render.line(ccx, ccy + 2 * d, ccx + 4, ccy - 2 * d, STYLE.VALUE, 1.5)

    if ui_s.menu and not CP.open and ui_s.clicked and in_rect(ui_s.mx, ui_s.my, bx, by, bw, bh) then
        INPUT_STATE.click_used = true
        if is_open then
            DD.open_id = nil
        else
            DD.open_id = id
            DD.items = items
            DD.setter = function(v) CFG[key] = v end
            DD.selected_idx = idx
            DD.x = bx
            DD.btn_y = by
            DD.btn_h = bh
            DD.y = by + bh + 2
            DD.w = bw
            DD.anim = 0
            DD.scroll = 0

            local _, sh = render.screen_size()
            local target_h = math.min(#items * DD.item_h, DD.max_h)
            if DD.y + target_h > sh then
                DD.y = by - target_h - 2
            end
        end
    end
end

local function widget_color_button(ui_s, id, x, ry, w, label, target)
    row_text(x, ry, label)
    local sw, sh = 34, 18
    local sx, sy = x + w - 14 - sw, ry + (STYLE.RH - sh) / 2
    local col = COLORS[target] or COLORS.accent
    render.rect_filled(sx, sy, sw, sh, STYLE.SW_OFF, 6)
    render.rect_filled(sx, sy, sw, sh, col, 6)
    render.rect(sx, sy, sw, sh, white(40), 6, 1)
    if ui_s.menu and not CP.open and ui_s.clicked and in_rect(ui_s.mx, ui_s.my, sx - 4, sy - 4, sw + 8, sh + 8) then
        INPUT_STATE.click_used = true
        local h, s_, v = col:hsv()
        CP.h, CP.s, CP.v = h, s_, v
        CP.a = col.a / 255
        CP.target = target
        CP.open = true
        CP.skip_close = true
    end
end

local function widget_button(ui_s, id, x, ry, w, label, fn)
    local bx, by, bw, bh = x + 14, ry + 6, w - 28, STYLE.RH - 12
    local hover = ui_s.menu and not CP.open and in_rect(ui_s.mx, ui_s.my, bx, by, bw, bh)
    local t = anim_to(id, hover and 1 or 0)
    render.rect_filled(bx, by, bw, bh, STYLE.FIELD:lerp(color(30, 32, 48, 255), t), 7)
    render.rect(bx, by, bw, bh, STYLE.BORDER:lerp(STYLE.ACCENT, t), 7, 1)
    local tw, th = tsize(label)
    text(bx + (bw - tw) / 2, by + (bh - th) / 2, STYLE.LABEL, label)
    if hover and ui_s.clicked then
        INPUT_STATE.click_used = true
        fn()
    end
end

-- ============================================================
--  DROPDOWN И COLOR PICKER OVERLAYS
-- ============================================================
local function draw_active_dropdown(ui_s)
    if not DD.open_id then return end

    local target_h = math.min(#DD.items * DD.item_h, DD.max_h)
    if ui_s.clicked and not in_rect(ui_s.mx, ui_s.my, DD.x, DD.y, DD.w, target_h) then
        if not INPUT_STATE.click_used and not in_rect(ui_s.mx, ui_s.my, DD.x, DD.btn_y, DD.w, DD.btn_h) then
            DD.open_id = nil
            return
        end
    end

    DD.anim = DD.anim + (1 - DD.anim) * math.min(1, globals.frametime() * 20)
    if DD.anim > 0.99 then DD.anim = 1 end

    local ease = 1 - (1 - DD.anim) ^ 3
    local h = target_h * ease
    if h < 1 then return end

    render.shadow(DD.x, DD.y, DD.w, h, black(120), 22, 10)
    render.rect_filled(DD.x, DD.y, DD.w, h, STYLE.CARD, 6)
    render.rect(DD.x, DD.y, DD.w, h, STYLE.BORDER, 6, 1)

    local max_scroll = math.max(0, #DD.items * DD.item_h - DD.max_h)
    if ui_s.menu and in_rect(ui_s.mx, ui_s.my, DD.x, DD.y, DD.w, h) then
        local wh = get_wheel()
        if wh ~= 0 then
            DD.scroll = math.max(0, math.min(DD.scroll - wh * 30, max_scroll))
        end
    end

    render.clip_push(DD.x, DD.y, DD.w, h, true)
    for i, item in ipairs(DD.items) do
        local iy = DD.y + (i - 1) * DD.item_h - DD.scroll
        if iy + DD.item_h > DD.y and iy < DD.y + h then
            local hover = ui_s.menu and in_rect(ui_s.mx, ui_s.my, DD.x, math.max(DD.y, iy), DD.w, math.min(h, DD.item_h))
            if hover then
                render.rect_filled(DD.x + 4, iy + 2, DD.w - 8, DD.item_h - 4, color(255, 255, 255, 15), 4)
            end
            local _, th = tsize(item)
            local text_col = (i - 1 == DD.selected_idx) and STYLE.ACCENT or STYLE.LABEL
            text(DD.x + 12, iy + (DD.item_h - th) / 2, text_col, item)

            if hover and ui_s.clicked then
                INPUT_STATE.click_used = true
                DD.setter(i - 1)
                DD.open_id = nil
            end
        end
    end
    render.clip_pop()

    if max_scroll > 0 then
        local sb_h = (DD.max_h / (#DD.items * DD.item_h)) * h
        local sb_y = DD.y + (DD.scroll / max_scroll) * (h - sb_h)
        render.rect_filled(DD.x + DD.w - 6, sb_y, 3, sb_h, color(255, 255, 255, 30), 1.5)
    end
end

local function cp_hbar(x, y, w, h, colfn)
    local r = h / 2
    for px = 0, w - 1, 2 do
        local cw = math.min(2, w - px)
        local d = math.min(px + 1, w - px - 1)
        local inset = 0
        if d < r then inset = r - math.sqrt(math.max(0, r * r - (r - d) * (r - d))) end
        render.rect_filled(x + px, y + inset, cw, h - inset * 2, colfn((px + 1) / w))
    end
end

local function cp_sv_area(x, y, w, h, r, hue_col, k)
    for py = 0, h - 1, 2 do
        local rh = math.min(2, h - py)
        local d = math.min(py + 1, h - py - 1)
        local inset = 0
        if d < r then inset = r - math.sqrt(math.max(0, r * r - (r - d) * (r - d))) end
        local v = 1 - (py + rh / 2) / h
        local left = color(255 * v, 255 * v, 255 * v, 255 * k)
        local right = color(hue_col.r * v, hue_col.g * v, hue_col.b * v, 255 * k)
        render.gradient(x + inset, y + py, w - inset * 2, rh, left, right, true)
    end
end

local function draw_color_picker(ui_s)
    local k = 1 - (1 - CP.anim) ^ 3
    if k <= 0.01 then return end
    local function A(c) return c:alpha(c.a * k) end

    local sw, sh = render.screen_size()
    local px = PANEL.x + PANEL.w + 12
    if px + CP.W > sw - 8 then px = PANEL.x + (PANEL.w - CP.W) / 2 end
    px = math.max(8, math.min(px, sw - CP.W - 8))
    local py = math.max(8, math.min(PANEL.y, sh - CP.H - 8))
    px = px - (1 - k) * 14
    py = py + (1 - k) * 10

    if CP.open then
        if CP.skip_close then
            CP.skip_close = false
        elseif ui_s.clicked and not in_rect(ui_s.mx, ui_s.my, px, py, CP.W, CP.H) then
            CP.open = false
            CP.drag = nil
        end
    end

    local pad = 12
    local iw = CP.W - pad * 2
    local svx, svy, svh = px + pad, py + pad, 170
    local hy = svy + svh + 14
    local ay = hy + 8 + 12
    local ry = ay + 8 + 16

    render.shadow(px, py, CP.W, CP.H, black(110 * k), 22, 12)
    render.rect_filled(px, py, CP.W, CP.H, A(STYLE.BG), 12)
    render.rect(px, py, CP.W, CP.H, A(STYLE.BORDER), 12, 1)

    local hue_col = color_hsv(CP.h, 1, 1, 255)
    local cur = color_hsv(CP.h, CP.s, CP.v, 255)

    cp_sv_area(svx, svy, iw, svh, 8, hue_col, k)
    render.rect(svx, svy, iw, svh, A(white(22)), 8, 1)
    cp_hbar(svx, hy + 1, iw, 8, function(f) return color_hsv(f, 1, 1, 255 * k) end)
    render.rect_filled(svx, ay + 1, iw, 8, A(STYLE.SW_OFF), 4)
    cp_hbar(svx, ay + 1, iw, 8, function(f) return color(cur.r, cur.g, cur.b, 255 * f * k) end)

    local kx, ky = svx + CP.s * iw, svy + (1 - CP.v) * svh
    render.circle_filled(kx, ky, 8, A(white(255)), 24)
    render.circle_filled(kx, ky, 6, A(cur), 24)

    local hx = svx + CP.h * iw
    render.rect_filled(hx - 5, hy - 4, 10, 18, A(white(255)), 5)
    render.rect_filled(hx - 3, hy - 2, 6, 14, A(hue_col), 3)

    local ax = svx + CP.a * iw
    render.circle_filled(ax, ay + 5, 8, A(white(255)), 24)
    render.circle_filled(ax, ay + 5, 6, A(cur), 24)

    local fw, vw, ow, rh = 50, 108, 46, 26
    local fx = svx
    local vx = fx + fw + 6
    local ox = vx + vw + 6
    local cc = color_hsv(CP.h, CP.s, CP.v, math.floor(CP.a * 255 + 0.5))

    local function field(x, w_)
        render.rect_filled(x, ry, w_, rh, A(STYLE.FIELD), 7)
        render.rect(x, ry, w_, rh, A(STYLE.BORDER), 7, 1)
    end
    local function ftext(x, w_, col, str)
        local tw, th = tsize(str)
        text(x + (w_ - tw) / 2, ry + (rh - th) / 2, A(col), str)
    end

    local fstr = (CP.fmt == 0) and "HEX" or "RGB"
    local ftw, fth = tsize(fstr)
    text(fx + 4, ry + (rh - fth) / 2, A(STYLE.LABEL), fstr)
    local ccx, ccy = fx + 4 + ftw + 10, ry + rh / 2
    render.line(ccx - 4, ccy - 2, ccx, ccy + 2, A(STYLE.VALUE), 1.5)
    render.line(ccx, ccy + 2, ccx + 4, ccy - 2, A(STYLE.VALUE), 1.5)

    field(vx, vw)
    render.rect_filled(vx + 7, ry + (rh - 14) / 2, 14, 14, A(color(cc.r, cc.g, cc.b, 255)), 4)
    local tx0, tw0 = vx + 26, vw - 26
    if CP.fmt == 0 then
        local hexs = cc:hex():upper()
        local hw_ = tsize("#")
        local tw_, th_ = tsize(hexs)
        local startx = tx0 + (tw0 - (hw_ + 2 + tw_)) / 2
        text(startx, ry + (rh - th_) / 2, A(STYLE.SECTION), "#")
        text(startx + hw_ + 2, ry + (rh - th_) / 2, A(STYLE.LABEL), hexs)
    else
        ftext(tx0, tw0, STYLE.LABEL, string.format("%d,%d,%d",
            math.floor(cc.r + 0.5), math.floor(cc.g + 0.5), math.floor(cc.b + 0.5)))
    end

    field(ox, ow)
    ftext(ox, ow, STYLE.LABEL, string.format("%d%%", math.floor(CP.a * 100 + 0.5)))

    if CP.open and ui_s.menu then
        if ui_s.released then CP.drag = nil end
        if ui_s.clicked and in_rect(ui_s.mx, ui_s.my, fx, ry, fw, rh) then CP.fmt = 1 - CP.fmt end
        if ui_s.down then
            if CP.drag == "sv" or (ui_s.clicked and in_rect(ui_s.mx, ui_s.my, svx, svy, iw, svh)) then
                CP.drag = "sv"
                CP.s = math.max(0, math.min(1, (ui_s.mx - svx) / iw))
                CP.v = math.max(0, math.min(1, 1 - (ui_s.my - svy) / svh))
            elseif CP.drag == "hue" or (ui_s.clicked and in_rect(ui_s.mx, ui_s.my, svx - 6, hy - 6, iw + 12, 22)) then
                CP.drag = "hue"
                CP.h = math.max(0, math.min(1, (ui_s.mx - svx) / iw))
            elseif CP.drag == "alpha" or (ui_s.clicked and in_rect(ui_s.mx, ui_s.my, svx - 6, ay - 6, iw + 12, 22)) then
                CP.drag = "alpha"
                CP.a = math.max(0, math.min(1, (ui_s.mx - svx) / iw))
            end
        end
        if COLORS[CP.target] then
            COLORS[CP.target] = color_hsv(CP.h, CP.s, CP.v, math.floor(CP.a * 255 + 0.5))
        end
    end
end

-- ============================================================
--  ВКЛАДКИ И КОНТЕНТ МЕНЮ
-- ============================================================
local TABS = { "Main", "Resolver", "Settings" }
local RES_MODES = { "Adaptive", "Jitter / Spin", "Bruteforce", "Static" }
local PITCH_MODES = { "Auto Clamp", "Down (89)", "Zero (0)", "Preserve" }

local function draw_tabs(ui_s, x, y, w)
    local bh = 30
    render.rect_filled(x, y, w, bh, STYLE.FIELD, 9)
    render.rect(x, y, w, bh, STYLE.BORDER, 9, 1)
    local sw = (w - 6) / #TABS
    for i, name in ipairs(TABS) do
        local sx = x + 3 + (i - 1) * sw
        local active = (PANEL.cur_tab == i)
        local t = anim_to("tab_" .. i, active and 1 or 0)
        if active then
            render.rect_filled(sx, y + 3, sw, bh - 6, STYLE.CARD, 7)
            render.rect(sx, y + 3, sw, bh - 6, STYLE.BORDER, 7, 1)
        end
        local tw, th = tsize(name)
        text(sx + (sw - tw) / 2, y + (bh - th) / 2 - 1, STYLE.SECTION:lerp(STYLE.KNOB, t), name)
        if active then
            render.rect_filled(sx + sw / 2 - 8, y + bh - 7, 16, 2, STYLE.ACCENT, 1)
        end
        if ui_s.menu and not CP.open and not DD.open_id and ui_s.clicked
           and in_rect(ui_s.mx, ui_s.my, sx, y, sw, bh) and PANEL.cur_tab ~= i then
            INPUT_STATE.click_used = true
            PANEL.cur_tab = i
            PANEL.scroll_y = 0
        end
    end
    return y + bh + 12
end

local function group(x, y, w, title, n)
    text(x + 4, y, STYLE.SECTION, title)
    local cy = y + 20
    local ch = n * STYLE.RH
    render.rect_filled(x, cy, w, ch, STYLE.CARD, 10)
    render.rect(x, cy, w, ch, STYLE.BORDER, 10, 1)
    local i = 1
    while i * STYLE.RH < ch - 2 do
        render.rect_filled(x + 12, cy + i * STYLE.RH, w - 24, 1, STYLE.SEP)
        i = i + 1
    end
    return cy, cy + ch + 14
end

local function fmt_int(suffix)
    return function(v) return string.format("%d%s", math.floor(v + 0.5), suffix) end
end

local function fmt_float(suffix)
    return function(v) return string.format("%.1f%s", v, suffix) end
end

local function tab_main(cui, gx, cy, gw)
    local ry
    ry, cy = group(gx, cy, gw, "WATERMARK", 1)
    widget_toggle(cui, "m_wm", gx, ry, gw, "Enable watermark", "watermark")

    ry, cy = group(gx, cy, gw, "HIT LOGS", 7)
    widget_toggle(cui, "hl_en", gx, ry, gw, "Enable hit logs", "hl_enable")
    widget_toggle(cui, "hl_out", gx, ry + STYLE.RH, gw, "Log hits & kills", "hl_outgoing")
    widget_toggle(cui, "hl_in", gx, ry + 2 * STYLE.RH, gw, "Log incoming damage", "hl_incoming")
    widget_slider(cui, "hl_dur", gx, ry + 3 * STYLE.RH, gw, "Duration", "hl_duration", 1.5, 8.0, 0.5, fmt_float("s"))
    widget_slider(cui, "hl_max", gx, ry + 4 * STYLE.RH, gw, "Max visible", "hl_max", 2, 8, 1, fmt_int(""))
    widget_slider(cui, "hl_yp", gx, ry + 5 * STYLE.RH, gw, "Vertical offset", "hl_y_pct", 10, 90, 1, fmt_int("%"))
    widget_button(cui, "hl_test", gx, ry + 6 * STYLE.RH, gw, "Test hit log", function()
        push_hit_log("harmed", "Харви", "right leg", 17)
        push_hit_log("killed", "Харви", "head", 100)
    end)

    return cy
end

local function tab_resolver(cui, gx, cy, gw)
    local ry
    ry, cy = group(gx, cy, gw, "CUSTOM RESOLVER", 9)
    widget_toggle(cui, "r_en", gx, ry, gw, "Enable custom resolver", "res_enable")
    widget_combo(cui, "r_mode", gx, ry + STYLE.RH, gw, "Resolver mode", "res_mode", RES_MODES)
    widget_combo(cui, "r_pitch", gx, ry + 2 * STYLE.RH, gw, "Pitch correction", "res_pitch_mode", PITCH_MODES)
    widget_toggle(cui, "r_jit", gx, ry + 3 * STYLE.RH, gw, "Anti-jitter prediction", "res_jitter")
    widget_toggle(cui, "r_bf", gx, ry + 4 * STYLE.RH, gw, "Adaptive bruteforce", "res_bruteforce")
    widget_slider(cui, "r_yaw", gx, ry + 5 * STYLE.RH, gw, "Base yaw offset", "res_yaw_offset", -60, 60, 1, fmt_int("°"))
    widget_slider(cui, "r_step", gx, ry + 6 * STYLE.RH, gw, "Bruteforce step", "res_brute_step", 15, 60, 5, fmt_int("°"))
    widget_toggle(cui, "r_mem", gx, ry + 7 * STYLE.RH, gw, "Apply eye angles (Insecure)", "res_apply_mem")
    widget_button(cui, "r_rst", gx, ry + 8 * STYLE.RH, gw, "Reset resolver data", function()
        reset_resolver_data()
        RESOLVER.mem_disabled = false
        client.notify("Resolver records cleared", META.name)
    end)

    return cy
end

local function tab_settings(cui, gx, cy, gw)
    local ry
    ry, cy = group(gx, cy, gw, "COLORS", 4)
    widget_toggle(cui, "s_sync", gx, ry, gw, "Sync menu accent", "sync_theme")
    widget_color_button(cui, "s_col1", gx, ry + STYLE.RH, gw, "Accent / bracket", "accent")
    widget_color_button(cui, "s_col2", gx, ry + 2 * STYLE.RH, gw, "Hit / Kill dot", "secondary")
    widget_color_button(cui, "s_col3", gx, ry + 3 * STYLE.RH, gw, "Harmed dot", "highlight")

    ry, cy = group(gx, cy, gw, "CONFIG", 3)
    widget_button(cui, "s_save", gx, ry, gw, "Save config", function()
        if save_config() then
            client.notify("Config saved", META.name)
        else
            client.notify("Failed to save config", META.name)
        end
    end)
    widget_button(cui, "s_load", gx, ry + STYLE.RH, gw, "Load config", function()
        if load_config() then
            client.notify("Config loaded", META.name)
        else
            client.notify("No saved config found", META.name)
        end
    end)
    widget_button(cui, "s_reset", gx, ry + 2 * STYLE.RH, gw, "Reset defaults", function()
        apply_defaults()
        client.notify("Settings reset", META.name)
    end)

    return cy
end

local function draw_header(x, y, w)
    local lx, ly, ls = x + 16, y + 13, 34
    render.rect_filled(lx, ly, ls, ls, color(22, 23, 34, 255), 9)
    render.rect(lx, ly, ls, ls, STYLE.BORDER, 9, 1)
    local mw, mh = tsize(META.short, 14)
    text(lx + (ls - mw) / 2, ly + (ls - mh) / 2, STYLE.ACCENT, META.short, 14)
    text(lx + ls + 12, y + 14, STYLE.KNOB, META.name, 15)
    text(lx + ls + 12, y + 33, STYLE.SECTION, "CS2 · v" .. META.version, 11)
    render.rect_filled(x + 16, y + STYLE.HEADER_H - 1, w - 32, 1, STYLE.SEP)
end

local function draw_controls(ui_s, x, y, w)
    local gx, gw = x + 14, w - 28
    local vp_y = draw_tabs(ui_s, gx, y + STYLE.HEADER_H + 10, gw)
    local vp_h = (y + PANEL.h) - vp_y - 10
    local max_scroll = math.max(0, PANEL.content_h - vp_h)
    INPUT_STATE.click_used = false

    if ui_s.menu and not CP.open and not DD.open_id and in_rect(ui_s.mx, ui_s.my, x, y, w, PANEL.h) then
        local wh = get_wheel()
        if wh ~= 0 then PANEL.scroll_y = PANEL.scroll_y - wh * 40 end
    end

    if PANEL.ds_drag then
        if ui_s.down and ui_s.menu and not DD.open_id then
            PANEL.scroll_y = PANEL.ds_s0 - (ui_s.my - PANEL.ds_y0)
        else
            PANEL.ds_drag = false
        end
    end

    local thumb_h = (max_scroll > 0) and math.max(28, vp_h * vp_h / PANEL.content_h) or 0
    if max_scroll > 0 and ui_s.menu and not DD.open_id then
        if ui_s.clicked and not CP.open and in_rect(ui_s.mx, ui_s.my, x + w - 20, vp_y, 20, vp_h) then
            PANEL.sb_drag = true
        end
        if PANEL.sb_drag then
            if ui_s.down then
                local f = (ui_s.my - vp_y - thumb_h / 2) / math.max(1, vp_h - thumb_h)
                PANEL.scroll_y = math.max(0, math.min(1, f)) * max_scroll
            else
                PANEL.sb_drag = false
            end
        end
    else
        PANEL.sb_drag = false
    end
    PANEL.scroll_y = math.max(0, math.min(PANEL.scroll_y, max_scroll))

    local cui = {
        mx = ui_s.mx,
        my = ui_s.my,
        down = ui_s.down,
        released = ui_s.released,
        menu = ui_s.menu,
        clicked = ui_s.clicked and not PANEL.sb_drag and in_rect(ui_s.mx, ui_s.my, x, vp_y, w - 20, vp_h),
    }

    render.clip_push(x + 1, vp_y, w - 2, vp_h, true)
    local start = vp_y - PANEL.scroll_y
    local fin
    if PANEL.cur_tab == 1 then
        fin = tab_main(cui, gx, start, gw)
    elseif PANEL.cur_tab == 2 then
        fin = tab_resolver(cui, gx, start, gw)
    else
        fin = tab_settings(cui, gx, start, gw)
    end
    render.clip_pop()
    PANEL.content_h = (fin - start) + 4

    if cui.clicked and not INPUT_STATE.click_used and not CP.open and not DD.open_id and max_scroll > 0 then
        PANEL.ds_drag, PANEL.ds_y0, PANEL.ds_s0 = true, ui_s.my, PANEL.scroll_y
    end

    if max_scroll > 0 then
        local tx = x + w - 10
        render.rect_filled(tx, vp_y, 3, vp_h, color(255, 255, 255, 10), 2)
        local ty = vp_y + (vp_h - thumb_h) * (PANEL.scroll_y / max_scroll)
        render.rect_filled(tx, ty, 3, thumb_h, STYLE.ACCENT:alpha(PANEL.sb_drag and 200 or 120), 2)
    end
end

local function update_dock()
    local mp = safe(function() return ui.position() end)
    local ms = safe(function() return ui.size() end)
    if not (mp and ms and mp.x and ms.x and ms.x > 0) then return false end

    PANEL.w = PANEL.DOCK_W
    PANEL.h = math.max(ms.y, PANEL.MIN_H)
    PANEL.dock_edge = mp.x + ms.x
    PANEL.x = PANEL.dock_edge + PANEL.DOCK_GAP - (1 - PANEL.dock_anim) * (PANEL.w + PANEL.DOCK_GAP)
    PANEL.y = mp.y
    return true
end

local function draw_panel(ui_s)
    if not ui_s.menu then return end
    render.shadow(PANEL.x, PANEL.y, PANEL.w, PANEL.h, black(120), 22, 12)
    render.rect_filled(PANEL.x, PANEL.y, PANEL.w, PANEL.h, STYLE.BG, 12)
    render.rect(PANEL.x, PANEL.y, PANEL.w, PANEL.h, STYLE.BORDER, 12, 1)
    draw_header(PANEL.x, PANEL.y, PANEL.w)
    draw_controls(ui_s, PANEL.x, PANEL.y, PANEL.w)
end

-- ============================================================
--  СОБЫТИЯ
-- ============================================================
local NET_UPDATE_END = (stage and stage.net_update_end) or 7
local cb_ids = {}

cb_ids[#cb_ids + 1] = events.on("paint", function()
    local mx, my = input.cursor()
    local down = input.key_down(0x01)
    local clicked = down and not INPUT_STATE.mouse_prev
    local released = INPUT_STATE.mouse_prev and not down
    local menu_open = input.menu_open()

    if not menu_open then
        INPUT_STATE.slider_active = nil
        PANEL.sb_drag = false
        PANEL.ds_drag = false
        CP.open = false
        CP.drag = nil
        CP.skip_close = false
        DD.open_id = nil
    end

    refresh_accent()
    draw_watermark()
    draw_hit_logs()

    local ui_s = { mx = mx, my = my, down = down, clicked = clicked, released = released, menu = menu_open }
    if DD.open_id and menu_open and clicked then
        local target_h = math.min(#DD.items * DD.item_h, DD.max_h)
        if in_rect(mx, my, DD.x, DD.y, DD.w, target_h) then
            ui_s.clicked = false
        end
    end

    if menu_open then
        PANEL.dock_anim = PANEL.dock_anim + (1 - PANEL.dock_anim) * math.min(1, globals.frametime() * 14)
        if PANEL.dock_anim > 0.995 then PANEL.dock_anim = 1 end
    else
        PANEL.dock_anim = 0
    end

    local docked = update_dock()
    if not docked then
        local sw, sh = render.screen_size()
        PANEL.w = PANEL.DOCK_W
        PANEL.h = PANEL.MIN_H
        PANEL.x, PANEL.y = sw - PANEL.w - 40, (sh - PANEL.h) / 2
    end

    if docked and PANEL.dock_anim < 1 then
        local sw, sh = render.screen_size()
        render.clip_push(PANEL.dock_edge, 0, sw - PANEL.dock_edge, sh)
        draw_panel(ui_s)
        render.clip_pop()
    else
        draw_panel(ui_s)
    end

    local ui_top = { mx = mx, my = my, down = down, clicked = clicked, released = released, menu = menu_open }
    draw_active_dropdown(ui_top)

    if menu_open then
        CP.anim = CP.anim + ((CP.open and 1 or 0) - CP.anim) * math.min(1, globals.frametime() * 16)
        if CP.open and CP.anim > 0.995 then CP.anim = 1 end
        if not CP.open and CP.anim < 0.01 then CP.anim = 0 end
        draw_color_picker(ui_top)
    else
        CP.anim = 0
    end

    INPUT_STATE.mouse_prev = down
end)

cb_ids[#cb_ids + 1] = events.on("frame_stage", function(cur_stage)
    if cur_stage == NET_UPDATE_END then
        update_resolver()
    end
end)

cb_ids[#cb_ids + 1] = events.on("player_hurt", function(ev)
    if not safe(engine.in_game) then return end
    local local_ctrl = safe(entity.local_controller)
    if not local_ctrl then return end

    local attacker = safe(function() return ev:get_controller("attacker") end)
    local victim = safe(function() return ev:get_controller("userid") end)
    if not victim then return end

    local dmg = ev:get_int("dmg_health") or 0
    local rem_hp = ev:get_int("health") or 1
    local hg = ev:get_int("hitgroup") or 0
    local hg_name = HITGROUP_NAMES[hg] or "body"

    on_resolver_combat_feedback(attacker, victim, hg)

    if not CFG.hl_enable or dmg <= 0 then return end

    local local_addr = local_ctrl:address()
    local victim_addr = victim:address()
    local attacker_addr = attacker and attacker:address() or 0

    if CFG.hl_outgoing and attacker_addr == local_addr and victim_addr ~= local_addr then
        local v_name = safe(function() return victim:name() end) or "enemy"
        if rem_hp <= 0 then
            push_hit_log("killed", v_name, hg_name, dmg)
        else
            push_hit_log("hit", v_name, hg_name, dmg)
        end
    elseif CFG.hl_incoming and victim_addr == local_addr and attacker and attacker_addr ~= local_addr then
        local a_name = safe(function() return attacker:name() end) or "enemy"
        push_hit_log("harmed", a_name, hg_name, dmg)
    end
end)

cb_ids[#cb_ids + 1] = events.on("level_shutdown", function()
    reset_resolver_data()
end)

events.on("unload", function()
    for _, id in ipairs(cb_ids) do
        safe(events.off, id)
    end
end)

client.notify("0x Project v1.1 loaded", META.name)