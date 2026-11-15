--[[
    0x — точность ragebot и оптимизация хитбоксов
    v1.0.0 · Neverlose CS2 Lua API (wl.*) · LuaJIT 2.1
    Документация API: https://github.com/PbLJk/neverlose-lua-api

    Модули
      • Прыжок / воздух ........ свой hitchance, мин. урон и safepoint в полёте
      • Летальный бодиаим ...... убирает голову, когда цель наверняка умирает от выстрела в корпус
      • Hitchance по состоянию . стоя / движение / присед + поправки по состоянию цели
      • Быстрые бинды .......... ручные оверрайды по клавишам
      • Индикатор .............. активные оверрайды на экране

    Как 0x меняет ragebot
      В Lua API этой сборки нет отдельного ragebot-модуля, поэтому параметры
      меняются через config.get / config.set (пути находятся автоматически по
      config.keys) или через ui.find -> wl.menu_control. Исходные значения
      запоминаются и возвращаются при выключении, паузе, смерти, смене оружия,
      смене карты и выгрузке скрипта. Запись идёт только при изменении значения.
]]

-- @author 0x

----------------------------------------------------------------------------
-- 0. Локальные ссылки и константы
----------------------------------------------------------------------------
local type, pairs, next, tostring, tonumber, pcall, print, setmetatable =
      type, pairs, next, tostring, tonumber, pcall, print, setmetatable
local unpack = unpack or table.unpack
local floor, abs, sqrt, min = math.floor, math.abs, math.sqrt, math.min
local s_lower, s_find, s_format, s_match, s_gmatch, s_sub =
      string.lower, string.find, string.format, string.match, string.gmatch, string.sub
local t_concat, t_sort = table.concat, table.sort
local band = bit.band

local VERSION     = "1.0.0"
local DB_SETTINGS = "0x_settings"
local DB_JOURNAL  = "0x_journal"

local HG_CHEST, HG_STOMACH = 2, 3                   -- hitgroup движка CS2
local FL_DUCKING = 2                                -- бит FL_DUCKING в m_fFlags
local BTN_JUMP = buttons and buttons.jump or 2      -- buttons.* из справочника
local BTN_DUCK = buttons and buttons.duck or 4

local ST_STAND, ST_MOVE, ST_DUCK, ST_AIR = 1, 2, 3, 4
local STATE_TAG = { "STAND", "MOVE", "DUCK", "AIR" }
local BAIM_TAG  = { "LETHAL", "2X", "KEY", "HP" }

local EVAL_TICKS   = 2      -- период пересчёта цели и летальности
local VERIFY_TICKS = 16     -- период сверки записанных значений с конфигом
local WEAPON_TICKS = 64     -- период перепроверки класса оружия
local MAX_PICK     = 16     -- сколько кандидатов доступно для ручного выбора
local MAX_CANDS    = 64     -- предел кандидатов на один параметр

local NONE = setmetatable({}, { __tostring = function() return "none" end })  -- «оригинал не сохранён»

-- Группы оружия: item definition index CS2 -> номер группы в мультивыборе
local WPN_ITEMS = { "SSG 08", "AWP", "Автоснайперки", "Deagle / R8", "Пистолеты", "Остальное" }
local WPN_BY_DEF = {
    [40] = 1,                                   -- ssg08
    [9]  = 2,                                   -- awp
    [11] = 3, [38] = 3,                         -- g3sg1, scar20
    [1]  = 4, [64] = 4,                         -- deagle, revolver
    [2] = 5, [3] = 5, [4] = 5, [30] = 5,        -- elite, fiveseven, glock, tec9
    [32] = 5, [36] = 5, [61] = 5, [63] = 5,     -- p2000, p250, usp-s, cz75a
}
local WPN_BY_NAME = {
    { "ssg08", 1 }, { "awp", 2 }, { "g3sg1", 3 }, { "scar20", 3 }, { "deagle", 4 }, { "revolver", 4 },
    { "elite", 5 }, { "fiveseven", 5 }, { "glock", 5 }, { "tec9", 5 }, { "hkp2000", 5 },
    { "p250", 5 }, { "usp", 5 }, { "cz75", 5 },
}
local WPN_EXCLUDE_DEF = { [31] = true }        -- taser
local NON_GUN = {
    "knife", "bayonet", "grenade", "flashbang", "smoke", "molotov", "decoy", "c4", "taser",
    "healthshot", "fists", "melee", "axe", "hammer", "spanner", "tablet", "shield", "breach", "bump",
}

----------------------------------------------------------------------------
-- 1. Утилиты
----------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round(v) return floor(v + 0.5) end

local function trim(s) return (s_match(s, "^%s*(.-)%s*$")) end

local function trunc(s, n)
    if #s > n then return s_sub(s, 1, n - 2) .. ".." end
    return s
end

