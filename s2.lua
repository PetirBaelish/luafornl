-- @author gera289
-- @uid 1

local VibeUI = {}
VibeUI.__index = VibeUI
VibeUI.__version = "2.0-library"

-- ============================================================
--  HELPERS
-- ============================================================
local function safe(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end
local function clamp255(v) return math.floor(math.max(0, math.min(255, v))) end
local function white(a) return color(255, 255, 255, clamp255(a)) end
local function black(a) return color(0, 0, 0, clamp255(a)) end
local function in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end
local function lerp(a, b, t) return a + (b - a) * t end

-- ============================================================
--  THEME
-- ============================================================
local THEME = {
    bg       = color(13, 14, 21, 244),
    border   = color(255, 255, 255, 16),
    card     = color(20, 21, 31, 255),
    sep      = color(255, 255, 255, 10),
    field    = color(12, 13, 19, 255),
    label    = color(206, 209, 222, 255),
    section  = color(96, 99, 118, 255),
    value    = color(190, 193, 208, 255),
    sw_off   = color(50, 52, 64, 255),
    knob_off = color(138, 142, 158, 255),
    knob     = color(255, 255, 255, 255),
    accent   = color(140, 148, 255, 255),
    row_h    = 36,
    header_h = 56,
    font_sz  = 13,
}

VibeUI.accent_override = nil
function VibeUI.set_accent(c) VibeUI.accent_override = c end
local function refresh_accent()
    if VibeUI.accent_override then THEME.accent = VibeUI.accent_override; return end
    local c = safe(render.theme, "accent")
    if type(c) == "table" and c.r ~= nil then THEME.accent = color(c.r, c.g, c.b, 255) end
end

-- ============================================================
--  FONT
-- ============================================================
local FONT = nil
for _, name in ipairs({ "Segoe UI", "Tahoma", "Roboto" }) do
    local f = safe(render.font, name, THEME.font_sz)
    if f and safe(function() return f:loaded() end) then FONT = f; break end
end
local function text(x, y, col, str, size)
    render.text(x, y, col, str, "", size or THEME.font_sz, FONT)
end
local function tsize(str, size)
    return render.text_size(str, "", size or THEME.font_sz, FONT)
end
local TH = nil
local function text_h()
    if not TH then local _, h = tsize("Ag"); TH = h or THEME.font_sz end
    return TH
end
local function row_text(x, ry, label)
    text(x + 14, ry + (THEME.row_h - text_h()) / 2, THEME.label, label)
end

-- ============================================================
--  WIDGET HANDLE
-- ============================================================
local Widget = {}
Widget.__index = Widget

function Widget:get() return self.value end
function Widget:set(v)
    self.value = v
    if self.type == "colorpicker" and v and v.hsv then
        local h, s, vv = v:hsv()
        self._h, self._s, self._v = h, s, vv
        self._a = v.a / 255
    end
    if self.on_change then pcall(self.on_change, v) end
    return self
end
function Widget:on_change(fn) self.on_change = fn; return self end

-- ============================================================
--  SECTION
-- ============================================================
local Section = {}
Section.__index = Section
function Section.new(title)
    return setmetatable({ title = title, widgets = {} }, Section)
end
function Section:add(w)
    table.insert(self.widgets, w)
    return w
end

-- ============================================================
--  TAB
-- ============================================================
local Tab = {}
Tab.__index = Tab

function Tab.new(menu, name)
    local t = setmetatable({
        menu = menu,
        name = name,
        sections = {},
        widget_map = {},
    }, Tab)
    t:section("")
    return t
end

function Tab:section(title)
    local s = Section.new(title or "")
    table.insert(self.sections, s)
    self._current = s
    return s
end

local function reg(tab, w)
    tab.widget_map[w.id] = w
    tab._current:add(w)
    return w
end

function Tab:checkbox(id, label, default, cb)
    return reg(self, setmetatable({
        type = "checkbox", id = id, label = label,
        value = default or false, on_change = cb,
        anim = default and 1 or 0,
    }, Widget))
end

function Tab:slider(id, label, default, lo, hi, step, fmt, cb)
    return reg(self, setmetatable({
        type = "slider", id = id, label = label,
        value = default or lo, lo = lo, hi = hi, step = step or 1,
        fmt = fmt or function(v) return tostring(math.floor(v + 0.5)) end,
        on_change = cb,
    }, Widget))
end

function Tab:combo(id, label, items, default_idx, cb)
    return reg(self, setmetatable({
        type = "combo", id = id, label = label,
        items = items, value = default_idx or 1,
        on_change = cb, hover_t = 0, arrow_t = 0,
    }, Widget))
end

function Tab:colorpicker(id, label, default, cb)
    local c = default or THEME.accent
    local h, s, v = c:hsv()
    return reg(self, setmetatable({
        type = "colorpicker", id = id, label = label,
        value = c, on_change = cb,
        _h = h, _s = s, _v = v, _a = c.a / 255,
    }, Widget))
end

function Tab:button(id, label, cb)
    return reg(self, setmetatable({
        type = "button", id = id, label = label,
        on_click = cb, hover_t = 0,
    }, Widget))
end

function Tab:label(txt)
    return reg(self, setmetatable({
        type = "label", id = "__lbl_" .. tostring(#self._current.widgets),
        label = txt,
    }, Widget))
end

function Tab:get(id) local w = self.widget_map[id]; return w and w:get() end
function Tab:set(id, v) local w = self.widget_map[id]; if w then w:set(v) end end
function Tab:find(id) return self.widget_map[id] end

-- ============================================================
--  MENU INSTANCE
-- ============================================================
local SPRING_STIFFNESS = 350
local SPRING_DAMPING   = 30
local DOCK_GAP = 8
local MIN_H = 480

local REGISTERED = {}
local mouse_prev_global = false

function VibeUI.new(opts)
    opts = opts or {}
    return setmetatable({
        title      = opts.title or "Menu",
        subtitle   = opts.subtitle or ("VibeUI " .. VibeUI.__version),
        opts_width = opts.width or 350,
        opts_height= opts.height or MIN_H,
        follow_ui  = opts.follow_ui ~= false,
        position   = opts.position or { x = 200, y = 200 },
        draggable  = opts.draggable ~= false,
        visible    = true,

        tabs = {},
        current_tab_idx = 1,
        prev_tab_idx = 1,

        -- dock
        dock_anim = 0,
        dock_edge = 0,

        -- layout / scroll
        x = 0, y = 0, w = 0, h = 0,
        scroll_y = 0,
        content_h = 0,

        -- tab indicator spring
        tab_y = nil,
        tab_vel_y = 0,

        -- content transition spring
        tab_spring = 1,
        tab_spring_vel = 0,
        anim_dir = 1,

        -- interaction
        slider_active = nil,
        sb_drag = false,
        ds_drag = false, ds_y0 = 0, ds_s0 = 0,
        click_used = false,
        drag_win = false, drag_off_x = 0, drag_off_y = 0,

        -- dropdown (per-instance)
        dd = { open_id = nil, items = {}, setter = nil, selected_idx = 0,
               x = 0, y = 0, w = 0, anim = 0, scroll = 0, item_h = 26, max_h = 150 },

        -- colorpicker (per-instance)
        cp = { open = false, target = nil, h = 0, s = 1, v = 1, a = 1,
               drag = nil, skip_close = false, anim = 0,
               fmt = 0, dd_open = false, dd_anim = 0 },

        mouse_prev = false,
        _registered = false,
    }, VibeUI)
end

function VibeUI:tab(name)
    local t = Tab.new(self, name)
    table.insert(self.tabs, t)
    return t
end
function VibeUI:get_tab(name)
    for _, t in ipairs(self.tabs) do
        if t.name == name then return t end
    end
end

function VibeUI:show() self.visible = true end
function VibeUI:hide() self.visible = false end
function VibeUI:set_position(x, y) self.position.x = x; self.position.y = y end

function VibeUI:register()
    if not self._registered then
        self._registered = true
        table.insert(REGISTERED, self)
    end
    return self
end
function VibeUI:unregister()
    for i, m in ipairs(REGISTERED) do
        if m == self then table.remove(REGISTERED, i); break end
    end
    self._registered = false
end

function VibeUI:is_visible()
    if not self.visible then return false end
    if self.follow_ui then return input.menu_open() == true end
    return true
end

function VibeUI:_blocked()
    return self.cp.open or self.dd.open_id ~= nil
end

-- ============================================================
--  POSITIONING
-- ============================================================
function VibeUI:_update_geometry()
    if self.follow_ui then
        local mp = safe(function() return ui.position() end)
        local ms = safe(function() return ui.size() end)
        if not (mp and ms and mp.x and ms.x and ms.x > 0) then
            local sw, sh = render.screen_size()
            self.w = self.opts_width
            self.h = math.max(self.opts_height, MIN_H)
            self.x = sw - self.w - 40
            self.y = (sh - self.h) / 2
            return false
        end
        self.w = self.opts_width
        self.h = math.max(ms.y, self.opts_height or MIN_H)
        self.dock_edge = mp.x + ms.x
        self.x = self.dock_edge + DOCK_GAP - (1 - self.dock_anim) * (self.w + DOCK_GAP)
        self.y = mp.y
        return true
    else
        self.w = self.opts_width
        self.h = self.opts_height
        self.x = self.position.x
        self.y = self.position.y
        return true
    end
end

-- ============================================================
--  SPRING UPDATERS
-- ============================================================
function VibeUI:_update_tab_spring(dt)
    if math.abs(self.tab_spring - 1) < 0.001 and math.abs(self.tab_spring_vel) < 0.001 then
        self.tab_spring = 1
        self.tab_spring_vel = 0
        return
    end
    local step = math.min(dt, 0.033)
    local force = SPRING_STIFFNESS * (1 - self.tab_spring) - SPRING_DAMPING * self.tab_spring_vel
    self.tab_spring_vel = self.tab_spring_vel + force * step
    self.tab_spring = self.tab_spring + self.tab_spring_vel * step
    if self.tab_spring > 1.15 then self.tab_spring = 1.15; self.tab_spring_vel = 0 end
    if self.tab_spring < -0.15 then self.tab_spring = -0.15; self.tab_spring_vel = 0 end
end

function VibeUI:_tab_anim_done()
    return math.abs(self.tab_spring - 1) < 0.02 and math.abs(self.tab_spring_vel) < 0.02
end

-- ============================================================
--  WIDGET DRAWERS
--  All receive (self, w, ui, x, ry, width, interactive)
-- ============================================================
function VibeUI:_draw_checkbox(w, ui, x, ry, width, interactive)
    row_text(x, ry, w.label)
    local on = w.value and 1 or 0
    w.anim = w.anim + (on - w.anim) * math.min(1, globals.frametime() * 16)
    if math.abs(w.anim - on) < 0.005 then w.anim = on end
    local t = w.anim
    local sw, sh = 34, 18
    local sx, sy = x + width - 14 - sw, ry + (THEME.row_h - sh) / 2
    render.rect_filled(sx, sy, sw, sh, THEME.sw_off:lerp(THEME.accent, t), sh / 2)
    render.circle_filled(sx + 9 + (sw - 18) * t, sy + sh / 2, 6,
        THEME.knob_off:lerp(THEME.knob, t), 24)
    if interactive and not self:_blocked() and ui.clicked
        and in_rect(ui.mx, ui.my, x, ry, width, THEME.row_h) then
        self.click_used = true
        w:set(not w.value)
    end
end

function VibeUI:_draw_slider(w, ui, x, ry, width, interactive)
    row_text(x, ry, w.label)
    local f = math.max(0, math.min(1, (w.value - w.lo) / (w.hi - w.lo)))

    local bw, bh = 56, 22
    local bx, by = x + width - 14 - bw, ry + (THEME.row_h - bh) / 2
    render.rect_filled(bx, by, bw, bh, THEME.field, 6)
    render.rect(bx, by, bw, bh, THEME.border, 6, 1)
    local vs = w.fmt(w.value)
    local vw, vh = tsize(vs)
    text(bx + (bw - vw) / 2, by + (bh - vh) / 2, THEME.value, vs)

    local tw = 92
    local tx = bx - 12 - tw
    local ty = ry + THEME.row_h / 2
    render.rect_filled(tx, ty - 2, tw, 4, THEME.sw_off, 2)
    if f > 0 then render.rect_filled(tx, ty - 2, tw * f, 4, THEME.accent, 2) end
    render.circle_filled(tx + tw * f, ty, 6, THEME.knob, 20)

    if interactive and not self:_blocked() then
        local on_track = in_rect(ui.mx, ui.my, tx - 8, ty - 10, tw + 16, 20)
        if ui.clicked and on_track then self.click_used = true end
        if ui.down and (self.slider_active == w.id or (ui.clicked and on_track)) then
            self.slider_active = w.id
            local nf = math.max(0, math.min(1, (ui.mx - tx) / tw))
            local v = w.lo + nf * (w.hi - w.lo)
            v = math.floor(v / w.step + 0.5) * w.step
            v = math.max(w.lo, math.min(w.hi, v))
            if v ~= w.value then w:set(v) end
        end
        if ui.released and self.slider_active == w.id then self.slider_active = nil end
    end
end

function VibeUI:_draw_combo(w, ui, x, ry, width, interactive)
    row_text(x, ry, w.label)
    local bw, bh = 134, 24
    local bx, by = x + width - 14 - bw, ry + (THEME.row_h - bh) / 2
    local idx = w.value

    local hover = interactive and not self:_blocked() and in_rect(ui.mx, ui.my, bx, by, bw, bh)
    w.hover_t = w.hover_t + ((hover and 1 or 0) - w.hover_t) * math.min(1, globals.frametime() * 16)
    local t = w.hover_t
    render.rect_filled(bx, by, bw, bh, THEME.field:lerp(color(28, 30, 46, 255), t), 6)
    render.rect(bx, by, bw, bh, THEME.border:lerp(THEME.accent:alpha(80), t), 6, 1)

    local cur = w.items[idx] or "?"
    local _, ch = tsize(cur)
    text(bx + 10, by + (bh - ch) / 2, THEME.label, cur)

    local is_open = (self.dd.open_id == w.id)
    w.arrow_t = w.arrow_t + ((is_open and 1 or 0) - w.arrow_t) * math.min(1, globals.frametime() * 16)
    local ccx, ccy = bx + bw - 14, by + bh / 2
    local d = 1 - 2 * w.arrow_t
    render.line(ccx - 4, ccy - 2 * d, ccx, ccy + 2 * d, THEME.value, 1.5)
    render.line(ccx, ccy + 2 * d, ccx + 4, ccy - 2 * d, THEME.value, 1.5)

    if interactive and not self.cp.open and ui.clicked
        and in_rect(ui.mx, ui.my, bx, by, bw, bh) then
        self.click_used = true
        if is_open then
            self.dd.open_id = nil
        else
            self.dd.open_id = w.id
            self.dd.items = w.items
            self.dd.setter = function(i) w:set(i) end
            self.dd.selected_idx = idx - 1
            self.dd.x = bx
            self.dd.y = by + bh + 2
            self.dd.w = bw
            self.dd.anim = 0
            self.dd.scroll = 0
            local _, sh = render.screen_size()
            local th = math.min(#w.items * self.dd.item_h, self.dd.max_h)
            if self.dd.y + th > sh then self.dd.y = by - th - 2 end
        end
    end
end

function VibeUI:_draw_colorpicker_btn(w, ui, x, ry, width, interactive)
    row_text(x, ry, w.label)
    local sw, sh = 34, 18
    local sx, sy = x + width - 14 - sw, ry + (THEME.row_h - sh) / 2
    local col = w.value
    render.rect_filled(sx, sy, sw, sh, THEME.sw_off, 6)
    render.rect_filled(sx, sy, sw, sh, col, 6)
    render.rect(sx, sy, sw, sh, white(40), 6, 1)
    if interactive and not self.cp.open and not self.dd.open_id and ui.clicked
        and in_rect(ui.mx, ui.my, sx - 4, sy - 4, sw + 8, sh + 8) then
        self.click_used = true
        local h, s, v = col:hsv()
        self.cp.h, self.cp.s, self.cp.v = h, s, v
        self.cp.a = col.a / 255
        self.cp.target = w
        self.cp.open = true
        self.cp.skip_close = true
    end
end

function VibeUI:_draw_button(w, ui, x, ry, width, interactive)
    local bx, by, bw, bh = x + 14, ry + 6, width - 28, THEME.row_h - 12
    local hover = interactive and not self:_blocked() and in_rect(ui.mx, ui.my, bx, by, bw, bh)
    w.hover_t = w.hover_t + ((hover and 1 or 0) - w.hover_t) * math.min(1, globals.frametime() * 16)
    local t = w.hover_t
    render.rect_filled(bx, by, bw, bh, THEME.field:lerp(color(30, 32, 48, 255), t), 7)
    render.rect(bx, by, bw, bh, THEME.border:lerp(THEME.accent, t), 7, 1)
    local tw, th = tsize(w.label)
    text(bx + (bw - tw) / 2, by + (bh - th) / 2, THEME.label, w.label)
    if hover and ui.clicked then
        self.click_used = true
        if w.on_click then pcall(w.on_click) end
    end
end

function VibeUI:_draw_label(w, ui, x, ry, width)
    row_text(x, ry, w.label)
end

function VibeUI:_draw_widget(w, ui, x, ry, width, interactive)
    if w.type == "checkbox" then self:_draw_checkbox(w, ui, x, ry, width, interactive)
    elseif w.type == "slider" then self:_draw_slider(w, ui, x, ry, width, interactive)
    elseif w.type == "combo" then self:_draw_combo(w, ui, x, ry, width, interactive)
    elseif w.type == "colorpicker" then self:_draw_colorpicker_btn(w, ui, x, ry, width, interactive)
    elseif w.type == "button" then self:_draw_button(w, ui, x, ry, width, interactive)
    elseif w.type == "label" then self:_draw_label(w, ui, x, ry, width)
    end
end

-- ============================================================
--  TAB CONTENT RENDER
-- ============================================================
function VibeUI:_draw_tab_content(tab, ui, gx, start_y, gw, interactive)
    local cy = start_y
    for _, section in ipairs(tab.sections) do
        if section.title ~= "" then
            text(gx + 4, cy, THEME.section, section.title)
            cy = cy + 20
        end
        if #section.widgets > 0 then
            local ch = #section.widgets * THEME.row_h
            render.rect_filled(gx, cy, gw, ch, THEME.card, 10)
            render.rect(gx, cy, gw, ch, THEME.border, 10, 1)
            for i = 1, #section.widgets - 1 do
                render.rect_filled(gx + 12, cy + i * THEME.row_h, gw - 24, 1, THEME.sep)
            end
            for i, w in ipairs(section.widgets) do
                self:_draw_widget(w, ui, gx, cy + (i - 1) * THEME.row_h, gw, interactive)
            end
            cy = cy + ch + 14
        else
            cy = cy + 10
        end
    end
    return cy
end

-- ============================================================
--  SIDE TABS
-- ============================================================
function VibeUI:_draw_tabs(ui, x, y)
    local tab = self.tabs[self.current_tab_idx]
    if not tab then return end

    local bh, tab_w, gap = 36, 54, 8
    local tx = x
    local ty = y + 16
    local target_y = ty + (self.current_tab_idx - 1) * (bh + gap)
    if self.tab_y == nil then self.tab_y = target_y end

    local dt = globals.frametime()
    local stiffness, damping = 300, 22
    local force = stiffness * (target_y - self.tab_y) - damping * self.tab_vel_y
    self.tab_vel_y = self.tab_vel_y + force * dt
    self.tab_y = self.tab_y + self.tab_vel_y * dt
    if math.abs(self.tab_vel_y) < 0.1 and math.abs(self.tab_y - target_y) < 0.1 then
        self.tab_y = target_y
        self.tab_vel_y = 0
    end

    local stretch = math.min(math.abs(self.tab_vel_y) * 0.06, 24)
    local cur_h = bh + stretch
    local cur_y = self.tab_y - stretch / 2
    local min_y = ty - 8
    local max_y = ty + (#self.tabs * bh + (#self.tabs - 1) * gap) - cur_h + 8
    cur_y = math.max(min_y, math.min(cur_y, max_y))

    for i = 1, #self.tabs do
        local sy = ty + (i - 1) * (bh + gap)
        render.rect_filled(tx, sy, tab_w, bh, THEME.card, 10)
        render.rect(tx, sy, tab_w, bh, THEME.border, 10, 1)
    end

    render.shadow(tx, cur_y, tab_w, cur_h, THEME.accent:alpha(60), 8, 4)
    render.rect_filled(tx, cur_y, tab_w, cur_h, color(255, 255, 255, 10), 10)
    render.rect(tx, cur_y, tab_w, cur_h, THEME.accent, 10, 1.5)

    for i = 1, #self.tabs do
        local sy = ty + (i - 1) * (bh + gap)
        local is_active = (self.current_tab_idx == i)
        local cx = tx + tab_w / 2
        local cy = sy + bh / 2
        local ic = is_active and THEME.knob or THEME.section

        if i == 1 then
            render.rect(cx - 7, cy - 6, 14, 10, ic, 2, 1.5)
            render.rect_filled(cx - 2, cy + 4, 4, 2, ic, 1)
        else
            local lw = 12
            render.line(cx - lw/2, cy - 4, cx + lw/2, cy - 4, ic, 1.5)
            render.circle_filled(cx - 2, cy - 4, 2.5, THEME.card, 12)
            render.circle(cx - 2, cy - 4, 2.5, ic, 12, 1.5)
            render.line(cx - lw/2, cy + 4, cx + lw/2, cy + 4, ic, 1.5)
            render.circle_filled(cx + 2, cy + 4, 2.5, THEME.card, 12)
            render.circle(cx + 2, cy + 4, 2.5, ic, 12, 1.5)
        end

        if not self:_blocked() and ui.clicked and self.current_tab_idx ~= i
            and in_rect(ui.mx, ui.my, tx, sy, tab_w, bh) then
            self.click_used = true
            self.prev_tab_idx = self.current_tab_idx
            self.current_tab_idx = i
            self.scroll_y = 0
            self.tab_spring = 0
            self.tab_spring_vel = 0
            self.anim_dir = (self.current_tab_idx > self.prev_tab_idx) and 1 or -1
            self.tab_vel_y = (target_y - self.tab_y) * 0.5
            self.dd.open_id = nil
        end
    end
end

-- ============================================================
--  HEADER
-- ============================================================
function VibeUI:_draw_header(x, y, w)
    local lx, ly, ls = x + 16, y + 11, 34
    render.rect_filled(lx, ly, ls, ls, color(22, 23, 34, 255), 9)
    render.rect(lx, ly, ls, ls, THEME.border, 9, 1)
    text(lx + ls + 12, y + 12, THEME.knob, self.title, 15)
    text(lx + ls + 12, y + 31, THEME.section, self.subtitle, 11)
    render.rect_filled(x + 16, y, w - 32, 1, THEME.sep)
end

-- ============================================================
--  MAIN CONTENT (scroll + tab spring transition)
-- ============================================================
local function get_wheel()
    if safe(input.key_down, 0x0E) then return -1 end
    if safe(input.key_down, 0x0F) then return  1 end
    return 0
end

function VibeUI:_draw_controls(ui, x, y, w)
    local gx, gw = x + 14, w - 28
    local vp_y = y + 16
    local vp_h = (y + self.h) - vp_y - THEME.header_h - 8
    local max_scroll = math.max(0, self.content_h - vp_h)
    self.click_used = false

    if not self:_blocked() and in_rect(ui.mx, ui.my, x, y, w, self.h) then
        local wh = get_wheel()
        if wh ~= 0 then self.scroll_y = self.scroll_y - wh * 40 end
    end

    if self.ds_drag then
        if ui.down and not self:_blocked() then self.scroll_y = self.ds_s0 - (ui.my - self.ds_y0)
        else self.ds_drag = false end
    end

    local thumb_h = (max_scroll > 0) and math.max(28, vp_h * vp_h / self.content_h) or 0
    if max_scroll > 0 and not self:_blocked() then
        if ui.clicked and in_rect(ui.mx, ui.my, x + w - 20, vp_y, 20, vp_h) then
            self.sb_drag = true
        end
        if self.sb_drag then
            if ui.down then
                local f = (ui.my - vp_y - thumb_h / 2) / math.max(1, vp_h - thumb_h)
                self.scroll_y = math.max(0, math.min(1, f)) * max_scroll
            else self.sb_drag = false end
        end
    else
        self.sb_drag = false
    end
    self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))

    self:_update_tab_spring(globals.frametime())

    local inner_click = self:_tab_anim_done() and ui.clicked and not self.sb_drag
        and in_rect(ui.mx, ui.my, x, vp_y, w - 20, vp_h)

    local cui = {
        mx = ui.mx, my = ui.my, down = ui.down, released = ui.released,
        clicked = inner_click,
    }

    render.clip_push(x + 1, vp_y, w - 2, vp_h, true)
    local start = vp_y - self.scroll_y
    local fin

    if not self:_tab_anim_done() then
        local p = self.tab_spring
        local shift_old = -self.anim_dir * p * vp_h
        local shift_new = self.anim_dir * (1 - p) * vp_h
        local dead = { mx = -1, my = -1, down = false, released = false, clicked = false }

        local old_tab = self.tabs[self.prev_tab_idx]
        local new_tab = self.tabs[self.current_tab_idx]
        if old_tab then self:_draw_tab_content(old_tab, dead, gx, start + shift_old, gw, false) end
        if new_tab then fin = self:_draw_tab_content(new_tab, cui, gx, start + shift_new, gw, true) end
    else
        local tab = self.tabs[self.current_tab_idx]
        if tab then fin = self:_draw_tab_content(tab, cui, gx, start, gw, true) end
    end

    render.clip_pop()
    self.content_h = ((fin or start) - start) + 4

    if cui.clicked and not self.click_used and not self:_blocked() and max_scroll > 0 then
        self.ds_drag, self.ds_y0, self.ds_s0 = true, ui.my, self.scroll_y
    end

    if max_scroll > 0 then
        local tx = x + w - 10
        render.rect_filled(tx, vp_y, 3, vp_h, color(255, 255, 255, 10), 2)
        local ty = vp_y + (vp_h - thumb_h) * (self.scroll_y / max_scroll)
        render.rect_filled(tx, ty, 3, thumb_h, THEME.accent:alpha(self.sb_drag and 200 or 120), 2)
    end
end

-- ============================================================
--  DROPDOWN OVERLAY
-- ============================================================
function VibeUI:_draw_dropdown(ui)
    local d = self.dd
    if not d.open_id then return end

    local _, sh = render.screen_size()
    local target_h = math.min(#d.items * d.item_h, d.max_h)

    if ui.clicked and not in_rect(ui.mx, ui.my, d.x, d.y, d.w, target_h) then
        if not self.click_used and not in_rect(ui.mx, ui.my, d.x, d.y - 26, d.w, 26) then
            d.open_id = nil
            return
        end
    end

    d.anim = d.anim + (1 - d.anim) * math.min(1, globals.frametime() * 20)
    if d.anim > 0.99 then d.anim = 1 end
    local ease = 1 - (1 - d.anim) ^ 3
    local h = target_h * ease
    if h < 1 then return end

    render.shadow(d.x, d.y, d.w, h, black(120), 22, 10)
    render.rect_filled(d.x, d.y, d.w, h, THEME.card, 6)
    render.rect(d.x, d.y, d.w, h, THEME.border, 6, 1)

    local max_scroll = math.max(0, #d.items * d.item_h - d.max_h)
    if in_rect(ui.mx, ui.my, d.x, d.y, d.w, h) then
        local wh = get_wheel()
        if wh ~= 0 then
            d.scroll = math.max(0, math.min(d.scroll - wh * 30, max_scroll))
        end
    end

    render.clip_push(d.x, d.y, d.w, h, true)
    for i, item in ipairs(d.items) do
        local iy = d.y + (i - 1) * d.item_h - d.scroll
        if iy + d.item_h > d.y and iy < d.y + h then
            local hover = in_rect(ui.mx, ui.my, d.x, math.max(d.y, iy), d.w,
                math.min(h, d.item_h))
            if hover then
                render.rect_filled(d.x + 4, iy + 2, d.w - 8, d.item_h - 4,
                    color(255, 255, 255, 15), 4)
            end
            local tw, th = tsize(item)
            local col = (i - 1 == d.selected_idx) and THEME.accent or THEME.label
            text(d.x + 12, iy + (d.item_h - th) / 2, col, item)
            if hover and ui.clicked then
                self.click_used = true
                d.setter(i)
                d.open_id = nil
            end
        end
    end
    render.clip_pop()

    if max_scroll > 0 then
        local sb_h = (d.max_h / (#d.items * d.item_h)) * h
        local sb_y = d.y + (d.scroll / max_scroll) * (h - sb_h)
        render.rect_filled(d.x + d.w - 6, sb_y, 3, sb_h, color(255, 255, 255, 30), 1.5)
    end
end

-- ============================================================
--  COLOR PICKER OVERLAY
-- ============================================================
local CP_W, CP_H = 250, 276

local function hbar(x, y, w, h, colfn)
    local r = h / 2
    for px = 0, w - 1, 2 do
        local cw = math.min(2, w - px)
        local dd = math.min(px + 1, w - px - 1)
        local inset = 0
        if dd < r then inset = r - math.sqrt(math.max(0, r * r - (r - dd) * (r - dd))) end
        render.rect_filled(x + px, y + inset, cw, h - inset * 2, colfn((px + 1) / w))
    end
end

local function sv_area(x, y, w, h, r, hue_col, k)
    for py = 0, h - 1, 2 do
        local rh = math.min(2, h - py)
        local dd = math.min(py + 1, h - py - 1)
        local inset = 0
        if dd < r then inset = r - math.sqrt(math.max(0, r * r - (r - dd) * (r - dd))) end
        local v = 1 - (py + rh / 2) / h
        local left = color(255 * v, 255 * v, 255 * v, 255 * k)
        local right = color(hue_col.r * v, hue_col.g * v, hue_col.b * v, 255 * k)
        render.gradient(x + inset, y + py, w - inset * 2, rh, left, right, true)
    end
end

function VibeUI:_draw_colorpicker(ui)
    local c = self.cp
    local k = 1 - (1 - c.anim) ^ 3
    if k <= 0.01 then return end
    local function A(col) return col:alpha(col.a * k) end

    local sw, sh = render.screen_size()
    local px = self.x + self.w + 12
    if px + CP_W > sw - 8 then px = self.x + (self.w - CP_W) / 2 end
    px = math.max(8, math.min(px, sw - CP_W - 8))
    local py = math.max(8, math.min(self.y, sh - CP_H - 8))
    px = px - (1 - k) * 14
    py = py + (1 - k) * 10

    if c.open then
        if c.skip_close then c.skip_close = false
        elseif ui.clicked and not in_rect(ui.mx, ui.my, px, py, CP_W, CP_H) then
            c.open = false; c.drag = nil; c.dd_open = false
        end
    end

    local pad = 12
    local iw = CP_W - pad * 2
    local svx, svy, svh = px + pad, py + pad, 170
    local hy = svy + svh + 14
    local ay = hy + 8 + 12
    local ry = ay + 8 + 16

    render.shadow(px, py, CP_W, CP_H, black(110 * k), 22, 12)
    render.rect_filled(px, py, CP_W, CP_H, A(THEME.bg), 12)
    render.rect(px, py, CP_W, CP_H, A(THEME.border), 12, 1)

    local hue_col = color_hsv(c.h, 1, 1, 255)
    local cur = color_hsv(c.h, c.s, c.v, 255)

    sv_area(svx, svy, iw, svh, 8, hue_col, k)
    render.rect(svx, svy, iw, svh, A(white(22)), 8, 1)
    hbar(svx, hy + 1, iw, 8, function(f) return color_hsv(f, 1, 1, 255 * k) end)
    render.rect_filled(svx, ay + 1, iw, 8, A(THEME.sw_off), 4)
    hbar(svx, ay + 1, iw, 8, function(f) return color(cur.r, cur.g, cur.b, 255 * f * k) end)

    local kx, ky = svx + c.s * iw, svy + (1 - c.v) * svh
    render.circle_filled(kx, ky, 8, A(white(255)), 24)
    render.circle_filled(kx, ky, 6, A(cur), 24)

    local hx = svx + c.h * iw
    render.rect_filled(hx - 5, hy - 4, 10, 18, A(white(255)), 5)
    render.rect_filled(hx - 3, hy - 2, 6, 14, A(hue_col), 3)

    local ax = svx + c.a * iw
    render.circle_filled(ax, ay + 5, 8, A(white(255)), 24)
    render.circle_filled(ax, ay + 5, 6, A(cur), 24)

    local fw, vw, ow, rh = 60, 110, 44, 26
    local fx = svx
    local vx = fx + fw + 6
    local ox = vx + vw + 6
    local cc = color_hsv(c.h, c.s, c.v, math.floor(c.a * 255 + 0.5))

    local function field(x, w_)
        render.rect_filled(x, ry, w_, rh, A(THEME.field), 7)
        render.rect(x, ry, w_, rh, A(THEME.border), 7, 1)
    end
    local function ftext(x, w_, col, str)
        local tw, th = tsize(str)
        text(x + (w_ - tw) / 2, ry + (rh - th) / 2, A(col), str)
    end

    field(fx, fw)
    local fstr = (c.fmt == 0) and "HEX" or "RGB"
    text(fx + 6, ry + (rh - text_h()) / 2, A(THEME.label), fstr)

    local arrow_t = 1 - 2 * (c.dd_anim or 0)
    local ccx, ccy = fx + fw - 12, ry + rh / 2
    render.line(ccx - 4, ccy - 2 * arrow_t, ccx, ccy + 2 * arrow_t, A(THEME.value), 1.5)
    render.line(ccx, ccy + 2 * arrow_t, ccx + 4, ccy - 2 * arrow_t, A(THEME.value), 1.5)

    field(vx, vw)
    render.rect_filled(vx + 7, ry + (rh - 14) / 2, 14, 14, A(color(cc.r, cc.g, cc.b, 255)), 4)
    local tx0, tw0 = vx + 26, vw - 26
    if c.fmt == 0 then
        local hexs = cc:hex():upper()
        local hw_ = tsize("#")
        local tw_, th_ = tsize(hexs)
        local startx = tx0 + (tw0 - (hw_ + 2 + tw_)) / 2
        text(startx, ry + (rh - th_) / 2, A(THEME.section), "#")
        text(startx + hw_ + 2, ry + (rh - th_) / 2, A(THEME.label), hexs)
    else
        ftext(tx0, tw0, THEME.label, string.format("%d,%d,%d",
            math.floor(cc.r + 0.5), math.floor(cc.g + 0.5), math.floor(cc.b + 0.5)))
    end

    field(ox, ow)
    ftext(ox, ow, THEME.label, string.format("%d%%", math.floor(c.a * 100 + 0.5)))

    local fmt_items = { "HEX", "RGB" }
    local drop_h = #fmt_items * 26
    local drop_y = ry + rh + 4
    c.dd_anim = c.dd_anim + ((c.dd_open and 1 or 0) - c.dd_anim) * math.min(1, globals.frametime() * 20)
    if c.dd_anim > 0.01 then
        local dh = drop_h * c.dd_anim
        render.shadow(fx, drop_y, fw, dh, A(black(100)), 6, 4)
        render.rect_filled(fx, drop_y, fw, dh, A(THEME.card), 6)
        render.rect(fx, drop_y, fw, dh, A(THEME.border), 6, 1)
        render.clip_push(fx, drop_y, fw, dh, true)
        for i, fmt_str in ipairs(fmt_items) do
            local iy = drop_y + (i - 1) * 26
            local ihover = in_rect(ui.mx, ui.my, fx, iy, fw, 26) and c.dd_anim > 0.95
            if ihover then
                render.rect_filled(fx + 2, iy + 2, fw - 4, 22, A(white(15)), 4)
            end
            local tw = tsize(fmt_str)
            text(fx + (fw - tw) / 2, iy + (26 - text_h()) / 2, A(THEME.label), fmt_str)
            if ihover and ui.clicked then
                c.fmt = i - 1
                c.dd_open = false
            end
        end
        render.clip_pop()
    end

    if c.open then
        if ui.released then c.drag = nil end
        if ui.clicked and in_rect(ui.mx, ui.my, fx, ry, fw, rh) then
            c.dd_open = not c.dd_open
            c.skip_close = true
        end
        if c.dd_open and ui.clicked
            and not in_rect(ui.mx, ui.my, fx, ry, fw, rh + drop_h) then
            c.dd_open = false
        end
        if not c.dd_open and ui.down then
            if c.drag == "sv" or (ui.clicked and in_rect(ui.mx, ui.my, svx, svy, iw, svh)) then
                c.drag = "sv"
                c.s = math.max(0, math.min(1, (ui.mx - svx) / iw))
                c.v = math.max(0, math.min(1, 1 - (ui.my - svy) / svh))
            elseif c.drag == "hue" or (ui.clicked and in_rect(ui.mx, ui.my, svx - 6, hy - 6, iw + 12, 22)) then
                c.drag = "hue"
                c.h = math.max(0, math.min(1, (ui.mx - svx) / iw))
            elseif c.drag == "alpha" or (ui.clicked and in_rect(ui.mx, ui.my, svx - 6, ay - 6, iw + 12, 22)) then
                c.drag = "alpha"
                c.a = math.max(0, math.min(1, (ui.mx - svx) / iw))
            end
        end

        -- Write back into target widget
        local w = c.target
        if w then
            local new_col = color_hsv(c.h, c.s, c.v, math.floor(c.a * 255 + 0.5))
            local old = w.value
            if not old or old.r ~= new_col.r or old.g ~= new_col.g
                or old.b ~= new_col.b or old.a ~= new_col.a then
                w._h, w._s, w._v = c.h, c.s, c.v
                w._a = c.a
                w.value = new_col
                if w.on_change then pcall(w.on_change, new_col) end
            end
        end
    end
end

-- ============================================================
--  FULL PAINT PASSES
-- ============================================================
function VibeUI:_paint_main(ui)
    if self.follow_ui then
        self.dock_anim = self.dock_anim + (1 - self.dock_anim) * math.min(1, globals.frametime() * 14)
        if self.dock_anim > 0.995 then self.dock_anim = 1 end
    else
        self.dock_anim = 1
    end

    self:_update_geometry()
    self:_draw_tabs(ui, self.x + self.w + 12, self.y)

    render.shadow(self.x, self.y, self.w, self.h, black(120), 22, 12)
    render.rect_filled(self.x, self.y, self.w, self.h, THEME.bg, 12)
    render.rect(self.x, self.y, self.w, self.h, THEME.border, 12, 1)

    self:_draw_controls(ui, self.x, self.y, self.w)
    self:_draw_header(self.x, self.y + self.h - THEME.header_h, self.w)

    self.click_used = self.click_used or false
end

function VibeUI:_paint_overlays(ui)
    self:_draw_dropdown(ui)
    local c = self.cp
    c.anim = c.anim + ((c.open and 1 or 0) - c.anim) * math.min(1, globals.frametime() * 16)
    if c.open and c.anim > 0.995 then c.anim = 1 end
    if not c.open and c.anim < 0.01 then c.anim = 0 end
    self:_draw_colorpicker(ui)
end

-- ============================================================
--  GLOBAL DISPATCHER
-- ============================================================
events.on("paint", function()
    refresh_accent()
    local mx, my = input.cursor()
    local down = input.key_down(0x01)
    local clicked = down and not mouse_prev_global
    local released = mouse_prev_global and not down

    -- pass 1: main panels
    for _, m in ipairs(REGISTERED) do
        if m:is_visible() then
            local ui = { mx = mx, my = my, down = down, clicked = clicked, released = released }
            -- suppress click inside an active dropdown to avoid double-handling
            if m.dd.open_id and clicked then
                local th = math.min(#m.dd.items * m.dd.item_h, m.dd.max_h)
                if in_rect(mx, my, m.dd.x, m.dd.y, m.dd.w, th) then
                    ui.clicked = false
                end
            end
            m:_paint_main(ui)
        end
    end

    -- pass 2: overlays on top of every panel
    for _, m in ipairs(REGISTERED) do
        if m:is_visible() then
            local ui = { mx = mx, my = my, down = down, clicked = clicked, released = released }
            m:_paint_overlays(ui)
        end
    end

    mouse_prev_global = down
end)

-- ============================================================
--  USAGE EXAMPLE  (delete or comment if not needed)
-- ============================================================
local menu = VibeUI.new({ title = "Menu", subtitle = "VibeUI " .. VibeUI.__version })

local tab_v = menu:tab("Visual")
local tab_s = menu:tab("Settings")

tab_v:section("DROPDOWNS")
tab_v:combo("combo1", "Test", { "Option 1", "Option 2", "Option 3", "Option 4" }, 1)

tab_v:section("CHECKBOXES")
tab_v:checkbox("cb_a", "Test Toggle 1", true)
tab_v:checkbox("cb_b", "Test Toggle 2", false)

tab_v:section("SLIDERS")
tab_v:slider("sl_int",   "Test Slider 1", 50,  0,   100, 1,
    function(v) return tostring(math.floor(v + 0.5)) end)
tab_v:slider("sl_float", "Test Slider 2", 1.5, 0.1, 5.0, 0.1,
    function(v) return string.format("%.1f", v) end)

tab_s:section("COLORS")
tab_s:colorpicker("c1", "Accent color",    color(140, 148, 255, 255))
tab_s:colorpicker("c2", "Secondary color", color(110, 200, 255, 200))
tab_s:colorpicker("c3", "Highlight color", color(255, 235, 65, 255))

tab_s:section("ACTIONS")
tab_s:button("reset", "Reset settings", function()
    tab_v:set("cb_a", true)
    tab_v:set("cb_b", false)
    tab_v:set("sl_int", 50)
    tab_v:set("sl_float", 1.5)
    tab_v:set("combo1", 1)
    client.notify("Settings reset", "VibeUI")
end)

menu:register()
client.notify("VibeUI " .. VibeUI.__version .. " loaded", "VibeCord")
