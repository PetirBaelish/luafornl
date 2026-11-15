-- @author 0x
--[[
    0x · v3.2
    Точность ragebot: стрельба в прыжке, летальный Body-Aim, hitchance по состоянию.
    Neverlose CS2 Lua API · LuaJIT 2.1 · режим Standard (Allow Insecure не нужен).
    Документация: https://github.com/PbLJk/neverlose-lua-api

    Интерфейс
      Нативное меню Neverlose: вкладка «0x» (игра) и «0x · Вид и сервис». Зависимые настройки
      скрыты, пока выключен их главный переключатель; у каждого элемента есть подсказка.
      Если между метками MENU_LIB встроен Menu.lua (VibeUI), настройки рисует он, а в нативной
      вкладке «0x» остаются бинды.

    Как 0x управляет ragebot
      Отдельного ragebot-модуля в API нет, поэтому значения читаются и пишутся через
      config.get / config.set. Пути ищутся автоматически по config.keys (группа «Связь с ragebot»,
      кнопка «Пересканировать config»). Если автопоиск ошибся, впишите пути в CUSTOM_PATHS ниже.
      Исходные значения запоминаются, пишутся в журнал (db) и возвращаются при выключении, паузе,
      смерти, смене оружия, смене карты и выгрузке. Запись журнала удаляется только после того,
      как значение действительно возвращено.

    v3.2 — аудит и рефакторинг v3.1 без новых функций. Имена настроек и файлы db прежние,
    сохранённые настройки v3.1 подхватываются.
]]

--@@MENU_LIB_BEGIN
local VibeUI = nil
--@@MENU_LIB_END

----------------------------------------------------------------------------
-- 0. Локальные ссылки и константы
----------------------------------------------------------------------------
local type, pairs, ipairs, tostring, tonumber, pcall, print, select, next, rawget =
      type, pairs, ipairs, tostring, tonumber, pcall, print, select, next, rawget
local floor, abs, sqrt, max, min, atan2 = math.floor, math.abs, math.sqrt, math.max, math.min, math.atan2
local s_lower, s_find, s_format, s_gsub, s_gmatch =
      string.lower, string.find, string.format, string.gsub, string.gmatch
local t_concat, t_sort = table.concat, table.sort
local band = bit.band

local VERSION     = "3.2.0"
local DB_SETTINGS = "0x_v31_settings"   -- имена хранилищ не менялись: настройки v3.1 остаются
local DB_JOURNAL  = "0x_v31_journal"
local RAD2DEG     = 180 / math.pi

-- Ручные пути config, если автопоиск ошибается. Пример: hc = { "путь.из.консоли" }
local CUSTOM_PATHS = { hc = {}, dmg = {}, safe = {}, baim = {}, hitbox = {} }
-- Если Safepoint в вашем ragebot — выпадающий список, это индекс пункта «Force».
local SAFE_COMBO_VALUE = 2

local K = {
    EVAL_TICKS = 4,        -- период пересчёта цели и летальности, тиков
    VERIFY_TICKS = 16,     -- период сверки записанных значений с config, тиков
    WEAPON_TICKS = 64,     -- период перепроверки класса оружия, тиков
    POLL_OPEN = 0.05,      -- период чтения виджетов при открытом меню, сек
    POLL_IDLE = 1.0,       -- то же при закрытом меню (значения не меняются), сек
    MENU_GRACE = 0.25,     -- сколько верить событию menu_toggled до сверки с input.menu_open, сек
    HK_INTERVAL = 1.0,     -- период фоновых задач, сек
    SAVE_DELAY = 1.5,      -- пауза после последней правки до автосохранения, сек
    JOURNAL_LAZY = 15,     -- сек тишины, после которых из файла журнала убираются устаревшие записи
    IO_RETRY = 5,          -- пауза после неудачной записи на диск, сек
    CM_TIMEOUT = 0.5,      -- createmove молчит дольше этого → значения ragebot возвращаются, сек
    PAINT_TIMEOUT = 2,     -- paint молчит дольше этого → фоновые задачи временно выполняет createmove, сек
    MAX_CANDS = 48,        -- предел путей на один параметр
    MAX_TARGETS = 3,       -- сколько ближайших к прицелу целей проверять трассировкой
    HOLD_TICKS = 12,       -- удержание решения Body-Aim (против мерцания)
    MOVE_EPS = 5,          -- порог «движения», u/s
    T_MOVE_SQR = 1600,     -- цель «бежит», если её скорость выше 40 u/s (квадрат)
    BAD_LIMIT = 3,         -- отказов записи подряд до отключения пути
    MISM_LIMIT = 3,        -- чужих перезаписей подряд до отключения пути
    ERR_LIMIT = 25,        -- ошибок подряд до приостановки
    ERR_COOLDOWN = 5,      -- длительность приостановки, сек
    ERR_STRIKES = 3,       -- приостановок до полной остановки
    ERR_FORGIVE = 60,      -- сек без ошибок, после которых приостановки забываются
    EYE_OFFSET = 46,       -- высота точки прицеливания над origin цели
    HB_TTL = 256,          -- время жизни кэша хитбоксов, тиков
    HB_MAX = 64,           -- предел записей кэша хитбоксов
    GRAVITY = 800,         -- sv_gravity по умолчанию; нужен только для отсечки лишних симуляций
    SIM_MARGIN = 16,       -- запас к этой отсечке, u/s
    MEMO_MAX = 512,        -- предел кэша ширины строк индикатора
    HG_HEAD = 1, HG_CHEST = 2, HG_STOMACH = 3,
    FL_DUCKING = 2,
    BTN_SPEED = (buttons and buttons.speed) or 65536,
    WRAP = 46,             -- ширина строки подсказок в Menu.lua, символов
    WRAP_NATIVE = 54,      -- ширина строки справки в нативном меню, символов
    WPN_KEY = { "wpn1", "wpn2", "wpn3", "wpn4", "wpn5", "wpn6" },
}

local ST = { STAND = 1, SLOW = 2, MOVE = 3, DUCK = 4, AIR = 5, APEX = 6 }
local ST_NAME = { "СТОЯ", "ШАГ", "БЕГ", "ПРИСЕД", "ВОЗДУХ", "ПИК" }

local WPN_ITEMS = { "SSG 08", "AWP", "Автоснайперки", "Deagle / R8", "Пистолеты", "Остальное" }
local WPN_BY_DEF = {
    [40] = 1, [9] = 2, [11] = 3, [38] = 3, [1] = 4, [64] = 4,
    [2] = 5, [3] = 5, [4] = 5, [30] = 5, [32] = 5, [36] = 5, [61] = 5, [63] = 5,
}
local WPN_BY_NAME = {
    { "ssg08", 1 }, { "awp", 2 }, { "g3sg1", 3 }, { "scar20", 3 }, { "deagle", 4 }, { "revolver", 4 },
    { "elite", 5 }, { "fiveseven", 5 }, { "glock", 5 }, { "tec9", 5 }, { "hkp2000", 5 },
    { "p250", 5 }, { "usp", 5 }, { "cz75", 5 },
}
local NON_GUN = {
    "knife", "bayonet", "grenade", "flashbang", "smoke", "molotov", "decoy", "c4", "taser",
    "healthshot", "fists", "melee", "axe", "hammer", "spanner", "tablet", "shield", "breach", "bump",
}
local NON_GUN_DEF = { [31] = true, [41] = true, [42] = true, [57] = true, [59] = true, [69] = true,
                      [70] = true, [72] = true, [74] = true, [75] = true, [76] = true, [78] = true, [85] = true }
for d = 43, 49 do NON_GUN_DEF[d] = true end
for d = 500, 526 do NON_GUN_DEF[d] = true end

----------------------------------------------------------------------------
-- 1. Состояние
----------------------------------------------------------------------------
local S = {}                                  -- снимок настроек (горячий путь читает только его)
local RT = {                                  -- рабочее состояние
    now = 0, tick = 0, cm_t = -1e9, paint_t = -1e9, hk_t = -1e9,
    snap_t = -1e9, poll_dt = K.POLL_IDLE, menu_evt_t = -1e9,
    cfg_dirty = false, cfg_t = 0, io_t = -1e9,
    air_ticks = 0, land_soon = false, sim_fail = 0, g_tick = K.GRAVITY * 0.015625, sync_mode = false,
    state = nil, wgroup = nil, waddr = nil, wtick = -1e9, eval_at = 0,
    t_hp = nil, t_air = false, t_move = false, t_addr = nil,
    baim_reason = nil, baim_until = 0, base_hc = nil, base_dmg = nil,
    hc = nil, dmg = nil, safe = false, baim = nil, strict = false, pub_thp = nil,
    touched = false, paused = false, menu_open = false, in_game = true,
    failed = false, suspend_until = nil, strikes = 0, strike_t = 0, errs = {},
    ind_dirty = true, last_preset = 1, preset_sync = true,
    sw = 0, sh = 0, menu_draw = nil,
}
local W, ORDER_W = {}, {}                     -- элементы меню: id -> дескриптор
local B = {}                                  -- нативные бинды: strict / baim / dmg
local VIS = {}                                -- правила видимости: { el, fn(S), shown }
local U, Journal, Bind, Logic, Settings, UIm, Draw, ACT = {}, {}, {}, {}, {}, {}, {}, {}

----------------------------------------------------------------------------
-- 2. Утилиты
----------------------------------------------------------------------------
function U.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.round(v) return floor(v + 0.5) end

function U.copy(v)
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

function U.same(a, b)
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

function U.any_match(s, list)
    for i = 1, #list do
        if s_find(s, list[i]) then return true end
    end
    return false
end

function U.utf8_len(s) return select(2, s_gsub(s, "[^\128-\193]", "")) end