local function utf8_trunc(s, n)
    local out, count = {}, 0
    for ch in s_gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then out[#out + 1] = ".."; break end
        out[#out + 1] = ch
    end
    return t_concat(out)
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = x end
    return o
end

local function same_scalar(a, b)
    if a == b then return true end
    if type(a) == "number" and type(b) == "number" then return abs(a - b) < 1e-4 end
    return false
end

-- Сравнение значений конфига: скаляры и плоские таблицы (списки / словари).
local function same(a, b)
    if same_scalar(a, b) then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not same_scalar(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function fmt_value(v)
    local tv = type(v)
    if tv == "number" then
        if v == floor(v) then return s_format("%d", v) end
        return s_format("%.2f", v)
    elseif tv == "table" then
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 6 then parts[#parts + 1] = "..."; break end
            parts[#parts + 1] = type(k) == "number" and tostring(x) or (tostring(k) .. "=" .. tostring(x))
        end
        return "{" .. t_concat(parts, ",") .. "}"
    elseif v == nil then
        return "nil"
    end
    return tostring(v)
end

local function say(msg) print("[0x] " .. msg) end

local function notify(msg)
    pcall(client.notify, msg, "0x")
    say(msg)
end

local err_last, err_time = nil, -100
local function report(where, err)
    local msg = tostring(err)
    local now = globals.realtime()
    if msg ~= err_last or now - err_time > 5 then
        err_last, err_time = msg, now
        say("ошибка в " .. where .. ": " .. msg)
    end
end

----------------------------------------------------------------------------
-- 2. Состояние скрипта и опережающие объявления
----------------------------------------------------------------------------
local S = {}                                    -- снимок настроек меню (обычная таблица для горячего пути)
local S_dirty = true
local bind_dirty, bind_changed_at, bind_version = false, 0, 0

local rescan, dump_binding, release_all, preset_save, preset_load   -- определяются ниже

local function mark_dirty() S_dirty = true end
local function mark_bind()
    S_dirty, bind_dirty, bind_changed_at = true, true, globals.realtime()
end

local E, G, C = {}, {}, {}                      -- элементы меню, группы, цвета
local REG = {}                                  -- элементы для пресетов: { key, el, kind }
local STATE_UI = {}                             -- элементы состояний «Стоя / Движение / Присед»

-- Привязка: режимы и параметры ragebot, которые меняет 0x
local BIND_MODES = { "Авто: все совпадения", "Один кандидат", "Свой путь", "Не трогать" }
local BM_AUTO, BM_PICK, BM_CUSTOM, BM_OFF = 1, 2, 3, 4

-- Шаблоны Lua; исключения отсекают бинды, визуал, legit/trigger и прочие посторонние пути.
local GENERIC_EXCLUDE = {
    "colou?r", "visual", "%f[%w]esp%f[%W]", "chams", "glow", "indicator", "draw", "show",
    "%f[%w]logs?%f[%W]", "legit", "trigger", "%f[%w]keys?%f[%W]", "hotkey", "bind", "sound",
    "notif", "%f[%w]hud%f[%W]", "font", "preview", "widget",
}

local SLOTS = {
    { id = "hc", tag = "HC", title = "Hitchance", kind = "number", lo = 0, hi = 100,
      patterns = { "hit[%s_%.%-]?chance" }, exclude = {} },
    { id = "dmg", tag = "DMG", title = "Мин. урон", kind = "number", lo = 0, hi = 150,
      patterns = { "min[%s_%.%-]?dmg", "min[%s_%.%-]?damage", "minimum[%s_%.%-]?damage" }, exclude = {} },
    { id = "sp", tag = "SP", title = "Safepoint", kind = "toggle",
      patterns = { "safe[%s_%.%-]?points?" }, exclude = { "disable", "ignore" } },
    { id = "hb", tag = "HB", title = "Хитбоксы", kind = "hitbox",
      patterns = { "hit[%s_%.%-]?box" }, exclude = { "scale", "multi", "point", "size", "radius", "prior", "prefer" } },
    { id = "baim", tag = "BAIM", title = "Форс-бодиаим", kind = "toggle",
      patterns = { "force[%s_%.%-]?body", "body[%s_%.%-]?aim", "baim", "prefer[%s_%.%-]?body" },
      exclude = { "disable", "ignore", "head" } },
}
local SLOT = {}
for i = 1, #SLOTS do
    local s = SLOTS[i]
    s.cands, s.targets, s.notes, s.status, s.numval = {}, {}, {}, "—", 1
    SLOT[s.id] = s
end

----------------------------------------------------------------------------
-- 3. Меню
----------------------------------------------------------------------------
local function combo_index(c)
    local v, n = c.el:get(), #c.items
    if type(v) == "string" then
        for i = 1, n do
            if c.items[i] == v then return i end
        end
    elseif type(v) == "number" then
        local i = floor(v) - c.base + 1
        if i >= 1 and i <= n then return i end
    end
    return 1
end

-- multi_combo:get() -> {[item]=bool}; дополнительно понимает список флагов и список имён.
local function multi_selected(el, items)
    local raw, out = el:get(), {}
    if type(raw) ~= "table" then return out end
    for i = 1, #items do
        local v = raw[items[i]]
        if v == nil then v = raw[i] end
        if v == true then out[i] = true end
    end
    for _, v in pairs(raw) do
        if type(v) == "string" then
            for i = 1, #items do
                if items[i] == v then out[i] = true end
            end
        end
    end
    return out
end

local function on(el) return el:get() == true end

local function num(el, def)
    local v = tonumber(el:get())
    if v == nil then return def end
    return v
end

do -- построение меню: вспомогательные конструкторы живут только внутри этого блока
    local function reg(key, el, kind, tip, cb)
        if tip then el:tooltip(tip) end
        el:callback(cb or mark_dirty)
        REG[#REG + 1] = { key = key, el = el, kind = kind }
        return el
    end

    local function tip_of(el, text) el:tooltip(text); return el end

    local function checkbox(g, key, name, def, tip, cb)
        return reg(key, g:checkbox(name, def), "bool", tip, cb)
    end
    local function slider(g, key, name, lo, hi, def, fmt, tip, cb)
        return reg(key, g:slider_int(name, lo, hi, def, fmt), "int", tip, cb)
    end
    local function keybind(g, key, name, tip)
        return reg(key, g:keybind(name), "key", tip)
    end
    local function picker(g, key, name, def, tip)
        return reg(key, g:color(name, def, true), "color", tip)
    end
    local function multi(g, key, name, items, defs, tip)
        return reg(key, g:multi_combo(name, items, defs), "multi", tip)
    end
    local function textbox(g, key, name, def, tip, cb)
        return reg(key, g:text(name, def), "text", tip, cb)
    end

    -- Комбобокс: справочник не фиксирует, отдаёт ли :get() строку или индекс (и с какой базы),
    -- поэтому база определяется сразу после создания, пока выбран первый пункт.
    local function combo(g, key, name, items, tip, cb)
        local el = g:combo(name, items)
        local probe = el:get()
        reg(key, el, "combo", tip, cb)
        return { el = el, items = items, base = (probe == 1) and 1 or 0 }
    end

    G.tab_main = ui.tab("0x")
    G.tab_bind = ui.tab("0x: привязка")

    G.main = G.tab_main:group("Главное")
    G.air  = G.tab_main:group("Прыжок / воздух")
    G.baim = G.tab_main:group("Летальный бодиаим")
    G.hc   = G.tab_main:group("Hitchance по состоянию")
    G.tgt  = G.tab_main:group("Поправки по цели")
    G.keys = G.tab_main:group("Быстрые бинды")
    G.ind  = G.tab_main:group("Индикатор")
    G.bind = G.tab_bind:group("Привязка к ragebot")
    G.tool = G.tab_bind:group("Инструменты")

    -- 3.1 Главное ---------------------------------------------------------------
    E.master = checkbox(G.main, "master", "Включить 0x", true,
        "Главный выключатель 0x. Когда он выключен, скрипт ничего не меняет в ragebot и сразу возвращает все исходные значения, которые успел изменить.")

    E.weapons = multi(G.main, "weapons", "Оружие", WPN_ITEMS, { true, true, true, true, true, true },
        "Для какого оружия работают оверрайды 0x. Если в руках оружие из невыбранной группы, нож, граната или Zeus, 0x возвращает исходные настройки ragebot и не вмешивается.")

    local TARGET_ITEMS = { "Ближайший к прицелу", "Ближайший по дистанции", "Наименьшее HP" }
    E.target = combo(G.main, "target_mode", "Выбор цели", TARGET_ITEMS,
        "Как 0x определяет цель ragebot, по которой считаются летальность и поправки. «Ближайший к прицелу» подходит большинству конфигов. «По дистанции» — если ragebot выбирает ближайших. «Наименьшее HP» — если ragebot в первую очередь добивает раненых. Цели, в корпус которых нельзя попасть, пропускаются в пользу простреливаемых.")

    E.fov = slider(G.main, "target_fov", "Макс. FOV цели", 1, 180, 180, "%d°",
        "Противники дальше этого угла от прицела не рассматриваются как цель. 180° — учитывать всех. Уменьшай, если ragebot у тебя работает с ограниченным FOV.")

    E.panic = keybind(G.main, "panic", "Пауза 0x",
        "Пока бинд активен, 0x на паузе: все исходные значения ragebot возвращаются, оверрайды не применяются. Удобно, чтобы быстро сравнить стрельбу с 0x и без него.")

    -- 3.2 Прыжок / воздух -------------------------------------------------------
    E.air = checkbox(G.air, "air_on", "Оптимизация прыжка", true,
        "Свои настройки точности, пока ты в воздухе. В прыжке разброс сильно растёт: повышенный hitchance заставляет ragebot ждать момента, когда выстрел действительно попадёт (обычно вершина прыжка), а не стрелять в разброс.")

    E.air_hc = slider(G.air, "air_hc", "Hitchance в воздухе", 0, 100, 60, "%d%%",
        "Hitchance на время прыжка. Для SSG 08 обычно 50–65%. Для автоматов и пистолетов высокое значение означает, что в прыжке они почти не будут стрелять — это и есть защита от промахов в разброс.")

    E.air_dmg_on = checkbox(G.air, "air_dmg_on", "Свой мин. урон в воздухе", false,
        "Включи, чтобы в воздухе использовать свой минимальный урон вместо значения из конфига ragebot.")

    E.air_dmg = slider(G.air, "air_dmg", "Мин. урон в воздухе", 0, 130, 50, "%d",
        "Минимальный урон в прыжке. Значение передаётся в ragebot как есть: если чит понимает 100+ как «HP + N», это работает так же, как в его меню.")

    E.air_sp = checkbox(G.air, "air_sp", "Safepoint в воздухе", true,
        "Форсировать safepoint в прыжке: ragebot стреляет только в точки, которые попадут при любом варианте резольва. Меньше промахов «в резольвер» ценой немного более редких выстрелов.")

    E.air_pred = checkbox(G.air, "air_pred", "Упреждение по кнопке прыжка", true,
        "Считать, что ты уже в воздухе, в тот же тик, когда нажата кнопка прыжка. Настройки успевают примениться до отрыва от земли, поэтому и первый выстрел в прыжке идёт с правильным hitchance.")

    E.air_vz = slider(G.air, "air_vz", "Порог вертикальной скорости", 0, 300, 150, "%d u/s",
        "Дополнительный признак прыжка: скорость вверх больше порога. Ловит начало прыжка на тик раньше. 0 — выключено (используется только флаг «на земле»). Не ставь ниже ~120, иначе бег вверх по крутому склону будет считаться прыжком.")

    E.air_land = slider(G.air, "air_land", "Удержание после приземления", 0, 16, 3, "%d тик.",
        "Сколько тиков после приземления держать настройки воздуха. Сразу после приземления точность ещё не восстановилась, и выстрел с обычным hitchance часто уходит в разброс. 2–4 тика — хорошая отправная точка.")

    -- 3.3 Летальный бодиаим -----------------------------------------------------
    E.baim = checkbox(G.baim, "baim_on", "Летальный бодиаим", true,
        "Когда цель гарантированно убивается выстрелом в корпус, 0x убирает голову из хитбоксов. Корпус — большая цель, поэтому промахов из-за разброса и резольвера заметно меньше, а убийство при этом не теряется. Урон считается трассировкой с учётом брони, дистанции и стен.")

    local BAIM_ITEMS = { "Без головы и шеи", "Только корпус", "Только флаг форс-бодиаима" }
    E.baim_mode = combo(G.baim, "baim_mode", "Режим хитбоксов", BAIM_ITEMS,
        "Что менять, когда цель летальна. «Без головы и шеи» — убрать только голову и шею. «Только корпус» — оставить грудь, живот и таз. «Только флаг» — хитбоксы не трогать, а лишь включить форс-бодиаим ragebot (если такой путь найден на вкладке привязки). Если в хитбоксах не остаётся ни одной части тела, 0x их не меняет.")

    E.baim_two = checkbox(G.baim, "baim_two", "Летал в 2 выстрела", false,
        "Считать цель летальной, если её добивают два выстрела в корпус. Имеет смысл для автоснайперок и быстрого оружия; для SSG 08 и AWP лучше оставить выключенным.")

    E.baim_margin = slider(G.baim, "baim_margin", "Запас урона", 0, 40, 10, "%d%%",
        "Расчётный урон в корпус уменьшается на этот процент перед сравнением с HP цели. Компенсирует неточность расчёта и случайный разброс урона. 10% — надёжно, 0% — агрессивно.")

    E.baim_hp = slider(G.baim, "baim_hp", "Бодиаим при HP не выше", 0, 100, 0, "%d hp",
        "Дополнительное правило: если у цели HP не выше этого значения и её корпус простреливается, бодиаим включается без проверки урона. 0 — правило выключено.")

    E.baim_sp = checkbox(G.baim, "baim_sp", "Safepoint при бодиаиме", true,
        "Форсировать safepoint, пока действует летальный бодиаим, чтобы выстрел в корпус гарантированно засчитался.")

    -- 3.4 Hitchance по состоянию -----------------------------------------------
    E.hcc = checkbox(G.hc, "hcc_on", "Контроллер hitchance", true,
        "Hitchance в зависимости от твоего состояния: стоишь, двигаешься или сидишь. Для каждого состояния можно задать свой hitchance, минимальный урон и safepoint. Состояние «в воздухе» настраивается в группе «Прыжок / воздух».")

    E.move_thr = slider(G.hc, "move_thr", "Порог движения", 1, 150, 10, "%d u/s",
        "Горизонтальная скорость, начиная с которой ты считаешься движущимся. Ниже порога — состояние «Стоя».")

    local STATE_DEFS = {
        { key = "stand", title = "Стоя", on = false, hc = 60,
          hint = "Стоя разброс минимальный — hitchance можно держать ниже, чтобы ragebot стрелял быстрее." },
        { key = "move", title = "Движение", on = true, hc = 70,
          hint = "В движении разброс большой: повышенный hitchance не даёт стрелять в разброс, пока автостоп не погасил скорость." },
        { key = "duck", title = "Присед", on = false, hc = 55,
          hint = "В приседе точность выше, чем стоя, поэтому hitchance обычно можно снизить." },
    }

    for i = 1, 3 do
        local d = STATE_DEFS[i]
        local q = "«" .. d.title .. "»"
        STATE_UI[i] = {
            div = tip_of(G.hc:divider(d.title), d.hint),
            on = checkbox(G.hc, d.key .. "_on", d.title .. ": свои значения", d.on,
                "Включить свои hitchance, минимальный урон и safepoint для состояния " .. q .. ". Если выключено, ragebot использует значения из своего конфига. " .. d.hint),
            hc = slider(G.hc, d.key .. "_hc", d.title .. ": hitchance", 0, 100, d.hc, "%d%%",
                "Hitchance в состоянии " .. q .. ". Чем выше значение, тем дольше ragebot ждёт точного выстрела."),
            dmg_on = checkbox(G.hc, d.key .. "_dmg_on", d.title .. ": свой мин. урон", false,
                "Использовать свой минимальный урон в состоянии " .. q .. " вместо значения из конфига ragebot."),
            dmg = slider(G.hc, d.key .. "_dmg", d.title .. ": мин. урон", 0, 130, 30, "%d",
                "Минимальный урон в состоянии " .. q .. ". Передаётся в ragebot как есть (100+ работает так же, как в меню чита)."),
            sp = checkbox(G.hc, d.key .. "_sp", d.title .. ": safepoint", false,
                "Форсировать safepoint в состоянии " .. q .. ": ragebot стреляет только в точки, которые попадут при любом варианте резольва."),
        }
    end

    -- 3.5 Поправки по цели ------------------------------------------------------
    E.tgt = checkbox(G.tgt, "tgt_on", "Поправки по цели", true,
        "Поправки hitchance по состоянию цели. Складываются с hitchance текущего состояния, а если состояние не переопределено — со значением из конфига ragebot.")

    E.tgt_air = slider(G.tgt, "tgt_air", "Цель в воздухе", -30, 30, 10, "%+d%%",
        "Поправка hitchance, если цель в воздухе. Прыгающая цель двигается непредсказуемо, поэтому hitchance обычно повышают (+5…+15).")

    E.tgt_fast_thr = slider(G.tgt, "tgt_fast_thr", "Порог скорости цели", 50, 400, 200, "%d u/s",
        "Горизонтальная скорость, выше которой цель считается быстро движущейся.")

    E.tgt_fast = slider(G.tgt, "tgt_fast", "Цель быстро движется", -30, 30, 5, "%+d%%",
        "Поправка hitchance для быстро движущейся цели: её модель смещается сильнее, и запас по точности уменьшает промахи.")

    E.tgt_low_thr = slider(G.tgt, "tgt_low_thr", "Порог «мало HP»", 1, 100, 30, "%d hp",
        "HP, при котором цель считается добиваемой.")

    E.tgt_low = slider(G.tgt, "tgt_low", "Цель с малым HP", -30, 30, -5, "%+d%%",
        "Поправка hitchance для цели с малым HP. Отрицательное значение помогает быстрее добить раненого противника — для убийства хватит любого попадания.")

    E.tgt_low_dmg = checkbox(G.tgt, "tgt_low_dmg", "Мин. урон не выше HP цели", true,
        "Ограничить минимальный урон текущим HP цели, когда у неё мало HP: ragebot не ждёт урона больше, чем нужно для убийства.")

    -- 3.6 Быстрые бинды ---------------------------------------------------------
    E.k_hc = keybind(G.keys, "k_hc", "Оверрайд hitchance",
        "Пока бинд активен, hitchance принудительно равен значению ниже — поверх всех остальных правил 0x.")
    E.k_hc_val = slider(G.keys, "k_hc_val", "Hitchance по бинду", 0, 100, 40, "%d%%",
        "Hitchance, который выставляется, пока активен бинд «Оверрайд hitchance».")
    E.k_dmg = keybind(G.keys, "k_dmg", "Оверрайд мин. урона",
        "Пока бинд активен, минимальный урон равен значению ниже. Удобно для стрельбы сквозь стены.")
    E.k_dmg_val = slider(G.keys, "k_dmg_val", "Мин. урон по бинду", 0, 130, 10, "%d",
        "Минимальный урон, который выставляется, пока активен бинд «Оверрайд мин. урона».")
    E.k_baim = keybind(G.keys, "k_baim", "Форс бодиаим",
        "Пока бинд активен, бодиаим включён для любой цели без проверки летальности (по режиму хитбоксов из группы «Летальный бодиаим»).")
    E.k_sp = keybind(G.keys, "k_sp", "Форс safepoint",
        "Пока бинд активен, safepoint форсирован всегда.")

    -- 3.7 Индикатор -------------------------------------------------------------
    E.ind = checkbox(G.ind, "ind_on", "Индикатор на экране", true,
        "Показывать на экране, какие оверрайды 0x сейчас действуют. Знак «?» рядом с пунктом означает, что для параметра не найден путь в конфиге.")
    E.ind_col = picker(G.ind, "ind_col", "Цвет акцента", color(235, 235, 235, 255),
        "Цвет активных пунктов индикатора.")
    E.ind_x = slider(G.ind, "ind_x", "Позиция X", 0, 100, 50, "%d%%",
        "Горизонтальная позиция индикатора в процентах ширины экрана. У краёв текст выравнивается по краю, в середине — по центру.")
    E.ind_y = slider(G.ind, "ind_y", "Позиция Y", 0, 100, 55, "%d%%",
        "Вертикальная позиция индикатора в процентах высоты экрана.")
    E.ind_idle = checkbox(G.ind, "ind_idle", "Показывать без оверрайдов", false,
        "Показывать индикатор, даже когда ни один оверрайд не активен (только текущее состояние).")
    E.ind_tgt = checkbox(G.ind, "ind_tgt", "Показывать цель", true,
        "Строка с текущей целью: имя, HP (+a — есть броня) и расчётный урон в корпус.")

    -- 3.8 Привязка к ragebot ----------------------------------------------------
    tip_of(G.bind:label("0x пишет в ragebot через конфиг чита"),
        "У Lua API этой сборки нет отдельного ragebot-модуля, поэтому 0x меняет hitchance, минимальный урон, safepoint и хитбоксы через config.set или через элементы меню (ui.find). Пути находятся автоматически; здесь можно проверить и поправить привязку.")

    E.panel = checkbox(G.bind, "panel", "Панель диагностики", true,
        "Пока открыто меню, на экране видна панель: какие пути конфига найдены для каждого параметра, их текущие значения и нумерованный список кандидатов для режима «Один кандидат».")

    for i = 1, #SLOTS do
        local s = SLOTS[i]
        local q = "«" .. s.title .. "»"
        s.ui = {}
        s.ui.mode = combo(G.bind, "b_" .. s.id .. "_mode", s.title .. ": привязка", BIND_MODES,
            "Откуда брать путь для " .. q .. ". «Авто: все совпадения» — все подходящие пути из конфига (например, значение всех групп оружия сразу). «Один кандидат» — только выбранный номер из панели диагностики. «Свой путь» — вписать путь вручную. «Не трогать» — 0x не меняет этот параметр.",
            mark_bind)
        s.ui.pick = slider(G.bind, "b_" .. s.id .. "_pick", s.title .. ": кандидат", 1, MAX_PICK, 1, "#%d",
            "Номер кандидата для " .. q .. " из панели диагностики (список отсортирован по релевантности). Используется в режиме «Один кандидат».",
            mark_bind)
        s.ui.path = textbox(G.bind, "b_" .. s.id .. "_path", s.title .. ": свой путь", "",
            "Путь в конфиге для " .. q .. " — так, как его выводит «Вывести привязку в консоль», или элемент меню в формате menu:Страница/Группа/Элемент. Несколько путей разделяй точкой с запятой «;».",
            mark_bind)
        if s.kind == "toggle" then
            s.ui.num = slider(G.bind, "b_" .. s.id .. "_num", s.title .. ": число «вкл.»", 0, 10, 1, "%d",
                "Какое число записывать, если путь " .. q .. " хранится числом (например, индекс режима в выпадающем списке), а не флажком. Для флажков всегда пишется «включено». В авто-режиме числовые пути не используются — только при ручной привязке.")
        end
    end

    -- 3.9 Инструменты -----------------------------------------------------------
    tip_of(G.tool:button("Пересканировать конфиг", function() rescan(true) end),
        "Заново прочитать список путей конфига через config.keys и обновить привязку. Нужно после смены или загрузки другого конфига чита.")
    tip_of(G.tool:button("Вывести привязку в консоль", function() dump_binding() end),
        "Напечатать в консоль Lua всех кандидатов и привязанные пути с текущими значениями — удобно, чтобы выбрать нужный путь вручную.")
    tip_of(G.tool:button("Вернуть исходные значения", function()
        release_all()
        notify("исходные значения ragebot возвращены")
    end), "Немедленно вернуть все значения ragebot, которые 0x успел изменить. Если условия оверрайда всё ещё выполняются, он применится снова — для полной остановки используй выключатель или бинд паузы.")
    tip_of(G.tool:button("Сохранить настройки", function() preset_save(false) end),
        "Сохранить все настройки 0x (кроме биндов клавиш) в файл scripts\\data\\db\\0x_settings.json.")
    tip_of(G.tool:button("Загрузить настройки", function() preset_load() end),
        "Загрузить настройки 0x, сохранённые кнопкой «Сохранить настройки».")
    E.autoload = checkbox(G.tool, "autoload", "Автозагрузка настроек", false,
        "Загружать сохранённые настройки при запуске скрипта и автоматически сохранять их при выгрузке. Выключи, если настройки 0x у тебя хранятся в конфигах чита.")
    tip_of(G.tool:label("0x v" .. VERSION),
        "Наведи курсор на любой элемент 0x, чтобы увидеть подробную подсказку.")
end -- построение меню

----------------------------------------------------------------------------
-- 4. Видимость элементов (чтобы меню не было перегружено)
----------------------------------------------------------------------------
local VIS = {}
local function show_if(el, fn) VIS[#VIS + 1] = { el = el, fn = fn, last = nil } end

local function refresh_visibility()
    for i = 1, #VIS do
        local r = VIS[i]
        local v = r.fn() and true or false
        if v ~= r.last then
            r.last = v
            r.el:visible(v)
        end
    end
end

do
    local function master() return on(E.master) end
    local function air() return master() and on(E.air) end
    local function baim() return master() and on(E.baim) end
    local function hcc() return master() and on(E.hcc) end
    local function tgt() return master() and on(E.tgt) end
    local function ind() return master() and on(E.ind) end
    local function each(list, fn) for i = 1, #list do show_if(list[i], fn) end end

    each({ E.weapons, E.target.el, E.fov, E.panic, E.air, E.baim, E.hcc, E.tgt, E.ind,
           E.k_hc, E.k_hc_val, E.k_dmg, E.k_dmg_val, E.k_baim, E.k_sp }, master)
    each({ E.air_hc, E.air_dmg_on, E.air_sp, E.air_pred, E.air_vz, E.air_land }, air)
    show_if(E.air_dmg, function() return air() and on(E.air_dmg_on) end)
    each({ E.baim_mode.el, E.baim_two, E.baim_margin, E.baim_hp, E.baim_sp }, baim)
    show_if(E.move_thr, hcc)
    for i = 1, 3 do
        local u = STATE_UI[i]
        local function st() return hcc() and on(u.on) end
        each({ u.div, u.on }, hcc)
        each({ u.hc, u.dmg_on, u.sp }, st)
        show_if(u.dmg, function() return st() and on(u.dmg_on) end)
    end
    each({ E.tgt_air, E.tgt_fast_thr, E.tgt_fast, E.tgt_low_thr, E.tgt_low, E.tgt_low_dmg }, tgt)
    each({ E.ind_col, E.ind_x, E.ind_y, E.ind_idle, E.ind_tgt }, ind)
    for i = 1, #SLOTS do
        local s = SLOTS[i]
        show_if(s.ui.pick, function() return combo_index(s.ui.mode) == BM_PICK end)
        show_if(s.ui.path, function() return combo_index(s.ui.mode) == BM_CUSTOM end)
        if s.ui.num then
            show_if(s.ui.num, function()
                local m = combo_index(s.ui.mode)
                return m == BM_PICK or m == BM_CUSTOM
            end)
        end
    end
end

----------------------------------------------------------------------------
-- 5. Снимок настроек (горячий путь читает только эту таблицу)
----------------------------------------------------------------------------
C.accent_default = color(235, 235, 235, 255)

local function read_settings()
    local s = {}
    s.master  = on(E.master)
    s.wpn     = multi_selected(E.weapons, WPN_ITEMS)
    s.tmode   = combo_index(E.target)
    s.fov     = num(E.fov, 180)

    s.air_on, s.air_hc, s.air_sp = on(E.air), num(E.air_hc, 60), on(E.air_sp)
    s.air_dmg_on, s.air_dmg = on(E.air_dmg_on), num(E.air_dmg, 50)
    s.air_pred, s.air_vz, s.air_land = on(E.air_pred), num(E.air_vz, 150), num(E.air_land, 3)
    s.st_air = { on = s.air_on, hc = s.air_hc, dmg_on = s.air_dmg_on, dmg = s.air_dmg, sp = s.air_sp }

    s.baim_on, s.baim_hb, s.baim_two = on(E.baim), combo_index(E.baim_mode), on(E.baim_two)
    s.baim_margin, s.baim_hp, s.baim_sp = num(E.baim_margin, 10), num(E.baim_hp, 0), on(E.baim_sp)

    s.hcc_on, s.move_thr = on(E.hcc), num(E.move_thr, 10)
    s.st = {}
    for i = 1, 3 do
        local u = STATE_UI[i]
        s.st[i] = { on = on(u.on), hc = num(u.hc, 60), dmg_on = on(u.dmg_on), dmg = num(u.dmg, 30), sp = on(u.sp) }
    end

    s.tgt_on, s.tgt_air = on(E.tgt), num(E.tgt_air, 0)
    s.tgt_fast_thr, s.tgt_fast = num(E.tgt_fast_thr, 200), num(E.tgt_fast, 0)
    s.tgt_low_thr, s.tgt_low, s.tgt_low_dmg = num(E.tgt_low_thr, 30), num(E.tgt_low, 0), on(E.tgt_low_dmg)

    s.k_hc_val, s.k_dmg_val = num(E.k_hc_val, 40), num(E.k_dmg_val, 10)

    s.ind_on, s.ind_idle, s.ind_tgt = on(E.ind), on(E.ind_idle), on(E.ind_tgt)
    s.ind_x, s.ind_y = num(E.ind_x, 50), num(E.ind_y, 55)
    local c = E.ind_col:get()
    s.ind_col = type(c) == "table" and c or C.accent_default
    s.panel = on(E.panel)

    for i = 1, #SLOTS do
        local sl = SLOTS[i]
        if sl.ui.num then sl.numval = floor(num(sl.ui.num, 1)) end
    end
    return s
end

----------------------------------------------------------------------------
-- 6. Цели записи (адаптеры config / wl.menu_control)
----------------------------------------------------------------------------
local cfg_ok = type(config) == "table" and type(config.keys) == "function"
           and type(config.get) == "function" and type(config.set) == "function"
local key_count = 0
local engaged = false
local journal_dirty, journal_last = false, -100

local function cfg_read(path)
    local ok, v = pcall(config.get, path)
    if ok then return v end
    return nil
end

local function t_read(t)
    local ok, v
    if t.backend == "cfg" then
        ok, v = pcall(config.get, t.path)
    elseif t.multi then
        ok, v = pcall(t.ctrl.get_values, t.ctrl)
    else
        ok, v = pcall(t.ctrl.get_value, t.ctrl)
    end
    if ok then return v end
    return nil
end

local function t_write(t, v)
    local ok, res
    if t.backend == "cfg" then
        ok, res = pcall(config.set, t.path, v)
    elseif t.multi then
        ok, res = pcall(t.ctrl.set_values, t.ctrl, v)
    else
        ok, res = pcall(t.ctrl.set_value, t.ctrl, v)
    end
    journal_dirty = true
    if ok and res ~= false then return true end
    t.dead = true
    say(s_format("запись в %s не удалась (%s) — путь отключён до пересканирования",
        t.label, ok and "config.set вернул false" or tostring(res)))
    return false
end

-- Части тела по названию пути / пункта списка (англ. и рус.).
local P_HEAD, P_NECK, P_LIMB, P_BODY = 1, 2, 3, 4
local PART_WORDS = {
    { P_HEAD, { "head", "голов", "Голов" } },
    { P_NECK, { "neck", "шея", "Шея", "шеи", "Шеи" } },
    { P_LIMB, { "arm", "hand", "leg", "foot", "feet", "thigh", "calf", "limb", "toe",
                "рук", "Рук", "ног", "Ног", "кист", "Кист", "ступ", "Ступ", "конеч", "Конеч" } },
    { P_BODY, { "chest", "thorax", "stomach", "belly", "pelvis", "torso", "body",
                "груд", "Груд", "живот", "Живот", "таз", "Таз", "тело", "Тело", "торс", "Торс", "корпус", "Корпус" } },
}

-- Последний сегмент пути: «ragebot.handguns.hitbox.chest» -> «chest» (чтобы «handguns» не считались рукой).
local function leaf(path) return s_match(path, "([^%./:\\]+)$") or path end

local function classify_part(name)
    local l = s_lower(leaf(name))
    for i = 1, #PART_WORDS do
        local words = PART_WORDS[i][2]
        for j = 1, #words do
            local w = words[j]
            if s_find(l, w, 1, true) and not (w == "arm" and s_find(l, "armo", 1, true)) then
                return PART_WORDS[i][1]
            end
        end
    end
    return nil
end

local function new_target(slot, key)
    return {
        slot = slot, key = key, label = s_sub(key, 5), saved = NONE, written = NONE, dead = false,
        lo = slot.lo or 0, hi = slot.hi or 100, scale = 1,
    }
end

local function finish_target(slot, t, v, name)
    t.vtype = type(v)
    t.part = classify_part(name)
    if slot.kind == "hitbox" and t.vtype == "boolean" and t.part == nil then
        t.part = P_HEAD     -- ручная привязка флажка без явного названия — считается головой
    end
    if slot.id == "hc" and t.scale == 1 and t.vtype == "number" and v > 0 and v < 1 and v ~= floor(v) then
        t.scale = 0.01      -- hitchance хранится долей 0..1
    end
    return t
end

local function cfg_target(slot, path)
    if not cfg_ok then return nil, "модуль config недоступен" end
    local v = cfg_read(path)
    if v == nil then return nil, "путь не найден в конфиге" end
    local t = new_target(slot, "cfg:" .. path)
    t.backend, t.path = "cfg", path
    return finish_target(slot, t, v, path)
end

local function menu_target(slot, locator)
    local parts = {}
    for p in s_gmatch(locator, "[^/]+") do
        local x = trim(p)
        if x ~= "" then parts[#parts + 1] = x end
    end
    if #parts < 3 then return nil, "нужен формат menu:Страница/Группа/Элемент" end
    local ok, ctrl = pcall(ui.find, unpack(parts))
    if not ok or ctrl == nil then return nil, "элемент меню не найден" end
    local okt, ctype = pcall(function() return ctrl:get_type() end)
    if not okt or type(ctype) ~= "string" or ctype == "unknown" then
        return nil, "это не поддерживаемый элемент меню"
    end
    local t = new_target(slot, "menu:" .. t_concat(parts, "/"))
    t.backend, t.ctrl, t.ctype, t.multi = "menu", ctrl, ctype, ctype == "multicombo"
    if ctype == "slider" then
        local ok1, lo = pcall(function() return ctrl:get_min() end)
        local ok2, hi = pcall(function() return ctrl:get_max() end)
        if ok1 and type(lo) == "number" then t.lo = lo end
        if ok2 and type(hi) == "number" then t.hi = hi end
        if slot.id == "hc" and t.hi <= 1 then
            t.scale, t.lo, t.hi = 0.01, t.lo * 100, t.hi * 100
        end
    end
    if ctype == "combo" or ctype == "multicombo" then
        local oki, items = pcall(function() return ctrl:get_items() end)
        if oki and type(items) == "table" then t.items = items end
    end
    local v = t_read(t)
    if v == nil then return nil, "не удалось прочитать значение элемента" end
    return finish_target(slot, t, v, parts[#parts])
end

----------------------------------------------------------------------------
-- 7. Движок оверрайдов: сохранить оригинал -> записать -> вернуть
----------------------------------------------------------------------------
local function engage(t)
    if t.saved ~= NONE then return true end
    local cur = t_read(t)
    if cur == nil then t.dead = true; return false end
    t.saved, t.written = copy(cur), NONE
    engaged = true
    return true
end

-- Возвращаем оригинал, только если в конфиге всё ещё наше значение:
-- ручную правку пользователя или смену конфига не перетираем.
local function release(t)
    if t.saved == NONE then return end
    if not t.dead and t.written ~= NONE and not same(t.written, t.saved) then
        local cur = t_read(t)
        if cur ~= nil and same(cur, t.written) then t_write(t, t.saved) end
    end
    t.saved, t.written, t.hb_mode, t.hb_val = NONE, NONE, nil, nil
    journal_dirty = true
end

local function put(t, v)
    if t.written ~= NONE and same(v, t.written) then return end
    if t.written == NONE and same(v, t.saved) then t.written = copy(v); return end
    if t_write(t, v) then t.written = copy(v) end
end

release_all = function()
    if not engaged then return end
    for i = 1, #SLOTS do
        local list = SLOTS[i].targets
        for j = 1, #list do release(list[j]) end
    end
    engaged = false
end

local function update_number(slot, active, abs_v, delta, cap)
    local list = slot.targets
    for i = 1, #list do
        local t = list[i]
        if not t.dead then
            if not active then
                if t.saved ~= NONE then release(t) end
            elseif engage(t) then
                local base = tonumber(t.saved)
                if base then
                    local v = (abs_v or base / t.scale) + delta
                    if cap and v > cap then v = cap end
                    v = clamp(round(v), t.lo, t.hi)
                    put(t, v * t.scale)
                end
            end
        end
    end
end

local function update_toggle(slot, active)
    local list = slot.targets
    for i = 1, #list do
        local t = list[i]
        if not t.dead then
            if not active then
                if t.saved ~= NONE then release(t) end
            elseif engage(t) then
                local v
                if t.vtype == "boolean" then v = true
                elseif t.vtype == "number" then v = slot.numval end
                if v ~= nil then put(t, v) end
            end
        end
    end
end

-- true — включить часть, false — выключить, nil — не трогать
local function hb_flag(part, mode)
    if part == P_HEAD or part == P_NECK then return false end
    if part == P_BODY then return true end
    if part == P_LIMB and mode == 2 then return false end
    return nil
end

-- Новое значение хитбоксов из исходного. nil — формат не распознан или не осталось
-- ни одной части тела (тогда хитбоксы не меняются, чтобы ragebot не перестал стрелять).
local function hitbox_value(t, orig, mode)
    local to = type(orig)
    if to == "boolean" then return hb_flag(t.part, mode) end
    if to ~= "table" then return nil end
    local out, enabled, n = {}, 0, #orig
    if n > 0 and type(orig[1]) == "string" then             -- список выбранных имён
        for i = 1, n do
            local name = orig[i]
            if hb_flag(classify_part(tostring(name)), mode) ~= false then
                out[#out + 1] = name
                enabled = enabled + 1
            end
        end
    elseif n > 0 and t.items and #t.items == n then         -- флаги, выровненные с get_items()
        for i = 1, n do
            local v = orig[i]
            local f = hb_flag(classify_part(tostring(t.items[i])), mode)
            local new_on = v == true or v == 1
            if f ~= nil then new_on = f end
            if type(v) == "number" then out[i] = new_on and 1 or 0 else out[i] = new_on end
            if new_on then enabled = enabled + 1 end
        end
    elseif n == 0 then                                      -- словарь {имя = флаг}
        for k, v in pairs(orig) do
            if type(k) ~= "string" then return nil end
            local f = hb_flag(classify_part(k), mode)
            local new_on = v == true or v == 1
            if f ~= nil then new_on = f end
            if type(v) == "number" then out[k] = new_on and 1 or 0 else out[k] = new_on end
            if new_on then enabled = enabled + 1 end
        end
    else
        return nil
    end
    if enabled == 0 then return nil end
    return out
end

local function update_hitbox(slot, mode)
    local list = slot.targets
    for i = 1, #list do
        local t = list[i]
        if not t.dead then
            if mode == 0 then
                if t.saved ~= NONE then release(t) end
                t.hb_skip = nil
            elseif t.hb_skip ~= mode and engage(t) then
                if t.hb_mode ~= mode then
                    t.hb_val, t.hb_mode = hitbox_value(t, t.saved, mode), mode
                end
                if t.hb_val == nil then
                    release(t)
                    t.hb_skip = mode
                else
                    put(t, t.hb_val)
                end
            end
        end
    end
end

-- Если значение изменили извне (меню, смена профиля оружия), принимаем его как новый оригинал.
local function verify_all()
    for i = 1, #SLOTS do
        local list = SLOTS[i].targets
        for j = 1, #list do
            local t = list[j]
            if not t.dead and t.saved ~= NONE and t.written ~= NONE then
                local cur = t_read(t)
                if cur ~= nil and not same(cur, t.written) then
                    t.saved, t.written, t.hb_mode, t.hb_val = copy(cur), NONE, nil, nil
                    journal_dirty = true
                end
            end
        end
    end
end

-- Журнал: защита от аварийного завершения (оригиналы восстанавливаются при следующем запуске).
local function journal_flush(force)
    if not journal_dirty then return end
    local now = globals.realtime()
    if not force and now - journal_last < 2 then return end
    journal_dirty, journal_last = false, now
    local j = {}
    for i = 1, #SLOTS do
        local list = SLOTS[i].targets
        for k = 1, #list do
            local t = list[k]
            if t.saved ~= NONE and t.written ~= NONE and not same(t.saved, t.written) then
                j[t.key] = { s = t.saved, w = t.written }
            end
        end
    end
    pcall(db.save, DB_JOURNAL, j)
end

local function journal_recover()
    local ok, j = pcall(db.load, DB_JOURNAL, nil)
    if not ok or type(j) ~= "table" or next(j) == nil then return end
    local fixed = 0
    for i = 1, #SLOTS do
        local list = SLOTS[i].targets
        for k = 1, #list do
            local t = list[k]
            local e = j[t.key]
            if type(e) == "table" and e.s ~= nil and e.w ~= nil and e.s ~= json.null and e.w ~= json.null then
                local cur = t_read(t)
                if cur ~= nil and same(cur, e.w) and not same(cur, e.s) and t_write(t, e.s) then
                    fixed = fixed + 1
                end
            end
        end
    end
    pcall(db.save, DB_JOURNAL, {})
    if fixed > 0 then notify("возвращено значений ragebot после аварийного завершения: " .. fixed) end
end

----------------------------------------------------------------------------
-- 8. Привязка: поиск путей конфига и сборка целей записи
----------------------------------------------------------------------------
local function match_any(l, list)
    for i = 1, #list do
        if s_find(l, list[i]) then return true end
    end
    return false
end

local function score_path(l, slot)
    if not match_any(l, slot.patterns) then return nil end
    if match_any(l, GENERIC_EXCLUDE) or match_any(l, slot.exclude) then return nil end
    local sc = 100 - #l * 0.1
    if s_find(l, "rage", 1, true) then sc = sc + 20 end
    if s_find(l, "aim", 1, true) then sc = sc + 5 end
    return sc
end

local function plausible(slot, l, v)
    local tv = type(v)
    if slot.kind == "number" then
        return tv == "number" and v >= 0 and v <= slot.hi
    elseif slot.kind == "toggle" then
        return tv == "boolean" or (tv == "number" and v >= 0 and v <= 10 and v == floor(v))
    end
    if tv == "table" then return next(v) ~= nil end
    return tv == "boolean" and classify_part(l) ~= nil
end

local function by_score(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.path < b.path
end

local function discover()
    for i = 1, #SLOTS do SLOTS[i].cands = {} end
    key_count = 0
    if not cfg_ok then return false, "модуль config недоступен" end
    local ok, keys = pcall(config.keys)
    if not ok or type(keys) ~= "table" then return false, "config.keys() не вернул список путей" end
    key_count = #keys
    for k = 1, #keys do
        local path = keys[k]
        if type(path) == "string" then
            local l = s_lower(path)
            for i = 1, #SLOTS do
                local slot = SLOTS[i]
                local sc = score_path(l, slot)
                if sc and #slot.cands < MAX_CANDS then
                    local v = cfg_read(path)
                    if v ~= nil and plausible(slot, l, v) then
                        slot.cands[#slot.cands + 1] = { path = path, score = sc, vtype = type(v) }
                    end
                end
            end
        end
    end
    for i = 1, #SLOTS do t_sort(SLOTS[i].cands, by_score) end
    return true
end

local function resolve(slot)
    for i = 1, #slot.targets do release(slot.targets[i]) end
    local list, notes = {}, {}
    local mode = combo_index(slot.ui.mode)
    if mode == BM_OFF then
        slot.status = "не трогать"
    elseif mode == BM_AUTO then
        for i = 1, #slot.cands do
            local c = slot.cands[i]
            if slot.kind ~= "toggle" or c.vtype == "boolean" then     -- в авто только флажки для toggle
                local t = cfg_target(slot, c.path)
                if t then list[#list + 1] = t end
            end
        end
        slot.status = #list > 0 and ("авто, путей: " .. #list) or "авто: ничего не найдено"
    elseif mode == BM_PICK then
        local k = floor(num(slot.ui.pick, 1))
        local c = slot.cands[k]
        if c then
            local t, err = cfg_target(slot, c.path)
            if t then list[1] = t else notes[1] = c.path .. " — " .. tostring(err) end
        end
        slot.status = #list > 0 and ("кандидат #" .. k) or ("кандидат #" .. k .. " отсутствует")
    else
        local text = slot.ui.path:get()
        if type(text) ~= "string" then text = "" end
        for entry in s_gmatch(text, "[^;]+") do
            local e = trim(entry)
            if e ~= "" then
                local t, err
                if s_sub(e, 1, 5) == "menu:" then t, err = menu_target(slot, s_sub(e, 6))
                else t, err = cfg_target(slot, e) end
                if t then list[#list + 1] = t else notes[#notes + 1] = e .. " — " .. tostring(err) end
            end
        end
        slot.status = #list > 0 and ("свой путь, путей: " .. #list) or "свой путь не задан или не найден"
    end
    slot.targets, slot.notes = list, notes
end

-- Элементы, которые ничего не делают без привязанного пути, помечаются неактивными.
local DEPS = {
    hc   = { E.air_hc, E.tgt_air, E.tgt_fast, E.tgt_low, E.k_hc, E.k_hc_val },
    dmg  = { E.air_dmg_on, E.air_dmg, E.tgt_low_dmg, E.k_dmg, E.k_dmg_val },
    sp   = { E.air_sp, E.baim_sp, E.k_sp },
    baim = { E.baim_mode.el, E.baim_two, E.baim_margin, E.baim_hp, E.k_baim },
}
for i = 1, 3 do
    local u = STATE_UI[i]
    DEPS.hc[#DEPS.hc + 1] = u.hc
    DEPS.dmg[#DEPS.dmg + 1] = u.dmg_on
    DEPS.dmg[#DEPS.dmg + 1] = u.dmg
    DEPS.sp[#DEPS.sp + 1] = u.sp
end
local INACTIVE_REASON = "Путь в конфиге не найден — настрой вкладку «0x: привязка»"
local inactive_last = {}

local function update_inactive()
    for id, list in pairs(DEPS) do
        local off
        if id == "baim" then off = #SLOT.hb.targets == 0 and #SLOT.baim.targets == 0
        else off = #SLOT[id].targets == 0 end
        if inactive_last[id] ~= off then
            inactive_last[id] = off
            for i = 1, #list do
                local el = list[i]
                if off then pcall(el.inactive, el, true, INACTIVE_REASON) else pcall(el.inactive, el, false) end
            end
        end
    end
end

local function resolve_all()
    for i = 1, #SLOTS do resolve(SLOTS[i]) end
    engaged = false
    bind_dirty = false
    bind_version = bind_version + 1
    update_inactive()
end

rescan = function(verbose)
    release_all()
    local ok, err = discover()
    resolve_all()
    if verbose then
        if ok then
            local parts = {}
            for i = 1, #SLOTS do parts[#parts + 1] = SLOTS[i].tag .. " " .. #SLOTS[i].targets end
            notify("конфиг просканирован (" .. key_count .. " путей): " .. t_concat(parts, ", "))
        else
            notify("сканирование не удалось: " .. tostring(err))
        end
    end
    return ok
end

dump_binding = function()
    say(s_format("v%s · config.keys: %d путей%s", VERSION, key_count, cfg_ok and "" or " (модуль config недоступен)"))
    for i = 1, #SLOTS do
        local s = SLOTS[i]
        say(s_format("[%s] %s — %s", s.tag, s.title, s.status))
        for j = 1, #s.cands do
            local c = s.cands[j]
            say(s_format("    #%d  %s = %s", j, c.path, fmt_value(cfg_read(c.path))))
        end
        for j = 1, #s.targets do
            local t = s.targets[j]
            say(s_format("    -> %s = %s%s", t.label, fmt_value(t_read(t)), t.dead and " (отключён)" or ""))
        end
        for j = 1, #s.notes do say("    ! " .. s.notes[j]) end
    end
end

----------------------------------------------------------------------------
-- 9. Пресеты настроек (db)
----------------------------------------------------------------------------
preset_save = function(silent)
    local data = { __v = 1 }
    for i = 1, #REG do
        local r = REG[i]
        if r.kind ~= "key" then
            local ok, v = pcall(r.el.get, r.el)
            if ok and v ~= nil then
                if r.kind == "color" and type(v) == "table" then v = { r = v.r, g = v.g, b = v.b, a = v.a } end
                data[r.key] = v
            end
        end
    end
    local ok, res = pcall(db.save, DB_SETTINGS, data)
    local good = ok and res ~= false
    if not silent then notify(good and "настройки сохранены" or "не удалось сохранить настройки") end
    return good
end

local function preset_apply(data)
    local n = 0
    for i = 1, #REG do
        local r = REG[i]
        local v = data[r.key]
        if v ~= nil and v ~= json.null and r.kind ~= "key" then
            if r.kind == "color" then
                if type(v) == "table" then
                    v = color(tonumber(v.r) or 255, tonumber(v.g) or 255, tonumber(v.b) or 255, tonumber(v.a) or 255)
                else
                    v = nil
                end
            end
            if v ~= nil and pcall(r.el.set, r.el, v) then n = n + 1 end
        end
    end
    mark_bind()
    return n
end

preset_load = function()
    local ok, data = pcall(db.load, DB_SETTINGS, nil)
    if not ok or type(data) ~= "table" or next(data) == nil then
        notify("сохранённых настроек нет")
        return
    end
    notify("загружено настроек: " .. preset_apply(data))
end

----------------------------------------------------------------------------
-- 10. Игровая логика
----------------------------------------------------------------------------
-- 10.1 Оружие
local wpn = { addr = false, tick = -1000, group = nil }

local function classify_weapon(w)
    local ok, info = pcall(w.weapon_info, w)
    if not ok or type(info) ~= "table" then return nil end
    local def = tonumber(info.def)
    if def and WPN_EXCLUDE_DEF[def] then return nil end
    if info.gun == false then return nil end
    local grp = def and WPN_BY_DEF[def] or nil
    if grp then return grp end
    local name = s_lower(tostring(info.name or ""))
    for i = 1, #WPN_BY_NAME do
        if s_find(name, WPN_BY_NAME[i][1], 1, true) then return WPN_BY_NAME[i][2] end
    end
    if info.gun ~= true then
        for i = 1, #NON_GUN do
            if s_find(name, NON_GUN[i], 1, true) then return nil end
        end
    end
    return 6
end

local function weapon_group(lp, tick)
    local w = lp:weapon()
    local addr = w and w:address() or false
    local changed = addr ~= wpn.addr
    if not changed and tick >= wpn.tick and tick - wpn.tick < WEAPON_TICKS then return wpn.group, false end
    wpn.addr, wpn.tick = addr, tick
    wpn.group = w and classify_weapon(w) or nil
    return wpn.group, changed
end

-- 10.2 Состояние локального игрока
local air_last = -1000

local function local_state(lp, cmd, tick)
    local vel = lp:velocity()
    local air = not lp:on_ground()
    if not air and S.air_vz > 0 and vel.z > S.air_vz then air = true end
    if not air and S.air_pred and cmd:has(BTN_JUMP) then air = true end
    if air then
        air_last = tick
    else
        local dt = tick - air_last
        if dt >= 0 and dt <= S.air_land then air = true end
    end
    if air then return ST_AIR end
    if band(lp:flags(), FL_DUCKING) ~= 0 or cmd:has(BTN_DUCK) then return ST_DUCK end
    if vel:length2d() > S.move_thr then return ST_MOVE end
    return ST_STAND
end

-- 10.3 Урон в корпус (trace.damage: броня, дистанция и стены учитываются движком)
local BODY_HB = nil     -- { {index, group}, ... } — общий набор хитбоксов моделей игроков

local function body_hitboxes(p)
    if BODY_HB then return BODY_HB end
    local ok, list = pcall(p.hitboxes, p)
    if not ok or type(list) ~= "table" then return nil end
    local out = {}
    for i = 1, #list do
        local h = list[i]
        local g = tonumber(h.group)
        local gn = type(h.group_name) == "string" and s_lower(h.group_name) or ""
        if g ~= HG_CHEST and g ~= HG_STOMACH then
            if s_find(gn, "stomach", 1, true) then g = HG_STOMACH
            elseif s_find(gn, "chest", 1, true) then g = HG_CHEST
            else g = nil end
        end
        if g and h.index ~= nil then out[#out + 1] = { index = h.index, group = g } end
    end
    if #out > 0 then BODY_HB = out end
    return BODY_HB
end

local function body_damage(p, eye, need)
    local best = 0
    local hbs = body_hitboxes(p)
    if hbs then
        for i = 1, #hbs do
            local h = hbs[i]
            local pos = p:hitbox(h.index)
            if pos then
                local ok, d = pcall(trace.damage, p, pos, h.group, eye)
                d = ok and tonumber(d) or 0
                if d > best then
                    best = d
                    if best >= need then break end
                end
            end
        end
    else
        local pos = p:origin():lerp(p:eye_position(), 0.72)     -- запасная точка груди
        local ok, d = pcall(trace.damage, p, pos, HG_CHEST, eye)
        best = ok and tonumber(d) or 0
    end
    return best
end

-- 10.4 Выбор цели
local TGT = { pawn = nil, name = "", hp = 0, armor = 0, dmg = 0, air = false, speed = 0, tick = -1000 }

local function fov_to(view, eye, pos)
    local a = math.calc_angle(eye, pos)
    local dp = math.normalize_angle(a.x - view.x)
    local dy = math.normalize_angle(a.y - view.y)
    return sqrt(dp * dp + dy * dy)
end

local function by_key(a, b) return a.key < b.key end

local function evaluate_target(eye, view, tick)
    TGT.tick = tick
    local players = entity.players()
    local list, mode, fov_lim = {}, S.tmode, S.fov
    for i = 1, #players do
        local rec = players[i]
        local p = rec.pawn
        if p and p:alive() and p:is_enemy() then
            local pos = p:eye_position()
            local fov = fov_to(view, eye, pos)
            if fov <= fov_lim then
                local key = fov
                if mode == 2 then key = eye:dist(pos)
                elseif mode == 3 then key = p:health() * 1000 + fov end
                list[#list + 1] = { pawn = p, ctrl = rec.controller, key = key }
            end
        end
    end
    if #list == 0 then TGT.pawn = nil; return end
    if #list > 1 then t_sort(list, by_key) end

    local keep = 1 - S.baim_margin / 100
    if keep < 0.01 then keep = 0.01 end
    local chosen, chosen_dmg = list[1], -1
    for i = 1, min(#list, 3) do              -- предпочитаем цель, чей корпус простреливается
        local c = list[i]
        local d = body_damage(c.pawn, eye, c.pawn:health() / keep)
        if i == 1 then chosen_dmg = d end
        if d > 0 then chosen, chosen_dmg = c, d; break end
    end

    local p = chosen.pawn
    TGT.pawn, TGT.dmg = p, chosen_dmg > 0 and chosen_dmg or 0
    TGT.hp, TGT.armor = p:health(), p:armor()
    TGT.air = not p:on_ground()
    TGT.speed = p:velocity():length2d()
    local nm = "?"
    if chosen.ctrl then
        local ok, v = pcall(chosen.ctrl.name, chosen.ctrl)
        if ok and type(v) == "string" and v ~= "" then nm = utf8_trunc(v, 16) end
    end
    TGT.name = nm
end

-- 10.5 Состояние индикатора (меняется в createmove, рисуется в paint)
local D = { version = 0, mode = 0, on = false, state = ST_STAND, hc = nil, hcd = 0, dmg = nil, dmgcap = nil,
            sp = false, baim = 0, tname = nil, thp = 0, tdmg = 0, tarm = false }
local function D_set(k, v)
    if D[k] ~= v then
        D[k] = v
        D.version = D.version + 1
    end
end

local D_HIDDEN, D_ACTIVE, D_PAUSED, D_WEAPON = 0, 1, 2, 3

local function go_idle(mode)
    release_all()
    D_set("mode", mode)
    D_set("on", false)
end

-- 10.6 Главный тик
local last_verify = -1000

local function on_createmove(cmd)
    if S_dirty then S = read_settings(); S_dirty = false end
    if not S.master then return go_idle(D_HIDDEN) end

    local lp = entity.local_pawn()
    if not lp or not lp:alive() then return go_idle(D_HIDDEN) end
    if E.panic:active() then return go_idle(D_PAUSED) end

    local tick = globals.tickcount()
    local grp, changed = weapon_group(lp, tick)
    if changed then release_all() end                  -- новое оружие — свежие оригиналы
    if not grp or not S.wpn[grp] then return go_idle(D_WEAPON) end

    local state = local_state(lp, cmd, tick)
    local eye = lp:eye_position()
    local view = engine.view_angles() or cmd:view_angles()

    if tick - TGT.tick >= EVAL_TICKS or tick < TGT.tick then
        evaluate_target(eye, view, tick)
    elseif TGT.pawn and not TGT.pawn:alive() then
        TGT.pawn = nil
    end
    local tp = TGT.pawn

    -- 1) состояние игрока
    local hc_abs, hc_delta, dmg_abs, dmg_cap, sp = nil, 0, nil, nil, false
    local st
    if state == ST_AIR then
        if S.air_on then st = S.st_air end
    elseif S.hcc_on and S.st[state].on then
        st = S.st[state]
    end
    if st then
        hc_abs, sp = st.hc, st.sp
        if st.dmg_on then dmg_abs = st.dmg end
    end

    -- 2) поправки по цели
    if tp and S.tgt_on then
        if TGT.air then hc_delta = hc_delta + S.tgt_air end
        if TGT.speed > S.tgt_fast_thr then hc_delta = hc_delta + S.tgt_fast end
        if TGT.hp <= S.tgt_low_thr then
            hc_delta = hc_delta + S.tgt_low
            if S.tgt_low_dmg then dmg_cap = TGT.hp end
        end
    end

    -- 3) летальный бодиаим (только если корпус простреливается)
    local baim_reason = 0
    if E.k_baim:active() then
        baim_reason = 3
    elseif S.baim_on and tp and TGT.dmg > 0 then
        local eff = TGT.dmg * (1 - S.baim_margin / 100)
        if eff >= TGT.hp then baim_reason = 1
        elseif S.baim_two and eff * 2 >= TGT.hp then baim_reason = 2
        elseif S.baim_hp > 0 and TGT.hp <= S.baim_hp then baim_reason = 4 end
    end
    local hb_mode = 0
    if baim_reason > 0 then
        if S.baim_hb == 1 then hb_mode = 1 elseif S.baim_hb == 2 then hb_mode = 2 end
        if S.baim_sp then sp = true end
    end

    -- 4) быстрые бинды — наивысший приоритет
    if E.k_hc:active() then hc_abs, hc_delta = S.k_hc_val, 0 end
    if E.k_dmg:active() then dmg_abs = S.k_dmg_val end
    if E.k_sp:active() then sp = true end

    local hc_on = hc_abs ~= nil or hc_delta ~= 0
    local dmg_on = dmg_abs ~= nil or dmg_cap ~= nil

    -- запись (только изменившиеся значения)
    update_number(SLOT.hc, hc_on, hc_abs, hc_delta, nil)
    update_number(SLOT.dmg, dmg_on, dmg_abs, 0, dmg_cap)
    update_toggle(SLOT.sp, sp)
    update_hitbox(SLOT.hb, hb_mode)
    update_toggle(SLOT.baim, baim_reason > 0)

    if tick - last_verify >= VERIFY_TICKS or tick < last_verify then
        last_verify = tick
        verify_all()
    end

    -- индикатор
    D_set("mode", D_ACTIVE)
    D_set("on", hc_on or dmg_on or sp or hb_mode > 0 or baim_reason > 0)
    D_set("state", state)
    local dhc, dhcd, ddmg, dcap = nil, 0, nil, nil
    if hc_on then
        if hc_abs then dhc = clamp(round(hc_abs + hc_delta), 0, 100) else dhcd = hc_delta end
    end
    if dmg_on then
        if dmg_abs then ddmg = dmg_cap and min(dmg_abs, dmg_cap) or dmg_abs else dcap = dmg_cap end
    end
    D_set("hc", dhc); D_set("hcd", dhcd); D_set("dmg", ddmg); D_set("dmgcap", dcap)
    D_set("sp", sp); D_set("baim", baim_reason)
    if tp then
        D_set("tname", TGT.name); D_set("thp", TGT.hp); D_set("tdmg", floor(TGT.dmg)); D_set("tarm", TGT.armor > 0)
    else
        D_set("tname", nil)
    end
end

----------------------------------------------------------------------------
-- 11. Отрисовка (paint): индикатор и панель диагностики
----------------------------------------------------------------------------
C.dim    = color(150, 150, 150, 255)
C.text   = color(225, 225, 225, 255)
C.warn   = color(255, 176, 64, 255)
C.shadow = color(0, 0, 0, 170)
C.bg     = color(10, 10, 10, 220)
C.line   = color(255, 255, 255, 24)

local IND = { version = -1, bind = -1, tgt = nil, lines = {}, n = 0 }
local PANEL = { t = -100, bind = -1, lines = {}, n = 0, w = 0, h = 0 }
local vis_last, snap_last = -100, -100

local function measure(text)
    local w, h = render.text_size(text)
    return tonumber(w) or 0, tonumber(h) or 12
end

local function seg_add(L, text, col) L.segs[#L.segs + 1] = { text = text, col = col } end

local function rebuild_indicator()
    IND.version, IND.bind, IND.tgt = D.version, bind_version, S.ind_tgt
    local lines = {}
    local L1 = { segs = {} }
    lines[1] = L1
    seg_add(L1, "0x", "acc")
    if D.mode == D_PAUSED then seg_add(L1, "  PAUSE", "warn")
    elseif D.mode == D_WEAPON then seg_add(L1, "  -", "dim")
    else seg_add(L1, "  " .. (STATE_TAG[D.state] or "-"), "dim") end

    if D.mode == D_ACTIVE and D.on then
        local L2 = { segs = {} }
        local function tag(text, slot)
            if #L2.segs > 0 then seg_add(L2, "  ", "dim") end
            if #slot.targets > 0 then seg_add(L2, text, "acc") else seg_add(L2, text .. "?", "warn") end
        end
        if D.hc then tag("HC " .. D.hc, SLOT.hc) elseif D.hcd ~= 0 then tag(s_format("HC %+d", D.hcd), SLOT.hc) end
        if D.dmg then tag("DMG " .. D.dmg, SLOT.dmg) elseif D.dmgcap then tag("DMG<=" .. D.dmgcap, SLOT.dmg) end
        if D.sp then tag("SP", SLOT.sp) end
        if #L2.segs > 0 then lines[#lines + 1] = L2 end
        if D.baim > 0 then
            local ok = #SLOT.hb.targets > 0 or #SLOT.baim.targets > 0
            local L3 = { segs = {} }
            seg_add(L3, "BAIM " .. BAIM_TAG[D.baim] .. (ok and "" or "?"), ok and "acc" or "warn")
            lines[#lines + 1] = L3
        end
    end
    if D.mode == D_ACTIVE and S.ind_tgt and D.tname then
        local L4 = { segs = {} }
        seg_add(L4, s_format("> %s  %dhp%s  %ddmg", D.tname, D.thp, D.tarm and "+a" or "", D.tdmg), "dim")
        lines[#lines + 1] = L4
    end

    for i = 1, #lines do
        local L = lines[i]
        local w, h = 0, 0
        for j = 1, #L.segs do
            local sg = L.segs[j]
            local sw, sh = measure(sg.text)
            sg.w = sw
            w = w + sw
            if sh > h then h = sh end
        end
        L.w, L.h = w, h
    end
    IND.lines, IND.n = lines, #lines
end

local function draw_indicator()
    if D.mode == D_HIDDEN then return end
    if D.mode == D_ACTIVE and not D.on and not S.ind_idle then return end
    if D.mode == D_WEAPON and not S.ind_idle then return end
    if IND.version ~= D.version or IND.bind ~= bind_version or IND.tgt ~= S.ind_tgt then rebuild_indicator() end

    local sw, sh = render.screen_size()
    local ax = S.ind_x / 100
    local x0, y = floor(sw * ax), floor(sh * S.ind_y / 100)
    local acc = S.ind_col
    for i = 1, IND.n do
        local L = IND.lines[i]
        local x
        if ax < 0.1 then x = x0 elseif ax > 0.9 then x = x0 - L.w else x = x0 - floor(L.w / 2) end
        for j = 1, #L.segs do
            local sg = L.segs[j]
            local col = C.dim
            if sg.col == "acc" then col = acc elseif sg.col == "warn" then col = C.warn end
            render.text(x + 1, y + 1, C.shadow, sg.text)
            render.text(x, y, col, sg.text)
            x = x + sg.w
        end
        y = y + L.h + 2
    end
end

local MODE_TAG = { "auto", "pick", "custom", "off" }

local function rebuild_panel(now)
    PANEL.t, PANEL.bind = now, bind_version
    local lines = {}
    local function add(text, col) lines[#lines + 1] = { text = text, col = col } end
    add(s_format("0x v%s  binding  config keys: %d%s", VERSION, key_count, cfg_ok and "" or "  (config API missing)"), "acc")
    for i = 1, #SLOTS do
        local s = SLOTS[i]
        local m = combo_index(s.ui.mode)
        local head = s_format("%-4s  %-6s  %2d", s.tag, MODE_TAG[m], #s.targets)
        if #s.targets > 0 then
            local t = s.targets[1]
            head = head .. "   " .. trunc(t.label, 46) .. " = " .. fmt_value(t_read(t))
            if #s.targets > 1 then head = head .. s_format("   (+%d)", #s.targets - 1) end
            add(head, t.dead and "warn" or nil)
        else
            add(head .. "   -", m == BM_OFF and "dim" or "warn")
        end
        if m == BM_PICK then
            local k = floor(num(s.ui.pick, 1))
            local n = min(#s.cands, MAX_PICK)
            for j = 1, n do
                add(s_format("        %s #%-2d %s", j == k and ">" or " ", j, trunc(s.cands[j].path, 56)), j == k and "acc" or "dim")
            end
            if n == 0 then add("        no candidates found", "warn") end
        end
    end
    local w, h = 0, 0
    for i = 1, #lines do
        local L = lines[i]
        L.w, L.h = measure(L.text)
        if L.w > w then w = L.w end
        h = h + L.h + 3
    end
    PANEL.lines, PANEL.n, PANEL.w, PANEL.h = lines, #lines, w, h
end

local function draw_panel(now)
    if now - PANEL.t > 0.5 or PANEL.bind ~= bind_version then rebuild_panel(now) end
    local x, y = 28, 96
    render.rect_filled(x - 10, y - 8, PANEL.w + 20, PANEL.h + 13, C.bg, 4)
    render.rect(x - 10, y - 8, PANEL.w + 20, PANEL.h + 13, C.line, 4, 1)
    for i = 1, PANEL.n do
        local L = PANEL.lines[i]
        local col = C.text
        if L.col == "acc" then col = S.ind_col elseif L.col == "warn" then col = C.warn elseif L.col == "dim" then col = C.dim end
        render.text(x, y, col, L.text)
        y = y + L.h + 3
    end
end

local function on_paint()
    local now = globals.realtime()
    local menu = input.menu_open()
    if menu then
        if now - snap_last > 0.25 then snap_last, S_dirty = now, true end   -- страховка, если колбэк не сработал
        if now - vis_last > 0.1 then vis_last = now; refresh_visibility() end
    end
    if S_dirty then S = read_settings(); S_dirty = false end
    if bind_dirty and now - bind_changed_at > 0.4 then resolve_all() end
    journal_flush(false)
    if menu and S.panel then draw_panel(now) end
    if S.master and S.ind_on and engine.in_game() then draw_indicator() end
end

----------------------------------------------------------------------------
-- 12. События
----------------------------------------------------------------------------
local function reset_runtime()
    TGT.pawn, TGT.tick = nil, -1000
    BODY_HB = nil
    wpn.addr, wpn.tick, wpn.group = false, -1000, nil
    air_last, last_verify = -1000, -1000
    D_set("mode", D_HIDDEN)
end

events.on("createmove", function(cmd)
    local ok, err = pcall(on_createmove, cmd)
    if not ok then report("createmove", err) end
end)

events.on("paint", function()
    local ok, err = pcall(on_paint)
    if not ok then report("paint", err) end
end)

events.on("menu_toggled", function()
    S_dirty, vis_last = true, -100
end)

events.on("level_init", function()
    release_all()
    reset_runtime()
end)

events.on("level_shutdown", function()
    release_all()
    reset_runtime()
    journal_flush(true)
end)

events.on("unload", function()
    release_all()
    journal_dirty = true
    journal_flush(true)
    if on(E.autoload) then preset_save(true) end
end)

----------------------------------------------------------------------------
-- 13. Запуск
----------------------------------------------------------------------------
do
    local ok, data = pcall(db.load, DB_SETTINGS, nil)
    if ok and type(data) == "table" and data.autoload == true then preset_apply(data) end
end

S, S_dirty = read_settings(), false
local scanned, scan_err = discover()
resolve_all()
journal_recover()
refresh_visibility()

-- Повторная привязка, когда чит восстановит сохранённые значения элементов скрипта.
client.delay(1, mark_bind)

do
    local parts = {}
    for i = 1, #SLOTS do parts[#parts + 1] = SLOTS[i].tag .. " " .. #SLOTS[i].targets end
    say(s_format("v%s загружен · путей в конфиге: %d · привязка: %s", VERSION, key_count, t_concat(parts, ", ")))
    if not scanned then
        notify("не удалось прочитать конфиг (" .. tostring(scan_err) .. "). Укажи пути вручную на вкладке «0x: привязка».")
    elseif #SLOT.hc.targets == 0 and #SLOT.dmg.targets == 0 then
        notify("пути ragebot не найдены автоматически — открой меню: панель диагностики покажет кандидатов, а привязку можно задать на вкладке «0x: привязка».")
    else
        notify("загружен. Наведи курсор на элементы меню, чтобы увидеть подсказки.")
    end
end
