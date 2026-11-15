-- @author 0x
--[[
    0x · v3.1
    Точность ragebot: стрельба в прыжке, летальный Body-Aim, hitchance по состоянию.
    Neverlose CS2 Lua API · LuaJIT 2.1 · режим Standard (Allow Insecure не нужен).
    Документация: https://github.com/PbLJk/neverlose-lua-api
    Интерфейс: Menu.lua (VibeUI). Сайт встраивает его при скачивании; если его нет,
    скрипт строит такое же нативное меню Neverlose.

    Как 0x управляет ragebot
      Отдельного ragebot-модуля в API нет, поэтому значения читаются и пишутся через
      config.get / config.set. Пути ищутся автоматически по config.keys (вкладка
      «Профили», кнопка «Пересканировать»). Если автопоиск ошибся, впишите пути
      в CUSTOM_PATHS ниже. Исходные значения запоминаются, пишутся в журнал (db) и
      возвращаются при выключении, паузе, смерти, смене оружия, смене карты и выгрузке.
]]

--@@MENU_LIB_BEGIN
local VibeUI = nil
--@@MENU_LIB_END

----------------------------------------------------------------------------
-- 0. Локальные ссылки и константы
----------------------------------------------------------------------------
local type, pairs, ipairs, tostring, tonumber, pcall, print, select, next, rawget =
      type, pairs, ipairs, tostring, tonumber, pcall, print, select, next, rawget
local floor, abs, sqrt, max, min = math.floor, math.abs, math.sqrt, math.max, math.min
local s_lower, s_find, s_format, s_gsub, s_gmatch =
      string.lower, string.find, string.format, string.gsub, string.gmatch
local t_concat, t_sort = table.concat, table.sort
local band = bit.band

local VERSION     = "3.1.0"
local DB_SETTINGS = "0x_v31_settings"
local DB_JOURNAL  = "0x_v31_journal"

-- Ручные пути config, если автопоиск ошибается. Пример: hc = { "путь.из.консоли" }
local CUSTOM_PATHS = { hc = {}, dmg = {}, safe = {}, baim = {}, hitbox = {} }
-- Если Safepoint в вашем ragebot — выпадающий список, это индекс пункта «Force».
local SAFE_COMBO_VALUE = 2