function U.wrap(text, width)
    local lines, cur, curlen = {}, "", 0
    for word in s_gmatch(text, "%S+") do
        local wl = U.utf8_len(word)
        if curlen == 0 then
            cur, curlen = word, wl
        elseif curlen + 1 + wl <= width then
            cur, curlen = cur .. " " .. word, curlen + 1 + wl
        else
            lines[#lines + 1] = cur
            cur, curlen = word, wl
        end
    end
    if curlen > 0 then lines[#lines + 1] = cur end
    return lines
end

function U.fmt(v)
    local tv = type(v)
    if tv == "number" then
        if v == floor(v) then return s_format("%d", v) end
        return s_format("%.2f", v)
    elseif tv == "table" then
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 8 then parts[#parts + 1] = ".."; break end
            parts[#parts + 1] = (type(k) == "number") and tostring(x) or (tostring(k) .. "=" .. tostring(x))
        end
        return "{" .. t_concat(parts, ",") .. "}"
    end
    return tostring(v)
end

local function is_head_name(x)
    if type(x) ~= "string" then return false end
    local l = s_lower(x)
    return s_find(l, "head", 1, true) ~= nil and s_find(l, "ahead", 1, true) == nil
end

-- Убирает пункт «голова» из значения мультивыбора хитбоксов.
-- Возвращает новое значение, исходное (голова не была включена) или nil (формат не поддержан
-- либо голова — единственный включённый хитбокс).
function U.strip_head(v)
    if type(v) ~= "table" then return nil end
    local out, enabled, changed = {}, 0, false
    if #v > 0 then                                  -- список имён включённых пунктов
        for i = 1, #v do
            local x = v[i]
            if type(x) ~= "string" then return nil end
            if is_head_name(x) then
                changed = true
            else
                out[#out + 1] = x
                enabled = enabled + 1
            end
        end
    else                                            -- словарь { [пункт] = bool }
        for k, x in pairs(v) do
            if type(k) ~= "string" then return nil end
            if is_head_name(k) and x then
                out[k] = false
                changed = true
            else
                out[k] = x
                if x then enabled = enabled + 1 end
            end
        end
    end
    if not changed then return v end
    if enabled == 0 then return nil end
    return out
end

function U.say(msg) print("[0x] " .. msg) end

function U.notify(msg)
    if S.notif ~= false then pcall(client.notify, msg, "0x") end
    U.say(msg)
end

local rep = { last = nil, t = -100 }
function U.report(where, err)
    local msg = tostring(err)
    if msg ~= rep.last or RT.now - rep.t > 5 then
        rep.last, rep.t = msg, RT.now
        U.say("ошибка в " .. where .. ": " .. msg)
    end
end

-- Вызовы методов объектов API через pcall: и поиск метода, и сам вызов оказываются под защитой.
local function m_get(o) return o:get() end
local function m_set(o, v) o:set(v) end
local function m_active(o) return o:active() end
local function m_visible(o, b) o:visible(b) end
local function m_tooltip(o, t) o:tooltip(t) end
local function m_loaded(o) return o:loaded() end
local function m_weapon_info(o) return o:weapon_info() end
local function m_hitboxes(o) return o:hitboxes() end

----------------------------------------------------------------------------
-- 3. Схема меню (одна на нативное меню и Menu.lua) и профили
----------------------------------------------------------------------------
-- Условия видимости: зависимая настройка показывается, только пока включён её переключатель.
local function v_air(s) return s.air_on end
local function v_apex(s) return s.air_on and s.apex_on end
local function v_thr(s) return s.air_mode ~= 2 end
local function v_land(s) return s.air_mode == 3 end
local function v_hc(s) return s.hc_on end
local function v_baim(s) return s.baim_on end
local function v_margin(s) return s.baim_on and (s.baim_lethal or s.baim_2x) end
local function v_bhp(s) return s.baim_on and s.baim_hp_on end
local function v_ind(s) return s.ind_on end

local WPN_CHECKS = {}
for i = 1, #WPN_ITEMS do
    WPN_CHECKS[i] = { id = K.WPN_KEY[i], t = "check", name = WPN_ITEMS[i], def = (i <= 5),
                      tip = "Разрешить 0x менять настройки ragebot, пока в руках оружие этой группы." }
end

-- tab     — вкладка в Menu.lua;  page — нативная вкладка (1 «0x», 2 «0x · Вид и сервис»)
-- section — группа; group объединяет несколько секций в одну нативную группу (секция идёт под разделителем)
-- item.t  — check | slider | combo | color | button | key (нативный бинд) | status | text
local SCHEMA = {
    { tab = "Ядро", page = 1, sections = {
        { title = "Главное",
          hint = "Всё, что 0x меняет в ragebot, возвращается при паузе, смерти, смене оружия и выгрузке скрипта.",
          items = {
            { id = "enable", t = "check", name = "Включить 0x", def = true,
              tip = "Главный переключатель. При выключении все значения ragebot сразу возвращаются к вашим." },
            { id = "preset", t = "combo", name = "Профиль", def = 2,
              items = { "Свой", "Баланс", "Агрессивный", "Консервативный" },
              tip = "Готовый набор hitchance, урона и Body-Aim. Баланс — универсальный, Агрессивный — быстрее огонь, Консервативный — выше точность. После ручной правки значений профиль становится «Свой»." },
            { id = "pause_menu", t = "check", name = "Пауза при открытом меню", def = true,
              tip = "Пока открыто меню Neverlose, 0x возвращает ваши значения и ничего не меняет: ragebot можно настраивать спокойно." },
        } },
        { title = "Оружие",
          hint = "0x работает только с отмеченными группами. Для остальных настройки ragebot не трогаются.",
          items = WPN_CHECKS },
        { title = "Бинды",
          hint = "Клавиши назначаются в нативной вкладке «0x», группа «Бинды». Здесь — их значения.",
          items = {
            { t = "key", bind = "strict", name = "Strict · макс. точность",
              tip = "Пока активен: hitchance растёт на прибавку Strict и включается safepoint. Для дальних и важных выстрелов." },
            { id = "strict_bonus", t = "slider", name = "Прибавка hitchance в Strict", def = 12, lo = 0, hi = 40, fmt = "+%d%%",
              tip = "На сколько растёт hitchance, пока активен бинд Strict." },
            { t = "key", bind = "baim", name = "Принудительный Body-Aim",
              tip = "Пока активен: голова исключается из целей, стрельба идёт по корпусу." },
            { t = "key", bind = "dmg", name = "Оверрайд мин. урона",
              tip = "Пока активен: мин. урон равен значению «Мин. урон по бинду»." },
            { id = "dmg_bind_val", t = "slider", name = "Мин. урон по бинду", def = 18, lo = 1, hi = 130, fmt = "%d HP",
              tip = "Мин. урон, пока активен бинд «Оверрайд мин. урона». Удобно для добивания и простреливания стен." },
        } },
    } },
    { tab = "Воздух", page = 1, sections = {
        { title = "Стрельба в прыжке", group = "Воздух", div = false,
          hint = "В воздухе разброс больше. 0x ставит свои hitchance и урон, только пока вы летите.",
          items = {
            { id = "air_on", t = "check", name = "Оптимизатор прыжка", def = true,
              tip = "Применяет воздушные hitchance, мин. урон и safepoint, пока вы в прыжке. Ориентир для SSG 08: hitchance 65–78, урон 45–65." },
            { id = "air_hc", t = "slider", name = "Hitchance в полёте", def = 70, lo = 1, hi = 100, fmt = "%d%%", vis = v_air,
              tip = "Требуемый hitchance при наборе высоты и падении." },
            { id = "air_dmg", t = "slider", name = "Мин. урон в полёте", def = 50, lo = 1, hi = 130, fmt = "%d HP", vis = v_air,
              tip = "Мин. урон при стрельбе в прыжке." },
            { id = "air_safe", t = "check", name = "Safepoint в полёте", def = true, vis = v_air,
              tip = "Принудительно включает safepoint, пока вы в воздухе." },
        } },
        { title = "Пик прыжка", group = "Воздух", vis = v_air,
          hint = "На пике вертикальная скорость близка к нулю, разброс минимален, hitchance можно снизить.",
          items = {
            { id = "apex_on", t = "check", name = "Отдельный hitchance на пике", def = true, vis = v_air,
              tip = "В верхней точке прыжка разброс минимален: там используется свой, обычно более низкий hitchance." },
            { id = "apex_hc", t = "slider", name = "Hitchance на пике", def = 58, lo = 1, hi = 100, fmt = "%d%%", vis = v_apex,
              tip = "Требуемый hitchance на пике прыжка." },
            { id = "apex_win", t = "slider", name = "Окно пика", def = 42, lo = 10, hi = 110, fmt = "≤ %d u/s", vis = v_apex,
              tip = "Пик — пока модуль вертикальной скорости не больше этого значения. Шире окно — дольше действует hitchance пика." },
        } },
        { title = "Детекция полёта", group = "Воздух",
          hint = "Как 0x понимает, что вы в прыжке. От этого же зависит, когда перестаёт действовать hitchance по состоянию.",
          items = {
            { id = "air_mode", t = "combo", name = "Режим детекции", def = 1,
              items = { "Земля + верт. скорость", "Только флаг земли", "С предсказанием посадки" },
              tip = "Земля + верт. скорость — надёжно, не срабатывает на ступеньках. Только флаг земли — самая быстрая реакция. С предсказанием посадки — как первый, но наземные значения возвращаются за несколько тиков до касания." },
            { id = "air_thr", t = "slider", name = "Порог верт. скорости", def = 22, lo = 5, hi = 220, fmt = "%d u/s", vis = v_thr,
              tip = "Вертикальная скорость, с которой отрыв от земли считается прыжком. Больше — меньше ложных срабатываний на ступенях и склонах." },
            { id = "land_ticks", t = "slider", name = "Упреждение посадки", def = 3, lo = 1, hi = 8, fmt = "%d тик.", vis = v_land,
              tip = "За сколько тиков до касания земли вернуть наземные значения (расчёт через engine.simulate)." },
        } },
    } },
    { tab = "Точность", page = 1, sections = {
        { title = "На земле",
          hint = "Свой hitchance для каждого состояния на земле. «Не менять» оставляет ваш.",
          items = {
            { id = "hc_on", t = "check", name = "Hitchance по состоянию", def = true,
              tip = "Свой hitchance для стоя, шага, бега и приседа. В воздухе действуют значения группы «Воздух»." },
            { id = "hc_stand", t = "slider", name = "Стоя", def = 70, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять", vis = v_hc,
              tip = "Hitchance, когда вы стоите. 0 — не менять ваш." },
            { id = "hc_slow", t = "slider", name = "Медленный шаг", def = 65, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять", vis = v_hc,
              tip = "Hitchance при ходьбе с зажатой клавишей шага (Shift). 0 — не менять ваш." },
            { id = "hc_move", t = "slider", name = "Бег", def = 55, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять", vis = v_hc,
              tip = "Hitchance при обычном беге. 0 — не менять ваш." },
            { id = "hc_duck", t = "slider", name = "Присед", def = 72, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять", vis = v_hc,
              tip = "Hitchance в приседе. 0 — не менять ваш." },
        } },
        { title = "Цель в прицеле",
          hint = "Цель — ближайший к прицелу противник в заданном радиусе. По ней считаются поправки, умный урон и Body-Aim.",
          items = {
            { id = "baim_fov", t = "slider", name = "Радиус поиска цели", def = 60, lo = 5, hi = 180, fmt = "%d°",
              tip = "Угол вокруг прицела, в котором ищется цель для поправок hitchance, умного урона и Body-Aim." },
            { id = "hc_tgt_air", t = "slider", name = "Поправка: цель в воздухе", def = -8, lo = -30, hi = 30, fmt = "%+d%%",
              tip = "Добавка к hitchance, если цель в прыжке. Отрицательное значение ускоряет выстрел." },
            { id = "hc_tgt_move", t = "slider", name = "Поправка: цель бежит", def = 0, lo = -30, hi = 30, fmt = "%+d%%",
              tip = "Добавка к hitchance, если цель движется быстрее 40 u/s." },
            { id = "dmg_cap", t = "check", name = "Мин. урон не выше HP цели", def = true,
              tip = "Если HP цели ниже вашего мин. урона, порог снижается до её HP, и добивающий выстрел не блокируется." },
        } },
    } },
    { tab = "Body-Aim", page = 1, sections = {
        { title = "Body-Aim",
          hint = "Если выстрел в корпус убивает, голова не нужна: 0x убирает её из целей, попасть проще.",
          items = {
            { id = "baim_on", t = "check", name = "Умный Body-Aim", def = true,
              tip = "Считает урон по корпусу трассировкой и убирает голову из хитбоксов, когда корпус выгоднее. Решение удерживается 12 тиков, чтобы не мерцало." },
            { id = "baim_lethal", t = "check", name = "Корпус убивает с 1 выстрела", def = true, vis = v_baim,
              tip = "Урон по корпусу не меньше HP цели плюс запас — голова исключается (причина LETHAL)." },
            { id = "baim_2x", t = "check", name = "Корпус убивает за 2 выстрела", def = false, vis = v_baim,
              tip = "Два попадания в корпус убивают, а голова с одного выстрела — нет (причина 2X). Полезно для Deagle и пистолетов." },
            { id = "baim_margin", t = "slider", name = "Запас урона", def = 2, lo = 0, hi = 30, fmt = "%d HP", vis = v_margin,
              tip = "На сколько урон по корпусу должен превышать HP цели. Больше — осторожнее." },
            { id = "baim_hp_on", t = "check", name = "Корпус при низком HP", def = false, vis = v_baim,
              tip = "Если HP цели не выше порога, стрельба идёт по корпусу (причина HP)." },
            { id = "baim_hp", t = "slider", name = "Порог HP", def = 40, lo = 1, hi = 100, fmt = "%d HP", vis = v_bhp,
              tip = "Порог для режима «Корпус при низком HP»." },
        } },
    } },
    { tab = "Вид", page = 2, sections = {
        { title = "Индикатор",
          hint = "Панель с текущим состоянием и оверрайдами, которые реально записаны в ragebot.",
          items = {
            { id = "ind_on", t = "check", name = "Показывать индикатор", def = true,
              tip = "Панель с состоянием, hitchance, уроном и причиной Body-Aim. Показывает только то, что реально записано в ragebot." },
            { id = "ind_x", t = "slider", name = "Позиция X", def = 1, lo = 0, hi = 100, fmt = "%d%%", vis = v_ind,
              tip = "Положение панели по горизонтали." },
            { id = "ind_y", t = "slider", name = "Позиция Y", def = 40, lo = 0, hi = 100, fmt = "%d%%", vis = v_ind,
              tip = "Положение панели по вертикали." },
            { id = "ind_scale", t = "slider", name = "Размер", def = 100, lo = 80, hi = 150, fmt = "%d%%", vis = v_ind,
              tip = "Масштаб текста индикатора." },
            { id = "ind_color", t = "color", name = "Цвет акцента", def = color(140, 148, 255, 255), vis = v_ind,
              tip = "Цвет заголовка и полосок индикатора." },
        } },
    } },
    { tab = "Профили", page = 2, sections = {
        { title = "Настройки",
          hint = "Изменения сохраняются автоматически через пару секунд после правки.",
          items = {
            { id = "notif", t = "check", name = "Уведомления", def = true,
              tip = "Всплывающие сообщения о загрузке, профилях и ошибках." },
            { id = "debug", t = "check", name = "Журнал записей в консоль", def = false,
              tip = "Печатает в консоль Lua путь, старое и новое значение при каждой записи в config. Нужно для проверки привязки." },
            { id = "btn_save", t = "button", name = "Сохранить сейчас", act = "save",
              tip = "Сразу записать настройки 0x на диск. Обычно они сохраняются сами через пару секунд после правки." },
            { id = "btn_load", t = "button", name = "Загрузить сохранённые", act = "load",
              tip = "Вернуть настройки, сохранённые ранее." },
            { id = "btn_reset", t = "button", name = "Сбросить к стандартным", act = "reset",
              tip = "Вернуть все значения 0x к заводским." },
        } },
        { title = "Связь с ragebot",
          hint = "0x ищет пути hitchance, урона, safepoint и хитбоксов в config автоматически.",
          items = {
            { t = "status" },
            { id = "btn_rescan", t = "button", name = "Пересканировать config", act = "rescan",
              tip = "Заново найти пути параметров ragebot." },
            { id = "btn_dump", t = "button", name = "Вывести пути в консоль", act = "dump",
              tip = "Печатает найденные пути с текущими значениями. Нужно, чтобы проверить привязку." },
        } },
    } },
    { tab = "Справка", page = 2, sections = {
        { title = "Принцип работы", group = "Справка", items = {
            { t = "text", text = "0x не стреляет за вас. Он на лету меняет настройки вашего ragebot (hitchance, мин. урон, safepoint, хитбоксы) и возвращает их обратно." },
            { t = "text", text = "Исходные значения возвращаются при выключении, паузе, смерти, смене оружия и карты, выгрузке скрипта." },
            { t = "text", text = "Запись идёт только при изменении значения. Раз в ~0.25 с значения сверяются с config: вашу правку 0x принимает как новое исходное значение." },
        } },
        { title = "Индикатор", group = "Справка", items = {
            { t = "text", text = "РЕЖИМ: СТОЯ — скорость около нуля, ШАГ — движение с Shift, БЕГ — обычное движение, ПРИСЕД, ВОЗДУХ — прыжок, ПИК — верхняя точка прыжка." },
            { t = "text", text = "BAIM: LETHAL — корпус убивает с одного выстрела, 2X — двумя, а голова одним не убивает, HP — у цели мало HP, KEY — ваш бинд." },
        } },
        { title = "Если что-то не работает", group = "Справка", items = {
            { t = "text", text = "1. «Связь с ragebot» → «Пересканировать config», затем «Вывести пути в консоль». В консоли Lua будут пути config и их значения." },
            { t = "text", text = "2. Если путей нет или они не те, впишите нужные в CUSTOM_PATHS в начале скрипта." },
            { t = "text", text = "3. Включите «Журнал записей в консоль» в группе «Настройки», чтобы видеть каждое изменение." },
            { t = "text", text = "4. Проверяйте по одной функции. Например, включите только воздух и прыгните." },
        } },
    } },
}

local PRESETS = {
    [2] = { name = "Баланс", air_hc = 70, apex_hc = 58, air_dmg = 50, hc_stand = 70, hc_slow = 65, hc_move = 55,
            hc_duck = 72, hc_tgt_air = -8, hc_tgt_move = 0, strict_bonus = 12, baim_margin = 2,
            baim_lethal = true, baim_2x = false, dmg_cap = true },
    [3] = { name = "Агрессивный", air_hc = 58, apex_hc = 48, air_dmg = 38, hc_stand = 60, hc_slow = 55, hc_move = 45,
            hc_duck = 62, hc_tgt_air = -12, hc_tgt_move = -4, strict_bonus = 8, baim_margin = 0,
            baim_lethal = true, baim_2x = true, dmg_cap = true },
    [4] = { name = "Консервативный", air_hc = 78, apex_hc = 68, air_dmg = 62, hc_stand = 80, hc_slow = 75, hc_move = 66,
            hc_duck = 82, hc_tgt_air = -4, hc_tgt_move = 0, strict_bonus = 16, baim_margin = 5,
            baim_lethal = true, baim_2x = false, dmg_cap = true },
}

-- Значения по умолчанию доступны сразу, даже если меню не построилось.
for ti = 1, #SCHEMA do
    for si = 1, #SCHEMA[ti].sections do
        local items = SCHEMA[ti].sections[si].items
        for ii = 1, #items do
            local it = items[ii]
            if it.id and it.def ~= nil then S[it.id] = it.def end
        end
    end
end

----------------------------------------------------------------------------
-- 4. Журнал оригиналов (восстановление после аварийного завершения)
----------------------------------------------------------------------------
-- data — оригиналы путей, значения которых сейчас изменены (или возврат которых не удался).
-- disk — копия того, что лежит в файле. Файл переписывается, только если в нём не хватает
-- записи (сразу, на ближайшем кадре) или в нём давно лежат устаревшие (лениво).
Journal.data, Journal.disk = {}, {}
Journal.add_dirty, Journal.rm_dirty, Journal.rm_t = false, false, 0

function Journal.add(path, orig)
    local v = U.copy(orig)
    Journal.data[path] = v
    if not U.same(Journal.disk[path], v) then Journal.add_dirty = true end
end

function Journal.remove(path)
    if Journal.data[path] == nil then return end
    Journal.data[path] = nil
    if Journal.disk[path] ~= nil then
        Journal.rm_dirty, Journal.rm_t = true, RT.now
    end
end

local function journal_missing()                    -- в data есть запись, которой нет в файле
    for k, v in pairs(Journal.data) do
        if not U.same(Journal.disk[k], v) then return true end
    end
    return false
end

local function journal_stale()                      -- в файле есть запись, которой уже нет в data
    for k in pairs(Journal.disk) do
        if Journal.data[k] == nil then return true end
    end
    return false
end

function Journal.flush(force)
    local need = false
    if Journal.add_dirty then
        need = journal_missing()
        if not need then Journal.add_dirty = false end   -- запись успела исчезнуть: писать нечего
    end
    if not need and Journal.rm_dirty and (force or RT.now - Journal.rm_t >= K.JOURNAL_LAZY) then
        need = journal_stale()
        if not need then Journal.rm_dirty = false end
    end
    if not need then return end
    if not force and RT.now - RT.io_t < K.IO_RETRY then return end
    local ok, res = pcall(db.save, DB_JOURNAL, Journal.data)
    if ok and res ~= false then
        local disk = {}
        for k, v in pairs(Journal.data) do disk[k] = U.copy(v) end
        Journal.disk = disk
        Journal.add_dirty, Journal.rm_dirty = false, false
    else
        RT.io_t = RT.now                            -- диск недоступен: повтор не раньше чем через IO_RETRY
    end
end

----------------------------------------------------------------------------
-- 5. Привязка к config ragebot
----------------------------------------------------------------------------
local NONE = {}          -- «оригинал не сохранён»
local TRANSFORM = {}     -- «значение вычисляется из исходного» (флаги, списки)

local GENERIC_EXCLUDE = {
    "colou?r", "visual", "%f[%w]esp%f[%W]", "chams", "glow", "indicator", "draw", "show",
    "%f[%w]logs?%f[%W]", "legit", "trigger", "%f[%w]keys?%f[%W]", "hotkey", "bind", "sound",
    "notif", "%f[%w]hud%f[%W]", "font", "preview", "widget", "overr", "%f[%w]ovr%f[%W]",
}

local ORDER = { "hc", "dmg", "safe", "baim", "hitbox" }
local SL = {
    hc = { tag = "HC", title = "Hitchance",
           patterns = { "hit[%s_%.%-]?chance" }, exclude = {},
           ok = function(v) return type(v) == "number" and v >= 0 and v <= 100 end },
    dmg = { tag = "DMG", title = "Мин. урон",
            patterns = { "min[%s_%.%-]?dam", "min[%s_%.%-]?dmg" }, exclude = {},
            ok = function(v) return type(v) == "number" and v >= 0 and v <= 300 end },
    safe = { tag = "SAFE", title = "Safepoint",
             patterns = { "safe[%s_%.%-]?point" },
             exclude = { "unsafe", "multi", "hitbox", "limit", "min" },
             ok = function(v) return type(v) == "boolean" or (type(v) == "number" and v >= 0 and v <= 10) end },
    baim = { tag = "BAIM", title = "Body-Aim",
             patterns = { "body[%s_%.%-]?aim", "baim", "prefer[%s_%.%-]?body", "force[%s_%.%-]?body" },
             exclude = { "lethal", "disabl", "hp", "health", "dam", "dmg", "condition", "unsafe",
                         "after", "miss", "shot", "min", "max" },
             ok = function(v) return type(v) == "boolean" end },
    hitbox = { tag = "HITBOX", title = "Хитбоксы",
               patterns = { "hit[%s_%.%-]?box" },
               exclude = { "point", "scale", "prior", "debug", "history", "backtrack" },
               ok = function(v) return type(v) == "table" end },
}
for i = 1, #ORDER do
    local sl = SL[ORDER[i]]
    sl.id, sl.recs, sl.n = ORDER[i], {}, 0
    sl.w, sl.g, sl.force, sl.custom, sl.live, sl.full = nil, 0, false, false, 0, false
end
local CLAIMED = {}       -- путь -> id параметра: один путь обслуживает только один параметр

SL.safe.transform = function(orig)
    if type(orig) == "boolean" then return true end
    if type(orig) == "number" then return SAFE_COMBO_VALUE end
    return nil
end
SL.baim.transform = function(orig)
    if type(orig) == "boolean" then return true end
    return nil
end
SL.hitbox.transform = function(orig) return U.strip_head(orig) end

-- Теги путей: к какой группе оружия относится путь. Путь без тегов действует на все группы.
local PATH_TAGS = {
    { 1, { "ssg", "scout" } },
    { 2, { "awp" } },
    { 3, { "autosnip", "auto[%s_%.%-]snip", "scar", "g3sg1", "%f[%w]auto%f[%W]" } },
    { 4, { "deagle", "revolver", "%f[%w]r8%f[%W]", "heavy" } },
    { 5, { "pistol" } },
    { 6, { "rifle", "smg", "shotgun", "machine", "%f[%w]other%f[%W]" } },
}

local function tags_for(low)
    local tags
    for i = 1, #PATH_TAGS do
        if U.any_match(low, PATH_TAGS[i][2]) then
            tags = tags or {}
            tags[PATH_TAGS[i][1]] = true
        end
    end
    if tags and tags[4] and tags[5] and s_find(low, "heavy", 1, true) then tags[5] = nil end
    return tags
end

local function cfg_get(path)
    local ok, v = pcall(config.get, path)
    if ok then return v end
    return nil
end

local function cfg_set(path, v)
    local ok, r = pcall(config.set, path, v)
    return ok and r ~= false
end

-- Возвращает в config значения, оставшиеся в журнале после аварийного завершения.
-- Что вернуть не удалось, остаётся в журнале: при следующем захвате пути оригинал берётся оттуда.
function Journal.restore()
    local ok, saved = pcall(db.load, DB_JOURNAL, nil)
    if not ok or type(saved) ~= "table" then return 0 end
    local n, any = 0, false
    for path, val in pairs(saved) do
        if type(path) == "string" and val ~= nil and val ~= json.null then
            any = true
            Journal.disk[path] = U.copy(val)
            local cur = cfg_get(path)
            if cur ~= nil and type(cur) == type(val) and not U.same(cur, val) then
                if cfg_set(path, val) then
                    n = n + 1
                else
                    Journal.data[path] = U.copy(val)
                end
            end
        end
    end
    if any then Journal.rm_dirty, Journal.rm_t = true, -1e9 end   -- файл чистится при первой возможности
    return n
end

function Bind.add_path(sl, path, forced)
    local owner = CLAIMED[path]
    if owner then
        if forced and owner ~= sl.id then
            U.say(sl.title .. ": путь «" .. path .. "» уже занят параметром «" .. SL[owner].title .. "»")
        end
        return false
    end
    local v = cfg_get(path)
    if v == nil then
        if forced then U.say(sl.title .. ": путь «" .. path .. "» не найден в config") end
        return false
    end
    if not sl.ok(v) then
        if forced then U.say(sl.title .. ": путь «" .. path .. "» имеет неподходящий тип (" .. type(v) .. ")") end
        return false
    end
    CLAIMED[path] = sl.id
    sl.n = sl.n + 1
    -- orig — значение пользователя (NONE, пока путь не тронут); cur — что сейчас лежит в config
    -- по нашим сведениям; want — последнее желаемое значение; eff — принято ли оно config.
    sl.recs[sl.n] = { path = path, tags = tags_for(s_lower(path)), orig = NONE, cur = nil, want = nil,
                      eff = false, bad = 0, mism = 0, dead = false, warned = false, ro = false }
    return true
end

local function clear_pub()
    if RT.hc ~= nil or RT.dmg ~= nil or RT.safe or RT.baim ~= nil or RT.strict or RT.pub_thp ~= nil then
        RT.hc, RT.dmg, RT.safe, RT.baim, RT.strict, RT.pub_thp = nil, nil, false, nil, false, nil
        RT.ind_dirty = true
    end
end

local function rec_fail(sl, rec, why)
    rec.bad = rec.bad + 1
    if rec.bad < K.BAD_LIMIT then
        sl.force = true                             -- повторить на следующем тике
    elseif not rec.dead then
        rec.dead = true
        U.say("путь отключён до пересканирования (" .. why .. "): " .. rec.path)
    end
end

-- Возвращает значение пользователя. true — config гарантированно содержит оригинал.
-- Отключённые пути повторяются только при final (смена карты, пересканирование, выгрузка).
function Bind.restore(sl, rec, final)
    if rec.orig == NONE then return true end
    if rec.dead and not final then return false end
    if not U.same(rec.cur, rec.orig) then
        if not cfg_set(rec.path, rec.orig) then
            rec_fail(sl, rec, "не удалось вернуть значение, оригинал остаётся в журнале")
            return false
        end
        if S.debug then U.say(s_format("%s <- %s (возврат)", rec.path, U.fmt(rec.orig))) end
    end
    rec.orig, rec.cur, rec.want, rec.eff = NONE, nil, nil, false
    Journal.remove(rec.path)
    return true
end

-- Возврат всех значений. Запись журнала исчезает только вместе с успешным возвратом.
function Bind.release(final)
    clear_pub()
    if not RT.touched and not final then return end
    local pending = false
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        local recs = sl.recs
        for j = 1, sl.n do
            local rec = recs[j]
            if rec.orig ~= NONE and not Bind.restore(sl, rec, final) and not rec.dead then pending = true end
        end
        sl.w, sl.g, sl.force, sl.live = nil, 0, false, 0
    end
    RT.touched = pending
end

function Bind.scan()
    Bind.release(true)
    for k in pairs(CLAIMED) do CLAIMED[k] = nil end
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        sl.recs, sl.n, sl.w, sl.g, sl.force, sl.custom, sl.live, sl.full = {}, 0, nil, 0, false, false, 0, false
        local list = CUSTOM_PATHS[sl.id]
        if type(list) == "table" and #list > 0 then
            sl.custom = true
            for j = 1, #list do
                if type(list[j]) == "string" then Bind.add_path(sl, list[j], true) end
            end
        end
    end
    RT.eval_at = 0
    local ok, keys = pcall(config.keys)
    if not ok or type(keys) ~= "table" then
        U.say("config.keys недоступен: " .. tostring(keys) .. ". Впишите пути в CUSTOM_PATHS.")
        return false
    end
    for i = 1, #keys do
        local path = keys[i]
        if type(path) == "string" and not CLAIMED[path] then
            local low = s_lower(path)
            local excluded = nil                    -- общий фильтр считается только для подходящих ключей
            for j = 1, #ORDER do
                local sl = SL[ORDER[j]]
                if not sl.custom and U.any_match(low, sl.patterns) then
                    if excluded == nil then excluded = U.any_match(low, GENERIC_EXCLUDE) end
                    if excluded then break end
                    if not U.any_match(low, sl.exclude) then
                        if sl.n < K.MAX_CANDS then
                            if Bind.add_path(sl, path, false) then break end
                        elseif not sl.full then
                            sl.full = true
                            U.say(s_format("%s: найдено больше %d путей, лишние пропущены. Впишите нужные в CUSTOM_PATHS.",
                                           sl.title, K.MAX_CANDS))
                        end
                    end
                end
            end
        end
    end
    return true
end

function Bind.total()
    local n = 0
    for i = 1, #ORDER do n = n + SL[ORDER[i]].n end
    return n
end

function Bind.summary()
    local p = {}
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        p[#p + 1] = s_format("%s %d", sl.tag, sl.n)
    end
    return t_concat(p, " · ")
end

function Bind.dump()
    U.say("---- пути config, найденные 0x ----")
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        U.say(s_format("%s: найдено %d%s", sl.title, sl.n, sl.custom and " (ручные пути)" or ""))
        for j = 1, sl.n do
            local r = sl.recs[j]
            local tg = "все"
            if r.tags then
                local t = {}
                for g in pairs(r.tags) do t[#t + 1] = tostring(g) end
                t_sort(t)
                tg = t_concat(t, ",")
            end
            U.say(s_format("   %s = %s  [группы оружия: %s]%s%s", r.path, U.fmt(cfg_get(r.path)), tg,
                           r.dead and "  ОТКЛЮЧЁН" or "", r.ro and "  НЕ МЕНЯЕТСЯ" or ""))
        end
    end
end

-- Исходное числовое значение первого подходящего пути (для Strict и умного урона).
function Bind.base(sl, group)
    if not group then return nil end
    for i = 1, sl.n do
        local r = sl.recs[i]
        if not r.dead and (r.tags == nil or r.tags[group]) then
            local v = r.orig
            if v == NONE then v = cfg_get(r.path) end
            if type(v) == "number" then return v end
        end
    end
    return nil
end

-- Записывает желаемое значение: число/значение или TRANSFORM.
-- true — config содержит желаемое значение (или то, во что config его превратил).
function Bind.push(sl, rec, target)
    if rec.dead then return false end
    if rec.orig == NONE then
        local cur = cfg_get(rec.path)
        if cur == nil then
            rec_fail(sl, rec, "путь перестал читаться")
            return false
        end
        local pending = Journal.data[rec.path]
        if pending ~= nil and type(pending) == type(cur) then
            rec.orig = U.copy(pending)              -- прошлый возврат не удался: настоящий оригинал в журнале
        else
            rec.orig = U.copy(cur)
            Journal.add(rec.path, rec.orig)
        end
        rec.cur, rec.want, rec.eff = U.copy(cur), nil, false
        RT.touched = true
    end

    local val, supported = target, true
    if target == TRANSFORM then
        val = sl.transform(rec.orig)
        if val == nil then
            if not rec.warned then
                rec.warned = true
                U.say("формат значения не поддержан, путь пропущен: " .. rec.path .. " = " .. U.fmt(rec.orig))
            end
            val, supported = rec.orig, false
        end
    end
    if rec.want ~= nil and U.same(rec.want, val) then return rec.eff end

    local eff
    if U.same(val, rec.orig) then
        -- Желаемое равно значению пользователя: в config должно лежать именно оно, а не прошлый оверрайд.
        if not U.same(rec.cur, rec.orig) then
            if not cfg_set(rec.path, rec.orig) then
                rec_fail(sl, rec, "запись отклонена")
                return false
            end
            if S.debug then U.say(s_format("%s <- %s (совпадает с вашим)", rec.path, U.fmt(rec.orig))) end
            rec.cur = U.copy(rec.orig)
        end
        eff = supported
    elseif cfg_set(rec.path, val) then
        -- Сверяемся с тем, что config реально сохранил: он может ограничить или округлить значение.
        local echo = cfg_get(rec.path)
        if echo == nil then echo = val end
        rec.cur, rec.bad = U.copy(echo), 0
        eff = not U.same(echo, rec.orig)
        if not eff and not rec.ro then
            rec.ro = true
            U.say("запись принята, но значение не изменилось: " .. rec.path .. " (нужно " .. U.fmt(val) .. ")")
        end
        if S.debug then U.say(s_format("%s: %s -> %s", rec.path, U.fmt(rec.orig), U.fmt(echo))) end
    else
        rec_fail(sl, rec, "запись отклонена")
        return false
    end
    rec.want, rec.eff = U.copy(val), eff
    return eff
end

function Bind.apply(sl, want, group)
    if sl.n == 0 then return end
    if want == nil then group = 0 end
    if sl.w == want and sl.g == group and not sl.force then return end
    sl.w, sl.g, sl.force = want, group, false
    local recs, live = sl.recs, 0
    for i = 1, sl.n do
        local rec = recs[i]
        if want ~= nil and (rec.tags == nil or rec.tags[group]) then
            if Bind.push(sl, rec, want) then live = live + 1 end
        elseif rec.orig ~= NONE then
            Bind.restore(sl, rec, false)
        end
    end
    sl.live = live                                  -- сколько путей реально держат желаемое значение
end

-- Сверка: если значение изменил пользователь или другой код, оно становится новым оригиналом.
function Bind.verify()
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        local recs = sl.recs
        for j = 1, sl.n do
            local rec = recs[j]
            if rec.orig ~= NONE and not rec.dead then
                local cur = cfg_get(rec.path)
                if cur ~= nil then
                    if U.same(cur, rec.cur) then
                        rec.mism = 0
                    else
                        -- Правки при открытом меню — это пользователь двигает слайдер, а не чужой код.
                        if not RT.menu_open then rec.mism = rec.mism + 1 end
                        if rec.mism > K.MISM_LIMIT then
                            rec.dead = true
                            rec.orig, rec.cur, rec.want, rec.eff = NONE, nil, nil, false
                            Journal.remove(rec.path)
                            U.say("путь отключён до пересканирования (значение постоянно меняет другой код): " .. rec.path)
                        else
                            rec.orig, rec.cur, rec.want, rec.eff = U.copy(cur), U.copy(cur), nil, false
                            Journal.add(rec.path, rec.orig)
                            sl.force = true
                        end
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------
-- 6. Логика: состояние игрока, оружие, цели, решения
----------------------------------------------------------------------------
local HB = { cache = {}, n = 0 }
local CAND, CAND_N = {}, 0                    -- пул кандидатов в цели (без выделений памяти на каждом пересчёте)

local function norm_angle(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local function bind_on(el)
    if el == nil then return false end
    local ok, v = pcall(m_active, el)
    return ok and v == true
end

local function clear_target()
    RT.t_hp, RT.t_air, RT.t_move = nil, false, false
    if RT.t_addr ~= nil then RT.t_addr, RT.baim_until = nil, 0 end
end

function Logic.reset()
    HB.cache, HB.n = {}, 0
    for i = 1, CAND_N do CAND[i].pawn = nil end
    CAND_N = 0
    RT.waddr, RT.wgroup, RT.state = nil, nil, nil
    RT.t_hp, RT.t_air, RT.t_move, RT.t_addr = nil, false, false, nil
    RT.baim_reason, RT.baim_until = nil, 0
    RT.base_hc, RT.base_dmg = nil, nil
    RT.land_soon, RT.air_ticks = false, 0
    RT.eval_at = 0
    RT.ind_dirty = true
end

function Logic.classify(w)
    local ok, info = pcall(m_weapon_info, w)
    if not ok or type(info) ~= "table" then return nil end
    if info.gun == false then return nil end
    local def = tonumber(info.def)
    if def and WPN_BY_DEF[def] then return WPN_BY_DEF[def] end
    if def and NON_GUN_DEF[def] then return nil end
    local name = type(info.name) == "string" and s_lower(info.name) or ""
    for i = 1, #WPN_BY_NAME do
        if s_find(name, WPN_BY_NAME[i][1], 1, true) then return WPN_BY_NAME[i][2] end
    end
    for i = 1, #NON_GUN do
        if s_find(name, NON_GUN[i], 1, true) then return nil end
    end
    return 6
end

function Logic.weapon(lp)
    local w = lp:weapon()
    if not w then
        RT.wgroup, RT.waddr = nil, nil
        return
    end
    local addr = w:address()
    if addr ~= RT.waddr or RT.tick - RT.wtick >= K.WEAPON_TICKS then
        RT.waddr, RT.wtick = addr, RT.tick
        local g = Logic.classify(w)
        if g ~= RT.wgroup then
            RT.wgroup = g
            RT.eval_at = 0                          -- базовые значения и цель считаются заново для новой группы
            RT.ind_dirty = true
        end
    end
end

-- Режим «С предсказанием посадки»: коснёмся ли земли в ближайшие land_ticks тиков.
function Logic.predict()
    local ok, sim = pcall(engine.simulate, S.land_ticks)
    if not ok or type(sim) ~= "table" then
        RT.sim_fail = RT.sim_fail + 1
        if RT.sim_fail >= 3 then
            RT.sim_fail = 0
            U.say("engine.simulate недоступен, детекция переключена на «Земля + верт. скорость»")
            S.air_mode = 1
            RT.sync_mode = 1                        -- виджет обновится в paint, до чтения настроек
        end
        return
    end
    RT.sim_fail = 0
    for i = 1, #sim do
        local s = sim[i]
        if type(s) == "table" and s.valid ~= false and (s.landed or s.on_ground) then
            RT.land_soon = true
            return
        end
    end
end

function Logic.movement(lp, cmd)
    local vel = lp:velocity()
    local vx, vy, vz = 0, 0, 0
    if vel then vx, vy, vz = vel.x or 0, vel.y or 0, vel.z or 0 end
    local speed = sqrt(vx * vx + vy * vy)
    local grounded = lp:on_ground() ~= false
    if grounded then
        RT.air_ticks, RT.land_soon = 0, false
    else
        RT.air_ticks = RT.air_ticks + 1
    end
    local mode = S.air_mode
    local air = false
    if not grounded then
        if mode == 2 then
            air = true
        else
            air = RT.air_ticks >= 2 and (abs(vz) >= S.air_thr or RT.air_ticks >= 10)
        end
    end
    if air and mode == 3 then
        -- Симуляция идёт каждый тик (а не раз в 4), иначе упреждение в 1–3 тика почти всегда опаздывает.
        -- При наборе высоты приземлиться за land_ticks тиков нельзя, симуляция пропускается;
        -- после срабатывания результат держится до касания земли.
        if not RT.land_soon and vz <= RT.g_tick * S.land_ticks + K.SIM_MARGIN then Logic.predict() end
        if RT.land_soon then air = false end
    end
    local st
    if air then
        st = (S.apex_on and abs(vz) <= S.apex_win) and ST.APEX or ST.AIR
    elseif band(lp:flags() or 0, K.FL_DUCKING) ~= 0 then
        st = ST.DUCK
    elseif speed < K.MOVE_EPS then
        st = ST.STAND
    elseif cmd:has(K.BTN_SPEED) then
        st = ST.SLOW
    else
        st = ST.MOVE
    end
    if st ~= RT.state then
        RT.state = st
        RT.ind_dirty = true
    end
end

local function hg_from_name(s)
    if type(s) ~= "string" then return 0 end
    local l = s_lower(s)
    if s_find(l, "head", 1, true) then return K.HG_HEAD end
    if s_find(l, "chest", 1, true) then return K.HG_CHEST end
    if s_find(l, "stomach", 1, true) then return K.HG_STOMACH end
    return 0
end

-- Индексы хитбоксов головы / груди / живота выбираются из pawn:hitboxes() и кэшируются.
function Logic.hitbox_ids(pawn)
    local addr = pawn:address()
    local c = HB.cache[addr]
    if c and RT.tick - c.t < K.HB_TTL then return c end
    local ok, list = pcall(m_hitboxes, pawn)
    if not ok or type(list) ~= "table" then return nil end
    local body, head, got = {}, nil, {}
    for i = 1, #list do
        local hb = list[i]
        if type(hb) == "table" and hb.index ~= nil then
            local g = hb.group
            if type(g) ~= "number" then g = hg_from_name(hb.group_name or g) end
            if g == K.HG_HEAD then
                if not head then head = { index = hb.index, group = g } end
            elseif (g == K.HG_CHEST or g == K.HG_STOMACH) and not got[g] then
                got[g] = true
                body[#body + 1] = { index = hb.index, group = g }
            end
        end
    end
    if c == nil then
        if HB.n >= K.HB_MAX then HB.cache, HB.n = {}, 0 end
        HB.n = HB.n + 1
    end
    c = { t = RT.tick, body = body, head = head }
    HB.cache[addr] = c
    return c
end

function Logic.dmg_at(eye, pawn, entry)
    local pos = pawn:hitbox(entry.index)
    if not pos then return 0 end
    local ok, d = pcall(trace.damage, pawn, pos, entry.group, eye)
    if ok and type(d) == "number" then return d end
    return 0
end

function Logic.eval_targets(lp)
    local grp = RT.wgroup
    RT.base_hc = Bind.base(SL.hc, grp)
    RT.base_dmg = Bind.base(SL.dmg, grp)

    -- Цель ищется, только если результат есть куда записать.
    local baim_ok = S.baim_on and (SL.baim.n + SL.hitbox.n) > 0
    local need_trace = baim_ok and (S.baim_lethal or S.baim_2x)
    local need_target = need_trace or (baim_ok and S.baim_hp_on)
                        or (S.dmg_cap and SL.dmg.n > 0)
                        or ((S.hc_tgt_air ~= 0 or S.hc_tgt_move ~= 0) and SL.hc.n > 0)
    if not need_target then
        clear_target()
        RT.baim_reason = nil
        return
    end
    local eye, view = lp:eye_position(), engine.view_angles()
    if not eye or not view then
        clear_target()
        RT.baim_reason = nil
        return
    end

    -- Угол до каждого противника считается без промежуточных векторов.
    local ex, ey, ez = eye.x, eye.y, eye.z - K.EYE_OFFSET
    local vp, vy, lim = view.x, view.y, S.baim_fov
    local players = entity.players()
    local n = 0
    if type(players) == "table" then
        for i = 1, #players do
            local p = players[i]
            local pawn = p and p.pawn
            if pawn and pawn:alive() and pawn:is_enemy() then
                local o = pawn:origin()
                if o then
                    local dx, dy, dz = o.x - ex, o.y - ey, o.z - ez
                    local dp = norm_angle(atan2(-dz, sqrt(dx * dx + dy * dy)) * RAD2DEG - vp)
                    local dw = norm_angle(atan2(dy, dx) * RAD2DEG - vy)
                    local fov = sqrt(dp * dp + dw * dw)
                    if fov <= lim then
                        n = n + 1
                        local c = CAND[n]
                        if not c then
                            c = {}
                            CAND[n] = c
                        end
                        c.pawn, c.fov, c.hp, c.bd, c.hd = pawn, fov, 100, 0, 0
                    end
                end
            end
        end
    end
    for i = n + 1, CAND_N do CAND[i].pawn = nil end   -- не держим ссылки на ушедших игроков
    CAND_N = n

    local pick = nil
    for i = 1, min(n, K.MAX_TARGETS) do
        local m = i                                   -- выбор i-го по близости к прицелу (без table.sort)
        for j = i + 1, n do
            if CAND[j].fov < CAND[m].fov then m = j end
        end
        if m ~= i then CAND[i], CAND[m] = CAND[m], CAND[i] end
        local c = CAND[i]
        c.hp = c.pawn:health() or 100
        if need_trace then
            local ids = Logic.hitbox_ids(c.pawn)
            if ids then
                local need = c.hp + S.baim_margin
                for j = 1, #ids.body do
                    local d = Logic.dmg_at(eye, c.pawn, ids.body[j])
                    if d > c.bd then c.bd = d end
                    if d >= need then break end       -- уже летально: остальные трассировки не нужны
                end
                -- Урон по голове нужен только для решения «2X».
                if S.baim_2x and ids.head and c.bd > 0 and c.bd * 2 >= need
                   and not (S.baim_lethal and c.bd >= need) then
                    c.hd = Logic.dmg_at(eye, c.pawn, ids.head)
                end
            end
        end
        if not pick then pick = c end
        if c.bd > 0 then
            pick = c
            break
        end
    end

    local reason = nil
    if pick then
        local p = pick.pawn
        local addr = p:address()
        if addr ~= RT.t_addr then RT.t_addr, RT.baim_until = addr, 0 end   -- удержание не переносится на другую цель
        RT.t_hp = pick.hp
        RT.t_air = (p:on_ground() == false)
        local pv = p:velocity()
        RT.t_move = (pv ~= nil) and (pv.x * pv.x + pv.y * pv.y > K.T_MOVE_SQR)
        if baim_ok then
            local hp, bd = pick.hp, pick.bd
            local need = hp + S.baim_margin
            if S.baim_lethal and bd > 0 and bd >= need then
                reason = "LETHAL"
            elseif S.baim_2x and bd > 0 and bd * 2 >= need and pick.hd < hp then
                reason = "2X"
            elseif S.baim_hp_on and hp <= S.baim_hp then
                reason = "HP"
            end
        end
    else
        clear_target()
    end

    if reason then
        RT.baim_reason, RT.baim_until = reason, RT.tick + K.HOLD_TICKS
    elseif RT.tick > RT.baim_until then
        RT.baim_reason = nil
    end
end

local function set_pub(k, v)
    if RT[k] ~= v then
        RT[k] = v
        RT.ind_dirty = true
    end
end

function Logic.decide(grp)
    local st = RT.state
    local airborne = (st == ST.AIR or st == ST.APEX)
    local strict, kbaim, kdmg = bind_on(B.strict), bind_on(B.baim), bind_on(B.dmg)
    if not S.baim_on then RT.baim_reason = nil end

    -- Hitchance
    local hc = nil
    if airborne then
        if S.air_on then
            hc = (st == ST.APEX and S.apex_on) and S.apex_hc or S.air_hc
        end
    elseif S.hc_on then
        local v
        if st == ST.STAND then v = S.hc_stand
        elseif st == ST.SLOW then v = S.hc_slow
        elseif st == ST.MOVE then v = S.hc_move
        else v = S.hc_duck end
        if v and v > 0 then hc = v end
    end
    if hc and RT.t_hp then
        if RT.t_air then hc = hc + S.hc_tgt_air end
        if RT.t_move then hc = hc + S.hc_tgt_move end
    end
    if strict then
        if not hc then hc = RT.base_hc end
        if hc then hc = hc + S.strict_bonus end
    end
    if hc then hc = U.clamp(U.round(hc), 1, 100) end

    -- Минимальный урон
    local dmg = nil
    if airborne and S.air_on then dmg = S.air_dmg end
    if kdmg then dmg = S.dmg_bind_val end
    if S.dmg_cap and RT.t_hp then
        local base = dmg or RT.base_dmg
        if base and base <= 100 and RT.t_hp < base then dmg = max(1, RT.t_hp) end
    end
    if dmg then dmg = U.clamp(U.round(dmg), 1, 130) end

    -- Safepoint и Body-Aim
    local safe = (airborne and S.air_on and S.air_safe) or strict
    local baim = nil
    if kbaim then baim = "KEY" elseif RT.baim_reason then baim = RT.baim_reason end

    local want_safe = safe and TRANSFORM or nil
    local want_baim = baim and TRANSFORM or nil
    Bind.apply(SL.hc, hc, grp)
    Bind.apply(SL.dmg, dmg, grp)
    Bind.apply(SL.safe, want_safe, grp)
    Bind.apply(SL.baim, want_baim, grp)
    Bind.apply(SL.hitbox, want_baim, grp)

    -- Индикатор показывает только то, что реально записано в ragebot.
    local hc_live, safe_live = SL.hc.live > 0, SL.safe.live > 0
    set_pub("hc", hc_live and hc or nil)
    set_pub("dmg", (SL.dmg.live > 0) and dmg or nil)
    set_pub("safe", (safe and safe_live) and true or false)
    set_pub("baim", (SL.baim.live + SL.hitbox.live > 0) and baim or nil)
    set_pub("strict", (strict and (hc_live or safe_live)) and true or false)
    set_pub("pub_thp", RT.t_hp)
end

----------------------------------------------------------------------------
-- 7. Настройки: чтение, профили, сохранение
----------------------------------------------------------------------------
function Settings.read(w)
    local ok, v = pcall(m_get, w.raw)
    if not ok or v == nil then return S[w.id] end
    local k = w.kind
    if k == "check" then return v and true or false end
    if k == "slider" then
        v = tonumber(v)
        if not v then return S[w.id] end
        return U.clamp(floor(v + 0.5), w.lo, w.hi)
    end
    if k == "combo" then
        if type(v) == "string" then
            for i = 1, #w.items do
                if w.items[i] == v then return i end
            end
            return S[w.id]
        end
        v = tonumber(v)
        if not v then return S[w.id] end
        return U.clamp(floor(v + 0.5) + 1 - w.base, 1, #w.items)
    end
    if k == "color" then
        if type(v) == "table" and type(v.r) == "number" and type(v.g) == "number" and type(v.b) == "number" then
            return v
        end
        return S[w.id]
    end
    return v
end

-- В S пункты combo всегда нумеруются с единицы; здесь номер переводится в нумерацию виджета.
function Settings.set(id, v)
    S[id] = v
    local w = W[id]
    if not w then return end
    if w.kind == "combo" then
        if w.by_name then v = w.items[v] else v = v - 1 + w.base end
    end
    pcall(m_set, w.raw, v)
end

local function differs(kind, a, b)
    if kind == "color" and type(a) == "table" and type(b) == "table" then
        return a.r ~= b.r or a.g ~= b.g or a.b ~= b.b or a.a ~= b.a
    end
    return a ~= b
end

function Settings.matches(idx)
    local p = PRESETS[idx]
    if not p then return true end
    for id, v in pairs(p) do
        if id ~= "name" and S[id] ~= v then return false end
    end
    return true
end

function Settings.apply_preset(idx)
    local p = PRESETS[idx]
    if not p then return end
    for id, v in pairs(p) do
        if id ~= "name" then Settings.set(id, v) end
    end
    RT.last_preset = idx
    Settings.poll(true)
    U.notify("Профиль «" .. p.name .. "» применён")
end

-- Вызывается, когда снимок настроек изменился. force = значения пришли из загрузки, сброса
-- или самого профиля: тогда выбранный профиль не накладывается поверх.
function Settings.changed(force)
    RT.cfg_dirty, RT.cfg_t = true, RT.now
    RT.ind_dirty = true
    RT.eval_at = 0
    if W.preset then
        local p = S.preset
        if p ~= RT.last_preset then
            RT.last_preset = p
            if p > 1 and not force then
                Settings.apply_preset(p)            -- сам перечитает виджеты и обновит видимость
                return
            end
        end
        -- Значения разошлись с выбранным профилем: показываем «Свой». Если виджет не принял
        -- программную установку, больше не пробуем, чтобы не спорить с пользователем.
        if p > 1 and RT.preset_sync and not Settings.matches(p) then
            Settings.set("preset", 1)
            local back = Settings.read(W.preset)
            S.preset, RT.last_preset = back, back
            if back ~= 1 then RT.preset_sync = false end
        end
    end
    UIm.refresh_vis()
end

-- Чтение виджетов: 20 раз в секунду при открытом меню и раз в секунду при закрытом.
-- Вызывается из paint, поэтому createmove в обычной работе не трогает меню вовсе.
function Settings.poll(force)
    local now = RT.now
    if not force and now - RT.snap_t < RT.poll_dt then return end
    RT.snap_t = now
    if now - RT.menu_evt_t > K.MENU_GRACE then      -- лечит пропущенное событие menu_toggled
        local ok, open = pcall(input.menu_open)
        if ok then RT.menu_open = (open == true) end
    end
    RT.poll_dt = RT.menu_open and K.POLL_OPEN or K.POLL_IDLE
    local changed = false
    for i = 1, #ORDER_W do
        local id = ORDER_W[i]
        local w = W[id]
        local v = Settings.read(w)
        if differs(w.kind, S[id], v) then
            S[id] = v
            changed = true
        end
    end
    if changed or force then Settings.changed(force) end
end

function Settings.validate(w, v)
    local k = w.kind
    if k == "check" then
        if type(v) == "boolean" then return v end
    elseif k == "slider" then
        if type(v) == "number" then return U.clamp(floor(v + 0.5), w.lo, w.hi) end
    elseif k == "combo" then
        if type(v) == "number" then return U.clamp(floor(v + 0.5), 1, #w.items) end
    elseif k == "color" then
        if type(v) == "table" and type(v.r) == "number" and type(v.g) == "number" and type(v.b) == "number" then
            return color(v.r, v.g, v.b, tonumber(v.a) or 255)
        end
    end
    return nil
end

function Settings.pack()
    local t = {}
    for i = 1, #ORDER_W do
        local id = ORDER_W[i]
        local v = S[id]
        if W[id].kind == "color" and type(v) == "table" then
            v = { r = v.r, g = v.g, b = v.b, a = v.a }
        end
        t[id] = v
    end
    return { v = 1, ver = VERSION, s = t }
end

function Settings.save()
    local ok, res = pcall(db.save, DB_SETTINGS, Settings.pack())
    return ok and res ~= false
end

function Settings.load()
    local ok, data = pcall(db.load, DB_SETTINGS, nil)
    if not ok or type(data) ~= "table" or type(data.s) ~= "table" then return false end
    for id, v in pairs(data.s) do
        local w = W[id]
        if w then
            local val = Settings.validate(w, v)
            if val ~= nil then Settings.set(id, val) end
        end
    end
    Settings.poll(true)
    return true
end

function ACT.save()
    if Settings.save() then
        RT.cfg_dirty = false
        U.notify("Настройки сохранены")
    else
        U.notify("Не удалось сохранить настройки")
    end
end

function ACT.load()
    if Settings.load() then
        RT.cfg_dirty = false
        U.notify("Сохранённые настройки загружены")
    else
        U.notify("Сохранённых настроек нет")
    end
end

function ACT.reset()
    for i = 1, #ORDER_W do
        local id = ORDER_W[i]
        Settings.set(id, W[id].def)
    end
    Settings.poll(true)
    U.notify("Настройки сброшены к стандартным")
end

function ACT.rescan()
    local ok = Bind.scan()
    local txt = ok and ("Найдено: " .. Bind.summary()) or "config.keys недоступен"
    UIm.set_status(txt)
    U.notify(txt)
end

function ACT.dump() Bind.dump() end

----------------------------------------------------------------------------
-- 8. Интерфейс: нативное меню Neverlose и Menu.lua (VibeUI)
----------------------------------------------------------------------------
UIm.mode, UIm.menu, UIm.status = "нет", nil, nil
UIm.boot_status, UIm.rescan_el, UIm.rescan_tip = "—", nil, nil
UIm.combo_base, UIm.vis_ok = nil, true

local function mk(it, raw)
    local w = { id = it.id, kind = it.t, raw = raw, def = it.def, lo = it.lo, hi = it.hi, items = it.items,
                base = 1, by_name = false }
    W[it.id] = w
    ORDER_W[#ORDER_W + 1] = it.id
    return w
end

local function click(act)
    return function()
        local f = ACT[act]
        if f then
            RT.now = globals.realtime()
            local ok, err = pcall(f)
            if not ok then U.report("кнопка " .. tostring(act), err) end
        end
    end
end

local function reset_widgets()
    for k in pairs(W) do W[k] = nil end
    for i = #ORDER_W, 1, -1 do ORDER_W[i] = nil end
    for i = #VIS, 1, -1 do VIS[i] = nil end
    UIm.status = nil
end

function UIm.set_status(txt)
    if type(UIm.status) == "table" then UIm.status.label = "Пути: " .. txt end   -- Menu.lua: текст метки — поле виджета
    if UIm.rescan_el then                                                         -- нативное меню: результат в подсказке кнопки
        pcall(m_tooltip, UIm.rescan_el, UIm.rescan_tip .. " Последний результат: " .. txt .. ".")
    end
end

-- Зависимые элементы скрываются через :visible(). Состояние меняется только при смене настроек.
function UIm.refresh_vis()
    if not UIm.vis_ok then return end
    for i = 1, #VIS do
        local v = VIS[i]
        local show = v.fn(S) and true or false
        if show ~= v.shown then
            if pcall(m_visible, v.el, show) then
                v.shown = show
            else
                -- :visible() недоступен: возвращаем всё на экран и больше ничего не прячем
                UIm.vis_ok = false
                for j = 1, #VIS do
                    if VIS[j].shown == false then
                        pcall(m_visible, VIS[j].el, true)
                        VIS[j].shown = true
                    end
                end
                return
            end
        end
    end
end

-- Справочник не уточняет, с нуля или с единицы нумеруются пункты combo, поэтому база определяется
-- по самому элементу: значение 0 возможно только при нумерации с нуля, #items — только с единицы.
-- Возвращает 0, 1, "name" (get отдаёт текст пункта) или nil (определить не удалось).
local function combo_probe(el, n)
    local ok, cur = pcall(m_get, el)
    if not ok or cur == nil then return nil end
    if type(cur) == "string" then return "name" end
    if type(cur) ~= "number" then return nil end
    local zero, top = (cur == 0), (cur == n)
    if not zero and not top then
        if pcall(m_set, el, 0) then
            local ok0, v0 = pcall(m_get, el)
            zero = ok0 and v0 == 0
        end
        if pcall(m_set, el, n) then
            local okn, vn = pcall(m_get, el)
            top = okn and vn == n
        end
        pcall(m_set, el, cur)
    end
    if zero and not top then return 0 end
    if top and not zero then return 1 end
    return nil
end

local function native_item(g, it)
    local t = it.t
    local ok, el
    if t == "check" then
        ok, el = pcall(g.checkbox, g, it.name, it.def)
    elseif t == "slider" then
        ok, el = pcall(g.slider_int, g, it.name, it.lo, it.hi, it.def, it.fmt or "%d")
    elseif t == "combo" then
        -- Без default_index: тогда первое чтение — это номер первого пункта (0 или 1), см. combo_probe.
        ok, el = pcall(g.combo, g, it.name, it.items)
    elseif t == "color" then
        ok, el = pcall(g.color, g, it.name, it.def, true)
    elseif t == "button" then
        ok, el = pcall(g.button, g, it.name, click(it.act))
    elseif t == "key" then
        ok, el = pcall(g.keybind, g, it.name, 0)
        if ok and el then B[it.bind] = el end
    elseif t == "status" then
        ok, el = pcall(g.label, g, "Пути при загрузке: " .. UIm.boot_status)
    elseif t == "text" then
        local lines = U.wrap(it.text, K.WRAP_NATIVE)
        for i = 1, #lines do pcall(g.label, g, lines[i]) end
        return
    else
        return
    end
    if not ok or not el then
        U.say("элемент меню «" .. tostring(it.name or t) .. "» не создан: " .. tostring(el))
        return
    end
    if it.id and t ~= "button" then
        local w = mk(it, el)
        if t == "combo" then
            if UIm.combo_base == nil then UIm.combo_base = combo_probe(el, #it.items) end
            if UIm.combo_base == "name" then w.by_name = true
            elseif UIm.combo_base == 0 then w.base = 0 end
            Settings.set(it.id, it.def)             -- пункт по умолчанию ставится уже в правильной нумерации
        end
    end
    if it.tip then pcall(m_tooltip, el, it.tip) end
    if it.vis then VIS[#VIS + 1] = { el = el, fn = it.vis, shown = true } end
    if it.act == "rescan" then UIm.rescan_el, UIm.rescan_tip = el, it.tip end
end

-- Нативное меню: две вкладки, группы по смыслу, зависимые элементы прячутся, у всего есть подсказки.
function UIm.native()
    local pages, groups = {}, {}
    for ti = 1, #SCHEMA do
        local ts = SCHEMA[ti]
        local tab = pages[ts.page]
        if not tab then
            tab = ui.tab(ts.page == 1 and "0x" or "0x · Вид и сервис")
            pages[ts.page] = tab
        end
        for si = 1, #ts.sections do
            local sec = ts.sections[si]
            local gname = sec.group or sec.title
            local gkey = ts.page .. "/" .. gname
            local g = groups[gkey]
            if not g then
                g = tab:group(gname)
                groups[gkey] = g
            end
            if sec.group and sec.div ~= false then  -- секция внутри общей группы идёт под разделителем
                local ok, d = pcall(g.divider, g, sec.title)
                if ok and d and sec.vis then VIS[#VIS + 1] = { el = d, fn = sec.vis, shown = true } end
            end
            for ii = 1, #sec.items do native_item(g, sec.items[ii]) end
        end
    end
    return true
end

-- Menu.lua не умеет рисовать бинды, поэтому в этом режиме они живут в нативной вкладке.
function UIm.binds()
    local ok, err = pcall(function()
        local g = ui.tab("0x"):group("Бинды")
        for ti = 1, #SCHEMA do
            for si = 1, #SCHEMA[ti].sections do
                local items = SCHEMA[ti].sections[si].items
                for ii = 1, #items do
                    local it = items[ii]
                    if it.t == "key" then
                        local el = g:keybind(it.name, 0)
                        B[it.bind] = el
                        pcall(m_tooltip, el, it.tip)
                    end
                end
            end
        end
        g:label("Остальные настройки — в панели 0x (Menu.lua) рядом с меню.")
    end)
    if not ok then U.say("нативные бинды недоступны: " .. tostring(err)) end
end

local function vibe_item(tab, it)
    local t = it.t
    if t == "check" then
        mk(it, tab:checkbox(it.id, it.name, it.def))
    elseif t == "slider" then
        local pat, zero, lo = it.fmt or "%d", it.zero, it.lo
        mk(it, tab:slider(it.id, it.name, it.def, it.lo, it.hi, 1, function(v)
            local n = floor(v + 0.5)
            if zero and n <= lo then return zero end
            return s_format(pat, n)
        end))
    elseif t == "combo" then
        mk(it, tab:combo(it.id, it.name, it.items, it.def))
    elseif t == "color" then
        mk(it, tab:colorpicker(it.id, it.name, it.def))
    elseif t == "button" then
        tab:button(it.id, it.name, click(it.act))
    elseif t == "status" then
        UIm.status = tab:label("Пути: " .. UIm.boot_status)
    elseif t == "text" then
        local lines = U.wrap(it.text, K.WRAP)
        for i = 1, #lines do tab:label(lines[i]) end
    end
    -- t == "key": бинды создаются в нативной вкладке (UIm.binds)
end

function UIm.vibe()
    if type(VibeUI) ~= "table" or type(VibeUI.new) ~= "function" then
        return false, "Menu.lua не подключён"
    end
    local menu = VibeUI.new({ title = "0x", subtitle = "точность ragebot · v" .. VERSION, width = 400, height = 540 })
    for ti = 1, #SCHEMA do
        local ts = SCHEMA[ti]
        local tab = menu:tab(ts.tab)
        for si = 1, #ts.sections do
            local sec = ts.sections[si]
            if si == 1 and tab._current then
                tab._current.title = sec.title
            else
                tab:section(sec.title)
            end
            if sec.hint then
                local lines = U.wrap(sec.hint, K.WRAP)
                for i = 1, #lines do tab:label(lines[i]) end
            end
            for ii = 1, #sec.items do vibe_item(tab, sec.items[ii]) end
        end
    end
    UIm.menu = menu
    return true
end

-- Подключение Menu.lua к отрисовке: сначала штатный show(); методы проверяются, а не угадываются.
function UIm.attach(menu)
    if type(menu.show) == "function" then pcall(menu.show, menu) end
    if rawget(menu, "_registered") == true then return true, "show" end
    for _, name in ipairs({ "register", "init", "start" }) do
        local fn = menu[name]
        if type(fn) == "function" then
            local ok = pcall(fn, menu)
            if ok and rawget(menu, "_registered") == true then return true, name end
        end
    end
    for _, name in ipairs({ "render", "draw", "paint" }) do
        local fn = menu[name]
        if type(fn) == "function" then
            RT.menu_draw = function() fn(menu) end
            return true, "paint:" .. name
        end
    end
    return false, "в Menu.lua не найден метод показа или отрисовки"
end

function UIm.boot()
    if type(VibeUI) == "table" then
        local why
        local ok, res, reason = pcall(UIm.vibe)
        if ok and res == true then
            local ok2, how = UIm.attach(UIm.menu)
            if ok2 then
                UIm.mode = "Menu.lua (" .. tostring(how) .. ")"
                UIm.binds()
                return true
            end
            why = tostring(how)
        else
            why = tostring(ok and reason or res)
        end
        reset_widgets()
        UIm.menu = nil
        U.say("Menu.lua не используется: " .. why .. ". Строю нативное меню.")
    end
    local ok, res = pcall(UIm.native)
    if ok and res == true then
        UIm.mode = "нативное меню"
        return true
    end
    -- Что успело построиться, продолжает работать; остальные настройки остаются по умолчанию.
    UIm.mode = (#ORDER_W > 0) and "нативное меню (частично)" or "без меню (значения по умолчанию)"
    U.say("меню построено не полностью: " .. tostring(res))
    return false
end

----------------------------------------------------------------------------
-- 9. Индикатор
----------------------------------------------------------------------------
Draw.font, Draw.a, Draw.rows, Draw.nrows = nil, 0, {}, 0
Draw.w, Draw.h, Draw.pad, Draw.rh, Draw.th, Draw.tw, Draw.size = 0, 0, 10, 18, 14, 14, 0
Draw.ver, Draw.paused = "v" .. VERSION, nil
Draw.memo, Draw.memo_n = {}, 0
Draw.pal, Draw.qa, Draw.ar, Draw.ag, Draw.ab = nil, -1, -1, -1, -1

-- Все строки, которые может показать индикатор: по ним один раз считается постоянная ширина панели.
local IND_KEYS = { "РЕЖИМ", "HC", "DMG", "SAFE", "BAIM", "STRICT", "ЦЕЛЬ" }
local IND_VALS = { "ПАУЗА", "100%", "130", "ON", "LETHAL", "100 HP" }

function Draw.init()
    local ok, f = pcall(render.font, "Segoe UI", 13)
    if ok and f then
        local ok2, loaded = pcall(m_loaded, f)
        if ok2 and loaded then Draw.font = f end
    end
    -- Палитра создаётся один раз; дальше меняются только поля цветов.
    Draw.pal = {
        bg = color(10, 11, 17, 0), line = color(255, 255, 255, 0),
        acc = color(140, 148, 255, 0), acc_dim = color(140, 148, 255, 0),
        key = color(122, 126, 146, 0), val = color(236, 238, 246, 0),
        good = color(120, 220, 160, 0), warn = color(255, 190, 96, 0),
    }
end

function Draw.text(x, y, col, str, size)
    if Draw.font then
        render.text(x, y, col, str, "", size, Draw.font)
    else
        render.text(x, y, col, str, "", size)
    end
end

function Draw.measure(str, size)
    local ok, w, h
    if Draw.font then
        ok, w, h = pcall(render.text_size, str, "", size, Draw.font)
    else
        ok, w, h = pcall(render.text_size, str, "", size)
    end
    if ok and type(w) == "number" then return w, (type(h) == "number") and h or size end
    return U.utf8_len(str) * size * 0.55, size
end

local function text_w(str)                          -- ширина строки текущим размером, с кэшем
    local w = Draw.memo[str]
    if not w then
        if Draw.memo_n >= K.MEMO_MAX then Draw.memo, Draw.memo_n = {}, 0 end
        w = Draw.measure(str, Draw.size)
        Draw.memo[str] = w
        Draw.memo_n = Draw.memo_n + 1
    end
    return w
end

-- Геометрия зависит только от размера текста и считается при его смене.
function Draw.layout(size)
    Draw.size, Draw.memo, Draw.memo_n = size, {}, 0
    local kw, vw = 0, 0
    for i = 1, #IND_KEYS do kw = max(kw, text_w(IND_KEYS[i])) end
    for i = 1, #IND_VALS do vw = max(vw, text_w(IND_VALS[i])) end
    for i = 1, #ST_NAME do vw = max(vw, text_w(ST_NAME[i])) end
    local pad = floor(size * 0.8)
    local tw, th = Draw.measure("0x", size + 2)
    local vwid = Draw.measure(Draw.ver, size - 2)
    Draw.pad, Draw.rh, Draw.th, Draw.tw = pad, floor(size * 1.55), th, tw
    Draw.w = max(pad * 2 + kw + 18 + vw, pad * 2 + tw + 6 + vwid + 40)
end

local function put_row(i, key, value, kind)
    local r = Draw.rows[i]
    if not r then
        r = {}
        Draw.rows[i] = r
    end
    r[1], r[2], r[3], r[4] = key, value, kind, text_w(value)
    return i + 1
end

function Draw.rebuild()
    local n = 1
    n = put_row(n, "РЕЖИМ", RT.paused and "ПАУЗА" or (RT.state and ST_NAME[RT.state] or "—"), 1)
    if RT.hc then n = put_row(n, "HC", RT.hc .. "%", 1) end
    if RT.dmg then n = put_row(n, "DMG", tostring(RT.dmg), 1) end
    if RT.safe then n = put_row(n, "SAFE", "ON", 2) end
    if RT.baim then n = put_row(n, "BAIM", RT.baim, 3) end
    if RT.strict then n = put_row(n, "STRICT", "ON", 2) end
    if RT.pub_thp then n = put_row(n, "ЦЕЛЬ", RT.pub_thp .. " HP", 1) end
    Draw.nrows = n - 1
    Draw.h = Draw.pad * 2 + Draw.th + 8 + Draw.nrows * Draw.rh + (RT.hc and 8 or 0)
end

function Draw.palette(qa, acc)
    local P, k = Draw.pal, qa / 255
    local r, g, b = 140, 148, 255
    if type(acc) == "table" and type(acc.r) == "number" and type(acc.g) == "number" and type(acc.b) == "number" then
        r, g, b = acc.r, acc.g, acc.b
    end
    P.bg.a, P.line.a = floor(214 * k), floor(24 * k)
    P.acc.r, P.acc.g, P.acc.b, P.acc.a = r, g, b, qa
    P.acc_dim.r, P.acc_dim.g, P.acc_dim.b, P.acc_dim.a = r, g, b, floor(70 * k)
    P.key.a, P.val.a, P.good.a, P.warn.a = qa, qa, qa, qa
    Draw.qa, Draw.ar, Draw.ag, Draw.ab = qa, r, g, b
end

function Draw.paint()
    if not S.ind_on or not S.enable or not RT.in_game then
        Draw.a = 0
        return
    end
    local show = (RT.state ~= nil or RT.paused)
    local a = Draw.a
    if not show and a == 0 then return end
    a = a + ((show and 1 or 0) - a) * min(1, globals.frametime() * 10)
    if a < 0.02 then
        Draw.a = show and a or 0
        return
    end
    Draw.a = a
    if RT.sw <= 0 or RT.sh <= 0 then return end

    local size = floor(13 * S.ind_scale / 100 + 0.5)
    if size ~= Draw.size then
        Draw.layout(size)
        RT.ind_dirty = true
    end
    if RT.ind_dirty or RT.paused ~= Draw.paused then
        Draw.rebuild()
        Draw.paused = RT.paused
        RT.ind_dirty = false
    end
    local qa = floor(a * 255 + 0.5)
    local acc = S.ind_color
    if qa ~= Draw.qa or (type(acc) == "table" and (acc.r ~= Draw.ar or acc.g ~= Draw.ag or acc.b ~= Draw.ab)) then
        Draw.palette(qa, acc)
    end

    local P = Draw.pal
    local w, h, pad = Draw.w, Draw.h, Draw.pad
    local x = floor((RT.sw - w) * S.ind_x / 100)
    local y = floor((RT.sh - h) * S.ind_y / 100)

    render.rect_filled(x, y, w, h, P.bg, 7)
    render.rect(x, y, w, h, P.line, 7, 1)
    render.rect_filled(x + 1, y + 10, 2, h - 20, P.acc, 1)
    Draw.text(x + pad, y + pad - 1, P.acc, "0x", size + 2)
    Draw.text(x + pad + Draw.tw + 6, y + pad + 1, P.key, Draw.ver, size - 2)
    local ry = y + pad + Draw.th + 8
    render.line(x + pad, ry - 4, x + w - pad, ry - 4, P.line, 1)
    local rows = Draw.rows
    for i = 1, Draw.nrows do
        local row = rows[i]
        local col = P.val
        if row[3] == 2 then col = P.good elseif row[3] == 3 then col = P.warn end
        Draw.text(x + pad, ry, P.key, row[1], size)
        Draw.text(x + w - pad - row[4], ry, col, row[2], size)
        ry = ry + Draw.rh
    end
    if RT.hc then
        local bw = w - pad * 2
        render.rect_filled(x + pad, y + h - 9, bw, 3, P.acc_dim, 1)
        render.rect_filled(x + pad, y + h - 9, max(2, floor(bw * RT.hc / 100)), 3, P.acc, 1)
    end
end

----------------------------------------------------------------------------
-- 10. Колбэки событий и запуск
----------------------------------------------------------------------------
-- 0x неактивен на этом тике: вернуть значения ragebot; индикатор прячется (state = nil).
local function stand_down(keep_state)
    if not keep_state and RT.state ~= nil then
        RT.state, RT.ind_dirty = nil, true
    end
    RT.eval_at = 0
    Bind.release(false)
end

-- Раз в секунду: всё, что не обязано происходить каждый кадр.
local function housekeeping(now)
    RT.hk_t = now
    local ok, ig = pcall(engine.in_game)
    RT.in_game = (not ok) or ig ~= false
    local sw, sh = render.screen_size()
    if type(sw) == "number" and type(sh) == "number" and sw > 0 and sh > 0 then RT.sw, RT.sh = sw, sh end
    if RT.cfg_dirty and now - RT.cfg_t >= K.SAVE_DELAY then
        if #ORDER_W == 0 or Settings.save() then RT.cfg_dirty = false else RT.cfg_t = now + K.IO_RETRY end
    end
    Journal.flush(false)
    if RT.strikes > 0 and now - RT.strike_t > K.ERR_FORGIVE then RT.strikes = 0 end
end

-- Фоновые задачи: чтение меню, журнал, автосохранение. Выполняются из paint; если paint
-- не приходит дольше PAINT_TIMEOUT, их подхватывает createmove, чтобы настройки не «застыли».
local function background(now)
    if RT.sync_mode then                            -- отложенная правка виджета из createmove
        Settings.set("air_mode", RT.sync_mode)
        RT.sync_mode = false
    end
    Settings.poll(false)
    if Journal.add_dirty then Journal.flush(false) end
    if now - RT.hk_t >= K.HK_INTERVAL then housekeeping(now) end
end

local function on_createmove(cmd)
    local now = globals.realtime()
    RT.now, RT.cm_t = now, now
    RT.tick = RT.tick + 1
    if now - RT.paint_t > K.PAINT_TIMEOUT then background(now) end
    if RT.suspend_until then
        if now < RT.suspend_until then return end
        RT.suspend_until = nil
    end

    if not S.enable then
        if RT.paused then RT.paused, RT.ind_dirty = false, true end
        stand_down(false)
        return
    end
    if RT.menu_open and S.pause_menu then
        if not RT.paused then RT.paused, RT.ind_dirty = true, true end
        stand_down(true)
        return
    end
    if RT.paused then RT.paused, RT.ind_dirty = false, true end

    local lp = entity.local_pawn()
    if not lp or not lp:alive() then
        if RT.state ~= nil then Logic.reset() end
        stand_down(false)
        return
    end

    Logic.weapon(lp)
    local grp = RT.wgroup
    if not grp or not S[K.WPN_KEY[grp]] then
        stand_down(false)
        return
    end

    Logic.movement(lp, cmd)
    if RT.tick >= RT.eval_at then
        RT.eval_at = RT.tick + K.EVAL_TICKS
        Logic.eval_targets(lp)
    end
    Logic.decide(grp)
    if RT.tick % K.VERIFY_TICKS == 0 then Bind.verify() end
end

local function on_paint()
    local now = globals.realtime()
    RT.now, RT.paint_t = now, now
    background(now)
    -- createmove замолчал (выход с сервера, зависание симуляции): значения ragebot не должны остаться изменёнными.
    if now - RT.cm_t > K.CM_TIMEOUT and (RT.touched or RT.state ~= nil or RT.paused) then
        RT.paused = false
        Bind.release(false)
        Logic.reset()
    end
    if RT.menu_draw then RT.menu_draw() end
    Draw.paint()
end

local function on_menu_toggled(open)
    RT.now = globals.realtime()
    RT.menu_open = open and true or false
    RT.menu_evt_t = RT.now
    RT.poll_dt = RT.menu_open and K.POLL_OPEN or K.POLL_IDLE
    RT.snap_t = -1e9                                -- перечитать виджеты на ближайшем кадре
    if RT.menu_open then
        if S.pause_menu and S.enable then
            RT.paused, RT.ind_dirty = true, true
            Bind.release(false)
        end
        Journal.flush(true)                         -- пользователь у настроек ragebot: в файле не должно быть устаревших записей
    end
end

local function on_level()
    RT.now = globals.realtime()
    Bind.release(true)
    Logic.reset()
    Journal.flush(true)
end

local function on_unload()
    RT.now = globals.realtime()
    Bind.release(true)
    Journal.flush(true)
    if #ORDER_W > 0 then Settings.save() end
end

-- Серия ошибок: значения ragebot возвращаются, 0x приостанавливается и пробует снова.
-- Только после ERR_STRIKES приостановок подряд скрипт останавливается до перезагрузки.
local function trip(name)
    RT.strikes, RT.strike_t = RT.strikes + 1, RT.now
    pcall(Bind.release, true)
    pcall(Logic.reset)
    pcall(Journal.flush, true)
    RT.paused = false
    if RT.strikes >= K.ERR_STRIKES then
        RT.failed = true
        U.notify("Слишком много ошибок в «" .. name .. "»: 0x остановлен, значения ragebot возвращены. Исправьте причину и сделайте Save & Reload.")
    else
        RT.suspend_until = RT.now + K.ERR_COOLDOWN
        U.notify(s_format("Ошибки в «%s»: 0x приостановлен на %d с, значения ragebot возвращены.", name, K.ERR_COOLDOWN))
    end
end

-- Любая ошибка в колбэке перехватывается и не доходит до игры.
local function guard(name, fn)
    return function(arg)
        if RT.failed and name ~= "unload" then return end
        local ok, err = pcall(fn, arg)
        if ok then
            RT.errs[name] = 0
            return
        end
        U.report(name, err)
        local n = (RT.errs[name] or 0) + 1
        RT.errs[name] = n
        if n >= K.ERR_LIMIT then
            RT.errs[name] = 0
            trip(name)
        end
    end
end

local function boot()
    RT.now = globals.realtime()
    local ok_dt, dt = pcall(globals.interval)
    if ok_dt and type(dt) == "number" and dt > 0 then RT.g_tick = K.GRAVITY * dt end
    local sw, sh = render.screen_size()
    if type(sw) == "number" and type(sh) == "number" then RT.sw, RT.sh = sw, sh end

    Draw.init()
    local restored = Journal.restore()
    local scanned = Bind.scan()                     -- до меню: строка состояния сразу показывает результат
    UIm.boot_status = scanned and Bind.summary() or "config.keys недоступен"
    UIm.boot()
    if #ORDER_W > 0 then Settings.load() end
    Settings.poll(true)
    RT.cfg_dirty = false

    local ok, open = pcall(input.menu_open)
    RT.menu_open = ok and open == true
    RT.poll_dt = RT.menu_open and K.POLL_OPEN or K.POLL_IDLE

    events.on("createmove", guard("createmove", on_createmove))
    events.on("paint", guard("paint", on_paint))
    events.on("menu_toggled", guard("menu_toggled", on_menu_toggled))
    events.on("level_init", guard("level_init", on_level))
    events.on("level_shutdown", guard("level_shutdown", on_level))
    events.on("unload", guard("unload", on_unload))

    if restored > 0 then
        U.notify("Восстановлено значений ragebot после аварийного завершения: " .. restored)
    end
    U.say(s_format("v%s загружен · интерфейс: %s · пути: %s", VERSION, UIm.mode, Bind.summary()))
    if W.preset and W.preset.kind == "combo" and UIm.menu == nil then
        local cb = UIm.combo_base
        U.say("нумерация пунктов combo: " .. ((cb == 0 and "с нуля") or (cb == 1 and "с единицы")
              or (cb == "name" and "по имени пункта") or "не определена, принята с единицы"))
    end
    if scanned and Bind.total() == 0 then
        U.notify("0x: пути ragebot в config не найдены. Откройте «Связь с ragebot» и выведите пути в консоль.")
    else
        U.notify("0x v" .. VERSION .. " загружен")
    end
end

local boot_ok, boot_err = pcall(boot)
if not boot_ok then
    RT.failed = true
    pcall(Bind.release, true)
    U.say("ошибка запуска: " .. tostring(boot_err))
end
