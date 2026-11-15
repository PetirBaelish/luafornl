-- @author KuKluaxK
-- @uid 1

-- ============================================================================
-- 0x — High-Precision Ragebot Accuracy, In-Air & Smart Lethal Hitbox Optimizer
-- Target API: Neverlose CS2 LuaJIT 2.1 (https://github.com/PbLJk/neverlose-lua-api)
-- Sandbox Mode: Standard (Does NOT require Allow Insecure)
-- ============================================================================

local math_abs       = math.abs
local math_floor     = math.floor
local math_ceil      = math.ceil
local math_min       = math.min
local math_max       = math.max
local math_sqrt      = math.sqrt
local math_clamp     = math.clamp
local math_lerp      = math.lerp
local math_round     = math.round
local math_remap     = math.remap
local string_format  = string.format
local string_lower   = string.lower
local string_find    = string.find
local table_concat   = table.concat
local table_insert   = table.insert
local pcall          = pcall
local ipairs         = ipairs
local pairs          = pairs
local type           = type
local tostring       = tostring
local tonumber       = tonumber

-- ============================================================================
-- 1. КОНСТАНТЫ И ОПРЕДЕЛЕНИЯ СОСТОЯНИЙ (CONSTANTS)
-- ============================================================================

local SCRIPT_VERSION = "2.4.0"
local DB_PROFILE_KEY = "0x_accuracy_profile_v2"

local STATE = {
    STANDING  = 1,
    CROUCHING = 2,
    SLOWWALK  = 3,
    MOVING    = 4,
    AIR       = 5,
    AIR_APEX  = 6
}

local STATE_NAMES_RU = {
    [STATE.STANDING]  = "СТОЯ (STANDING)",
    [STATE.CROUCHING] = "В ПРИСЕДЕ (CROUCH)",
    [STATE.SLOWWALK]  = "МЕДЛ. ШАГ (SLOWWALK)",
    [STATE.MOVING]    = "В ДВИЖЕНИИ (MOVING)",
    [STATE.AIR]       = "В ВОЗДУХЕ (IN-AIR)",
    [STATE.AIR_APEX]  = "ПИК ПРЫЖКА (APEX)"
}

local STATE_SHORT = {
    [STATE.STANDING]  = "STND",
    [STATE.CROUCHING] = "DUCK",
    [STATE.SLOWWALK]  = "SLOW",
    [STATE.MOVING]    = "MOVE",
    [STATE.AIR]       = "AIR",
    [STATE.AIR_APEX]  = "APEX"
}

local HITGROUP = {
    GENERIC  = 0,
    HEAD     = 1,
    CHEST    = 2,
    STOMACH  = 3,
    LEFTARM  = 4,
    RIGHTARM = 5,
    LEFTLEG  = 6,
    RIGHTLEG = 7
}

-- Справочник базового урона оружия на случай недоступности прямой трассировки
local WEAPON_BASE_DAMAGE = {
    ssg08     = 88,
    awp       = 115,
    scar20    = 80,
    g3sg1     = 80,
    deagle    = 53,
    revolver  = 86,
    ak47      = 36,
    m4a1      = 33,
    m4a1_silencer = 38,
    aug       = 28,
    sg556     = 30,
    galilar   = 30,
    famas     = 30,
    usp_silencer = 35,
    glock     = 30,
    hkp2000   = 35,
    p250      = 38,
    fiveseven = 32,
    tec9      = 33,
    cz75a     = 31,
    dualberettas = 38
}

local FL_DUCKING = 2 -- Бит приседания в m_fFlags
local BTN_ATTACK = (buttons and buttons.attack) or (button and button.attack) or 1
local BTN_SPEED  = (buttons and buttons.speed)  or (button and button.sprint) or 65536
local BTN_DUCK   = (buttons and buttons.duck)   or (button and button.duck)   or 4

-- ============================================================================
-- 2. НАТИВНОЕ МЕНЮ И РУССКИЕ ПОДСКАЗКИ (NATIVE UI & RUSSIAN TOOLTIPS)
-- ============================================================================

local tab = ui.tab("0x Accuracy")

local grp_master = tab:group("0x • Ядро и Профили")
local grp_air    = tab:group("0x • Воздух (In-Air)")
local grp_baim   = tab:group("0x • Умный Body-Aim")
local grp_hc     = tab:group("0x • Anti-Spread & Хитшанс")
local grp_vis    = tab:group("0x • Индикация и Мост API")

local UI = {}

-- Группа 1: Ядро и Профили
UI.master_enable = grp_master:checkbox("Включить ядро точности 0x", true)
    :tooltip("Главный переключатель скрипта 0x. Активирует модули оптимизации прыжков, расчёта летального урона в тело, динамического хитшанса и защиты от миссов по разбросу.")

UI.preset_mode = grp_master:combo("Профиль конфигурации", {
    "Пользовательский (Custom)",
    "Сбалансированный (Balanced)",
    "Агрессивный (Fast-Fire)",
    "Консервативный (Anti-Spread)"
}, 1)
    :depends(UI.master_enable)
    :tooltip("Быстрый выбор преднастроенного профиля точности. При выборе пресета ползунки автоматически установятся в оптимальные значения для выбранного стиля игры.")

UI.quick_precision_bind = grp_master:keybind("Бинд: Макс. точность (Strict)", 0)
    :depends(UI.master_enable)
    :tooltip("Клавиша экстренного повышения точности. Пока активна, скрипт повышает требуемый хитшанс на +12% и принудительно включает строгие сейфпоинты (Force Safepoint).")

UI.force_baim_bind = grp_master:keybind("Бинд: Принудительный Body-Aim", 0)
    :depends(UI.master_enable)
    :tooltip("При активации бинда полностью блокирует выбор головы и переводит стрельбу исключительно в хитбоксы тела (грудь, живот, таз).")

UI.min_dmg_bind = grp_master:keybind("Бинд: Оверрайд мин. урона", 0)
    :depends(UI.master_enable)
    :tooltip("Позволяет мгновенно изменить порог минимального урона по нажатию или удержанию клавиши (например, для прострела тонких стен или быстрого добивания).")

UI.min_dmg_bind_val = grp_master:slider_int("Значение урона по бинду", 1, 130, 18, "%d HP")
    :depends(UI.master_enable)
    :tooltip("Целевой минимальный урон, который будет применён к Ragebot при активном бинде 'Оверрайд мин. урона'.")

grp_master:divider("Хранилище конфигурации (db)")

-- Группа 2: Оптимизатор точности в воздухе (In-Air / Jump Optimizer)
UI.air_enable = grp_air:checkbox("Оптимизатор стрельбы в прыжке", true)
    :depends(UI.master_enable)
    :tooltip("Автоматически определяет нахождение вашего персонажа в воздухе и динамически переопределяет Hitchance, Minimum Damage и Safepoints для предотвращения миссов по разбросу.")

UI.air_detect_mode = grp_air:combo("Метод детекции полёта", {
    "Флаг земли + верт. скорость",
    "Только отрыв от земли (on_ground)",
    "Симуляция траектории (engine.simulate)"
}, 1)
    :depends(UI.air_enable)
    :tooltip("Алгоритм определения состояния прыжка. Комбинированный режим учитывает как отсутствие флага земли, так и вертикальный вектор скорости для исключения ложных срабатываний на ступеньках.")

UI.air_vel_threshold = grp_air:slider_int("Порог верт. скорости (|vel.z|)", 5, 220, 22, "%d u/s")
    :depends(UI.air_enable)
    :tooltip("Минимальная вертикальная скорость персонажа по оси Z, начиная с которой активируется воздушный профиль точности.")

UI.air_apex_enable = grp_air:checkbox("Приоритет пика прыжка (Jump Apex)", true)
    :depends(UI.air_enable)
    :tooltip("Использует физическую симуляцию engine.simulate и анализ вертикальной скорости для определения верхней мёртвой точки прыжка, где разброс оружия в воздухе минимален.")

UI.air_apex_window = grp_air:slider_int("Окно пика прыжка (|vel.z|)", 10, 110, 42, "<= %d u/s")
    :depends(UI.air_apex_enable)
    :tooltip("Диапазон модуля вертикальной скорости в верхней фазе прыжка. Когда |vel.z| попадает в это окно, оружие достигает максимальной кучности в воздухе.")

UI.air_hitchance = grp_air:slider_int("Хитшанс в полёте (In-Air HC)", 1, 100, 70, "%d%%")
    :depends(UI.air_enable)
    :tooltip("Значение Hitchance во время набора высоты или падения. Рекомендуется 65–78% для SSG-08 и револьвера, чтобы исключить выстрелы в молоко из-за воздушного разброса.")

UI.air_apex_hitchance = grp_air:slider_int("Хитшанс на пике (Apex HC)", 1, 100, 58, "%d%%")
    :depends(UI.air_apex_enable)
    :tooltip("Сбалансированный хитшанс в верхней точке прыжка (Apex). Небольшое снижение относительно обычного полёта позволяет гарантированно успеть выстрелить в момент пиковой кучности.")

UI.air_min_damage = grp_air:slider_int("Мин. урон в воздухе", 1, 130, 50, "%d HP")
    :depends(UI.air_enable)
    :tooltip("Переопределение минимального урона при стрельбе в прыжке. Оптимально выставить 45–65 HP для уверенного попадания с SSG-08 без пропуска кадра.")

UI.air_safepoint = grp_air:combo("Сейфпоинты в воздухе", {
    "Не изменять",
    "Предпочитать (Prefer)",
    "Принудительно (Force)"
}, 3)
    :depends(UI.air_enable)
    :tooltip("Режим Safepoints, когда ваш персонаж находится в воздухе. Режим 'Принудительно' (Force) исключает стрельбу в края несовпадающих матриц противника.")

UI.air_gate_fire = grp_air:checkbox("Задержка выстрела до пика прыжка", false)
    :depends(UI.air_apex_enable)
    :tooltip("Аппаратный фильтр в createmove: временно блокирует отправку флага атаки в воздухе, пока персонаж не приблизится к пику прыжка (Apex) или допустимой неточности оружия.")

-- Группа 3: Умный Body-Aim (Smart Lethal Body-Aim)
UI.baim_enable = grp_baim:checkbox("Умный летальный Body-Aim", true)
    :depends(UI.master_enable)
    :tooltip("В реальном времени вычисляет пробивной урон оружия по груди, животу и тазу цели с учётом брони. Если цель гарантированно умирает в тело, отключает голову для исключения миссов.")

UI.baim_lethal_shots = grp_baim:slider_int("Выстрелов для летала в тело", 1, 3, 1, "%d выстр.")
    :depends(UI.baim_enable)
    :tooltip("Допустимое число попаданий в тело для активации летал-приоритета. 1 выстрел — строгий ваншот (идеально для Scout/AWP), 2 выстрела — быстрый дабл-тап в тело (идеально для SCAR-20/G3SG1).")

UI.baim_hp_threshold = grp_baim:slider_int("Безусловный порог HP цели", 1, 100, 46, "<= %d HP")
    :depends(UI.baim_enable)
    :tooltip("Если текущее здоровье противника опускается до указанной отметки или ниже, скрипт принудительно активирует стрельбу в тело независимо от расчёта пробития стены.")

UI.baim_conditions = grp_baim:multi_combo("Дополнительные триггеры Baim", {
    "Противник в воздухе",
    "Высокая скорость цели",
    "Игрок в приседе",
    "Цель без брони",
    "Дальняя дистанция (>28м)"
}, { true, true, false, true, false })
    :depends(UI.baim_enable)
    :tooltip("Дополнительные боевые условия, при которых стрельба в широкие хитбоксы тела статистически надёжнее попытки попасть в голову.")

UI.baim_target_speed = grp_baim:slider_int("Порог высокой скорости цели", 80, 260, 170, "%d u/s")
    :depends(UI.baim_enable)
    :tooltip("Горизонтальная скорость противника (length2d), при превышении которой срабатывает триггер 'Высокая скорость цели' для переключения на тело.")

UI.baim_hitbox_mode = grp_baim:combo("Режим переопределения хитбоксов", {
    "Предпочитать тело (Грудь + Живот)",
    "Только тело (Отключить голову)",
    "Только Живот и Таз (Макс. множитель)"
}, 2)
    :depends(UI.baim_enable)
    :tooltip("Выбор стратегии хитбоксов при срабатывании Smart Body-Aim. 'Только тело' полностью исключает голову из пула сканирования Ragebot.")

UI.baim_safepoint = grp_baim:combo("Сейфпоинты по летальной цели", {
    "Не изменять",
    "Предпочитать (Prefer)",
    "Принудительно (Force)"
}, 3)
    :depends(UI.baim_enable)
    :tooltip("Переопределение Safepoints, когда цель признана летальной в тело. Принудительный сейфпоинт гарантирует 100% реализацию летального выстрела.")

-- Группа 4: Anti-Spread & Контроллер Хитшанса
UI.hc_enable = grp_hc:checkbox("Динамический контроллер Хитшанса", true)
    :depends(UI.master_enable)
    :tooltip("Адаптивно регулирует Hitchance и Safepoints на каждом тике createmove в зависимости от скорости вашего движения, приседания, дистанции и состояния цели.")

UI.hc_standing = grp_hc:slider_int("Хитшанс: Стоя на месте", 1, 100, 62, "%d%%")
    :depends(UI.hc_enable)
    :tooltip("Базовое значение Hitchance, когда ваш персонаж неподвижен на земле (скорость < 5 u/s).")

UI.hc_moving = grp_hc:slider_int("Хитшанс: В движении", 1, 100, 56, "%d%%")
    :depends(UI.hc_enable)
    :tooltip("Значение Hitchance при беге и пике из-за угла. Оптимизирует скорость срабатывания после автостопа.")

UI.hc_crouching = grp_hc:slider_int("Хитшанс: В приседе (Duck)", 1, 100, 66, "%d%%")
    :depends(UI.hc_enable)
    :tooltip("Значение Hitchance при стрельбе из положения сидя, когда движок CS2 обеспечивает минимальный базовый разброс.")

UI.hc_slowwalk = grp_hc:slider_int("Хитшанс: Медленный шаг", 1, 100, 60, "%d%%")
    :depends(UI.hc_enable)
    :tooltip("Значение Hitchance при перемещении с зажатым модификатором медленной ходьбы (Slow-Walk / Shift).")

UI.hc_target_air_bonus = grp_hc:slider_int("Коррекция ХС: Цель в воздухе", 0, 30, 10, "+%d%%")
    :depends(UI.hc_enable)
    :tooltip("Дополнительная прибавка к хитшансу, если выбранная цель находится в прыжке, для предотвращения ранних выстрелов с большим разбросом.")

UI.hc_target_vel_bonus = grp_hc:slider_int("Коррекция ХС: Быстрая цель", 0, 25, 6, "+%d%%")
    :depends(UI.hc_enable)
    :tooltip("Дополнительная прибавка к хитшансу при стрельбе по стремительно движущемуся противнику.")

UI.hc_low_hp_relax = grp_hc:slider_int("Снижение ХС: Добивание (<25 HP)", 0, 25, 7, "-%d%%")
    :depends(UI.hc_enable)
    :tooltip("Ослабление требуемого хитшанса, когда у противника осталось критически мало здоровья (<25 HP), для мгновенного выстрела на опережение.")

UI.spread_guard_enable = grp_hc:checkbox("Контроль неточности оружия (Anti-Spread)", true)
    :depends(UI.master_enable)
    :tooltip("Анализирует параметры inaccuracy и spread текущего оружия через weapon_info(). Повышает защиту от миссов при нестабильном прицеле.")

UI.spread_max_limit = grp_hc:slider_float("Порог критического разброса", 0.005, 0.150, 0.042, "%.3f")
    :depends(UI.spread_guard_enable)
    :tooltip("Максимально допустимая сумма (inaccuracy + spread) оружия. При превышении этого порога активируется защита от выстрела в разброс.")

UI.spread_force_safe = grp_hc:checkbox("Форс сейфпоинтов при скачке разброса", true)
    :depends(UI.spread_guard_enable)
    :tooltip("Автоматически включает Force Safepoint и добавляет +8% к хитшансу, если текущая неточность оружия приближается к критическому порогу.")

UI.spread_block_shot = grp_hc:checkbox("Блокировать атаку при пиковом сприде", false)
    :depends(UI.spread_guard_enable)
    :tooltip("Строгий режим Anti-Spread: отменяет бит атаки в wl.cmd на текущем тике, если реальный разброс оружия превышает установленный критический порог.")

-- Группа 5: Индикация и Мост API (Visuals & Native Bridge)
UI.hud_enable = grp_vis:checkbox("Включить экранный индикатор 0x", true)
    :depends(UI.master_enable)
    :tooltip("Отрисовывает минималистичную телеметрию 0x в событии paint: текущее состояние, активный хитшанс, мин. урон, разброс и статус летальной цели.")

UI.hud_style = grp_vis:combo("Режим отображения HUD", {
    "Панель телеметрии + Индикатор у прицела",
    "Только панель телеметрии",
    "Только компактный блок у прицела"
}, 1)
    :depends(UI.hud_enable)
    :tooltip("Выберите удобный формат визуальной индикации активных оверрайдов 0x во время матча.")

UI.hud_x = grp_vis:slider_int("Позиция панели X", 10, 1800, 24, "%d px")
    :depends(UI.hud_enable)
    :tooltip("Координата панели телеметрии 0x по горизонтали (в пикселях от левого края экрана).")

UI.hud_y = grp_vis:slider_int("Позиция панели Y", 10, 1000, 340, "%d px")
    :depends(UI.hud_enable)
    :tooltip("Координата панели телеметрии 0x по вертикали (в пикселях от верхнего края экрана).")

UI.hud_accent = grp_vis:color("Акцентный цвет интерфейса", color(230, 235, 245, 255), true)
    :depends(UI.hud_enable)
    :tooltip("Основной цвет активных индикаторов, полосы кучности и тегов срабатывания 0x.")

UI.esp_tag_enable = grp_vis:checkbox("ESP-индикатор летальной цели (0x BAIM)", true)
    :depends(UI.master_enable)
    :tooltip("Добавляет динамический текстовый флаг '0x LETHAL [BAIM]' справа от бокса противника в ESP, когда цель гарантированно убивается в тело.")

UI.bridge_enable = grp_vis:checkbox("Синхронизация с меню Ragebot (Bridge)", true)
    :depends(UI.master_enable)
    :tooltip("Автоматически находит элементы основного меню (ui.find / config) и синхронизирует вычисленные значения Hitchance, Min Damage, Hitboxes и Safepoints.")

-- ============================================================================
-- 3. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ UI И УПРАВЛЕНИЯ ПРОФИЛЯМИ (HELPERS)
-- ============================================================================

local function combo_index(ctrl, items_list)
    local val = ctrl:get()
    if type(val) == "number" then
        if val >= 1 and val <= #items_list then
            return val
        end
        return math_clamp(val + 1, 1, #items_list)
    elseif type(val) == "string" then
        for i = 1, #items_list do
            if items_list[i] == val then
                return i
            end
        end
    end
    return 1
end

local function multi_selected(ctrl, item_name, index_1based)
    local val = ctrl:get()
    if type(val) == "table" then
        if val[item_name] ~= nil then
            return val[item_name] == true
        end
        if val[index_1based] ~= nil then
            return val[index_1based] == true
        end
    end
    local ok, sub = pcall(ctrl.get, ctrl, index_1based)
    if ok and type(sub) == "boolean" then
        return sub
    end
    return false
end

local PRESET_ITEMS = {
    "Пользовательский (Custom)",
    "Сбалансированный (Balanced)",
    "Агрессивный (Fast-Fire)",
    "Консервативный (Anti-Spread)"
}

local function apply_preset(idx)
    if idx == 2 then
        -- Сбалансированный (Balanced)
        UI.air_hitchance:set(70)
        UI.air_apex_hitchance:set(58)
        UI.air_min_damage:set(50)
        UI.baim_lethal_shots:set(1)
        UI.baim_hp_threshold:set(46)
        UI.hc_standing:set(62)
        UI.hc_moving:set(56)
        UI.hc_crouching:set(66)
        UI.hc_slowwalk:set(60)
        UI.spread_max_limit:set(0.042)
        client.notify("Применён сбалансированный профиль точности", "0x Accuracy")
    elseif idx == 3 then
        -- Агрессивный (Fast-Fire)
        UI.air_hitchance:set(60)
        UI.air_apex_hitchance:set(50)
        UI.air_min_damage:set(38)
        UI.baim_lethal_shots:set(2)
        UI.baim_hp_threshold:set(55)
        UI.hc_standing:set(54)
        UI.hc_moving:set(48)
        UI.hc_crouching:set(58)
        UI.hc_slowwalk:set(52)
        UI.spread_max_limit:set(0.058)
        client.notify("Применён агрессивный профиль (быстрый отстрел)", "0x Accuracy")
    elseif idx == 4 then
        -- Консервативный (Anti-Spread)
        UI.air_hitchance:set(82)
        UI.air_apex_hitchance:set(68)
        UI.air_min_damage:set(65)
        UI.baim_lethal_shots:set(1)
        UI.baim_hp_threshold:set(52)
        UI.hc_standing:set(72)
        UI.hc_moving:set(66)
        UI.hc_crouching:set(76)
        UI.hc_slowwalk:set(70)
        UI.spread_max_limit:set(0.028)
        client.notify("Применён консервативный профиль Anti-Spread", "0x Accuracy")
    end
end

UI.preset_mode:callback(function()
    local idx = combo_index(UI.preset_mode, PRESET_ITEMS)
    if idx > 1 then
        apply_preset(idx)
    end
end)

local function save_profile_to_db()
    local data = {
        air_enable         = UI.air_enable:get(),
        air_vel_threshold  = UI.air_vel_threshold:get(),
        air_apex_enable    = UI.air_apex_enable:get(),
        air_apex_window    = UI.air_apex_window:get(),
        air_hitchance      = UI.air_hitchance:get(),
        air_apex_hitchance = UI.air_apex_hitchance:get(),
        air_min_damage     = UI.air_min_damage:get(),
        air_gate_fire      = UI.air_gate_fire:get(),
        baim_enable        = UI.baim_enable:get(),
        baim_lethal_shots  = UI.baim_lethal_shots:get(),
        baim_hp_threshold  = UI.baim_hp_threshold:get(),
        baim_target_speed  = UI.baim_target_speed:get(),
        hc_enable          = UI.hc_enable:get(),
        hc_standing        = UI.hc_standing:get(),
        hc_moving          = UI.hc_moving:get(),
        hc_crouching       = UI.hc_crouching:get(),
        hc_slowwalk        = UI.hc_slowwalk:get(),
        hc_target_air_bonus = UI.hc_target_air_bonus:get(),
        hc_target_vel_bonus = UI.hc_target_vel_bonus:get(),
        hc_low_hp_relax    = UI.hc_low_hp_relax:get(),
        spread_guard_enable = UI.spread_guard_enable:get(),
        spread_max_limit   = UI.spread_max_limit:get(),
        spread_force_safe  = UI.spread_force_safe:get(),
        spread_block_shot  = UI.spread_block_shot:get(),
        hud_enable         = UI.hud_enable:get(),
        hud_x              = UI.hud_x:get(),
        hud_y              = UI.hud_y:get(),
        min_dmg_bind_val   = UI.min_dmg_bind_val:get()
    }
    local ok = db.save(DB_PROFILE_KEY, data)
    if ok then
        client.notify("Конфигурация 0x успешно сохранена в db", "0x Accuracy")
    else
        client.notify("Не удалось сохранить конфигурацию в db", "0x Accuracy")
    end
end

local function load_profile_from_db()
    local data = db.load(DB_PROFILE_KEY, nil)
    if type(data) ~= "table" then
        client.notify("Сохранённый профиль db ещё не создан", "0x Accuracy")
        return
    end
    for k, v in pairs(data) do
        if UI[k] and UI[k].set then
            pcall(UI[k].set, UI[k], v)
        end
    end
    client.notify("Конфигурация 0x загружена из db", "0x Accuracy")
end

UI.btn_save = grp_master:button("Сохранить настройки в базу (db.save)", save_profile_to_db)
    :depends(UI.master_enable)
    :tooltip("Сохраняет текущие параметры всех ползунков и переключателей 0x в локальное JSON-хранилище C:\\neverwin\\scripts\\data\\db\\.json.")

UI.btn_load = grp_master:button("Загрузить настройки из базы (db.load)", load_profile_from_db)
    :depends(UI.master_enable)
    :tooltip("Восстанавливает ранее сохранённые параметры скрипта 0x из локального хранилища db.")

-- ============================================================================
-- 4. МОСТ СИНХРОНИЗАЦИИ С НАТИВНЫМ RAGEBOT (UI.FIND & CONFIG BRIDGE)
-- ============================================================================

local Bridge = {
    initialized   = false,
    controls      = {},
    config_paths  = {
        hitchance  = {},
        min_damage = {},
        safepoint  = {},
        hitboxes   = {},
        baim       = {}
    },
    baseline_ctrl = {},
    baseline_cfg  = {},
    last_applied  = {
        hitchance  = nil,
        min_damage = nil,
        safepoint  = nil,
        body_mode  = nil
    },
    synced_keys_count = 0
}

local CANDIDATE_UI_PATHS = {
    hitchance = {
        { "Ragebot", "Main", "Hitchance" },
        { "Ragebot", "Accuracy", "Hitchance" },
        { "Rage", "Aimbot", "Hitchance" },
        { "Rage", "Accuracy", "Hit Chance" },
        { "Rage", "Main", "Hit chance" }
    },
    min_damage = {
        { "Ragebot", "Main", "Min Damage" },
        { "Ragebot", "Main", "Minimum Damage" },
        { "Ragebot", "Damage", "Minimum Damage" },
        { "Rage", "Aimbot", "Minimum Damage" },
        { "Rage", "Aimbot", "Min. Damage" },
        { "Rage", "Main", "Min damage" }
    },
    safepoint = {
        { "Ragebot", "Accuracy", "Safepoint" },
        { "Ragebot", "Accuracy", "Safe Point" },
        { "Rage", "Aimbot", "Safe Point" },
        { "Rage", "Accuracy", "Safepoints" }
    },
    hitboxes = {
        { "Ragebot", "Hitboxes", "Hitboxes" },
        { "Ragebot", "Target", "Hitboxes" },
        { "Rage", "Aimbot", "Hitboxes" },
        { "Rage", "Hitboxes", "Target Hitboxes" }
    },
    baim = {
        { "Ragebot", "Hitboxes", "Body Aim" },
        { "Ragebot", "Accuracy", "Prefer Body Aim" },
        { "Rage", "Aimbot", "Prefer Body Aim" },
        { "Rage", "Aimbot", "Force Body Aim" }
    }
}

local function try_find_control(path_tuple)
    local ok, ctrl = pcall(ui.find, path_tuple[1], path_tuple[2], path_tuple[3])
    if ok and ctrl ~= nil then
        return ctrl
    end
    return nil
end

function Bridge.scan()
    Bridge.controls = {}
    Bridge.config_paths = {
        hitchance  = {},
        min_damage = {},
        safepoint  = {},
        hitboxes   = {},
        baim       = {}
    }
    local count = 0

    for category, list in pairs(CANDIDATE_UI_PATHS) do
        for i = 1, #list do
            local ctrl = try_find_control(list[i])
            if ctrl then
                Bridge.controls[category] = ctrl
                if Bridge.baseline_ctrl[category] == nil then
                    local ok_v, cur = pcall(function()
                        if ctrl.get_type and ctrl:get_type() == "multicombo" and ctrl.get_values then
                            return ctrl:get_values()
                        elseif ctrl.get_value then
                            return ctrl:get_value()
                        elseif ctrl.get then
                            return ctrl:get()
                        end
                        return nil
                    end)
                    if ok_v and cur ~= nil then
                        Bridge.baseline_ctrl[category] = cur
                    end
                end
                count = count + 1
                break
            end
        end
    end

    local ok_keys, all_keys = pcall(config.keys)
    if ok_keys and type(all_keys) == "table" then
        for i = 1, #all_keys do
            local k = all_keys[i]
            if type(k) == "string" then
                local kl = string_lower(k)
                local is_rage = string_find(kl, "rage", 1, true) or string_find(kl, "aimbot", 1, true) or string_find(kl, "weapon", 1, true)
                if is_rage then
                    if string_find(kl, "hitchance", 1, true) or string_find(kl, "hit_chance", 1, true) then
                        table_insert(Bridge.config_paths.hitchance, k)
                        count = count + 1
                    elseif string_find(kl, "mindmg", 1, true) or string_find(kl, "min_damage", 1, true) or string_find(kl, "minimum_damage", 1, true) then
                        table_insert(Bridge.config_paths.min_damage, k)
                        count = count + 1
                    elseif string_find(kl, "safepoint", 1, true) or string_find(kl, "safe_point", 1, true) then
                        table_insert(Bridge.config_paths.safepoint, k)
                        count = count + 1
                    elseif string_find(kl, "body_aim", 1, true) or string_find(kl, "prefer_body", 1, true) or string_find(kl, "baim", 1, true) then
                        table_insert(Bridge.config_paths.baim, k)
                        count = count + 1
                    end
                    if Bridge.baseline_cfg[k] == nil then
                        local ok_g, val = pcall(config.get, k)
                        if ok_g and val ~= nil then
                            Bridge.baseline_cfg[k] = val
                        end
                    end
                end
            end
        end
    end

    Bridge.synced_keys_count = count
    Bridge.initialized = true
end

local function set_control_value(ctrl, val)
    if not ctrl then
        return
    end
    if ctrl.set_value then
        pcall(ctrl.set_value, ctrl, val)
    elseif ctrl.set then
        pcall(ctrl.set, ctrl, val)
    end
end

function Bridge.apply(hc_val, md_val, sp_mode, body_mode)
    if not UI.bridge_enable:get() then
        return
    end
    if not Bridge.initialized then
        Bridge.scan()
    end

    -- 1. Применение Hitchance
    if hc_val ~= nil and Bridge.last_applied.hitchance ~= hc_val then
        Bridge.last_applied.hitchance = hc_val
        set_control_value(Bridge.controls.hitchance, hc_val)
        local paths = Bridge.config_paths.hitchance
        for i = 1, #paths do
            local k = paths[i]
            if type(Bridge.baseline_cfg[k]) == "number" then
                pcall(config.set, k, hc_val)
            end
        end
    end

    -- 2. Применение Minimum Damage
    if md_val ~= nil and Bridge.last_applied.min_damage ~= md_val then
        Bridge.last_applied.min_damage = md_val
        set_control_value(Bridge.controls.min_damage, md_val)
        local paths = Bridge.config_paths.min_damage
        for i = 1, #paths do
            local k = paths[i]
            if type(Bridge.baseline_cfg[k]) == "number" then
                pcall(config.set, k, md_val)
            end
        end
    end

    -- 3. Применение Safepoints (1 = Default, 2 = Prefer, 3 = Force)
    if sp_mode ~= nil and Bridge.last_applied.safepoint ~= sp_mode then
        Bridge.last_applied.safepoint = sp_mode
        local ctrl = Bridge.controls.safepoint
        if ctrl and sp_mode > 1 then
            local ctype = ctrl.get_type and ctrl:get_type() or "unknown"
            if ctype == "toggle" then
                set_control_value(ctrl, true)
            else
                set_control_value(ctrl, sp_mode - 1)
            end
        end
        local paths = Bridge.config_paths.safepoint
        for i = 1, #paths do
            local k = paths[i]
            local base = Bridge.baseline_cfg[k]
            if sp_mode > 1 then
                if type(base) == "boolean" then
                    pcall(config.set, k, true)
                elseif type(base) == "number" then
                    pcall(config.set, k, sp_mode - 1)
                end
            elseif base ~= nil then
                pcall(config.set, k, base)
            end
        end
    end

    -- 4. Применение Body-Aim и фильтрации хитбоксов (0 = Обычный, 1 = Prefer Body, 2 = Only Body, 3 = Stomach/Pelvis)
    if body_mode ~= nil and Bridge.last_applied.body_mode ~= body_mode then
        Bridge.last_applied.body_mode = body_mode
        local b_ctrl = Bridge.controls.baim
        if b_ctrl then
            local ctype = b_ctrl.get_type and b_ctrl:get_type() or "unknown"
            if body_mode > 0 then
                if ctype == "toggle" then
                    set_control_value(b_ctrl, true)
                else
                    set_control_value(b_ctrl, body_mode)
                end
            elseif Bridge.baseline_ctrl.baim ~= nil then
                set_control_value(b_ctrl, Bridge.baseline_ctrl.baim)
            end
        end

        local hb_ctrl = Bridge.controls.hitboxes
        if hb_ctrl and hb_ctrl.get_type and hb_ctrl:get_type() == "multicombo" and hb_ctrl.set_values then
            if body_mode >= 2 then
                local ok_items, items = pcall(hb_ctrl.get_items, hb_ctrl)
                if ok_items and type(items) == "table" then
                    local new_vals = {}
                    for i = 1, #items do
                        local name_l = string_lower(tostring(items[i]))
                        local is_head = string_find(name_l, "head", 1, true) or string_find(name_l, "голова", 1, true)
                        local is_body = string_find(name_l, "chest", 1, true)
                            or string_find(name_l, "stomach", 1, true)
                            or string_find(name_l, "pelvis", 1, true)
                            or string_find(name_l, "body", 1, true)
                            or string_find(name_l, "грудь", 1, true)
                            or string_find(name_l, "живот", 1, true)
                        if body_mode == 3 then
                            local is_lower = string_find(name_l, "stomach", 1, true) or string_find(name_l, "pelvis", 1, true)
                            new_vals[items[i]] = (not is_head) and (is_lower or false)
                        else
                            new_vals[items[i]] = (not is_head) and (is_body or false)
                        end
                    end
                    pcall(hb_ctrl.set_values, hb_ctrl, new_vals)
                end
            elseif Bridge.baseline_ctrl.hitboxes ~= nil then
                pcall(hb_ctrl.set_values, hb_ctrl, Bridge.baseline_ctrl.hitboxes)
            end
        end

        local paths = Bridge.config_paths.baim
        for i = 1, #paths do
            local k = paths[i]
            local base = Bridge.baseline_cfg[k]
            if body_mode > 0 then
                if type(base) == "boolean" then
                    pcall(config.set, k, true)
                elseif type(base) == "number" then
                    pcall(config.set, k, body_mode)
                end
            elseif base ~= nil then
                pcall(config.set, k, base)
            end
        end
    end
end

function Bridge.restore_all()
    for category, base_val in pairs(Bridge.baseline_ctrl) do
        local ctrl = Bridge.controls[category]
        if ctrl and base_val ~= nil then
            if ctrl.get_type and ctrl:get_type() == "multicombo" and ctrl.set_values then
                pcall(ctrl.set_values, ctrl, base_val)
            else
                set_control_value(ctrl, base_val)
            end
        end
    end
    for k, base_val in pairs(Bridge.baseline_cfg) do
        pcall(config.set, k, base_val)
    end
    Bridge.last_applied.hitchance  = nil
    Bridge.last_applied.min_damage = nil
    Bridge.last_applied.safepoint  = nil
    Bridge.last_applied.body_mode  = nil
end

UI.btn_rescan = grp_vis:button("Пересканировать мост Ragebot", function()
    Bridge.scan()
    client.notify(string_format("Синхронизировано элементов Ragebot: %d", Bridge.synced_keys_count), "0x Bridge")
end)
    :depends(UI.bridge_enable)
    :tooltip("Повторно сканирует элементы основного меню (ui.find) и пути конфигурации (config.keys) для привязки оверрайдов 0x.")

-- ============================================================================
-- 5. ВЫЧИСЛИТЕЛЬНОЕ ЯДРО 0x: СОСТОЯНИЕ, СИМУЛЯЦИЯ И АНАЛИЗ ЦЕЛЕЙ (ENGINE CORE)
-- ============================================================================

local Runtime = {
    player_state     = STATE.STANDING,
    local_speed_2d   = 0,
    local_vel_z      = 0,
    in_air           = false,
    in_apex          = false,
    ticks_to_land    = -1,
    ticks_to_apex    = -1,
    weapon_name      = "none",
    weapon_inacc     = 0.0,
    weapon_spread    = 0.0,
    total_spread     = 0.0,
    spread_ratio     = 0.0,
    spread_warning   = false,
    shot_gated       = false,
    active_hc        = 60,
    active_md        = 50,
    active_sp        = 1,
    active_body_mode = 0,
    override_reason  = "БАЗОВЫЙ",
    target_pawn      = nil,
    target_name      = "Нет цели",
    target_hp        = 0,
    target_armor     = 0,
    target_dist_m    = 0.0,
    target_speed     = 0.0,
    target_in_air    = false,
    target_body_dmg  = 0,
    target_lethal    = false,
    target_baim_trig = false,
    baim_reason_str  = "",
    lethal_map       = {},
    shots_fired      = 0,
    shots_hit        = 0
}

local function get_active_weapon_info(local_pawn)
    local ok_direct, info = pcall(local_pawn.weapon_info, local_pawn)
    if ok_direct and type(info) == "table" then
        return info
    end
    local ok_wep, wep = pcall(local_pawn.weapon, local_pawn)
    if ok_wep and wep ~= nil then
        local ok_wi, winfo = pcall(wep.weapon_info, wep)
        if ok_wi and type(winfo) == "table" then
            return winfo
        end
    end
    return nil
end

local function resolve_base_weapon_damage(wep_info)
    if type(wep_info) ~= "table" then
        return 45
    end
    local raw_name = string_lower(tostring(wep_info.name or wep_info.display or ""))
    for k, dmg in pairs(WEAPON_BASE_DAMAGE) do
        if string_find(raw_name, k, 1, true) then
            return dmg
        end
    end
    return 45
end

local AIR_DETECT_ITEMS = {
    "Флаг земли + верт. скорость",
    "Только отрыв от земли (on_ground)",
    "Симуляция траектории (engine.simulate)"
}

local function analyze_local_state(local_pawn, cmd)
    local vel = local_pawn:velocity() or vector(0, 0, 0)
    local speed_2d = vel:length2d()
    local vel_z = vel.z
    local abs_vz = math_abs(vel_z)
    local on_ground = local_pawn:on_ground()
    local flags = local_pawn:flags() or 0
    local is_ducking = cmd:has(BTN_DUCK) or ((flags % (FL_DUCKING * 2)) >= FL_DUCKING)
    local is_slowwalk = cmd:has(BTN_SPEED) and speed_2d > 5 and speed_2d < 135

    Runtime.local_speed_2d = speed_2d
    Runtime.local_vel_z    = vel_z
    Runtime.ticks_to_land  = -1
    Runtime.ticks_to_apex  = -1

    local detect_mode = combo_index(UI.air_detect_mode, AIR_DETECT_ITEMS)
    local vz_thresh = UI.air_vel_threshold:get()
    local airborne = false

    if detect_mode == 1 then
        airborne = (not on_ground) or (abs_vz > vz_thresh)
    elseif detect_mode == 2 then
        airborne = not on_ground
    else
        airborne = not on_ground
        local ok_sim, sim_steps = pcall(engine.simulate, 14)
        if ok_sim and type(sim_steps) == "table" then
            for i = 1, #sim_steps do
                local st = sim_steps[i]
                if st and st.valid then
                    if not st.on_ground then
                        airborne = true
                    end
                    if st.on_ground or st.landed then
                        Runtime.ticks_to_land = i
                        break
                    end
                end
            end
        end
    end

    local is_apex = false
    if airborne and UI.air_enable:get() and UI.air_apex_enable:get() then
        local apex_win = UI.air_apex_window:get()
        if abs_vz <= apex_win then
            is_apex = true
            Runtime.ticks_to_apex = 0
        else
            local ok_sim, sim_steps = pcall(engine.simulate, 12)
            if ok_sim and type(sim_steps) == "table" then
                for i = 1, #sim_steps do
                    local st = sim_steps[i]
                    if st and st.valid then
                        if st.on_ground or st.landed then
                            if Runtime.ticks_to_land < 0 then
                                Runtime.ticks_to_land = i
                            end
                            break
                        end
                        if st.velocity and math_abs(st.velocity.z) <= apex_win and Runtime.ticks_to_apex < 0 then
                            Runtime.ticks_to_apex = i
                            if i <= 2 then
                                is_apex = true
                            end
                        end
                    end
                end
            end
        end
    end

    Runtime.in_air  = airborne
    Runtime.in_apex = is_apex

    if airborne then
        Runtime.player_state = is_apex and STATE.AIR_APEX or STATE.AIR
    elseif is_ducking then
        Runtime.player_state = STATE.CROUCHING
    elseif is_slowwalk then
        Runtime.player_state = STATE.SLOWWALK
    elseif speed_2d > 8 then
        Runtime.player_state = STATE.MOVING
    else
        Runtime.player_state = STATE.STANDING
    end
end

local function evaluate_target_body_damage(local_pawn, eye_pos, target_pawn, base_dmg)
    local best_body_dmg = 0

    local stomach_pos = target_pawn:hitbox(3) or target_pawn:hitbox(2)
    local chest_pos   = target_pawn:hitbox(4) or target_pawn:hitbox(5)

    if not stomach_pos and not chest_pos then
        local ok_hbs, hbs = pcall(target_pawn.hitboxes, target_pawn)
        if ok_hbs and type(hbs) == "table" then
            for i = 1, #hbs do
                local hb = hbs[i]
                if hb and hb.center then
                    if hb.group == HITGROUP.STOMACH and not stomach_pos then
                        stomach_pos = hb.center
                    elseif hb.group == HITGROUP.CHEST and not chest_pos then
                        chest_pos = hb.center
                    end
                end
            end
        end
    end

    if not stomach_pos and not chest_pos then
        local orig = target_pawn:origin()
        if orig then
            stomach_pos = orig + vector(0, 0, 38)
            chest_pos   = orig + vector(0, 0, 52)
        end
    end

    if stomach_pos then
        local ok_d, dmg = pcall(trace.damage, target_pawn, stomach_pos, HITGROUP.STOMACH, eye_pos)
        if ok_d and type(dmg) == "number" and dmg > best_body_dmg then
            best_body_dmg = dmg
        else
            local ok_b, bul = pcall(trace.bullet, eye_pos, stomach_pos, target_pawn, HITGROUP.STOMACH)
            if ok_b and type(bul) == "table" then
                local bd = bul.target_damage or bul.damage or 0
                if bd > best_body_dmg then
                    best_body_dmg = bd
                end
            end
        end
    end

    if chest_pos then
        local ok_d, dmg = pcall(trace.damage, target_pawn, chest_pos, HITGROUP.CHEST, eye_pos)
        if ok_d and type(dmg) == "number" and dmg > best_body_dmg then
            best_body_dmg = dmg
        end
    end

    if best_body_dmg <= 0 then
        local ok_sc, scaled_stomach = pcall(trace.scale_damage, base_dmg, HITGROUP.STOMACH, target_pawn)
        if ok_sc and type(scaled_stomach) == "number" and scaled_stomach > 0 then
            best_body_dmg = scaled_stomach
        else
            local armor = target_pawn:armor() or 0
            local raw_stomach = base_dmg * 1.25
            best_body_dmg = armor > 0 and (raw_stomach * 0.78) or raw_stomach
        end
    end

    return math_floor(best_body_dmg)
end

local function scan_and_analyze_targets(local_pawn, base_dmg)
    Runtime.target_pawn      = nil
    Runtime.target_name      = "Ожидание цели"
    Runtime.target_hp        = 0
    Runtime.target_armor     = 0
    Runtime.target_dist_m    = 0.0
    Runtime.target_speed     = 0.0
    Runtime.target_in_air    = false
    Runtime.target_body_dmg  = 0
    Runtime.target_lethal    = false
    Runtime.target_baim_trig = false
    Runtime.baim_reason_str  = ""
    Runtime.lethal_map       = {}

    local eye_pos = local_pawn:eye_position() or local_pawn:origin()
    if not eye_pos then
        return
    end
    local view_ang = engine.view_angles() or local_pawn:eye_angles() or vector(0, 0, 0)

    local ok_pl, list = pcall(entity.players)
    if not ok_pl or type(list) ~= "table" then
        return
    end

    local best_pawn = nil
    local best_fov  = 999999.0

    local lethal_shots_req = UI.baim_lethal_shots:get()
    local hp_static_thresh = UI.baim_hp_threshold:get()

    for i = 1, #list do
        local entry = list[i]
        local pawn = entry and entry.pawn
        if pawn and pawn:alive() and pawn:is_enemy() and not pawn:is_local() then
            local t_origin = pawn:origin()
            if t_origin then
                local aim_ang = math.calc_angle(eye_pos, t_origin + vector(0, 0, 44))
                local dp = math.normalize_angle(view_ang.x - aim_ang.x)
                local dy = math.normalize_angle(view_ang.y - aim_ang.y)
                local fov_dist = math_sqrt(dp * dp + dy * dy)

                local t_hp = pawn:health() or 100
                local est_body_dmg = evaluate_target_body_damage(local_pawn, eye_pos, pawn, base_dmg)
                local is_lethal_enemy = (est_body_dmg * lethal_shots_req >= t_hp) or (t_hp <= hp_static_thresh)

                local addr_ok, addr = pcall(pawn.address, pawn)
                if addr_ok and addr then
                    Runtime.lethal_map[addr] = is_lethal_enemy
                end

                if fov_dist < best_fov then
                    best_fov  = fov_dist
                    best_pawn = pawn
                    Runtime.target_body_dmg = est_body_dmg
                    Runtime.target_lethal   = is_lethal_enemy
                end
            end
        end
    end

    if not best_pawn then
        return
    end

    Runtime.target_pawn   = best_pawn
    Runtime.target_name   = best_pawn:name() or "Враг"
    Runtime.target_hp     = best_pawn:health() or 100
    Runtime.target_armor  = best_pawn:armor() or 0
    local t_vel           = best_pawn:velocity() or vector(0, 0, 0)
    Runtime.target_speed  = t_vel:length2d()
    Runtime.target_in_air = not best_pawn:on_ground()

    local t_orig = best_pawn:origin()
    if t_orig then
        Runtime.target_dist_m = eye_pos:dist(t_orig) * 0.0254
    end

    if not UI.baim_enable:get() then
        return
    end

    local reasons = {}
    if Runtime.target_lethal then
        if Runtime.target_body_dmg >= Runtime.target_hp then
            table_insert(reasons, "1-SHOT LETHAL")
        elseif Runtime.target_hp <= hp_static_thresh then
            table_insert(reasons, string_format("LOW HP (%d)", Runtime.target_hp))
        else
            table_insert(reasons, string_format("%d-SHOT LETHAL", lethal_shots_req))
        end
    end

    if multi_selected(UI.baim_conditions, "Противник в воздухе", 1) and Runtime.target_in_air then
        table_insert(reasons, "TARGET AIR")
    end
    if multi_selected(UI.baim_conditions, "Высокая скорость цели", 2) and Runtime.target_speed >= UI.baim_target_speed:get() then
        table_insert(reasons, "FAST TARGET")
    end
    if multi_selected(UI.baim_conditions, "Игрок в приседе", 3) and Runtime.player_state == STATE.CROUCHING then
        table_insert(reasons, "CROUCH PRECISION")
    end
    if multi_selected(UI.baim_conditions, "Цель без брони", 4) and Runtime.target_armor <= 0 then
        table_insert(reasons, "NO ARMOR")
    end
    if multi_selected(UI.baim_conditions, "Дальняя дистанция (>28м)", 5) and Runtime.target_dist_m >= 28.0 then
        table_insert(reasons, "LONG RANGE")
    end

    if #reasons > 0 then
        Runtime.target_baim_trig = true
        Runtime.baim_reason_str  = table_concat(reasons, " + ")
    end
end

-- ============================================================================
-- 6. ГЛАВНЫЙ ОБРАБОТЧИК CREATEMOVE (RAGEBOT ACCURACY & ANTI-SPREAD CONTROLLER)
-- ============================================================================

local SAFEPOINT_ITEMS = {
    "Не изменять",
    "Предпочитать (Prefer)",
    "Принудительно (Force)"
}

local BAIM_HITBOX_ITEMS = {
    "Предпочитать тело (Грудь + Живот)",
    "Только тело (Отключить голову)",
    "Только Живот и Таз (Макс. множитель)"
}

events.on("createmove", function(cmd)
    if not UI.master_enable:get() then
        return
    end
    if not engine.in_game() then
        return
    end

    local local_pawn = entity.local_pawn()
    if not local_pawn or not local_pawn:alive() then
        return
    end

    analyze_local_state(local_pawn, cmd)

    local wep_info = get_active_weapon_info(local_pawn)
    local base_dmg = resolve_base_weapon_damage(wep_info)
    if wep_info then
        Runtime.weapon_name   = tostring(wep_info.display or wep_info.name or "Weapon")
        Runtime.weapon_inacc  = tonumber(wep_info.inaccuracy) or 0.0
        Runtime.weapon_spread = tonumber(wep_info.spread) or 0.0
    else
        Runtime.weapon_name   = "Active Weapon"
        Runtime.weapon_inacc  = 0.0
        Runtime.weapon_spread = 0.0
    end
    Runtime.total_spread = Runtime.weapon_inacc + Runtime.weapon_spread

    local max_spread_lim = UI.spread_max_limit:get()
    Runtime.spread_ratio = math_clamp(Runtime.total_spread / math_max(max_spread_lim, 0.001), 0.0, 2.0)
    Runtime.spread_warning = UI.spread_guard_enable:get() and (Runtime.total_spread > max_spread_lim)

    scan_and_analyze_targets(local_pawn, base_dmg)

    local target_hc   = UI.hc_standing:get()
    local target_md   = nil
    local target_sp   = 1
    local target_body = 0
    local reason_tags = {}

    local pstate = Runtime.player_state

    if pstate == STATE.AIR or pstate == STATE.AIR_APEX then
        if UI.air_enable:get() then
            if pstate == STATE.AIR_APEX and UI.air_apex_enable:get() then
                target_hc = UI.air_apex_hitchance:get()
                table_insert(reason_tags, "AIR-APEX")
            else
                target_hc = UI.air_hitchance:get()
                table_insert(reason_tags, "IN-AIR")
            end
            target_md = UI.air_min_damage:get()
            target_sp = combo_index(UI.air_safepoint, SAFEPOINT_ITEMS)
        end
    elseif UI.hc_enable:get() then
        if pstate == STATE.CROUCHING then
            target_hc = UI.hc_crouching:get()
        elseif pstate == STATE.SLOWWALK then
            target_hc = UI.hc_slowwalk:get()
        elseif pstate == STATE.MOVING then
            target_hc = UI.hc_moving:get()
        else
            target_hc = UI.hc_standing:get()
        end
    end

    if UI.hc_enable:get() and Runtime.target_pawn ~= nil then
        if Runtime.target_in_air then
            local bonus = UI.hc_target_air_bonus:get()
            if bonus > 0 then
                target_hc = target_hc + bonus
                table_insert(reason_tags, "T-AIR")
            end
        elseif Runtime.target_speed >= UI.baim_target_speed:get() then
            local bonus = UI.hc_target_vel_bonus:get()
            if bonus > 0 then
                target_hc = target_hc + bonus
                table_insert(reason_tags, "T-FAST")
            end
        end

        if Runtime.target_hp > 0 and Runtime.target_hp <= 25 then
            local relax = UI.hc_low_hp_relax:get()
            if relax > 0 then
                target_hc = target_hc - relax
                table_insert(reason_tags, "FINISHER")
            end
        end
    end

    local manual_baim = UI.force_baim_bind:active()
    if manual_baim then
        target_body = 2
        target_sp   = 3
        table_insert(reason_tags, "FORCE-BAIM [KEY]")
    elseif UI.baim_enable:get() and Runtime.target_baim_trig then
        target_body = combo_index(UI.baim_hitbox_mode, BAIM_HITBOX_ITEMS)
        local baim_sp = combo_index(UI.baim_safepoint, SAFEPOINT_ITEMS)
        if baim_sp > target_sp then
            target_sp = baim_sp
        end
        if Runtime.target_lethal and Runtime.target_hp > 0 then
            local lethal_md = math_clamp(Runtime.target_hp + 2, 1, 120)
            if target_md == nil or lethal_md < target_md then
                target_md = lethal_md
            end
        end
        table_insert(reason_tags, "SMART-BAIM")
    end

    if UI.spread_guard_enable:get() then
        if Runtime.spread_ratio >= 0.75 and UI.spread_force_safe:get() then
            target_sp = 3
            target_hc = target_hc + 6
            table_insert(reason_tags, "SPREAD-SAFE")
        end
    end

    if UI.quick_precision_bind:active() then
        target_hc = target_hc + 12
        target_sp = 3
        table_insert(reason_tags, "STRICT [KEY]")
    end

    if UI.min_dmg_bind:active() then
        target_md = UI.min_dmg_bind_val:get()
        table_insert(reason_tags, string_format("DMG:%d [KEY]", target_md))
    end

    target_hc = math_clamp(math_round(target_hc), 1, 100)

    Runtime.shot_gated = false
    local wants_attack = cmd:has(BTN_ATTACK)

    if wants_attack then
        local gate_air = Runtime.in_air
            and UI.air_enable:get()
            and UI.air_apex_enable:get()
            and UI.air_gate_fire:get()
            and (not Runtime.in_apex)

        local gate_spread = UI.spread_guard_enable:get()
            and UI.spread_block_shot:get()
            and Runtime.spread_warning

        if gate_air or gate_spread then
            cmd:release(BTN_ATTACK)
            pcall(cmd.remove_button, cmd, BTN_ATTACK)
            Runtime.shot_gated = true
            table_insert(reason_tags, gate_air and "WAIT-APEX" or "SPREAD-GATE")
        end
    end

    Runtime.active_hc        = target_hc
    Runtime.active_md        = target_md or (Bridge.baseline_ctrl.min_damage or 50)
    Runtime.active_sp        = target_sp
    Runtime.active_body_mode = target_body
    Runtime.override_reason  = #reason_tags > 0 and table_concat(reason_tags, " • ") or "БАЗОВЫЙ ПРОФИЛЬ"

    Bridge.apply(target_hc, target_md, target_sp, target_body)
end)

-- ============================================================================
-- 7. ИГРОВЫЕ СОБЫТИЯ И СТАТИСТИКА ТОЧНОСТИ (GAME EVENTS & ESP)
-- ============================================================================

events.on("weapon_fire", function(ev)
    if not UI.master_enable:get() then
        return
    end
    local local_pawn = entity.local_pawn()
    if not local_pawn then
        return
    end
    local ok_p, shooter = pcall(ev.get_pawn, ev, "userid")
    if ok_p and shooter and shooter == local_pawn then
        Runtime.shots_fired = Runtime.shots_fired + 1
    end
end)

events.on("player_hurt", function(ev)
    if not UI.master_enable:get() then
        return
    end
    local local_pawn = entity.local_pawn()
    if not local_pawn then
        return
    end
    local ok_att, attacker = pcall(ev.get_pawn, ev, "attacker")
    if ok_att and attacker and attacker == local_pawn then
        Runtime.shots_hit = Runtime.shots_hit + 1
    end
end)

events.on("round_start", function()
    Runtime.lethal_map = {}
end)

local esp_lethal_el = nil
local function register_esp_element()
    if not esp or not esp.add_text then
        return
    end
    local ok, el = pcall(esp.add_text, "0x Lethal Baim", function(ent)
        if not UI.master_enable:get() or not UI.esp_tag_enable:get() then
            return ""
        end
        if not ent or not ent:alive() or not ent:is_enemy() then
            return ""
        end
        local ok_a, addr = pcall(ent.address, ent)
        if ok_a and addr and Runtime.lethal_map[addr] then
            return "0x LETHAL [BAIM]"
        end
        return ""
    end, {
        side  = "right",
        color = color(235, 240, 250, 255),
        small = true,
        text  = true
    })
    if ok then
        esp_lethal_el = el
    end
end
register_esp_element()

-- ============================================================================
-- 8. ОТРИСОВКА ЭКРАННОГО ИНДИКАТОРА В PAINT (MINIMALIST TELEMETRY HUD)
-- ============================================================================

local COL_BG_DARK   = color(10, 11, 14, 230)
local COL_BG_HEADER = color(16, 18, 22, 245)
local COL_BORDER    = color(38, 42, 50, 220)
local COL_TEXT_MAIN = color(238, 240, 245, 255)
local COL_TEXT_DIM  = color(142, 148, 160, 255)
local COL_OK        = color(74, 222, 128, 255)
local COL_WARN      = color(250, 204, 21, 255)
local COL_DANGER    = color(248, 113, 113, 255)

local HUD_STYLE_ITEMS = {
    "Панель телеметрии + Индикатор у прицела",
    "Только панель телеметрии",
    "Только компактный блок у прицела"
}

local SP_LABELS = {
    [1] = "DEFAULT",
    [2] = "PREFER",
    [3] = "FORCE"
}

local BODY_LABELS = {
    [0] = "HEAD + BODY",
    [1] = "PREFER BODY",
    [2] = "ONLY BODY",
    [3] = "STOMACH ONLY"
}

events.on("paint", function()
    if not UI.master_enable:get() or not UI.hud_enable:get() then
        return
    end
    if not engine.in_game() then
        return
    end

    local local_pawn = entity.local_pawn()
    if not local_pawn or not local_pawn:alive() then
        return
    end

    local style_idx = combo_index(UI.hud_style, HUD_STYLE_ITEMS)
    local accent    = UI.hud_accent:get() or color(230, 235, 245, 255)
    local sw, sh    = render.screen_size()

    if style_idx == 1 or style_idx == 2 then
        local px = math_clamp(UI.hud_x:get(), 4, math_max(4, sw - 260))
        local py = math_clamp(UI.hud_y:get(), 4, math_max(4, sh - 170))
        local pw = 248
        local ph = 148

        render.blur(px, py, pw, ph, 4, color(10, 11, 14, 180))
        render.rect_filled(px, py, pw, ph, COL_BG_DARK, 4)
        render.rect_filled(px, py, pw, 24, COL_BG_HEADER, 4)
        render.rect(px, py, pw, ph, COL_BORDER, 4, 1)

        render.rect_filled(px + 1, py + 1, pw - 2, 2, accent, 2)

        render.text(px + 10, py + 6, COL_TEXT_MAIN, "0x ACCURACY CORE")
        local state_tag = STATE_SHORT[Runtime.player_state] or "STND"
        local tag_w = render.text_size(state_tag)
        render.text(px + pw - tag_w - 10, py + 6, accent, state_tag)

        local r1_y = py + 31
        render.text(px + 10, r1_y, COL_TEXT_DIM, "Режим:")
        render.text(px + 62, r1_y, COL_TEXT_MAIN, Runtime.override_reason)

        local r2_y = py + 49
        render.text(px + 10, r2_y, COL_TEXT_DIM, "Хитшанс:")
        render.text(px + 72, r2_y, accent, string_format("%d%%", Runtime.active_hc))

        render.text(px + 126, r2_y, COL_TEXT_DIM, "Мин. урон:")
        render.text(px + 195, r2_y, COL_TEXT_MAIN, string_format("%d", Runtime.active_md))

        local r3_y = py + 67
        local hb_str = BODY_LABELS[Runtime.active_body_mode] or "HEAD + BODY"
        local hb_col = Runtime.active_body_mode > 0 and COL_OK or COL_TEXT_MAIN
        render.text(px + 10, r3_y, COL_TEXT_DIM, "Приоритет:")
        render.text(px + 82, r3_y, hb_col, string_format("%s [%s]", hb_str, SP_LABELS[Runtime.active_sp] or "DEF"))

        local r4_y = py + 85
        render.text(px + 10, r4_y, COL_TEXT_DIM, "Цель:")
        if Runtime.target_pawn ~= nil then
            local t_col = Runtime.target_lethal and COL_OK or COL_TEXT_MAIN
            local t_info = string_format("%s (%d HP | Тело: %d)", Runtime.target_name, Runtime.target_hp, Runtime.target_body_dmg)
            render.text(px + 50, r4_y, t_col, t_info)
        else
            render.text(px + 50, r4_y, COL_TEXT_DIM, "Сканирование сектора...")
        end

        local r5_y = py + 106
        local spread_pct = math_clamp(1.0 - (Runtime.spread_ratio * 0.5), 0.0, 1.0)
        local bar_col = Runtime.spread_warning and COL_DANGER or (Runtime.spread_ratio > 0.75 and COL_WARN or accent)

        render.text(px + 10, r5_y, COL_TEXT_DIM, string_format("Разброс: %.4f", Runtime.total_spread))
        local gate_str = Runtime.shot_gated and "GATE HOLD" or (Runtime.in_apex and "APEX READY" or "READY")
        local gw = render.text_size(gate_str)
        render.text(px + pw - gw - 10, r5_y, Runtime.shot_gated and COL_WARN or COL_OK, gate_str)

        local bar_x = px + 10
        local bar_y = py + 126
        local bar_w = pw - 20
        render.rect_filled(bar_x, bar_y, bar_w, 6, color(24, 27, 34, 255), 3)
        render.rect_filled(bar_x, bar_y, math_max(4, math_floor(bar_w * spread_pct)), 6, bar_col, 3)
    end

    if style_idx == 1 or style_idx == 3 then
        local cx = math_floor(sw * 0.5)
        local cy = math_floor(sh * 0.5) + 28

        local main_tag = string_format("0x [%s] HC:%d%%", STATE_SHORT[Runtime.player_state] or "STND", Runtime.active_hc)
        local tw = render.text_size(main_tag)
        render.text(cx - math_floor(tw * 0.5), cy, accent, main_tag)

        if Runtime.active_body_mode > 0 then
            local b_tag = Runtime.target_lethal and "LETHAL BODY-AIM" or "BODY-AIM ACTIVE"
            local bw = render.text_size(b_tag)
            render.text(cx - math_floor(bw * 0.5), cy + 14, COL_OK, b_tag)
        elseif Runtime.shot_gated then
            local g_tag = "WAITING SPREAD / APEX"
            local gw = render.text_size(g_tag)
            render.text(cx - math_floor(gw * 0.5), cy + 14, COL_WARN, g_tag)
        end
    end
end)

-- ============================================================================
-- 9. ИНИЦИАЛИЗАЦИЯ И ЧИСТАЯ ВЫГРУЗКА (INIT & UNLOAD)
-- ============================================================================

Bridge.scan()
log.console(string_format("[0x] Core v%s initialized. Synced controls: %d", SCRIPT_VERSION, Bridge.synced_keys_count))

events.on("unload", function()
    Bridge.restore_all()
    if esp_lethal_el and esp_lethal_el.remove then
        pcall(esp_lethal_el.remove, esp_lethal_el)
    elseif esp and esp.remove then
        pcall(esp.remove, "0x Lethal Baim")
    end
    log.console("[0x] Unloaded cleanly and restored baseline Ragebot controls.")
end)