local K = {
    EVAL_TICKS = 4,        -- период пересчёта цели и летальности
    VERIFY_TICKS = 16,     -- период сверки записанных значений с config
    WEAPON_TICKS = 64,     -- период перепроверки класса оружия
    FLUSH_TICKS = 64,      -- период сброса журнала на диск
    SNAP_INTERVAL = 0.05,  -- период чтения настроек меню, сек
    MAX_CANDS = 48,        -- предел путей на один параметр
    MAX_TARGETS = 3,       -- сколько ближайших к прицелу целей проверять трассировкой
    HOLD_TICKS = 12,       -- удержание решения Body-Aim (против мерцания)
    MOVE_EPS = 5,          -- порог «движения», u/s
    ERR_LIMIT = 25,        -- ошибок подряд до аварийной остановки
    EYE_OFFSET = 46,       -- высота точки прицеливания над origin цели
    HB_TTL = 256,          -- время жизни кэша хитбоксов, тиков
    HG_HEAD = 1, HG_CHEST = 2, HG_STOMACH = 3,
    FL_DUCKING = 2,
    BTN_SPEED = (buttons and buttons.speed) or 65536,
    WRAP = 46,             -- ширина строки подсказок в Menu.lua, символов
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
local S = {}                                  -- снимок настроек (горячий путь)
local RT = {                                  -- рабочее состояние
    tick = 0, snap_t = -1, hk_t = 0, sig_t = 0,
    air_ticks = 0, raw_air = false, land_soon = false, sim_fail = 0,
    state = nil, speed = 0, vz = 0,
    wgroup = nil, waddr = nil, wtick = -9999,
    t_hp = nil, t_air = false, t_move = false,
    baim_reason = nil, baim_until = 0, base_hc = nil, base_dmg = nil,
    k_strict = false, k_baim = false, k_dmg = false,
    hc = nil, dmg = nil, safe = false, baim = nil, strict = false,
    touched = false, paused = false, menu_open = false, failed = false,
    errs = {}, ev = {}, ind_dirty = true,
    last_preset = 1, cur_sig = nil, saved_sig = nil, menu_draw = nil,
}
local W, ORDER_W = {}, {}                     -- элементы меню: id -> дескриптор
local B = {}                                  -- нативные бинды
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
    local now = globals.realtime()
    if msg ~= rep.last or now - rep.t > 5 then
        rep.last, rep.t = msg, now
        U.say("ошибка в " .. where .. ": " .. msg)
    end
end

----------------------------------------------------------------------------
-- 3. Схема меню (одна на Menu.lua и нативный запасной вариант) и профили
----------------------------------------------------------------------------
local WPN_CHECKS = {}
for i = 1, #WPN_ITEMS do
    WPN_CHECKS[i] = { id = K.WPN_KEY[i], t = "check", name = WPN_ITEMS[i], def = (i <= 5),
                      tip = "Включить 0x для этой группы оружия." }
end

local SCHEMA = {
    { tab = "Ядро", sections = {
        { title = "Главное",
          hint = "Всё, что 0x меняет в ragebot, возвращается при паузе, смерти, смене оружия и выгрузке скрипта.",
          items = {
            { id = "enable", t = "check", name = "Включить 0x", def = true,
              tip = "Главный переключатель. При выключении все значения ragebot мгновенно возвращаются к вашим." },
            { id = "pause_menu", t = "check", name = "Пауза при открытом меню", def = true,
              tip = "Пока открыто меню Neverlose, 0x ничего не меняет. Можно спокойно настраивать ragebot." },
            { id = "preset", t = "combo", name = "Профиль", def = 2,
              items = { "Свой", "Баланс", "Агрессивный", "Консервативный" },
              tip = "Баланс — универсально. Агрессивный — ниже hitchance, быстрее огонь. Консервативный — выше точность. «Свой» ничего не меняет." },
        } },
        { title = "Оружие",
          hint = "0x работает только с отмеченными группами. Для остальных настройки ragebot не трогаются.",
          items = WPN_CHECKS },
        { title = "Бинды",
          hint = "Клавиши назначаются в нативной вкладке «0x»: Strict, Body-Aim и оверрайд урона.",
          items = {
            { id = "dmg_bind_val", t = "slider", name = "Мин. урон по бинду", def = 18, lo = 1, hi = 130, fmt = "%d HP",
              tip = "Значение мин. урона, пока удерживается бинд «Оверрайд мин. урона». Удобно для добивания и простреливания стен." },
        } },
    } },
    { tab = "Воздух", sections = {
        { title = "Стрельба в прыжке",
          hint = "В воздухе разброс больше. 0x ставит свои hitchance и урон, только пока вы летите.",
          items = {
            { id = "air_on", t = "check", name = "Оптимизатор прыжка", def = true,
              tip = "Применяет воздушные значения hitchance, урона и safepoint, пока вы в прыжке." },
            { id = "air_mode", t = "combo", name = "Детекция полёта", def = 1,
              items = { "Земля + верт. скорость", "Только флаг земли", "С предсказанием посадки" },
              tip = "1 — надёжный, игнорирует ступеньки. 2 — самый быстрый. 3 — ещё и предсказывает посадку через engine.simulate." },
            { id = "air_thr", t = "slider", name = "Порог верт. скорости", def = 22, lo = 5, hi = 220, fmt = "%d u/s",
              tip = "С какой вертикальной скоростью состояние считается прыжком (режим 1). Больше — меньше ложных срабатываний на ступенях." },
            { id = "land_ticks", t = "slider", name = "Предсказание посадки", def = 3, lo = 1, hi = 8, fmt = "%d тик.",
              tip = "Только режим 3: за сколько тиков до касания земли вернуть наземный профиль." },
        } },
        { title = "Пик прыжка",
          hint = "На пике вертикальная скорость близка к нулю, разброс минимален, hitchance можно снизить.",
          items = {
            { id = "apex_on", t = "check", name = "Приоритет пика", def = true,
              tip = "На верхней точке прыжка используется отдельный hitchance." },
            { id = "apex_win", t = "slider", name = "Окно пика", def = 42, lo = 10, hi = 110, fmt = "≤ %d u/s",
              tip = "Пик — когда модуль вертикальной скорости не больше этого значения." },
        } },
        { title = "Значения в воздухе",
          hint = "Ориентир для SSG 08: hitchance 65–78, урон 45–65.",
          items = {
            { id = "air_hc", t = "slider", name = "Hitchance в полёте", def = 70, lo = 1, hi = 100, fmt = "%d%%",
              tip = "Требуемый hitchance при наборе высоты и падении." },
            { id = "apex_hc", t = "slider", name = "Hitchance на пике", def = 58, lo = 1, hi = 100, fmt = "%d%%",
              tip = "Требуемый hitchance на пике прыжка. Обычно ниже, чем в полёте." },
            { id = "air_dmg", t = "slider", name = "Мин. урон в полёте", def = 50, lo = 1, hi = 130, fmt = "%d HP",
              tip = "Мин. урон при стрельбе в прыжке." },
            { id = "air_safe", t = "check", name = "Safepoint в полёте", def = true,
              tip = "Принудительно включает safepoint, пока вы в воздухе." },
        } },
    } },
    { tab = "Body-Aim", sections = {
        { title = "Летальный корпус",
          hint = "Если выстрел в корпус убивает, голова не нужна: 0x убирает её из целей, попасть проще.",
          items = {
            { id = "baim_on", t = "check", name = "Умный Body-Aim", def = true,
              tip = "Включает расчёт урона по корпусу трассировкой и исключает голову, когда это выгодно." },
            { id = "baim_lethal", t = "check", name = "Корпус убивает с 1 выстрела", def = true,
              tip = "Урон по корпусу не меньше HP цели плюс запас. Голова исключается." },
            { id = "baim_2x", t = "check", name = "Корпус убивает за 2 выстрела", def = false,
              tip = "Два попадания в корпус убивают, а голова с одного выстрела — нет. Полезно для Deagle и пистолетов." },
            { id = "baim_margin", t = "slider", name = "Запас урона", def = 2, lo = 0, hi = 30, fmt = "%d HP",
              tip = "Урон по корпусу должен превышать HP цели минимум на столько. Больше — осторожнее." },
        } },
        { title = "Дополнительно",
          hint = "Цель выбирается по близости к прицелу среди тех, кого можно прострелить.",
          items = {
            { id = "baim_hp_on", t = "check", name = "Корпус при низком HP", def = false,
              tip = "Если у цели HP ниже порога, стрельба идёт по корпусу." },
            { id = "baim_hp", t = "slider", name = "Порог HP", def = 40, lo = 1, hi = 100, fmt = "%d HP",
              tip = "Порог для режима «Корпус при низком HP»." },
            { id = "baim_fov", t = "slider", name = "Радиус поиска цели", def = 60, lo = 5, hi = 180, fmt = "%d°",
              tip = "Угол вокруг прицела, в котором ищется цель для Body-Aim, поправок и умного урона." },
            { id = "dmg_cap", t = "check", name = "Мин. урон не выше HP цели", def = true,
              tip = "Если HP цели ниже вашего мин. урона, порог снижается до HP, и добивающий выстрел не блокируется." },
        } },
    } },
    { tab = "Точность", sections = {
        { title = "Hitchance по состоянию",
          hint = "Значение «Не менять» оставляет ваш hitchance. Разные состояния дают разный разброс.",
          items = {
            { id = "hc_on", t = "check", name = "Hitchance по состоянию", def = true,
              tip = "Свой hitchance для стоя, медленного шага, бега и приседа. В воздухе действуют значения вкладки «Воздух»." },
            { id = "hc_stand", t = "slider", name = "Стоя", def = 70, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять",
              tip = "Hitchance, когда вы стоите. 0 — не менять." },
            { id = "hc_slow", t = "slider", name = "Медленный шаг", def = 65, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять",
              tip = "Hitchance при ходьбе с зажатым Shift. 0 — не менять." },
            { id = "hc_move", t = "slider", name = "Бег", def = 55, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять",
              tip = "Hitchance при обычном беге. 0 — не менять." },
            { id = "hc_duck", t = "slider", name = "Присед", def = 72, lo = 0, hi = 100, fmt = "%d%%", zero = "Не менять",
              tip = "Hitchance в приседе. 0 — не менять." },
        } },
        { title = "Поправки",
          hint = "Поправки действуют, когда в прицеле есть цель. Strict включается биндом.",
          items = {
            { id = "hc_tgt_air", t = "slider", name = "Цель в воздухе", def = -8, lo = -30, hi = 30, fmt = "%+d%%",
              tip = "Добавка к hitchance, если цель в прыжке. Отрицательное значение облегчает попадание." },
            { id = "hc_tgt_move", t = "slider", name = "Цель бежит", def = 0, lo = -30, hi = 30, fmt = "%+d%%",
              tip = "Добавка к hitchance, если цель движется." },
            { id = "strict_bonus", t = "slider", name = "Прибавка в Strict", def = 12, lo = 0, hi = 40, fmt = "+%d%%",
              tip = "Пока активен бинд Strict: hitchance растёт на это значение и включается safepoint." },
        } },
    } },
    { tab = "Вид", sections = {
        { title = "Индикатор",
          hint = "Показывает состояние и активные оверрайды. Значения обновляются только при изменении.",
          items = {
            { id = "ind_on", t = "check", name = "Показывать индикатор", def = true,
              tip = "Панель с состоянием, hitchance, уроном и причиной Body-Aim." },
            { id = "ind_x", t = "slider", name = "Позиция X", def = 1, lo = 0, hi = 100, fmt = "%d%%",
              tip = "Положение панели по горизонтали." },
            { id = "ind_y", t = "slider", name = "Позиция Y", def = 40, lo = 0, hi = 100, fmt = "%d%%",
              tip = "Положение панели по вертикали." },
            { id = "ind_scale", t = "slider", name = "Размер", def = 100, lo = 80, hi = 150, fmt = "%d%%",
              tip = "Масштаб текста индикатора." },
            { id = "ind_color", t = "color", name = "Цвет акцента", def = color(140, 148, 255, 255),
              tip = "Цвет заголовка и полосок индикатора." },
        } },
        { title = "Сервис",
          hint = "Журнал печатает каждую запись в config в консоль Lua, удобно для проверки.",
          items = {
            { id = "notif", t = "check", name = "Уведомления", def = true,
              tip = "Сообщения о загрузке, профилях и ошибках." },
            { id = "debug", t = "check", name = "Журнал записей в консоль", def = false,
              tip = "Выводит в консоль путь, старое и новое значение при каждой записи." },
        } },
    } },
    { tab = "Профили", sections = {
        { title = "Настройки",
          hint = "Изменения сохраняются автоматически через пару секунд после правки.",
          items = {
            { id = "btn_save", t = "button", name = "Сохранить сейчас", act = "save",
              tip = "Сразу записать настройки на диск." },
            { id = "btn_load", t = "button", name = "Загрузить сохранённые", act = "load",
              tip = "Вернуть настройки, сохранённые ранее." },
            { id = "btn_reset", t = "button", name = "Сбросить к стандартным", act = "reset",
              tip = "Вернуть все значения 0x к заводским." },
        } },
        { title = "Связь с ragebot",
          hint = "0x ищет пути hitchance, урона, safepoint и хитбоксов в config автоматически.",
          items = {
            { id = "btn_rescan", t = "button", name = "Пересканировать config", act = "rescan",
              tip = "Заново найти пути параметров ragebot." },
            { id = "btn_dump", t = "button", name = "Вывести пути в консоль", act = "dump",
              tip = "Печатает найденные пути с текущими значениями. Нужно, чтобы проверить привязку." },
            { t = "status", text = "Пути: ещё не сканировались" },
        } },
    } },
    { tab = "Справка", sections = {
        { title = "Принцип работы", items = {
            { t = "text", text = "0x не стреляет за вас. Он на лету меняет настройки вашего ragebot (hitchance, мин. урон, safepoint, хитбоксы) и возвращает их обратно." },
            { t = "text", text = "Исходные значения запоминаются и возвращаются при выключении, паузе, смерти, смене оружия и карты, выгрузке скрипта." },
            { t = "text", text = "Запись идёт только при изменении значения. Раз в ~0.25 с значения сверяются с config." },
        } },
        { title = "Состояния", items = {
            { t = "text", text = "СТОЯ — скорость около нуля. ШАГ — движение с Shift. БЕГ — обычное движение. ПРИСЕД — флаг приседа." },
            { t = "text", text = "ВОЗДУХ — вы в прыжке. ПИК — верхняя точка прыжка, где вертикальная скорость не больше окна пика." },
        } },
        { title = "Body-Aim", items = {
            { t = "text", text = "LETHAL — корпус убивает с одного выстрела. 2X — убивает двумя, а голова не убивает одним. HP — у цели мало HP. KEY — ваш бинд." },
            { t = "text", text = "Голова исключается из хитбоксов, пока причина активна. Решение удерживается 12 тиков, чтобы не мерцало." },
        } },
        { title = "Бинды", items = {
            { t = "text", text = "STRICT: hitchance плюс прибавка и принудительный safepoint. BODY-AIM: только корпус. МИН. УРОН: значение со слайдера «Мин. урон по бинду»." },
        } },
        { title = "Если что-то не работает", items = {
            { t = "text", text = "1. «Профили» → «Пересканировать», затем «Вывести пути в консоль». В консоли Lua будут пути config и их значения." },
            { t = "text", text = "2. Если путей нет или они не те, впишите нужные в CUSTOM_PATHS в начале скрипта." },
            { t = "text", text = "3. Включите «Журнал записей» во вкладке «Вид», чтобы видеть каждое изменение." },
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
Journal.data, Journal.dirty = {}, false

function Journal.add(rec)
    Journal.data[rec.path] = U.copy(rec.orig)
    Journal.dirty = true
end

function Journal.remove(path)
    if Journal.data[path] ~= nil then
        Journal.data[path] = nil
        Journal.dirty = true
    end
end

function Journal.clear()
    if next(Journal.data) ~= nil then
        for k in pairs(Journal.data) do Journal.data[k] = nil end
        Journal.dirty = true
    end
end

function Journal.flush(force)
    if not Journal.dirty and not force then return end
    Journal.dirty = false
    pcall(db.save, DB_JOURNAL, Journal.data)
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
    sl.id, sl.recs, sl.n, sl.seen = ORDER[i], {}, 0, {}
    sl.w, sl.g, sl.force, sl.custom = nil, 0, false, false
end

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

function Bind.add_path(sl, path, forced)
    if sl.seen[path] then return false end
    local v = cfg_get(path)
    if v == nil then
        if forced then U.say(sl.title .. ": путь «" .. path .. "» не найден в config") end
        return false
    end
    if not sl.ok(v) then
        if forced then U.say(sl.title .. ": путь «" .. path .. "» имеет неподходящий тип (" .. type(v) .. ")") end
        return false
    end
    sl.seen[path] = true
    sl.n = sl.n + 1
    sl.recs[sl.n] = { path = path, tags = tags_for(s_lower(path)), orig = NONE, last = nil,
                      bad = 0, mism = 0, dead = false, warned = false }
    return true
end

function Bind.scan()
    Bind.release("scan")
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        sl.recs, sl.n, sl.seen, sl.w, sl.g, sl.force, sl.custom = {}, 0, {}, nil, 0, false, false
        local list = CUSTOM_PATHS[sl.id]
        if type(list) == "table" and #list > 0 then
            sl.custom = true
            for j = 1, #list do Bind.add_path(sl, list[j], true) end
        end
    end
    local ok, keys = pcall(config.keys)
    if not ok or type(keys) ~= "table" then
        U.say("config.keys недоступен: " .. tostring(keys) .. ". Впишите пути в CUSTOM_PATHS.")
        return false
    end
    for i = 1, #keys do
        local path = keys[i]
        if type(path) == "string" then
            local low = s_lower(path)
            if not U.any_match(low, GENERIC_EXCLUDE) then
                for j = 1, #ORDER do
                    local sl = SL[ORDER[j]]
                    if not sl.custom and sl.n < K.MAX_CANDS
                       and U.any_match(low, sl.patterns) and not U.any_match(low, sl.exclude) then
                        Bind.add_path(sl, path, false)
                    end
                end
            end
        end
    end
    return true
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
            U.say(s_format("   %s = %s  [группы оружия: %s]%s", r.path, U.fmt(cfg_get(r.path)), tg,
                           r.dead and "  ОТКЛЮЧЁН" or ""))
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

-- target: nil (вернуть оригинал) | число/значение | TRANSFORM
function Bind.push(sl, rec, target)
    if rec.dead then return end
    if target == nil then
        if rec.orig ~= NONE then
            if rec.last ~= nil and not U.same(rec.last, rec.orig) then
                if cfg_set(rec.path, rec.orig) then
                    if S.debug then U.say(s_format("%s <- %s (возврат)", rec.path, U.fmt(rec.orig))) end
                else
                    rec.bad = rec.bad + 1
                    sl.force, RT.touched = true, true
                    if rec.bad >= 3 then
                        rec.dead = true
                        U.say("путь отключён (не удалось вернуть значение): " .. rec.path)
                    end
                    return
                end
            end
            rec.orig, rec.last = NONE, nil
        end
        return
    end
    if rec.orig == NONE then
        local cur = cfg_get(rec.path)
        if cur == nil then
            rec.bad = rec.bad + 1
            if rec.bad >= 3 then rec.dead = true end
            return
        end
        rec.orig = U.copy(cur)
        Journal.add(rec)
    end
    local val = target
    if target == TRANSFORM then
        val = sl.transform(rec.orig)
        if val == nil then
            if not rec.warned then
                rec.warned = true
                U.say("формат значения не поддержан, путь пропущен: " .. rec.path .. " = " .. U.fmt(rec.orig))
            end
            val = rec.orig
        end
    end
    if U.same(rec.last, val) then return end
    if U.same(val, rec.orig) then
        rec.last = U.copy(val)
        RT.touched = true
        return
    end
    if cfg_set(rec.path, val) then
        if S.debug then U.say(s_format("%s: %s -> %s", rec.path, U.fmt(rec.orig), U.fmt(val))) end
        rec.last, rec.bad = U.copy(val), 0
        RT.touched = true
    else
        rec.bad = rec.bad + 1
        sl.force = true
        if rec.bad >= 3 then
            rec.dead = true
            U.say("путь отключён (запись отклонена): " .. rec.path)
        end
    end
end

function Bind.apply(sl, want, group)
    if sl.n == 0 then return end
    if want == nil then group = 0 end
    if sl.w == want and sl.g == group and not sl.force then return end
    sl.w, sl.g, sl.force = want, group, false
    local recs = sl.recs
    for i = 1, sl.n do
        local rec = recs[i]
        local target = nil
        if want ~= nil and (rec.tags == nil or rec.tags[group]) then target = want end
        Bind.push(sl, rec, target)
    end
end

-- Сверка: если значение изменил пользователь или другой код, берём его как новый оригинал.
function Bind.verify()
    for i = 1, #ORDER do
        local sl = SL[ORDER[i]]
        for j = 1, sl.n do
            local rec = sl.recs[j]
            if not rec.dead and rec.last ~= nil then
                local cur = cfg_get(rec.path)
                if cur ~= nil then
                    if U.same(cur, rec.last) then
                        rec.mism = 0
                    else
                        rec.mism = rec.mism + 1
                        if rec.mism > 3 then
                            rec.dead = true
                            cfg_set(rec.path, rec.orig)
                            rec.orig, rec.last = NONE, nil
                            Journal.remove(rec.path)
                            U.say("путь отключён (значение меняется другим кодом): " .. rec.path)
                        else
                            rec.orig, rec.last = U.copy(cur), nil
                            Journal.add(rec)
                            sl.force = true
                        end
                    end
                end
            end
        end
    end
end

function Bind.release(reason)
    if RT.touched then
        RT.touched = false
        for i = 1, #ORDER do Bind.apply(SL[ORDER[i]], nil, 0) end
        RT.hc, RT.dmg, RT.safe, RT.baim, RT.strict = nil, nil, false, nil, false
        RT.ind_dirty = true
    end
    Journal.clear()
end

function Journal.restore()
    local ok, saved = pcall(db.load, DB_JOURNAL, nil)
    if not ok or type(saved) ~= "table" then return 0 end
    local n, any = 0, false
    for path, val in pairs(saved) do
        any = true
        if type(path) == "string" and val ~= nil and cfg_get(path) ~= nil then
            if cfg_set(path, val) then n = n + 1 end
        end
    end
    if any then pcall(db.save, DB_JOURNAL, {}) end
    return n
end

----------------------------------------------------------------------------
-- 6. Логика: состояние игрока, оружие, цели, решения
----------------------------------------------------------------------------
local HB = { cache = {}, n = 0 }

function Logic.reset()
    HB.cache, HB.n = {}, 0
    RT.waddr, RT.wgroup, RT.state = nil, nil, nil
    RT.t_hp, RT.t_air, RT.t_move, RT.baim_reason = nil, false, false, nil
    RT.land_soon, RT.air_ticks, RT.raw_air = false, 0, false
    RT.ind_dirty = true
end

function Logic.classify(w)
    local ok, info = pcall(w.weapon_info, w)
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
            RT.ind_dirty = true
        end
    end
end

function Logic.predict()
    local ok, sim = pcall(engine.simulate, S.land_ticks)
    if not ok or type(sim) ~= "table" then
        RT.sim_fail = RT.sim_fail + 1
        RT.land_soon = false
        if RT.sim_fail >= 3 then
            U.say("engine.simulate недоступен, режим детекции переключён на «Земля + верт. скорость»")
            Settings.set("air_mode", 1)
            RT.sim_fail = 0
        end
        return
    end
    local soon = false
    for i = 1, #sim do
        local s = sim[i]
        if type(s) == "table" and (s.landed or s.on_ground) then
            soon = true
            break
        end
    end
    RT.land_soon = soon
end

function Logic.movement(lp, cmd)
    local vel = lp:velocity()
    local speed = vel and vel:length2d() or 0
    local vz = vel and vel.z or 0
    local grounded = lp:on_ground()
    if grounded == nil then grounded = true end
    if grounded then
        RT.air_ticks = 0
        RT.land_soon = false
    else
        RT.air_ticks = RT.air_ticks + 1
    end
    local raw_air = false
    if not grounded then
        if S.air_mode == 2 then
            raw_air = RT.air_ticks >= 1
        else
            raw_air = RT.air_ticks >= 2 and (abs(vz) >= S.air_thr or RT.air_ticks >= 10)
        end
    end
    RT.raw_air = raw_air
    local air = raw_air
    if air and S.air_mode == 3 and RT.land_soon then air = false end
    local st
    if air then
        st = (S.apex_on and abs(vz) <= S.apex_win) and ST.APEX or ST.AIR
    elseif band(lp:flags(), K.FL_DUCKING) ~= 0 then
        st = ST.DUCK
    elseif speed < K.MOVE_EPS then
        st = ST.STAND
    elseif cmd:has(K.BTN_SPEED) then
        st = ST.SLOW
    else
        st = ST.MOVE
    end
    if st ~= RT.state then RT.ind_dirty = true end
    RT.state, RT.speed, RT.vz = st, speed, vz
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
    local ok, list = pcall(pawn.hitboxes, pawn)
    if not ok or type(list) ~= "table" then return nil end
    local body, head, got = {}, nil, {}
    for i = 1, #list do
        local hb = list[i]
        local g = hb.group
        if type(g) ~= "number" then g = hg_from_name(hb.group_name or g) end
        if g == K.HG_HEAD then
            if not head then head = { index = hb.index, group = g } end
        elseif (g == K.HG_CHEST or g == K.HG_STOMACH) and not got[g] then
            got[g] = true
            body[#body + 1] = { index = hb.index, group = g }
        end
    end
    if HB.n > 64 then HB.cache, HB.n = {}, 0 end
    c = { t = RT.tick, body = body, head = head }
    if HB.cache[addr] == nil then HB.n = HB.n + 1 end
    HB.cache[addr] = c
    return c
end

function Logic.dmg_at(eye, pawn, entry)
    if not entry.index then return 0 end
    local pos = pawn:hitbox(entry.index)
    if not pos then return 0 end
    local ok, d = pcall(trace.damage, pawn, pos, entry.group, eye)
    if ok and type(d) == "number" then return d end
    return 0
end

function Logic.eval_targets(lp, eye)
    local has_baim = (SL.baim.n + SL.hitbox.n) > 0
    local need_trace = S.baim_on and (S.baim_lethal or S.baim_2x) and has_baim
    local need_target = need_trace or (S.baim_on and S.baim_hp_on) or S.dmg_cap
                        or S.hc_tgt_air ~= 0 or S.hc_tgt_move ~= 0
    RT.base_hc = Bind.base(SL.hc, RT.wgroup)
    RT.base_dmg = Bind.base(SL.dmg, RT.wgroup)
    if not need_target then
        RT.t_hp, RT.t_air, RT.t_move = nil, false, false
        if RT.tick > RT.baim_until then RT.baim_reason = nil end
        return
    end

    local view = engine.view_angles()
    local players = entity.players()
    local cand, n = {}, 0
    for i = 1, #players do
        local pawn = players[i].pawn
        if pawn and pawn:alive() and pawn:is_enemy() then
            local o = pawn:origin()
            if o then
                local ang = math.calc_angle(eye, vector(o.x, o.y, o.z + K.EYE_OFFSET))
                local dp = math.normalize_angle(ang.x - view.x)
                local dy = math.normalize_angle(ang.y - view.y)
                local fov = sqrt(dp * dp + dy * dy)
                if fov <= S.baim_fov then
                    n = n + 1
                    cand[n] = { pawn = pawn, fov = fov }
                end
            end
        end
    end

    local pick = nil
    if n > 0 then
        t_sort(cand, function(a, b) return a.fov < b.fov end)
        for i = 1, min(n, K.MAX_TARGETS) do
            local c = cand[i]
            c.hp = c.pawn:health() or 100
            c.bd, c.hd = 0, 0
            if need_trace then
                local ids = Logic.hitbox_ids(c.pawn)
                if ids then
                    for j = 1, #ids.body do
                        local d = Logic.dmg_at(eye, c.pawn, ids.body[j])
                        if d > c.bd then c.bd = d end
                    end
                    if S.baim_2x and ids.head then c.hd = Logic.dmg_at(eye, c.pawn, ids.head) end
                end
            end
            if not pick then pick = c end
            if c.bd > 0 then
                pick = c
                break
            end
        end
    end

    local reason = nil
    if pick then
        local p = pick.pawn
        RT.t_hp = pick.hp
        RT.t_air = (p:on_ground() == false)
        local pv = p:velocity()
        RT.t_move = (pv ~= nil) and (pv:length2d() > 40)
        if S.baim_on then
            local need = pick.hp + S.baim_margin
            if S.baim_lethal and pick.bd > 0 and pick.bd >= need then
                reason = "LETHAL"
            elseif S.baim_2x and pick.bd > 0 and pick.bd * 2 >= need and pick.hd < pick.hp then
                reason = "2X"
            elseif S.baim_hp_on and pick.hp <= S.baim_hp then
                reason = "HP"
            end
        end
    else
        RT.t_hp, RT.t_air, RT.t_move = nil, false, false
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
    local strict, kbaim, kdmg = RT.k_strict, RT.k_baim, RT.k_dmg
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

    set_pub("hc", hc)
    set_pub("dmg", dmg)
    set_pub("safe", safe and true or false)
    set_pub("baim", baim)
    set_pub("strict", strict and true or false)
    if RT.t_hp ~= RT.pub_thp then
        RT.pub_thp = RT.t_hp
        RT.ind_dirty = true
    end
end

----------------------------------------------------------------------------
-- 7. Настройки: чтение, профили, сохранение
----------------------------------------------------------------------------
function Settings.read(w)
    local ok, v = pcall(w.raw.get, w.raw)
    if not ok or v == nil then return S[w.id] end
    local k = w.kind
    if k == "check" then return v and true or false end
    if k == "slider" then
        v = tonumber(v)
        if not v then return S[w.id] end
        return U.clamp(v, w.lo, w.hi)
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
        return U.clamp(floor(v + 0.5), 1, #w.items)
    end
    if k == "color" then
        if type(v) == "table" and v.r then return v end
        return S[w.id]
    end
    return v
end

function Settings.set(id, v)
    S[id] = v
    local w = W[id]
    if w then pcall(w.raw.set, w.raw, v) end
end

function Settings.apply_preset(idx)
    local p = PRESETS[idx]
    if not p then return end
    for id, v in pairs(p) do
        if id ~= "name" then Settings.set(id, v) end
    end
    Settings.poll(true)
    U.notify("Профиль «" .. p.name .. "» применён")
end

function Settings.poll(force)
    local now = globals.realtime()
    if not force and now - RT.snap_t < K.SNAP_INTERVAL then return end
    RT.snap_t = now
    for i = 1, #ORDER_W do
        local id = ORDER_W[i]
        S[id] = Settings.read(W[id])
    end
    if W.preset and S.preset ~= RT.last_preset then
        local p = S.preset
        RT.last_preset = p
        -- force=true вызывают только загрузка, сброс и сам профиль: тогда значения не перезаписываются
        if p > 1 and not force then Settings.apply_preset(p) end
    end
end

function Settings.validate(w, v)
    local k = w.kind
    if k == "check" then
        if type(v) == "boolean" then return v end
    elseif k == "slider" then
        if type(v) == "number" then return U.clamp(v, w.lo, w.hi) end
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

function Settings.sig()
    local parts = {}
    for i = 1, #ORDER_W do
        local v = S[ORDER_W[i]]
        if type(v) == "table" then
            v = s_format("%d,%d,%d,%d", v.r or 0, v.g or 0, v.b or 0, v.a or 255)
        end
        parts[i] = tostring(v)
    end
    return t_concat(parts, ";")
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
    RT.last_preset = S.preset or 1
    return true
end

function Settings.housekeeping()
    local now = globals.realtime()
    if now - RT.hk_t < 1 then return end
    RT.hk_t = now
    if #ORDER_W > 0 then
        local sig = Settings.sig()
        if sig ~= RT.cur_sig then
            RT.cur_sig, RT.sig_t = sig, now
        elseif sig ~= RT.saved_sig and now - RT.sig_t >= 1.5 then
            if Settings.save() then RT.saved_sig = sig end
        end
    end
    Journal.flush()
end

function ACT.save()
    if Settings.save() then
        RT.saved_sig = Settings.sig()
        U.notify("Настройки сохранены")
    else
        U.notify("Не удалось сохранить настройки")
    end
end

function ACT.load()
    if Settings.load() then
        RT.saved_sig = Settings.sig()
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
    RT.last_preset = S.preset or 1
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
-- 8. Интерфейс: Menu.lua (VibeUI) и нативный запасной вариант
----------------------------------------------------------------------------
UIm.mode, UIm.menu, UIm.ntab, UIm.status = "нет", nil, nil, nil

local function mk(it, raw)
    local w = { id = it.id, kind = it.t, raw = raw, def = it.def, lo = it.lo, hi = it.hi, items = it.items }
    W[it.id] = w
    ORDER_W[#ORDER_W + 1] = it.id
    return w
end

local function click(act)
    return function()
        local f = ACT[act]
        if f then
            local ok, err = pcall(f)
            if not ok then U.report("кнопка " .. tostring(act), err) end
        end
    end
end

local function reset_widgets()
    for k in pairs(W) do W[k] = nil end
    for i = #ORDER_W, 1, -1 do ORDER_W[i] = nil end
    UIm.status = nil
end

function UIm.set_status(txt)
    if type(UIm.status) == "table" then UIm.status.label = txt end
end

function UIm.binds()
    local ok, err = pcall(function()
        local tab = ui.tab("0x")
        UIm.ntab = tab
        local g = tab:group("Бинды · 0x v" .. VERSION)
        B.strict = g:keybind("Strict · макс. точность", 0)
        B.baim = g:keybind("Принудительный Body-Aim", 0)
        B.dmg = g:keybind("Оверрайд мин. урона", 0)
        B.strict:tooltip("Пока активен: hitchance растёт на прибавку Strict и включается safepoint. Для дальних и важных выстрелов.")
        B.baim:tooltip("Пока активен: голова исключается из целей, стрельба идёт по корпусу.")
        B.dmg:tooltip("Пока активен: мин. урон равен значению «Мин. урон по бинду» (вкладка «Ядро»).")
        g:label("Остальные настройки находятся в панели 0x (Menu.lua) рядом с меню.")
    end)
    if not ok then U.say("нативные бинды недоступны: " .. tostring(err)) end
end

local function bind_on(el)
    if el == nil then return false end
    local ok, v = pcall(el.active, el)
    return ok and v == true
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
        UIm.status = tab:label(it.text)
    elseif t == "text" then
        local lines = U.wrap(it.text, K.WRAP)
        for i = 1, #lines do tab:label(lines[i]) end
    end
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

function UIm.native()
    local tab = UIm.ntab
    if not tab then
        local ok, t = pcall(ui.tab, "0x")
        if not ok or not t then return false, "ui.tab недоступен" end
        tab = t
        UIm.ntab = t
    end
    for ti = 1, #SCHEMA do
        local ts = SCHEMA[ti]
        for si = 1, #ts.sections do
            local sec = ts.sections[si]
            local g = tab:group(ts.tab .. " · " .. sec.title)
            if sec.hint then g:label(sec.hint) end
            for ii = 1, #sec.items do
                local it = sec.items[ii]
                local t, el = it.t, nil
                if t == "check" then
                    el = g:checkbox(it.name, it.def)
                    mk(it, el)
                elseif t == "slider" then
                    el = g:slider_int(it.name, it.lo, it.hi, it.def, it.fmt or "%d")
                    mk(it, el)
                elseif t == "combo" then
                    el = g:combo(it.name, it.items, it.def)
                    mk(it, el)
                elseif t == "color" then
                    el = g:color(it.name, it.def, true)
                    mk(it, el)
                elseif t == "button" then
                    el = g:button(it.name, click(it.act))
                elseif t == "status" or t == "text" then
                    g:label(it.text)
                end
                if el and it.tip then el:tooltip(it.tip) end
            end
        end
    end
    return true
end

function UIm.boot()
    UIm.binds()
    if VibeUI == nil then
        local ok, lib = pcall(require, "Menu")
        if ok and type(lib) == "table" and type(lib.new) == "function" then VibeUI = lib end
    end
    local why = "Menu.lua не встроен"
    if type(VibeUI) == "table" then
        local names = {}
        for k, v in pairs(VibeUI) do
            if type(v) == "function" then names[#names + 1] = tostring(k) end
        end
        t_sort(names)
        U.say("Menu.lua (VibeUI " .. tostring(VibeUI.__version) .. "), методы: " .. t_concat(names, ", "))
        local ok, res, reason = pcall(UIm.vibe)
        if ok and res == true then
            local ok2, how = UIm.attach(UIm.menu)
            if ok2 then
                UIm.mode = "Menu.lua (" .. tostring(how) .. ")"
                return true
            end
            why = tostring(how)
        else
            why = tostring(ok and reason or res)
        end
        reset_widgets()
        UIm.menu = nil
    end
    U.say("Menu.lua не используется: " .. why .. ". Строю нативное меню.")
    local ok, res, reason = pcall(UIm.native)
    if ok and res == true then
        UIm.mode = "нативное меню"
        return true
    end
    reset_widgets()
    UIm.mode = "без меню (значения по умолчанию)"
    U.say("меню недоступно: " .. tostring(ok and reason or res))
    return false
end

----------------------------------------------------------------------------
-- 9. Индикатор
----------------------------------------------------------------------------
Draw.font, Draw.a, Draw.rows, Draw.w, Draw.h = nil, 0, {}, 0, 0
Draw.pad, Draw.rh, Draw.th, Draw.tw, Draw.size = 10, 18, 14, 14, 0
Draw.pal, Draw.qa, Draw.acc, Draw.ver = nil, -1, nil, "v" .. VERSION

function Draw.init()
    local ok, f = pcall(render.font, "Segoe UI", 13)
    if ok and f then
        local ok2, loaded = pcall(f.loaded, f)
        if ok2 and loaded then Draw.font = f end
    end
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
    if ok and w then return w, h or size end
    return #str * size * 0.55, size
end

function Draw.rebuild(size)
    local rows = {}
    local sname = RT.paused and "ПАУЗА" or (RT.state and ST_NAME[RT.state] or "—")
    rows[#rows + 1] = { "РЕЖИМ", sname, 1 }
    if RT.hc then rows[#rows + 1] = { "HC", RT.hc .. "%", 1 } end
    if RT.dmg then rows[#rows + 1] = { "DMG", tostring(RT.dmg), 1 } end
    if RT.safe then rows[#rows + 1] = { "SAFE", "ON", 2 } end
    if RT.baim then rows[#rows + 1] = { "BAIM", RT.baim, 3 } end
    if RT.strict then rows[#rows + 1] = { "STRICT", "ON", 2 } end
    if RT.t_hp then rows[#rows + 1] = { "ЦЕЛЬ", RT.t_hp .. " HP", 1 } end
    local kw, vw = 0, 0
    for i = 1, #rows do
        local w1 = Draw.measure(rows[i][1], size)
        local w2 = Draw.measure(rows[i][2], size)
        rows[i][4] = w2
        if w1 > kw then kw = w1 end
        if w2 > vw then vw = w2 end
    end
    local pad = floor(size * 0.8)
    local tw, th = Draw.measure("0x", size + 2)
    local vwid = Draw.measure(Draw.ver, size - 2)
    Draw.pad, Draw.rh, Draw.th, Draw.tw = pad, floor(size * 1.55), th, tw
    Draw.w = max(pad * 2 + kw + 18 + vw, pad * 2 + tw + 6 + vwid + 40)
    Draw.h = pad * 2 + th + 8 + #rows * Draw.rh + (RT.hc and 8 or 0)
    Draw.rows, Draw.size = rows, size
end

function Draw.palette(qa, acc)
    local k = qa / 255
    local r, g, b = 140, 148, 255
    if type(acc) == "table" and acc.r then r, g, b = acc.r, acc.g, acc.b end
    Draw.pal = {
        bg = color(10, 11, 17, floor(214 * k)),
        line = color(255, 255, 255, floor(24 * k)),
        acc = color(r, g, b, qa),
        acc_dim = color(r, g, b, floor(70 * k)),
        key = color(122, 126, 146, qa),
        val = color(236, 238, 246, qa),
        good = color(120, 220, 160, qa),
        warn = color(255, 190, 96, qa),
    }
    Draw.qa, Draw.acc = qa, acc
end

function Draw.paint()
    if not S.ind_on or not S.enable or RT.failed then
        Draw.a = 0
        return
    end
    if not engine.in_game() then return end
    local show = (RT.state ~= nil or RT.paused) and 1 or 0
    Draw.a = Draw.a + (show - Draw.a) * min(1, globals.frametime() * 10)
    if Draw.a < 0.02 then return end

    local size = floor(13 * S.ind_scale / 100 + 0.5)
    if RT.ind_dirty or size ~= Draw.size or RT.paused ~= Draw.paused then
        Draw.rebuild(size)
        Draw.paused = RT.paused
        RT.ind_dirty = false
    end
    local qa = floor(Draw.a * 255 + 0.5)
    local acc = S.ind_color
    if qa ~= Draw.qa or acc ~= Draw.acc then Draw.palette(qa, acc) end

    local P = Draw.pal
    local sw, sh = render.screen_size()
    local w, h, pad = Draw.w, Draw.h, Draw.pad
    local x = floor((sw - w) * S.ind_x / 100)
    local y = floor((sh - h) * S.ind_y / 100)

    render.rect_filled(x, y, w, h, P.bg, 7)
    render.rect(x, y, w, h, P.line, 7, 1)
    render.rect_filled(x + 1, y + 10, 2, h - 20, P.acc, 1)
    Draw.text(x + pad, y + pad - 1, P.acc, "0x", size + 2)
    Draw.text(x + pad + Draw.tw + 6, y + pad + 1, P.key, Draw.ver, size - 2)
    local ry = y + pad + Draw.th + 8
    render.line(x + pad, ry - 4, x + w - pad, ry - 4, P.line, 1)
    for i = 1, #Draw.rows do
        local row = Draw.rows[i]
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
local function on_createmove(cmd)
    RT.tick = RT.tick + 1
    Settings.poll(false)

    if not S.enable then
        RT.state, RT.paused = nil, false
        Bind.release("off")
        return
    end
    if RT.menu_open and S.pause_menu then
        RT.paused = true
        Bind.release("menu")
        return
    end
    RT.paused = false

    local lp = entity.local_pawn()
    if not lp or not lp:alive() then
        if RT.state ~= nil then Logic.reset() end
        Bind.release("dead")
        return
    end

    Logic.weapon(lp)
    local grp = RT.wgroup
    if not grp or not S[K.WPN_KEY[grp]] then
        RT.state = nil
        Bind.release("weapon")
        return
    end

    Logic.movement(lp, cmd)
    RT.k_strict, RT.k_baim, RT.k_dmg = bind_on(B.strict), bind_on(B.baim), bind_on(B.dmg)

    if RT.tick % K.EVAL_TICKS == 0 then
        if S.air_mode == 3 and RT.raw_air then Logic.predict() end
        Logic.eval_targets(lp, lp:eye_position())
    end

    Logic.decide(grp)

    if RT.tick % K.VERIFY_TICKS == 0 then Bind.verify() end
    if RT.tick % K.FLUSH_TICKS == 0 then Journal.flush() end
end

local function on_paint()
    Settings.poll(false)
    Settings.housekeeping()
    if RT.menu_draw then RT.menu_draw() end
    Draw.paint()
end

local function on_menu_toggled(open)
    RT.menu_open = open and true or false
    if RT.menu_open and S.pause_menu and S.enable then
        RT.paused = true
        Bind.release("menu")
    end
end

local function on_level()
    Bind.release("level")
    Logic.reset()
end

local function on_unload()
    Bind.release("unload")
    Journal.flush(true)
    if #ORDER_W > 0 then Settings.save() end
end

-- Любая ошибка в колбэке перехватывается; после ERR_LIMIT ошибок подряд скрипт останавливается
-- и возвращает значения ragebot.
local function guard(name, fn)
    return function(...)
        if RT.failed and name == "createmove" then return end
        local ok, err = pcall(fn, ...)
        if ok then
            RT.errs[name] = 0
            return
        end
        U.report(name, err)
        local n = (RT.errs[name] or 0) + 1
        RT.errs[name] = n
        if n >= K.ERR_LIMIT and not RT.failed then
            RT.failed = true
            pcall(Bind.release, "error")
            pcall(Journal.flush, true)
            U.notify("Слишком много ошибок в «" .. name .. "»: 0x остановлен, значения возвращены. Исправьте причину и сделайте Save & Reload.")
        end
    end
end

local function boot()
    Draw.init()
    local restored = Journal.restore()
    UIm.boot()
    if #ORDER_W > 0 then
        Settings.load()
        RT.saved_sig = Settings.sig()
        RT.cur_sig = RT.saved_sig
    end
    Settings.poll(true)
    RT.last_preset = S.preset or 1

    local ok, open = pcall(input.menu_open)
    RT.menu_open = ok and open == true

    local scanned = Bind.scan()
    UIm.set_status(scanned and ("Найдено: " .. Bind.summary()) or "config.keys недоступен")

    local ev = RT.ev
    ev[#ev + 1] = events.on("createmove", guard("createmove", on_createmove))
    ev[#ev + 1] = events.on("paint", guard("paint", on_paint))
    ev[#ev + 1] = events.on("menu_toggled", guard("menu_toggled", on_menu_toggled))
    ev[#ev + 1] = events.on("level_init", guard("level_init", on_level))
    ev[#ev + 1] = events.on("level_shutdown", guard("level_shutdown", on_level))
    ev[#ev + 1] = events.on("unload", guard("unload", on_unload))

    if restored > 0 then
        U.notify("Восстановлено значений ragebot после аварийного завершения: " .. restored)
    end
    U.say(s_format("v%s загружен · интерфейс: %s · пути: %s", VERSION, UIm.mode, Bind.summary()))
    if scanned and Bind.summary() == "HC 0 · DMG 0 · SAFE 0 · BAIM 0 · HITBOX 0" then
        U.notify("0x: пути ragebot в config не найдены. Откройте «Профили» и выведите пути в консоль.")
    else
        U.notify("0x v" .. VERSION .. " загружен")
    end
end

local boot_ok, boot_err = pcall(boot)
if not boot_ok then
    RT.failed = true
    pcall(Bind.release, "boot")
    U.say("ошибка запуска: " .. tostring(boot_err))
end
