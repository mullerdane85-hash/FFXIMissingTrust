--[[
Copyright © 2026, mullerdane85-hash
All rights reserved. BSD-3-Clause. See LICENSE.

FFXIMissingSpells — quick visual reference for which spells your
character still needs to learn, broken out by magic-using job.
Twelve tabs (WHM / BLM / RDM / PLD / DRK / BRD / NIN / SMN / BLU /
GEO / SCH / RUN) each list every spell the job can learn at lv 1-99
with a colored prefix:

    - red    you don't have this spell scrolled yet
    + green  already learned

Filter sub-tabs in the title bar (Missing / Owned / All) trim the
list to whichever subset you want. Click any row for a BG-Wiki info
panel: NPC, recipe, vendor, description, trust party-name, etc.
]]

_addon.name     = 'FFXIMissingSpells'
_addon.author   = 'mullerdane85-hash'
_addon.version  = '1.0'
-- Bare //ms toggles the window. //mt is kept as a back-compat alias so
-- anyone who scripted the older FFXIMissingTrust commands keeps working.
_addon.commands = {'missingspells', 'mspells', 'ms', 'mt', 'mtrust'}

-- =============================================================================
-- FFXIMissingSpells
--
-- Shows which spells your character still needs to learn, broken out by
-- magic-using job. Same idea as FFXIMissingTrust but for the full spell
-- book — twelve job tabs across the top (WHM / BLM / RDM / PLD / DRK /
-- BRD / NIN / SMN / BLU / GEO / SCH / RUN), each listing every spell
-- the job can learn at lv 1-99 with a colored prefix:
--
--   - red  → you don't have this spell scrolled yet
--   + green → already learned
--
-- Filter sub-tabs in the title bar (Missing / Owned / All) cut the list
-- to whichever subset you care about.
--
-- Window:       //ms show | hide | toggle      (or just //ms)
-- Chat summary: //ms count               (current tab)
--               //ms count WHM
-- Chat list:    //ms list  | //ms list WHM    (missing for that job)
--               //ms have  | //ms have BLM    (owned)
--               //ms find <name>              (search across every job)
--
-- The data source is res.spells filtered by `spell.levels[job_id]` ≤ 99
-- (i.e. spells the job CAN learn natively, ignoring sub-job). Trust
-- spells are skipped — they have their own addon (FFXIMissingTrust /
-- now folded here is OPT-IN later; for now, trusts stay separate).
-- =============================================================================

require('luau')
local config = require('config')
local res    = require('resources')
local texts  = require('texts')
local images = require('images')

-- =============================================================================
-- Spell-acquisition data tables.
--
-- The two main tables (acquisition.lua + acquisition_full.lua) were generated
-- from a CSV provided by ISOLRAINE @ ASURA. Every vendor name, NPC location,
-- gil price, monster drop, BCNM source, and Blue Magic mob list shown in the
-- detail pane comes from Isolraine's tables — full credit there. See README
-- for the prominent credit block.
-- =============================================================================

-- Short tag (e.g. "Drop / Vendor", "Quest / BCNM"). Indexed by spell.en.
local spell_acquisition = require('libs/acquisition')

-- Full acquisition detail (vendor names, NPC coords, gil prices, mob lists).
-- Shown in the click-locked detail pane.
local spell_acquisition_full = require('libs/acquisition_full')

-- Hand-curated additions for spells that weren't in the original CSV
-- (SMN avatars, BLM/RDM tier-V upgrades, BRD higher-tier songs, NIN
-- "Ni"/"San" scrolls, a few singletons). These entries get used for
-- BOTH the in-row tag and the full hover tooltip.
local spell_acquisition_extra = require('libs/acquisition_extra')

-- Auto-generated trust info (Job / Spells / Abilities / Weapon Skills /
-- Acquisition / Special Features) scraped from BG-Wiki Cipher: pages.
-- Used by the TRUST tab's right-panel rendering. Trusts whose
-- BG-Wiki cipher page is a stub (older Story-of-Vana'diel trusts)
-- have an empty table entry; the renderer falls back to "(no
-- detailed wiki info available)" in that case.
local trust_info = require('libs/trust_info')

-- Auto-generated COR die data (BG-Wiki Category:Dice). 31 dice, each
-- teaching a Phantom Roll. Used by the COR tab to populate rows and by
-- build_die_info_lines() to render Description / Purchased / Obtained.
local dice_info = require('libs/dice_info')

-- Auto-generated BLU spell info (BG-Wiki Category:Blue_Magic). 199
-- spells with description / target / stat_bonus / creates_trait /
-- notes / obtainment (monster + level + zone). Used on the BLU tab to
-- replace the generic acquisition_full rendering with a structured
-- panel that mirrors the BG-Wiki layout.
local blu_info = require('libs/blu_info')

-- Auto-generated spell info for ALL learnable spells (BG-Wiki
-- Category:Spells, ~773 entries). Per spell: description, type, skill,
-- element, target, notes, dropped_from (monster + level + zone + rate
-- + notes), purchased_from (npc + zone + notes). Used by every non-COR
-- non-TRUST job tab to render a structured info panel on click. The
-- BLU tab still prefers blu_info first for the Stat Bonus / Creates
-- Job Trait fields BLU spells uniquely have.
local spell_info = require('libs/spell_info')
local hotkey = require('libs/hotkey')

-- Helper: short tag for a spell name. Tries the curated extras first,
-- then the CSV-derived short table, then derives a BLU family name
-- from the full-detail text if the spell is a Blue Magic learn, then
-- falls back to ''.
local function acquisition_tag_for(spell_name)
    if not spell_name then return '' end
    -- Curated extras: use as-is (truncate to keep the in-row column
    -- readable — the tooltip still shows the full text).
    local x = spell_acquisition_extra[spell_name]
    if x then return x:sub(1, 30) end
    -- For BLU spells the CSV's short-tag fallback was just "Blue Magic",
    -- which is unhelpful in the column. Pull the [Family: X] from the
    -- full detail and surface it as "BLU: <family>".
    local full = spell_acquisition_full[spell_name]
    if full then
        local family = full:match('Blue Magic %[Family: ([^%]]+)%]')
        if family then return 'BLU: ' .. family end
    end
    return spell_acquisition[spell_name] or ''
end

-- Helper: full detail (tooltip text). Prefers extras over CSV; falls
-- back to '' when nothing is known for that spell.
local function acquisition_full_for(spell_name)
    if not spell_name then return '' end
    return spell_acquisition_extra[spell_name]
        or spell_acquisition_full[spell_name]
        or ''
end

-- ---------------------------------------------------------------------------
-- Tab list across the top of the window. 'TRUST' is special — it's not a
-- res.jobs entry, it's the original FFXIMissingTrust functionality folded
-- in as a tab. The other twelve are job ens codes that match res.jobs.
-- ---------------------------------------------------------------------------
local JOB_TABS = { 'TRUST','WHM','BLM','RDM','PLD','DRK','BRD','NIN','SMN','BLU','GEO','SCH','RUN','COR' }

-- ens (e.g. 'WHM') → numeric job id. Populated from res.jobs at load.
local job_id_by_ens = {}
for jid, j in pairs(res.jobs) do
    if j and j.ens then job_id_by_ens[j.ens] = jid end
end

-- (is_trust_tab is defined further down, AFTER the settings local exists —
-- otherwise it would capture `settings` as a global lookup and always
-- return nil/false.)

-- ---------------------------------------------------------------------------
-- Trust → combat job (FFXI's spell data doesn't expose this — it's hand-
-- curated from BG-Wiki). Editable; alphabetical for easy upkeep.
-- ---------------------------------------------------------------------------
local JOB_BY_TRUST = {
    -- Ark Angel (Vagary) trusts — Five Race Avatars
    ["AAEV"]             = "?",
    ["AAGK"]             = "?",
    ["AAHM"]             = "?",
    ["AAMR"]             = "?",
    ["AATT"]             = "?",

    ["Abenzio"]          = "THF",
    ["Abquhbah"]         = "WAR",
    ["Adelheid"]         = "SCH",
    ["Ajido-Marujido"]   = "BLM",
    ["Aldo"]             = "THF",
    ["Aldo (UC)"]        = "THF",
    ["Amchuchu"]         = "RUN",
    ["Apururu (UC)"]     = "WHM",
    ["Arciela"]          = "RDM",
    ["Arciela II"]       = "RDM",
    ["Areuhat"]          = "DRK",
    ["August"]           = "PLD",
    ["Ayame"]            = "SAM",
    ["Ayame (UC)"]       = "SAM",
    ["Babban"]           = "DNC",
    ["Balamor"]          = "DRK",
    ["Brygid"]           = "WHM",
    ["Chacharoon"]       = "THF",
    ["Cherukiki"]        = "WHM",
    ["Cid"]              = "WAR",
    ["Cornelia"]         = "MNK",
    ["Curilla"]          = "PLD",
    ["D. Shantotto"]     = "BLM",
    ["Darrcuiln"]        = "WAR",
    ["Elivira"]          = "RDM",
    ["Excenmille"]       = "PLD",
    ["Excenmille [S]"]   = "PLD",
    ["Fablinix"]         = "THF",
    ["Ferreous Coffin"]  = "WHM",
    ["Flaviria (UC)"]    = "DRG",
    ["Gadalar"]          = "BLM",
    ["Gessho"]           = "NIN",
    ["Gilgamesh"]        = "SAM",
    ["Halver"]           = "PLD",
    ["I. Shield (UC)"]   = "PLD",
    ["Ingrid"]           = "PLD",
    ["Ingrid II"]        = "PLD",
    ["Iroha"]            = "SAM",
    ["Iroha II"]         = "SAM",
    ["Iron Eater"]       = "WAR",
    ["Jakoh (UC)"]       = "WAR",
    ["Joachim"]          = "BRD",
    ["Karaha-Baruha"]    = "WHM",
    ["Kayeel-Payeel"]    = "BLM",
    ["King of Hearts"]   = "PLD",
    ["Klara"]            = "WAR",
    ["Koru-Moru"]        = "RDM",
    ["Kukki-Chebukki"]   = "THF",
    ["Kupipi"]           = "WHM",
    ["Kupofried"]        = "GEO",
    ["Kuyin Hathdenna"]  = "DRG",
    ["Lehko Habhoka"]    = "THF",
    ["Leonoyne"]         = "DRG",
    ["Lhe Lhangavo"]     = "MNK",
    ["Lhu Mhakaracca"]   = "BST",
    ["Lilisette"]        = "DNC",
    ["Lilisette II"]     = "DNC",
    ["Lion"]             = "THF",
    ["Lion II"]          = "THF",
    ["Luzaf"]            = "COR",
    ["Maat"]             = "MNK",
    ["Maat (UC)"]        = "MNK",
    ["Makki-Chebukki"]   = "THF",
    ["Margret"]          = "RNG",
    ["Matsui-P"]         = "GEO",
    ["Maximilian"]       = "PLD",
    ["Mayakov"]          = "DNC",
    ["Mihli Aliapoh"]    = "WHM",
    ["Mildaurion"]       = "WHM",
    ["Mnejing"]          = "WAR",
    ["Monberaux"]        = "WHM",
    ["Moogle"]           = "RDM",
    ["Morimar"]          = "BST",
    ["Mumor"]            = "DNC",
    ["Mumor II"]         = "BRD",
    ["Naja (UC)"]        = "WAR",
    ["Naja Salaheem"]    = "WAR",
    ["Najelith"]         = "RNG",
    ["Naji"]             = "THF",
    ["Nanaa Mihgo"]      = "THF",
    ["Nashmeira"]        = "WHM",
    ["Nashmeira II"]     = "PUP",
    ["Noillurie"]        = "WHM",
    ["Ovjang"]           = "RDM",
    ["Pieuje (UC)"]      = "WHM",
    ["Prishe"]           = "MNK",
    ["Prishe II"]        = "MNK",
    ["Qultada"]          = "COR",
    ["Rahal"]            = "PLD",
    ["Rainemard"]        = "RDM",
    ["Robel-Akbel"]      = "BLM",
    ["Romaa Mihgo"]      = "THF",
    ["Rongelouts"]       = "PLD",
    ["Rosulatia"]        = "SCH",
    ["Rughadjeen"]       = "PLD",
    ["Sakura"]           = "NIN",
    ["Selh'teus"]        = "DRG",
    ["Semih Lafihna"]    = "RNG",
    ["Shantotto"]        = "BLM",
    ["Shantotto II"]     = "BLM",
    ["Shikaree Z"]       = "RNG",
    ["Star Sibyl"]       = "WHM",
    ["Sylvie (UC)"]      = "GEO",
    ["Tenzen"]           = "SAM",
    ["Tenzen II"]        = "SAM",
    ["Teodor"]           = "BLM",
    ["Trion"]            = "PLD",
    ["Uka Totlihn"]      = "DNC",
    ["Ullegore"]         = "DRK",
    ["Ulmia"]            = "BRD",
    ["Valaineral"]       = "PLD",
    ["Volker"]           = "WAR",
    ["Ygnas"]            = "WAR",
    ["Yoran-Oran (UC)"]  = "WHM",
    ["Zazarg"]           = "MNK",
    ["Zeid"]             = "DRK",
    ["Zeid II"]          = "DRK",
}
local function trust_job(name) return JOB_BY_TRUST[name] or "?" end

-- ---------------------------------------------------------------------------
-- Trust → role descriptor (curated from BG-Wiki). Format:
--   "Tank" | "Healer" | "DPS Melee <weapon>" | "DPS Ranged <weapon>" |
--   "DPS Magic" | "Support" | "Support <aura>"
-- ---------------------------------------------------------------------------
local DESC_BY_TRUST = {
    ["AAEV"]              = "Tank",
    ["AAGK"]              = "DPS Melee GA",
    ["AAHM"]              = "Tank",
    ["AAMR"]              = "DPS Melee Dagger",
    ["AATT"]              = "DPS Magic",

    ["Abenzio"]           = "DPS Melee Dagger",
    ["Abquhbah"]          = "DPS Melee Axe",
    ["Adelheid"]          = "DPS Magic",
    ["Ajido-Marujido"]    = "DPS Magic",
    ["Aldo"]              = "DPS Melee Dagger",
    ["Amchuchu"]          = "Tank",
    ["Areuhat"]           = "DPS Melee Scythe",
    ["Arciela"]           = "Support Debuffs",
    ["Arciela II"]        = "Support Debuffs",
    ["August"]            = "Tank",
    ["Ayame"]             = "DPS Melee GK",
    ["Babban"]            = "DPS Melee Dagger",
    ["Balamor"]           = "DPS Melee Sword",
    ["Brygid"]            = "Support Erase",
    ["Chacharoon"]        = "DPS Melee Dagger",
    ["Cherukiki"]         = "Healer",
    ["Cid"]               = "DPS Melee GA",
    ["Cornelia"]          = "DPS Melee H2H",
    ["Curilla"]           = "Tank",
    ["D. Shantotto"]      = "DPS Magic",
    ["Darrcuiln"]         = "DPS Melee H2H",
    ["Elivira"]           = "DPS Ranged Bow",
    ["Excenmille"]        = "Tank",
    ["Excenmille [S]"]    = "Tank",
    ["Fablinix"]          = "DPS Melee Dagger",
    ["Ferreous Coffin"]   = "Healer",
    ["Gadalar"]           = "DPS Magic",
    ["Gessho"]            = "Tank",
    ["Gilgamesh"]         = "DPS Melee GK",
    ["Halver"]            = "Tank",
    ["Ingrid"]            = "DPS Magic",
    ["Ingrid II"]         = "DPS Melee Sword",
    ["Iroha"]             = "DPS Melee GK",
    ["Iroha II"]          = "DPS Melee GK",
    ["Iron Eater"]        = "DPS Melee GA",
    ["Joachim"]           = "Support Honor March",
    ["Karaha-Baruha"]     = "Healer",
    ["Kayeel-Payeel"]     = "DPS Magic",
    ["King of Hearts"]    = "Support Haste",
    ["Klara"]             = "DPS Ranged Gun",
    ["Koru-Moru"]         = "Support Haste II/Refresh II",
    ["Kukki-Chebukki"]    = "DPS Magic",
    ["Kupipi"]            = "Healer",
    ["Kupofried"]         = "Support Refresh",
    ["Kuyin Hathdenna"]   = "Support",
    ["Lehko Habhoka"]     = "DPS Melee Dagger",
    ["Leonoyne"]          = "DPS Magic",
    ["Lhe Lhangavo"]      = "DPS Melee H2H",
    ["Lhu Mhakaracca"]    = "DPS Melee + Pet",
    ["Lilisette"]         = "DPS Melee Dagger",
    ["Lilisette II"]      = "DPS Melee Dagger",
    ["Lion"]              = "DPS Melee Dagger",
    ["Lion II"]           = "DPS Melee Dagger",
    ["Luzaf"]             = "DPS Ranged Gun",
    ["Maat"]              = "DPS Melee H2H",
    ["Makki-Chebukki"]    = "DPS Ranged Bow",
    ["Margret"]           = "DPS Ranged Bow",
    ["Matsui-P"]          = "Support GEO",
    ["Maximilian"]        = "Tank",
    ["Mayakov"]           = "DPS Melee Dagger",
    ["Mihli Aliapoh"]     = "Healer",
    ["Mildaurion"]        = "DPS Melee Sword",
    ["Mnejing"]           = "Tank",
    ["Monberaux"]         = "Healer",
    ["Moogle"]            = "Support",
    ["Morimar"]           = "DPS Melee + Pet",
    ["Mumor"]             = "DPS Melee Dagger",
    ["Mumor II"]          = "Support Songs",
    ["Naja Salaheem"]     = "DPS Melee GA",
    ["Najelith"]          = "DPS Ranged Bow",
    ["Naji"]              = "DPS Melee Dagger",
    ["Nanaa Mihgo"]       = "DPS Melee Dagger",
    ["Nashmeira"]         = "DPS Melee Sword",
    ["Nashmeira II"]      = "DPS Melee + Auto",
    ["Noillurie"]         = "DPS Melee H2H",
    ["Ovjang"]            = "Support Debuffs",
    ["Prishe"]            = "DPS Melee H2H",
    ["Prishe II"]         = "DPS Melee H2H",
    ["Qultada"]           = "Support COR Rolls",
    ["Rahal"]             = "Tank",
    ["Rainemard"]         = "DPS Melee Sword",
    ["Robel-Akbel"]       = "DPS Magic",
    ["Romaa Mihgo"]       = "DPS Melee Dagger",
    ["Rongelouts"]        = "Tank",
    ["Rosulatia"]         = "DPS Magic",
    ["Rughadjeen"]        = "Tank",
    ["Sakura"]            = "DPS Melee Katana",
    ["Selh'teus"]         = "DPS Melee Polearm",
    ["Semih Lafihna"]     = "DPS Ranged Bow",
    ["Shantotto"]         = "DPS Magic",
    ["Shantotto II"]      = "DPS Magic",
    ["Shikaree Z"]        = "DPS Ranged Bow",
    ["Star Sibyl"]        = "Support",
    ["Tenzen"]            = "DPS Melee GK",
    ["Tenzen II"]         = "DPS Ranged Bow",
    ["Teodor"]            = "DPS Magic",
    ["Trion"]             = "Tank",
    ["Uka Totlihn"]       = "DPS Melee Dagger",
    ["Ullegore"]          = "DPS Magic",
    ["Ulmia"]             = "Support Songs",
    ["Valaineral"]        = "Tank",
    ["Volker"]            = "DPS Melee GA",
    ["Ygnas"]             = "Healer",
    ["Zazarg"]            = "DPS Melee H2H",
    ["Zeid"]              = "DPS Melee GS",
    ["Zeid II"]           = "DPS Melee GS",
}
local function trust_desc(name) return DESC_BY_TRUST[name] or "" end

-- ---------------------------------------------------------------------------
-- Settings (persistent — saved to data/settings.xml)
-- ---------------------------------------------------------------------------
local defaults = {
    pos      = { x = 220, y = 220 },
    visible  = false,
    mode     = 'missing',    -- missing | owned | all
    job      = 'TRUST',      -- one of JOB_TABS (TRUST is the original use case)
    -- Click-locked spell whose acquisition detail shows in the right-side
    -- detail pane. '' means nothing selected -> pane shows a hint.
    selected_spell = '',
}
local settings = config.load(defaults)

-- Guard against a stale settings file picking a job we no longer support.
local function is_valid_job(j)
    for _, v in ipairs(JOB_TABS) do if v == j then return true end end
    return false
end
if not is_valid_job(settings.job) then settings.job = 'TRUST' end
config.save(settings)

-- Now that `settings` exists as a local in this chunk, define the helper
-- (Lua captures `settings` lexically at definition time).
local function is_trust_tab() return settings.job == 'TRUST' end
local function is_cor_tab()   return settings.job == 'COR'   end

-- ---------------------------------------------------------------------------
-- Visual constants — same family as FFXIMissingTrust (red/pink palette) so
-- the two windows feel like siblings.
-- ---------------------------------------------------------------------------
local BORDER       = 3
local TITLE_BAR_H  = 30
local JOB_TAB_H    = 22       -- new row beneath title bar holding 12 job tabs
local TAB_H        = 22
local TAB_GAP      = 4
local SUMMARY_H    = 26
local ROW_H        = 18
local SCROLL_BTN_H = 20
local PAD          = 8
local PANEL_W      = 1040     -- wider to fit a right-side detail pane (~340px)
local DETAIL_W     = 340      -- width of the right-side detail pane (info column)
local VISIBLE_ROWS = 22

-- Colors (alpha, r, g, b)
local C_BORDER     = { 220, 70,  130, 200 }
local C_TITLE_BG   = { 240, 30,  60,  120 }
local C_TITLE_TXT  = { 255, 200, 200, 230 }
local C_BODY_BG    = { 200, 15,  15,  35  }
local C_JOB_BAR_BG = { 220, 20,  30,  60  }      -- background strip behind job tabs
local C_TAB_ON     = { 240, 50,  100, 180 }
local C_TAB_OFF    = { 180, 30,  40,  70  }
local C_TAB_TXT_ON = { 255, 255, 255, 255 }
local C_TAB_TXT_OFF= { 255, 160, 160, 200 }
local C_SUMMARY    = { 255, 230, 230, 150 }
local C_MISSING    = { 255, 255, 130, 130 }
local C_OWNED      = { 255, 130, 230, 130 }
local C_LEVEL      = { 255, 200, 200, 240 }      -- "[Lv 99]" prefix
local C_SKILL      = { 255, 170, 200, 230 }      -- skill-name column on the right
local C_UC_DIM     = { 180, 180, 180, 200 }      -- Unity Concord rows (informational)
local C_ACQUIRE    = { 255, 150, 220, 180 }      -- "where to get" middle column (greenish)
local C_SCROLL_BG  = { 200, 40,  50,  90  }
local C_SCROLL_TXT = { 255, 255, 255, 255 }
local C_SCROLL_OFF = { 80,  40,  50,  90  }
local C_SCROLL_TXT_OFF = { 100, 200, 200, 200 }

-- ---------------------------------------------------------------------------
-- Chat colors (used by chat commands)
-- ---------------------------------------------------------------------------
local CHAT_HEADER  = 207
local CHAT_OWNED   = 158
local CHAT_MISSING = 167
local CHAT_ITEM    = 160

-- ---------------------------------------------------------------------------
-- UI element factories — same shape as GSUI's make_bg / make_text
-- ---------------------------------------------------------------------------
local function make_bg(x, y, w, h, c)
    return images.new({
        color = { alpha = c[1], red = c[2], green = c[3], blue = c[4] },
        pos   = { x = x, y = y },
        size  = { width = w, height = h },
        draggable = false,
    })
end

local function make_text(content, x, y, c, size, bold)
    local t = texts.new({
        text = { size = size or 10, font = 'Consolas',
            alpha = c[1] or 255, red = c[2] or 255, green = c[3] or 255, blue = c[4] or 255,
            stroke = { width = 1, alpha = 180, red = 0, green = 0, blue = 0 },
        },
        bg = { alpha = 0 },
        pos = { x = x, y = y },
        flags = { draggable = false, bold = bold or false },
    })
    t:text(content)
    return t
end

local function show(el)   if el and el.show then el:show() end end
local function hide(el)   if el and el.hide then el:hide() end end
local function destroy(el)
    if not el then return end
    if el.hide then el:hide() end
    if el.destroy then el:destroy() end
end

-- ---------------------------------------------------------------------------
-- Data layer
-- ---------------------------------------------------------------------------

-- Friendly label for a spell's "skill" field. spell.skill is a numeric id
-- into res.skills, BUT the IDs in there cover combat skills too (Sword,
-- Hand-to-Hand, etc.) and not every spell has a skill set. Fall back to
-- spell.type (e.g. 'WhiteMagic', 'Ninjutsu', 'Geomancy') which is always
-- populated and is the more useful classification anyway.
--
-- All labels are kept short (≤8 chars) so they don't run off the right
-- edge of the body inside the skill column. Full res.skills names like
-- "Enhancing Magic" are 15+ chars which overflows visibly.
local SKILL_LABEL = {
    WhiteMagic   = 'White',
    BlackMagic   = 'Black',
    DarkMagic    = 'Dark',
    DivineMagic  = 'Divine',
    Ninjutsu     = 'Ninjutsu',
    BlueMagic    = 'Blue',
    Geomancy     = 'Geomancy',
    Trust        = 'Trust',
    SummonerPact = 'Summon',
    BardSong     = 'Song',
}
-- Compact aliases for the res.skills English names that come back from
-- spell.skill — every "X Magic" gets shortened to its first word, plus a
-- few one-offs for bard / blue / geo etc.
local SKILL_ALIAS = {
    ['Healing Magic']        = 'Heal',
    ['Enhancing Magic']      = 'Enh',
    ['Enfeebling Magic']     = 'Enf',
    ['Elemental Magic']      = 'Ele',
    ['Dark Magic']           = 'Dark',
    ['Divine Magic']         = 'Divine',
    ['Summoning Magic']      = 'Summon',
    ['Blue Magic']           = 'Blue',
    ['Geomancy']             = 'Geomancy',
    ['Ninjutsu']             = 'Ninjutsu',
    ['Singing']              = 'Song',
    ['String Instrument']    = 'Strings',
    ['Stringed Instrument']  = 'Strings',
    ['Wind Instrument']      = 'Wind',
}
local function skill_label(spell)
    if not spell then return '' end
    -- Prefer the resource skill name if it's actually a magic skill
    if spell.skill and res.skills and res.skills[spell.skill] and res.skills[spell.skill].en then
        local en = res.skills[spell.skill].en
        if SKILL_ALIAS[en] then return SKILL_ALIAS[en] end
        -- res.skills mixes combat + magic; only the magic ones are useful here
        if en:find('Magic') or en:find('Ninjutsu') or en:find('Song')
           or en:find('Summoning') or en:find('Geomancy') or en:find('Blue') then
            -- Unknown magic skill — truncate so it never overflows
            return en:sub(1, 8)
        end
    end
    return SKILL_LABEL[spell.type] or (spell.type or ''):sub(1, 8)
end

-- Unity Concord trusts are awarded via Unity accolades / rank — a separate
-- progression from the regular cipher / quest / merit trusts. They're still
-- shown in the list (alphabetically sorted alongside regular trusts) but
-- the row carries an is_uc flag so the summary count can skip them.
local function is_unity_concord(spell_name)
    return spell_name and spell_name:find('%(UC%)') ~= nil
end

-- All trusts (UC included). Returns rows matching the spell row schema so
-- the rest of the code can stay uniform (level/skill fields stay empty;
-- trust_job / trust_desc fill in; is_uc marks Unity Concord variants).
local function all_trusts()
    local out = {}
    for id, spell in pairs(res.spells) do
        if spell and spell.type == 'Trust' and spell.en then
            table.insert(out, {
                id        = id,
                name      = spell.en,
                level     = 0,                       -- unused for trusts
                skill     = '',                      -- unused
                type      = 'Trust',
                is_trust  = true,
                is_uc     = is_unity_concord(spell.en),
                trust_job = trust_job(spell.en),
                trust_desc= trust_desc(spell.en),
            })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- COR-tab row list: every die from dice_info, treated as a "spell" entry
-- so the existing row builder / mouse handler can pick it up. The dice
-- list comes from BG-Wiki Category:Dice (libs/dice_info.lua) and is
-- sorted by COR level then name. is_die=true tags the entries so the
-- detail-pane renderer (build_die_info_lines) knows to format them
-- with Description / Purchased From / Obtained From instead of the
-- usual acquisition CSV layout. There's no "owned" tracking yet because
-- dice are consumable -- once used they teach the matching Phantom Roll
-- and disappear; "missing" semantics would mean "the player doesn't
-- have the Phantom Roll yet" but that requires reading job-ability
-- state which the addon doesn't currently fetch.  For now every die
-- shows as "missing" (yellow) so the user can scan the whole list.
local function all_dice()
    local out = {}
    for name, info in pairs(dice_info) do
        table.insert(out, {
            id     = name,                              -- string ID is fine here
            name   = name,
            level  = info.cor_level or 99,
            skill  = info.phantom_roll or '',           -- shown in the skill column
            type   = 'Die',
            is_die = true,
            phantom_roll = info.phantom_roll,
        })
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return a.name < b.name
    end)
    return out
end

-- Every spell the given job (ens like 'WHM') can natively learn at lv 1-cap.
-- For the special 'TRUST' tab, defers to all_trusts() above. Returns a
-- list of { id, name, level, skill, type, is_trust?, trust_job?, trust_desc? }
-- sorted by level then name (trusts: alphabetical).
--
-- Filter: spells with `unlearnable=true` in res.spells are mob-only /
-- unreleased / placeholder entries that players can't normally acquire
-- (e.g. Curse, Bio IV/V, Banishga IV/V). Skip them — UNLESS:
--   (a) the player already KNOWS the spell (something put it in their
--       spell book somehow, so we shouldn't hide it from them), or
--   (b) a SEPARATE entry with the same spell.en exists that IS
--       learnable (e.g. Sleepga has both id=273 learnable and id=363
--       unlearnable duplicate — we want to show the learnable one).
-- This matches what other "spellbook" addons display.
local function all_spells_for_job(ens, lv_cap)
    if ens == 'TRUST' then return all_trusts() end
    if ens == 'COR'   then return all_dice()   end
    lv_cap = lv_cap or 99
    local jid = job_id_by_ens[ens]
    if not jid then return {} end
    local known = windower.ffxi.get_spells() or {}

    -- First pass: which spell.en values have a learnable entry somewhere
    -- in res.spells? Used to dedupe Sleepga-style double entries.
    local has_learnable = {}
    for _, spell in pairs(res.spells) do
        if spell and spell.en and spell.type ~= 'Trust' and not spell.unlearnable then
            has_learnable[spell.en] = true
        end
    end

    -- Second pass: collect this job's spells, applying the filter and
    -- deduping by name (so Sleepga doesn't show twice).
    local out, seen_en = {}, {}
    for id, spell in pairs(res.spells) do
        if spell and spell.en and spell.levels and spell.type ~= 'Trust'
           and not seen_en[spell.en] then
            local lv = spell.levels[jid]
            if lv and lv >= 0 and lv <= lv_cap then
                local show = false
                if not spell.unlearnable then
                    show = true                    -- normal learnable spell
                elseif known[id] then
                    show = true                    -- player has it, don't hide it
                elseif has_learnable[spell.en] then
                    show = false                   -- a learnable copy exists, defer to it
                else
                    show = false                   -- mob-only / unreleased
                end
                if show then
                    seen_en[spell.en] = true
                    table.insert(out, {
                        id    = id,
                        name  = spell.en,
                        level = lv,
                        skill = skill_label(spell),
                        type  = spell.type or '',
                    })
                end
            end
        end
    end
    -- GEO has three distinct families of spells that share the same job:
    --   1. Normal (non-prefixed) spells learned the usual way
    --   2. Indi-X — companion debuff/buff spells purchased from Adoulin vendors
    --   3. Geo-X  — the matching Geomantic Reservoir spells (need the Indi-X first)
    -- Sorting them all together by level interleaves the three families,
    -- which makes it hard to scan when you're hunting one specific category.
    -- Group them: Normal first, then Indi-, then Geo-. WITHIN each group,
    -- keep the usual level-then-name ordering so the lowest-level missing
    -- spell in each family is right at the top. Other jobs keep the
    -- single-list level-then-name sort.
    if ens == 'GEO' then
        local function geo_group(name)
            if name:sub(1, 5) == 'Indi-' then return 2 end
            if name:sub(1, 4) == 'Geo-'  then return 3 end
            return 1
        end
        table.sort(out, function(a, b)
            local ga, gb = geo_group(a.name), geo_group(b.name)
            if ga ~= gb then return ga < gb end
            if a.level ~= b.level then return a.level < b.level end
            return a.name < b.name
        end)
    else
        table.sort(out, function(a, b)
            if a.level ~= b.level then return a.level < b.level end
            return a.name < b.name
        end)
    end
    return out
end

local function partition_for_job(ens)
    local owned, missing = {}, {}
    if ens == 'COR' then
        -- COR dice are "owned" once the player KNOWS the matching Phantom
        -- Roll. windower.ffxi.get_abilities() returns the abilities the
        -- current job/sub can use — so this only reflects reality when the
        -- player is actually playing COR (or has COR sub). On other jobs
        -- every die just shows as missing, which is the right fallback.
        local abil = windower.ffxi.get_abilities() or {}
        local known_roll_names = {}
        for _, id in pairs(abil.job_abilities or {}) do
            local a = res.job_abilities and res.job_abilities[id]
            if a and a.en then known_roll_names[a.en] = true end
        end
        for _, s in ipairs(all_spells_for_job(ens)) do
            if s.phantom_roll and known_roll_names[s.phantom_roll] then
                table.insert(owned, s)
            else
                table.insert(missing, s)
            end
        end
        return owned, missing
    end

    local known = windower.ffxi.get_spells() or {}
    for _, s in ipairs(all_spells_for_job(ens)) do
        if known[s.id] then table.insert(owned, s)
        else                table.insert(missing, s) end
    end
    return owned, missing
end

-- Count helper: split a list of trust rows into regular + UC. Used only
-- for the TRUST tab so UC trusts (Unity-rank-awarded; need accolades)
-- don't inflate the "X / Y trusts learned" tally.
local function split_uc(list)
    local reg, uc = {}, {}
    for _, s in ipairs(list) do
        if s.is_uc then table.insert(uc, s) else table.insert(reg, s) end
    end
    return reg, uc
end

-- Returns ({rows}, summary_line, row_color) for the current mode + job.
local function rows_for_view()
    local job = settings.job
    local unit = 'spells'
    if job == 'TRUST' then unit = 'trusts'
    elseif job == 'COR' then unit = 'dice' end
    local owned, missing = partition_for_job(job)

    -- For the TRUST tab specifically, separate UC from regular for the
    -- summary text. The list of rows still includes UC trusts so the user
    -- can see what they could earn via accolades — they're just not in the
    -- progress count.
    if job == 'TRUST' then
        local reg_owned, uc_owned   = split_uc(owned)
        local reg_missing, uc_missing = split_uc(missing)
        local reg_total = #reg_owned + #reg_missing
        local uc_total  = #uc_owned  + #uc_missing
        local uc_suffix = (uc_total > 0)
            and string.format('   (+%d UC: %d owned, %d via accolades)', uc_total, #uc_owned, #uc_missing)
            or ''
        if settings.mode == 'owned' then
            return owned,
                   string.format('TRUST   Owned trusts: %d / %d%s',
                       #reg_owned, reg_total, uc_suffix),
                   C_OWNED
        elseif settings.mode == 'all' then
            local everything = all_spells_for_job(job)
            return everything,
                   string.format('TRUST   All trusts: %d  (owned %d, missing %d)%s',
                       reg_total, #reg_owned, #reg_missing, uc_suffix),
                   C_SUMMARY
        else
            return missing,
                   string.format('TRUST   Missing trusts: %d / %d%s',
                       #reg_missing, reg_total, uc_suffix),
                   C_MISSING
        end
    end

    -- Non-TRUST tabs: regular spell-school counting, no UC complications.
    local total = #owned + #missing
    if settings.mode == 'owned' then
        return owned,
               string.format('%s   Owned %s: %d / %d', job, unit, #owned, total),
               C_OWNED
    elseif settings.mode == 'all' then
        local everything = all_spells_for_job(job)
        return everything,
               string.format('%s   All %s: %d  (owned %d, missing %d)', job, unit, total, #owned, #missing),
               C_SUMMARY
    else
        return missing,
               string.format('%s   Missing %s: %d / %d', job, unit, #missing, total),
               C_MISSING
    end
end

-- ---------------------------------------------------------------------------
-- Chat output
-- ---------------------------------------------------------------------------

local function chat(color, line) windower.add_to_chat(color, line) end

-- Resolves a user-supplied job arg to a canonical tab name, or nil. Empty
-- arg → falls back to the currently-selected tab so `//ms count` Just Works.
local function resolve_job_arg(arg)
    if not arg or arg == '' then return settings.job end
    arg = arg:upper()
    for _, j in ipairs(JOB_TABS) do if j == arg then return j end end
    return nil
end

-- Format one row for chat output. Trust rows use the old name [JOB] role
-- layout; spell rows use the new [Lv NN] name (Skill) layout.
local function row_chat_line(s, prefix)
    if s.is_trust then
        return string.format('  %s %-22s [%s]  %s',
            prefix, s.name, s.trust_job or '?', s.trust_desc or '')
    else
        return string.format('  %s [Lv %2d]  %-22s  (%s)',
            prefix, s.level, s.name, s.skill)
    end
end

local function cmd_count(arg)
    local job = resolve_job_arg(arg)
    if not job then chat(CHAT_MISSING, '[MissingSpells] unknown tab "'..tostring(arg)..'"'); return end
    local unit = 'spells'
    if job == 'TRUST' then unit = 'trusts'
    elseif job == 'COR' then unit = 'dice' end
    local owned, missing = partition_for_job(job)
    if job == 'TRUST' then
        -- Split UC from regular so the headline count matches what the
        -- window summary shows. UC trusts are accolade-gated, separate path.
        local reg_owned, uc_owned   = split_uc(owned)
        local reg_missing, uc_missing = split_uc(missing)
        local reg_total = #reg_owned + #reg_missing
        chat(CHAT_HEADER, string.format(
            '[MissingSpells] TRUST: %d / %d trusts learned  (%d still needed)',
            #reg_owned, reg_total, #reg_missing))
        if (#uc_owned + #uc_missing) > 0 then
            chat(CHAT_ITEM, string.format(
                '  + %d UC trusts: %d owned via accolades, %d still locked',
                #uc_owned + #uc_missing, #uc_owned, #uc_missing))
        end
    else
        local total = #owned + #missing
        chat(CHAT_HEADER, string.format(
            '[MissingSpells] %s: %d / %d %s learned  (%d still needed)',
            job, #owned, total, unit, #missing))
    end
end

local function cmd_list_chat(arg)
    local job = resolve_job_arg(arg)
    if not job then chat(CHAT_MISSING, '[MissingSpells] unknown tab "'..tostring(arg)..'"'); return end
    local unit = (job == 'TRUST') and 'trusts' or 'spells'
    local _, missing = partition_for_job(job)
    if #missing == 0 then
        chat(CHAT_OWNED, '[MissingSpells] '..job..': every '..unit:sub(1, -2)..' learned. Nice.')
        return
    end
    chat(CHAT_HEADER, string.format('[MissingSpells] %s: %d %s still needed:', job, #missing, unit))
    for _, s in ipairs(missing) do
        chat(CHAT_MISSING, row_chat_line(s, '-'))
    end
end

local function cmd_have_chat(arg)
    local job = resolve_job_arg(arg)
    if not job then chat(CHAT_MISSING, '[MissingSpells] unknown tab "'..tostring(arg)..'"'); return end
    local unit = (job == 'TRUST') and 'trusts' or 'spells'
    local owned = partition_for_job(job)
    if #owned == 0 then
        chat(CHAT_MISSING, '[MissingSpells] '..job..': no '..unit..' learned yet.')
        return
    end
    chat(CHAT_HEADER, string.format('[MissingSpells] %s: %d %s learned:', job, #owned, unit))
    for _, s in ipairs(owned) do
        chat(CHAT_OWNED, row_chat_line(s, '+'))
    end
end

-- Search across every job AND every trust, since the user might not know
-- which tab a given name belongs to. Marks each hit with [LEARNED] or
-- [MISSING] and includes trust matches with their [JOB] role tag.
local function cmd_find_chat(query)
    if not query or query == '' then
        chat(CHAT_MISSING, '[MissingSpells] usage: //ms find <name fragment>')
        return
    end
    query = query:lower()
    local known = windower.ffxi.get_spells() or {}
    local hits = 0
    chat(CHAT_HEADER, string.format('[MissingSpells] Matches for "%s":', query))
    local seen = {}
    for id, spell in pairs(res.spells) do
        if spell and spell.en and spell.en:lower():find(query, 1, true) and not seen[id] then
            seen[id] = true
            hits = hits + 1
            if spell.type == 'Trust' then
                -- Trust match — use the trust's job + role columns instead
                if not is_unity_concord(spell.en) then
                    local tjob  = trust_job(spell.en)
                    local tdesc = trust_desc(spell.en)
                    if known[id] then
                        chat(CHAT_OWNED, string.format('  + %-22s [%s]  %s   [LEARNED Trust]', spell.en, tjob, tdesc))
                    else
                        chat(CHAT_MISSING, string.format('  - %-22s [%s]  %s   [MISSING Trust]', spell.en, tjob, tdesc))
                    end
                end
            else
                -- Spell match — show which of our 12 job tabs can learn it
                local jobs = {}
                if spell.levels then
                    for _, ens in ipairs(JOB_TABS) do
                        if ens ~= 'TRUST' then
                            local jid = job_id_by_ens[ens]
                            if jid and spell.levels[jid] then
                                table.insert(jobs, string.format('%s@%d', ens, spell.levels[jid]))
                            end
                        end
                    end
                end
                local job_str = (#jobs > 0) and table.concat(jobs, ' ') or '(no tabbed job)'
                if known[id] then
                    chat(CHAT_OWNED,   string.format('  + %-22s  %s   [LEARNED]', spell.en, job_str))
                else
                    chat(CHAT_MISSING, string.format('  - %-22s  %s   [MISSING]', spell.en, job_str))
                end
            end
        end
    end
    if hits == 0 then chat(CHAT_ITEM, '  (no matches)') end
end

-- ---------------------------------------------------------------------------
-- Tooltip helpers
-- ---------------------------------------------------------------------------
-- Wrap width for the right-side detail pane. DETAIL_W is ~340 px; at
-- Arial 10pt with ~9 px per character that gives ~36 visible chars per
-- line. TOOLTIP_MAX_LINES is the cap on the FULL formatted text.
-- DETAIL_VISIBLE_LINES is computed at frame time from the actual body
-- height (see build_window) rather than being a fixed constant — that
-- way the detail pane never overflows the panel bottom no matter how
-- many spells / job tabs are visible.
local TOOLTIP_WIDTH_CHARS = 36
local TOOLTIP_MAX_LINES   = 200
local DETAIL_LINE_H       = 16    -- approximate rendered height of one Arial 10pt line

-- Split a string on top-level commas (commas that are NOT inside brackets
-- or parens). The CSV format puts method names separated by commas at
-- depth 0, with details inside brackets that may themselves contain
-- commas — we want to split the methods apart cleanly.
local function split_top_level_commas(s)
    local parts = {}
    local depth = 0
    local start = 1
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == '[' or c == '(' then depth = depth + 1
        elseif c == ']' or c == ')' then depth = depth - 1
        elseif c == ',' and depth == 0 then
            table.insert(parts, (s:sub(start, i - 1):gsub('^%s+', ''):gsub('%s+$', '')))
            start = i + 1
        end
    end
    table.insert(parts, (s:sub(start):gsub('^%s+', ''):gsub('%s+$', '')))
    return parts
end

-- Pull "<method>" and "<details inside brackets>" out of one chunk.
local function parse_method(chunk)
    local method, details = chunk:match('^(.-)%s*%[(.*)%]%s*$')
    if not method then
        return (chunk:gsub('^%s+', ''):gsub('%s+$', '')), nil
    end
    method  = method:gsub('^%s+', ''):gsub('%s+$', '')
    details = details:gsub('^%s+', ''):gsub('%s+$', '')
    return method, details
end

-- Friendly label remapping for the section headers.
local METHOD_LABEL = {
    ['Monster Drop']               = 'Monster Drops',
    ['Monster Drop (BCNM/Instance)'] = 'BCNM / Instance Drop',
    ['Purchasable']                = 'Vendor',
    ['Quest']                      = 'Quest',
    ['Mission']                    = 'Mission',
    ['Trade']                      = 'Trade',
    ['Reward']                     = 'Reward',
    ['Crafting']                   = 'Crafting',
    ['Records of Eminence']        = 'Records of Eminence',
    ['RoE']                        = 'Records of Eminence',
    ['Limit Break']                = 'Limit Break',
    ['Coffer']                     = 'Coffer',
    ['Treasure Casket']            = 'Treasure Casket',
    ['Job Point Prog']             = 'Job Point Gift',
}
local function method_label(m) return METHOD_LABEL[m] or m end

-- Wrap one line to `width`, preserving its leading whitespace so continuation
-- lines align with the original indentation.
local function wrap_line(line, width)
    if #line <= width then return { line } end
    local out = {}
    local indent = line:match('^(%s*)') or ''
    local rest   = line:sub(#indent + 1)
    local cont   = indent .. '  '
    local cur    = indent
    local first  = true
    for word in rest:gmatch('%S+') do
        local sep = first and '' or ' '
        if #cur + #sep + #word > width and not first then
            table.insert(out, cur)
            cur = cont .. word
            first = false
        else
            cur = cur .. sep .. word
            first = false
        end
    end
    if cur:match('%S') then table.insert(out, cur) end
    return out
end

-- =====================================================================
-- Trust right-panel renderer
-- =====================================================================
-- Builds the list of lines that go in the right panel when the TRUST
-- tab is active and the user has locked a trust by clicking it. Pulls
-- structured fields out of libs/trust_info.lua and wraps each one to
-- the same TOOLTIP_WIDTH_CHARS width the spell renderer uses.
--
-- Layout (top -> bottom):
--   <Trust name>                                   (yellow)
--   <existing job + role descriptor from JOB_BY_TRUST / DESC_BY_TRUST>
--                                                  (muted)
--   ---
--   Job:           <wiki Job field>                (cyan header / white body)
--   Spells:        <wiki Spells field>
--   Abilities:     <wiki Abilities field>
--   Weapon Skills: <wiki Weapon Skills field>
--   Acquisition:                                   (cyan header)
--     - <bullet 1>                                 (indented)
--     - <bullet 2>
--   Special Features:
--     - <bullet 1>
--     ...
--
-- When the wiki entry for a trust is a stub (typical for older
-- Story-of-Vana'diel trusts whose Cipher_of_X%27s_alter_ego page on
-- BG-Wiki has no detail), the body collapses to just the two header
-- lines + a muted "(no detailed wiki info available)" placeholder.
local function build_trust_info_lines(name)
    local out = {}
    -- Header: name (yellow) + the addon's existing one-line summary
    table.insert(out, '\\cs(255,220,140)' .. name .. '\\cr')
    local jb = trust_job(name)
    local desc = trust_desc(name)
    local header = jb
    if desc and desc ~= '' then header = header .. ' - ' .. desc end
    if header ~= '?' then
        table.insert(out, '\\cs(180,180,180)' .. header .. '\\cr')
    end
    -- Separator
    table.insert(out, '')

    local info = trust_info[name]
    if not info or next(info) == nil then
        table.insert(out, '\\cs(180,180,180)(no detailed wiki info available)\\cr')
        return out
    end

    -- Single-value fields: emit "<label>:" header + wrapped body lines
    local function emit_field(label, value)
        if not value or value == '' then return end
        table.insert(out, '\\cs(150,220,255)' .. label .. ':\\cr')
        for _, l in ipairs(wrap_line('  ' .. value, TOOLTIP_WIDTH_CHARS)) do
            table.insert(out, l)
        end
    end
    -- List fields: emit "<label>:" header + each bullet, indented + wrapped
    local function emit_list(label, items)
        if not items or #items == 0 then return end
        table.insert(out, '\\cs(150,220,255)' .. label .. ':\\cr')
        for _, item in ipairs(items) do
            for _, l in ipairs(wrap_line('  - ' .. item, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
        end
    end

    emit_field('Job',           info.job)
    emit_field('Spells',        info.spells)
    emit_field('Abilities',     info.abilities)
    emit_field('Weapon Skills', info.weapon_skills)
    emit_list ('Acquisition',   info.acquisition)
    emit_list ('Special',       info.special)
    return out
end

-- =====================================================================
-- COR die right-panel renderer
-- =====================================================================
-- Builds the right-panel lines for a clicked die on the COR tab. Pulls
-- Description / Purchased From / Obtained From out of libs/dice_info.lua
-- and wraps each one to TOOLTIP_WIDTH_CHARS.
--
-- Layout (top -> bottom):
--   <Die name>                                     (yellow)
--   COR lv NN  ·  teaches: <Phantom Roll>          (muted summary)
--   ---
--   Description:                                   (cyan header)
--     <description text wrapped>
--   Purchased from:                                (cyan header)
--     - <NPC>  ·  <Zone>
--         <Notes>
--   Obtained from:                                 (cyan header, optional)
--     - <Source>
--         <Notes>
local function build_die_info_lines(name)
    local out = {}
    local info = dice_info[name]
    if not info then
        table.insert(out, '\\cs(255,220,140)' .. name .. '\\cr')
        table.insert(out, '\\cs(180,180,180)(no info available)\\cr')
        return out
    end

    -- Header: die name + COR level + Phantom Roll it teaches
    table.insert(out, '\\cs(255,220,140)' .. name .. '\\cr')
    local summary_bits = {}
    if info.cor_level then
        table.insert(summary_bits, 'COR lv ' .. info.cor_level)
    end
    if info.phantom_roll and info.phantom_roll ~= '' then
        table.insert(summary_bits, 'teaches: ' .. info.phantom_roll)
    end
    if #summary_bits > 0 then
        table.insert(out, '\\cs(180,180,180)' .. table.concat(summary_bits, '  ·  ') .. '\\cr')
    end
    table.insert(out, '')

    -- Description
    if info.description and info.description ~= '' then
        table.insert(out, '\\cs(150,220,255)Description:\\cr')
        for _, l in ipairs(wrap_line('  ' .. info.description, TOOLTIP_WIDTH_CHARS)) do
            table.insert(out, l)
        end
        table.insert(out, '')
    end

    -- Purchased From
    if info.purchased_from and #info.purchased_from > 0 then
        table.insert(out, '\\cs(150,220,255)Purchased from:\\cr')
        for _, row in ipairs(info.purchased_from) do
            local npc  = row['NPC Name'] or row.NPC or ''
            local zone = row.Zone or row['Zone'] or ''
            local note = row.Notes or row.Note or ''
            local head = '  - ' .. npc
            if zone ~= '' then head = head .. '  ·  ' .. zone end
            for _, l in ipairs(wrap_line(head, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
            if note ~= '' then
                for _, l in ipairs(wrap_line('      ' .. note, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
        end
        table.insert(out, '')
    end

    -- Obtained From  (e.g. quest reward — only a few dice have this)
    if info.obtained_from and #info.obtained_from > 0 then
        table.insert(out, '\\cs(150,220,255)Obtained from:\\cr')
        for _, row in ipairs(info.obtained_from) do
            -- Column names vary; pick the most likely.
            local src  = row.Quest or row.Source or row.Type or row.Mob or ''
            local note = row.Notes or row.Note or ''
            for _, l in ipairs(wrap_line('  - ' .. src, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
            if note ~= '' then
                for _, l in ipairs(wrap_line('      ' .. note, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
        end
    end

    return out
end

-- =====================================================================
-- Unified spell right-panel renderer
-- =====================================================================
-- Used by EVERY non-COR non-TRUST job tab, including BLU. Merges data
-- from libs/spell_info.lua and libs/blu_info.lua so the same label set
-- appears for every spell regardless of which job tab the user
-- happened to click in from. Field order, label spelling, separator
-- glyphs, indentation, and trailing colons are all standardized here
-- so two adjacent clicks on different jobs don't render two slightly-
-- different layouts.
--
-- Field order (every present field uses the same label text):
--   Description
--   Type
--   Skill
--   Element
--   Target
--   Stat Bonus       (BLU only -- absent from general spell info)
--   Creates Trait    (BLU only)
--   Notes            (bullet list)
--   Dropped from     (mob drops -- monster + zone + notes)
--   Learn from       (BLU mob trigger -- monster + level + zone)
--   Purchased from   (NPC + zone + price)
--
-- Empty fields are skipped silently so the user sees exactly the rows
-- the wiki has data for, in the same order, every time.
local function build_spell_info_lines(name)
    local out = {}
    local gi = spell_info[name]
    local bi = blu_info[name]
    if not gi and not bi then
        table.insert(out, '\\cs(255,220,140)' .. name .. '\\cr')
        table.insert(out, '\\cs(180,180,180)(no detailed wiki info available)\\cr')
        return out
    end

    -- Prefer BG-Wiki's general spell-info for the top-line attributes,
    -- fall back to blu_info when only the BLU page is present.
    -- (Both sources agree on shared fields like description / target
    -- because both scrape the same wiki.)
    local function pick(field)
        if gi and gi[field] then return gi[field] end
        if bi and bi[field] then return bi[field] end
        return nil
    end

    table.insert(out, '\\cs(255,220,140)' .. name .. '\\cr')
    table.insert(out, '')

    local function emit_field(label, value)
        if not value or value == '' then return end
        table.insert(out, '\\cs(150,220,255)' .. label .. ':\\cr')
        for _, l in ipairs(wrap_line('  ' .. value, TOOLTIP_WIDTH_CHARS)) do
            table.insert(out, l)
        end
    end

    emit_field('Description',   pick('description'))
    emit_field('Type',          pick('type'))
    emit_field('Skill',         pick('skill'))
    emit_field('Element',       pick('element'))
    emit_field('Target',        pick('target'))
    -- BLU-only fields appear here if present, but only when blu_info
    -- carries them (general spell pages don't have these labels).
    emit_field('Stat Bonus',    bi and bi.stat_bonus)
    emit_field('Creates Trait', bi and bi.creates_trait)

    -- Notes (bullet list)
    local notes = (gi and gi.notes) or (bi and bi.notes)
    if notes and #notes > 0 then
        table.insert(out, '')
        table.insert(out, '\\cs(150,220,255)Notes:\\cr')
        for _, note in ipairs(notes) do
            for _, l in ipairs(wrap_line('  - ' .. note, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
        end
    end

    -- Dropped from: scroll-drop rows from the general spell-info table.
    local dropped = gi and gi.dropped_from
    if dropped and #dropped > 0 then
        table.insert(out, '')
        table.insert(out, '\\cs(150,220,255)Dropped from:\\cr')
        for _, row in ipairs(dropped) do
            local head = '  - ' .. (row.monster or '')
            if row.level and row.level ~= '' then
                head = head .. '  ·  Lv ' .. row.level
            end
            for _, l in ipairs(wrap_line(head, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
            if row.zone and row.zone ~= '' then
                for _, l in ipairs(wrap_line('      ' .. row.zone, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
            if row.notes and row.notes ~= '' then
                for _, l in ipairs(wrap_line('      ' .. row.notes, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
        end
    end

    -- Learn from: BLU's Spell Obtainment table -- conceptually distinct
    -- from "Dropped from" because BLU spells are learned by being hit
    -- with the ability, not by acquiring a scroll. Keep the label
    -- distinct so the user knows which mechanic applies.
    local learn = bi and bi.obtainment
    if learn and #learn > 0 then
        table.insert(out, '')
        table.insert(out, '\\cs(150,220,255)Learn from:\\cr')
        for _, row in ipairs(learn) do
            local head = '  - ' .. (row.monster or '')
            if row.level and row.level ~= '' then
                head = head .. '  ·  Lv ' .. row.level
            end
            for _, l in ipairs(wrap_line(head, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
            if row.zone and row.zone ~= '' then
                for _, l in ipairs(wrap_line('      ' .. row.zone, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
        end
    end

    -- Purchased from: NPC + zone + price.
    local purchased = gi and gi.purchased_from
    if purchased and #purchased > 0 then
        table.insert(out, '')
        table.insert(out, '\\cs(150,220,255)Purchased from:\\cr')
        for _, row in ipairs(purchased) do
            local head = '  - ' .. (row.npc or '')
            if row.zone and row.zone ~= '' then
                head = head .. '  ·  ' .. row.zone
            end
            for _, l in ipairs(wrap_line(head, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
            if row.notes and row.notes ~= '' then
                for _, l in ipairs(wrap_line('      ' .. row.notes, TOOLTIP_WIDTH_CHARS)) do
                    table.insert(out, l)
                end
            end
        end
    end

    return out
end

-- Convert a raw CSV detail string into a tooltip-friendly multi-line text:
-- each acquisition method gets its own labelled header line, with its
-- details on indented bullet lines below. BLU spells get a custom layout
-- since their CSV format is different ("Blue Magic [Family: X] (Mobs: ...)").
local function format_acquisition(text)
    if not text or text == '' then return '' end

    -- BLU spells
    if text:find('^Blue Magic %[') then
        local out = {}
        local family = text:match('%[Family:%s*([^%]]+)%]')
        local mobs   = text:match('%(Mobs:%s*Learned from:%s*(.-)%)')
        table.insert(out, '\\cs(150,220,255)Blue Magic\\cr')
        if family then
            for _, l in ipairs(wrap_line('Family: ' .. family, TOOLTIP_WIDTH_CHARS)) do
                table.insert(out, l)
            end
        end
        if mobs then
            table.insert(out, '\\cs(180,230,255)Learn from:\\cr')
            for mob in mobs:gmatch('[^,]+') do
                local m = mob:gsub('^%s+', ''):gsub('%s+$', '')
                if m ~= '' then
                    for _, l in ipairs(wrap_line('  ' .. m, TOOLTIP_WIDTH_CHARS)) do
                        table.insert(out, l)
                    end
                end
            end
        end
        return table.concat(out, '\n')
    end

    -- Generic: split into methods, group, render each as its own section.
    local parts = split_top_level_commas(text)
    local groups = {}              -- method -> list of detail strings
    local method_order = {}
    for _, part in ipairs(parts) do
        local method, details = parse_method(part)
        if method ~= '' then
            if not groups[method] then
                groups[method] = {}
                table.insert(method_order, method)
            end
            if details and details ~= '' then
                table.insert(groups[method], details)
            end
        end
    end

    local out_lines = {}
    for _, m in ipairs(method_order) do
        table.insert(out_lines, '\\cs(150,220,255)' .. method_label(m) .. ':\\cr')
        local d = groups[m]
        if #d == 0 then
            table.insert(out_lines, '  (see in-game wiki for specifics)')
        else
            for _, detail in ipairs(d) do
                -- detail may itself contain "/" or " / " as a separator
                -- between alternatives (e.g. multiple NPCs). Show each
                -- alternative on its own bullet to make scanning easier.
                local first_alt = true
                for alt in (detail .. ' /'):gmatch('(.-)%s*/%s*') do
                    local a = alt:gsub('^%s+', ''):gsub('%s+$', '')
                    if a ~= '' then
                        for _, l in ipairs(wrap_line('  ' .. a, TOOLTIP_WIDTH_CHARS)) do
                            table.insert(out_lines, l)
                        end
                        first_alt = false
                    end
                end
                if first_alt then
                    -- No "/" alternatives — show the whole detail wrapped
                    for _, l in ipairs(wrap_line('  ' .. detail, TOOLTIP_WIDTH_CHARS)) do
                        table.insert(out_lines, l)
                    end
                end
            end
        end
    end

    -- Cap to max lines
    if #out_lines > TOOLTIP_MAX_LINES then
        out_lines[TOOLTIP_MAX_LINES] = out_lines[TOOLTIP_MAX_LINES] .. ' ...'
        for i = TOOLTIP_MAX_LINES + 1, #out_lines do out_lines[i] = nil end
    end
    return table.concat(out_lines, '\n')
end

-- ---------------------------------------------------------------------------
-- Window UI
-- ---------------------------------------------------------------------------

local ui = {
    el        = {},
    rows      = {},
    scroll    = 0,
    drag      = nil,
    rect      = {},
    total_w   = PANEL_W,
    total_h   = 0,
    -- Tooltip elements (lazy-created the first time it's shown so the
    -- normal render path doesn't pay the cost when nothing's hovered).
    -- Right-side detail pane: a single text element that shows the
    -- click-locked spell's full acquisition info. Replaces the old
    -- hover tooltip. Lives inside the main panel so it always stays on
    -- screen and never gets clipped.
    detail_text    = nil,
    detail_scroll  = 0,        -- vertical offset (in lines) into the formatted detail
    detail_total   = 0,        -- total formatted lines available for the current selection
}

local function calc_dims(row_count)
    local visible = math.min(row_count, VISIBLE_ROWS)
    local body_h  = SUMMARY_H + PAD + (visible * ROW_H)
    if row_count > VISIBLE_ROWS then
        body_h = body_h + PAD + SCROLL_BTN_H + 2 + SCROLL_BTN_H
    end
    body_h = body_h + PAD * 2
    -- Total = borders + title bar + job-tab strip + body
    ui.total_h = BORDER * 2 + TITLE_BAR_H + JOB_TAB_H + body_h
end

local function destroy_window()
    for _, e in pairs(ui.el)   do destroy(e) end
    for _, r in ipairs(ui.rows) do
        destroy(r.bg); destroy(r.lv); destroy(r.name); destroy(r.acq); destroy(r.skill)
    end
    -- Detail pane text is recreated each build_window pass since the
    -- panel size + position can change; destroy it here so it's
    -- regenerated cleanly with the new geometry.
    if ui.detail_text then destroy(ui.detail_text); ui.detail_text = nil end
    ui.el = {}
    ui.rows = {}
    ui.rect = {}
end

local function build_window()
    destroy_window()

    local rows, summary, row_color = rows_for_view()
    calc_dims(#rows)

    local x, y = settings.pos.x, settings.pos.y
    local W, H = ui.total_w, ui.total_h

    -- Border frame
    ui.el.border_top    = make_bg(x,             y,             W,      BORDER, C_BORDER)
    ui.el.border_bottom = make_bg(x,             y + H - BORDER,W,      BORDER, C_BORDER)
    ui.el.border_left   = make_bg(x,             y,             BORDER, H,      C_BORDER)
    ui.el.border_right  = make_bg(x + W - BORDER,y,             BORDER, H,      C_BORDER)

    -- Title bar
    local tb_x = x + BORDER
    local tb_y = y + BORDER
    local tb_w = W - BORDER * 2
    ui.el.title_bar  = make_bg(tb_x, tb_y, tb_w, TITLE_BAR_H, C_TITLE_BG)
    ui.el.title_text = make_text('FFXIMissingSpells', tb_x + PAD, tb_y + 7, C_TITLE_TXT, 11, true)
    ui.rect.title_bar = { x = tb_x, y = tb_y, w = tb_w, h = TITLE_BAR_H }

    -- Mode tabs in the title bar (right-aligned): Missing | Owned | All.
    -- 3 equal-width buttons, leaving room for the title text on the left.
    local mode_avail = tb_w - 140
    local mode_tab_w = math.floor((mode_avail - TAB_GAP * 2) / 3)
    local mode_tab_y = tb_y + math.floor((TITLE_BAR_H - TAB_H) / 2)
    local mode_origin_x = tb_x + 140
    -- Push tabs to the right edge of the title bar so the title text stays
    -- visually balanced.
    local mode_total_w = mode_tab_w * 3 + TAB_GAP * 2
    local mode_right_x = tb_x + tb_w - PAD - mode_total_w
    if mode_right_x > mode_origin_x then mode_origin_x = mode_right_x end

    local modes  = { 'missing', 'owned', 'all' }
    local mlabels = { 'Missing', 'Owned', 'All' }
    for i, key in ipairs(modes) do
        local tx = mode_origin_x + (i - 1) * (mode_tab_w + TAB_GAP)
        local on = (settings.mode == key)
        local bg_c  = on and C_TAB_ON  or C_TAB_OFF
        local txt_c = on and C_TAB_TXT_ON or C_TAB_TXT_OFF
        local bg = make_bg(tx, mode_tab_y, mode_tab_w, TAB_H, bg_c)
        local label = mlabels[i]
        local label_x = tx + math.floor(mode_tab_w / 2) - math.floor(#label * 6 / 2) - 2
        local txt = make_text(label, label_x, mode_tab_y + 4, txt_c, 11, on)
        ui.el['mode_bg_' .. key]   = bg
        ui.el['mode_txt_' .. key]  = txt
        ui.rect['mode_' .. key]    = { x = tx, y = mode_tab_y, w = mode_tab_w, h = TAB_H }
    end

    -- Job tab strip (one row of 12 tabs immediately below the title bar)
    local jt_x = tb_x
    local jt_y = tb_y + TITLE_BAR_H
    local jt_w = tb_w
    ui.el.job_bar = make_bg(jt_x, jt_y, jt_w, JOB_TAB_H, C_JOB_BAR_BG)

    local job_avail = jt_w - PAD * 2
    local job_count = #JOB_TABS
    local job_tab_w = math.floor((job_avail - TAB_GAP * (job_count - 1)) / job_count)
    local job_tab_y = jt_y + math.floor((JOB_TAB_H - TAB_H) / 2)
    for i, jb in ipairs(JOB_TABS) do
        local tx = jt_x + PAD + (i - 1) * (job_tab_w + TAB_GAP)
        local on = (settings.job == jb)
        local bg_c  = on and C_TAB_ON  or C_TAB_OFF
        local txt_c = on and C_TAB_TXT_ON or C_TAB_TXT_OFF
        local bg = make_bg(tx, job_tab_y, job_tab_w, TAB_H, bg_c)
        local label = jb
        local label_x = tx + math.floor(job_tab_w / 2) - math.floor(#label * 6 / 2) - 2
        local txt = make_text(label, label_x, job_tab_y + 4, txt_c, 11, on)
        ui.el['jtab_bg_' .. jb]   = bg
        ui.el['jtab_txt_' .. jb]  = txt
        ui.rect['jtab_' .. jb]    = { x = tx, y = job_tab_y, w = job_tab_w, h = TAB_H }
    end

    -- Body background (below the job tab strip)
    local body_y = jt_y + JOB_TAB_H
    local body_h = H - BORDER - TITLE_BAR_H - JOB_TAB_H - BORDER
    ui.el.body_bg = make_bg(tb_x, body_y, tb_w, body_h, C_BODY_BG)
    ui.rect.body = { x = tb_x, y = body_y, w = tb_w, h = body_h }

    -- Body is split into:
    --   left:  spell list (lv / name / skill)
    --   right: detail pane showing click-locked spell's acquisition info
    -- list_w is the width of the LEFT half; rows + skill column live inside it.
    local list_w = tb_w - DETAIL_W - 4        -- leave 4px for the divider
    -- Vertical divider between list and detail pane
    ui.el.detail_divider = make_bg(tb_x + list_w, body_y + PAD,
                                   1, body_h - PAD * 2, { 200, 60, 100, 160 })

    -- Summary line at top of body (above the list)
    ui.el.summary = make_text(summary, tb_x + PAD, body_y + PAD, C_SUMMARY, 11, true)

    -- Visible rows
    local row_x = tb_x + PAD
    local list_y0 = body_y + PAD + SUMMARY_H
    local visible = math.min(#rows, VISIBLE_ROWS)
    ui.scroll = math.min(ui.scroll, math.max(0, #rows - VISIBLE_ROWS))

    if #rows == 0 then
        local unit = is_trust_tab() and 'trusts' or 'spells'
        local msg = (settings.mode == 'missing') and ('No missing '..unit..' for ' .. settings.job .. '. Done!')
                 or (settings.mode == 'owned')   and (settings.job .. ': no '..unit..' learned yet.')
                 or (settings.job .. ': no '..unit..' in resources.')
        ui.el.empty = make_text(msg, row_x, list_y0 + 4, C_OWNED, 11)
    end

    -- Column layouts:
    --   Trust:  "- name                  [JOB]   role"
    --   Spell:  "- [Lv NN]   spell name                              (Skill)"
    -- Spell-row columns (acquisition info moved to the hover tooltip
    -- only — the in-row "where to get" column was unhelpful):
    --   lv:    prefix + "[Lv NN]"     at row_x          (~70px wide)
    --   name:  spell.en               at row_x + 70
    --   skill: short skill label      right-aligned ~ tb_x + tb_w - PAD - 130
    local lv_col_x    = row_x
    local name_col_x  = row_x + 70
    -- skill column is anchored to the right side of the LIST (not the
    -- whole body), so the detail pane on the right gets clean space.
    local skill_col_x = tb_x + list_w - PAD - 130
    local t_name_col_x = row_x
    local t_job_col_x  = row_x + 200
    local t_role_col_x = row_x + 250

    local known = windower.ffxi.get_spells() or {}
    for i = 1, visible do
        local data_idx = ui.scroll + i
        local entry = rows[data_idx]
        if entry then
            local ry = list_y0 + (i - 1) * ROW_H
            -- Subtle alternating row tint
            local row_bg
            -- Selected (click-locked) spell gets a brighter highlight
            -- bg so the user can see which row their click + arrow-keys
            -- last landed on. This always paints regardless of the
            -- normal alternating-tint logic.
            if entry.name == settings.selected_spell then
                row_bg = make_bg(row_x - 2, ry - 1, list_w - PAD * 2 + 4, ROW_H,
                                  { 200, 50, 120, 200 })
            elseif i % 2 == 0 then
                -- Row bg only spans the LEFT (list) section, not the
                -- detail pane on the right.
                row_bg = make_bg(row_x - 2, ry - 1, list_w - PAD * 2 + 4, ROW_H,
                                  { 90, 30, 40, 75 })
            end
            -- In ALL mode, color each row by ownership instead of using the
            -- single mode-wide color.
            local color = row_color
            local prefix
            if settings.mode == 'all' then
                color  = known[entry.id] and C_OWNED or C_MISSING
                prefix = known[entry.id] and '+' or '-'
            else
                prefix = (settings.mode == 'missing') and '-' or '+'
            end
            if entry.is_trust then
                -- UC trusts are listed for reference but excluded from the
                -- count (accolade-gated). Use a dimmer name color so the
                -- regular trusts visually take precedence.
                local name_color = entry.is_uc and C_UC_DIM or color
                local name_text = make_text(prefix..' '..entry.name, t_name_col_x, ry + 2, name_color, 10)
                local job_text  = make_text('['..(entry.trust_job or '?')..']',
                                            t_job_col_x, ry + 2, C_SUMMARY, 10, true)
                local desc_text = make_text(entry.trust_desc or '', t_role_col_x, ry + 2, C_SKILL, 10, false)
                -- Hit-rect for click selection — same as the spell branch
                -- below, just with the trust's display name. Without this,
                -- click handler at line 1627 finds no `rect` field on the
                -- trust row and the click silently no-ops (which is what
                -- the user reported as "I can't click on trusts").
                local hit_rect = {x = row_x - 2, y = ry - 1,
                                  w = list_w - PAD * 2 + 4, h = ROW_H,
                                  spell_name = entry.name}
                -- Reuse the same field names so destroy_window() handles cleanup
                -- with no special-case code (lv/skill fields just stand in for
                -- the trust columns).
                table.insert(ui.rows, { bg = row_bg, lv = job_text, name = name_text,
                                        skill = desc_text,
                                        rect = hit_rect })
            else
                local lv_str    = string.format('%s [Lv %2d]', prefix, entry.level)
                local lv_text   = make_text(lv_str, lv_col_x, ry + 2, C_LEVEL, 10)
                local name_text = make_text(entry.name, name_col_x, ry + 2, color, 10)
                local skill_text= make_text(entry.skill, skill_col_x, ry + 2, C_SKILL, 10, false)
                -- Hit-rect for click selection — only spans the list
                -- section so a click on the detail pane doesn't pick
                -- a spell.
                local hit_rect = {x = row_x - 2, y = ry - 1,
                                  w = list_w - PAD * 2 + 4, h = ROW_H,
                                  spell_name = entry.name}
                table.insert(ui.rows, { bg = row_bg, lv = lv_text, name = name_text,
                                        skill = skill_text,
                                        rect = hit_rect })
            end
        end
    end

    -- Scroll buttons (only when needed) — anchored to the list section
    -- so they stay inside the list column, not over the detail pane.
    if #rows > VISIBLE_ROWS then
        local btn_w = 40
        local btn_x = tb_x + list_w - PAD - btn_w
        local up_y  = list_y0 + visible * ROW_H + PAD
        local dn_y  = up_y + SCROLL_BTN_H + 2

        local can_up = ui.scroll > 0
        local can_dn = ui.scroll < #rows - VISIBLE_ROWS

        ui.el.scroll_up_bg = make_bg(btn_x, up_y, btn_w, SCROLL_BTN_H,
            can_up and C_SCROLL_BG or C_SCROLL_OFF)
        ui.el.scroll_up_txt = make_text('▲', btn_x + 14, up_y + 3,
            can_up and C_SCROLL_TXT or C_SCROLL_TXT_OFF, 11, true)
        ui.rect.scroll_up = { x = btn_x, y = up_y, w = btn_w, h = SCROLL_BTN_H, enabled = can_up }

        ui.el.scroll_dn_bg = make_bg(btn_x, dn_y, btn_w, SCROLL_BTN_H,
            can_dn and C_SCROLL_BG or C_SCROLL_OFF)
        ui.el.scroll_dn_txt = make_text('▼', btn_x + 14, dn_y + 3,
            can_dn and C_SCROLL_TXT or C_SCROLL_TXT_OFF, 11, true)
        ui.rect.scroll_dn = { x = btn_x, y = dn_y, w = btn_w, h = SCROLL_BTN_H, enabled = can_dn }

        -- "1-22 / 35" already says where you are; the % was redundant
        ui.el.scroll_pos = make_text(
            string.format('%d-%d / %d', ui.scroll + 1, ui.scroll + visible, #rows),
            tb_x + PAD, up_y + 4, C_SUMMARY, 10, false)
    end

    -- =========================================================================
    -- Right-side detail pane (click-locked acquisition info, scrollable)
    -- =========================================================================
    local detail_x = tb_x + list_w + PAD
    local detail_y = body_y + PAD

    -- Anchor the ▲/▼ scroll buttons to the BOTTOM of the body. That way
    -- they're guaranteed to be inside the panel no matter what body_h
    -- works out to this frame. Then derive how many text lines we can
    -- fit between detail_y and the buttons.
    local d_btn_w = 26
    local d_btn_x = tb_x + tb_w - PAD - d_btn_w - 2
    local d_dn_y  = body_y + body_h - SCROLL_BTN_H - PAD
    local d_up_y  = d_dn_y - SCROLL_BTN_H - 2

    local visible_h = (d_up_y - 4) - detail_y
    local detail_visible_lines = math.max(4, math.floor(visible_h / DETAIL_LINE_H))

    local sel = settings.selected_spell or ''
    -- Build the full content as a list of lines so we can paginate it.
    local full_lines
    if sel == '' then
        full_lines = { '\\cs(150,180,220)Click a spell to lock its acquisition info here.\\cr' }
    elseif is_trust_tab() then
        -- TRUST tab: pull from libs/trust_info.lua (auto-generated from
        -- BG-Wiki Cipher: pages) and render a structured panel with
        -- Job / Spells / Abilities / Weapon Skills / Acquisition /
        -- Special Features. Falls back gracefully when a particular
        -- trust's Cipher page on the wiki is a stub.
        full_lines = build_trust_info_lines(sel)
    elseif is_cor_tab() then
        -- COR tab: pull from libs/dice_info.lua (BG-Wiki Category:Dice)
        -- and render Description / Purchased from / Obtained from.
        full_lines = build_die_info_lines(sel)
    elseif spell_info[sel] or blu_info[sel] then
        -- Unified path for every non-COR non-TRUST job tab, including
        -- BLU. build_spell_info_lines() merges libs/spell_info.lua and
        -- libs/blu_info.lua so the same field order and labels render
        -- regardless of which job tab the spell is on -- no more two-
        -- different-layouts-for-the-same-renderer behavior.
        full_lines = build_spell_info_lines(sel)
    else
        local raw = acquisition_full_for(sel)
        if raw == '' then
            full_lines = {
                '\\cs(255,220,140)'..sel..'\\cr',
                '\\cs(180,180,180)(no acquisition info available)\\cr',
            }
        else
            full_lines = { '\\cs(255,220,140)'..sel..'\\cr' }
            for line in (format_acquisition(raw) .. '\n'):gmatch('([^\n]*)\n') do
                table.insert(full_lines, line)
            end
        end
    end
    ui.detail_total = #full_lines

    -- Clamp scroll to valid range so re-rendering doesn't leave an
    -- off-end window when the selection changes to a shorter detail.
    local max_dscroll = math.max(0, ui.detail_total - detail_visible_lines)
    if ui.detail_scroll < 0 then ui.detail_scroll = 0 end
    if ui.detail_scroll > max_dscroll then ui.detail_scroll = max_dscroll end

    -- Slice the lines to the visible window
    local sliced = {}
    for i = 1, detail_visible_lines do
        local idx = ui.detail_scroll + i
        if not full_lines[idx] then break end
        table.insert(sliced, full_lines[idx])
    end
    ui.detail_text = make_text(table.concat(sliced, '\n'),
                               detail_x, detail_y, { 255, 245, 245, 250 }, 10, false)

    -- Remember for the wheel handler
    ui.detail_visible_lines = detail_visible_lines

    -- Scroll buttons render only when content overflows the visible window
    if ui.detail_total > detail_visible_lines then
        local can_du = ui.detail_scroll > 0
        local can_dd = ui.detail_scroll < max_dscroll

        ui.el.detail_scroll_up_bg = make_bg(d_btn_x, d_up_y, d_btn_w, SCROLL_BTN_H,
            can_du and C_SCROLL_BG or C_SCROLL_OFF)
        ui.el.detail_scroll_up_txt = make_text('▲', d_btn_x + 7, d_up_y + 3,
            can_du and C_SCROLL_TXT or C_SCROLL_TXT_OFF, 11, true)
        ui.rect.detail_scroll_up = { x = d_btn_x, y = d_up_y, w = d_btn_w, h = SCROLL_BTN_H, enabled = can_du }

        ui.el.detail_scroll_dn_bg = make_bg(d_btn_x, d_dn_y, d_btn_w, SCROLL_BTN_H,
            can_dd and C_SCROLL_BG or C_SCROLL_OFF)
        ui.el.detail_scroll_dn_txt = make_text('▼', d_btn_x + 7, d_dn_y + 3,
            can_dd and C_SCROLL_TXT or C_SCROLL_TXT_OFF, 11, true)
        ui.rect.detail_scroll_dn = { x = d_btn_x, y = d_dn_y, w = d_btn_w, h = SCROLL_BTN_H, enabled = can_dd }
    else
        -- No overflow — make sure stale rects don't trigger hit-testing
        ui.rect.detail_scroll_up = nil
        ui.rect.detail_scroll_dn = nil
    end
    -- Hit-rect for the entire detail pane so the mouse-wheel handler
    -- knows when the cursor is over it (separate from the list scroll).
    ui.rect.detail_pane = { x = detail_x - PAD, y = detail_y,
                            w = DETAIL_W, h = body_h - PAD * 2 }

    -- Show everything
    for _, e in pairs(ui.el) do show(e) end
    for _, r in ipairs(ui.rows) do
        if r.bg then show(r.bg) end
        show(r.lv)
        show(r.name)
        show(r.skill)
    end
    if ui.detail_text then show(ui.detail_text) end
end

local function show_window()
    settings.visible = true
    config.save(settings)
    build_window()
end

local function hide_window()
    settings.visible = false
    config.save(settings)
    destroy_window()
end

local function toggle_window()
    if settings.visible then hide_window() else show_window() end
end

local function refresh_window()
    if settings.visible then build_window() end
end

-- ---------------------------------------------------------------------------
-- Hit testing & mouse handling
-- ---------------------------------------------------------------------------

local function in_rect(x, y, r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function is_over_window(x, y)
    if not settings.visible then return false end
    local W, H = ui.total_w, ui.total_h
    return x >= settings.pos.x and x <= settings.pos.x + W
        and y >= settings.pos.y and y <= settings.pos.y + H
end

local function scroll_by(delta)
    local rows = rows_for_view()
    local max_scroll = math.max(0, #rows - VISIBLE_ROWS)
    ui.scroll = math.max(0, math.min(max_scroll, ui.scroll + delta))
    refresh_window()
end

-- Windower mouse event types: 0=move, 1=LMB down, 2=LMB up, 10=wheel.
-- See SESSION-NOTES gotcha F (FFXIMissingTrust) for full mapping.
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if not settings.visible then return false end
    if blocked then return false end

    -- Mouse MOVE — only used to follow the drag when the title bar is
    -- being dragged. (Hover-tooltip detection is gone; the right-side
    -- detail pane is click-locked instead.)
    if mtype == 0 then
        if ui.drag then
            settings.pos.x = x - ui.drag.dx
            settings.pos.y = y - ui.drag.dy
            build_window()
            return true
        end
        return is_over_window(x, y)
    end

    -- LMB UP — release the drag regardless of cursor position
    if mtype == 2 then
        if ui.drag then
            ui.drag = nil
            config.save(settings)
            return true
        end
        return is_over_window(x, y)
    end

    if not is_over_window(x, y) then return false end

    -- LMB DOWN — mode tab, job tab, scroll button, or start a drag
    if mtype == 1 then
        -- Title-bar mode tabs (Missing / Owned / All)
        if in_rect(x, y, ui.rect.title_bar) then
            for _, key in ipairs({'missing','owned','all'}) do
                if in_rect(x, y, ui.rect['mode_' .. key]) then
                    if settings.mode ~= key then
                        settings.mode = key
                        ui.scroll = 0
                        config.save(settings)
                        build_window()
                    end
                    return true
                end
            end
            ui.drag = { dx = x - settings.pos.x, dy = y - settings.pos.y }
            return true
        end

        -- Job tabs (one row, twelve tabs)
        for _, jb in ipairs(JOB_TABS) do
            if in_rect(x, y, ui.rect['jtab_' .. jb]) then
                if settings.job ~= jb then
                    settings.job = jb
                    ui.scroll = 0
                    config.save(settings)
                    build_window()
                end
                return true
            end
        end

        if ui.rect.scroll_up and in_rect(x, y, ui.rect.scroll_up) and ui.rect.scroll_up.enabled then
            scroll_by(-math.floor(VISIBLE_ROWS / 2))
            return true
        end
        if ui.rect.scroll_dn and in_rect(x, y, ui.rect.scroll_dn) and ui.rect.scroll_dn.enabled then
            scroll_by(math.floor(VISIBLE_ROWS / 2))
            return true
        end
        -- Detail-pane scroll buttons (separate up/down for the right
        -- column; tested BEFORE the list scroll so a click in the
        -- detail-pane buttons doesn't fall through).
        local dvis = ui.detail_visible_lines or 20
        if ui.rect.detail_scroll_up and in_rect(x, y, ui.rect.detail_scroll_up)
           and ui.rect.detail_scroll_up.enabled then
            ui.detail_scroll = math.max(0, ui.detail_scroll - math.floor(dvis / 2))
            build_window()
            return true
        end
        if ui.rect.detail_scroll_dn and in_rect(x, y, ui.rect.detail_scroll_dn)
           and ui.rect.detail_scroll_dn.enabled then
            ui.detail_scroll = ui.detail_scroll + math.floor(dvis / 2)
            build_window()
            return true
        end
        -- Row click: lock the clicked spell as the detail pane's subject.
        -- Resets detail_scroll so the new spell's content starts at the top.
        for _, row in ipairs(ui.rows) do
            local r = row.rect
            if r and r.spell_name and in_rect(x, y, r) then
                if settings.selected_spell ~= r.spell_name then
                    ui.detail_scroll = 0
                end
                settings.selected_spell = r.spell_name
                config.save(settings)
                build_window()
                return true
            end
        end
        return true
    end

    -- Scroll wheel: route to whichever column the cursor is over.
    -- detail pane > list (default).
    if mtype == 10 then
        local dvis = ui.detail_visible_lines or 20
        if ui.rect.detail_pane and in_rect(x, y, ui.rect.detail_pane)
           and ui.detail_total > dvis then
            local step = (delta > 0) and -3 or 3
            local max_dscroll = math.max(0, ui.detail_total - dvis)
            ui.detail_scroll = math.max(0, math.min(max_dscroll, ui.detail_scroll + step))
            build_window()
            return true
        end
        scroll_by(delta > 0 and -3 or 3)
        return true
    end

    return true     -- block stray events over the window (no camera rotation)
end)

-- ---------------------------------------------------------------------------
-- Command dispatch
-- ---------------------------------------------------------------------------

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'toggle'):lower()
    local args = {...}

    if cmd == 'toggle' or cmd == 't' then
        toggle_window()
    elseif cmd == 'show' or cmd == 'window' or cmd == 'open' or cmd == 'w' then
        show_window()
    elseif cmd == 'hide' or cmd == 'close' then
        hide_window()

    elseif cmd == 'count' or cmd == 'summary' or cmd == 's' then
        cmd_count(args[1])
    elseif cmd == 'list' or cmd == 'missing' or cmd == 'l' then
        cmd_list_chat(args[1])
    elseif cmd == 'have' or cmd == 'owned' or cmd == 'h' then
        cmd_have_chat(args[1])
    elseif cmd == 'find' or cmd == 'search' or cmd == 'f' then
        cmd_find_chat(table.concat(args, ' '))

    -- Direct tab-switch shortcuts: //ms whm, //ms blm, ...
    elseif resolve_job_arg(cmd) then
        settings.job = resolve_job_arg(cmd)
        config.save(settings)
        refresh_window()
        cmd_count(settings.job)

    elseif cmd == 'mode' then
        local m = args[1] and args[1]:lower()
        if m == 'missing' or m == 'owned' or m == 'all' then
            settings.mode = m
            config.save(settings)
            refresh_window()
        else
            chat(CHAT_MISSING, '[MissingSpells] mode is missing | owned | all')
        end

    elseif cmd == 'refresh' or cmd == 'r' then
        refresh_window()
        cmd_count(settings.job)
    elseif cmd == 'help' or cmd == '?' then
        chat(CHAT_HEADER, '[MissingSpells] Commands:')
        chat(CHAT_ITEM, '  //ms              — toggle the window')
        chat(CHAT_ITEM, '  //ms show / hide  — show/hide the window')
        chat(CHAT_ITEM, '  //ms <TAB>        — switch tabs: TRUST | WHM | BLM | RDM | PLD |')
        chat(CHAT_ITEM, '                       DRK | BRD | NIN | SMN | BLU | GEO | SCH | RUN')
        chat(CHAT_ITEM, '  //ms count [TAB]  — one-line summary')
        chat(CHAT_ITEM, '  //ms list  [TAB]  — list missing in chat')
        chat(CHAT_ITEM, '  //ms have  [TAB]  — list owned in chat')
        chat(CHAT_ITEM, '  //ms find <name>  — search across every spell + trust')
        chat(CHAT_ITEM, '  //ms mode <missing|owned|all>')
        chat(CHAT_ITEM, '  //ms refresh      — re-read spell book + redraw')
    else
        chat(CHAT_MISSING, '[MissingSpells] unknown command: ' .. cmd)
    end
end)

-- ---------------------------------------------------------------------------
-- Keyboard handler (navigation only).
-- Window toggle lives in libs/hotkey (Alt+M, bound on 'load').
--   ; / '             — move selection up / down in the spell list.
--                       (Arrow keys aren't used because FFXI reads them
--                       at the DirectInput device level, below Windower's
--                       keyboard hook — Windower can't suppress the
--                       camera-rotate even with return true. The
--                       semicolon and apostrophe keys aren't polled by
--                       FFXI for anything other than chat input, so
--                       they're safe to repurpose when chat is closed.)
--   PgUp / PgDn       — page-jump in the list (also safe — unbound)
--   All gated on: window visible + chat closed.
-- ---------------------------------------------------------------------------
local DIK_SEMICOLON  = 39    -- 0x27 — ";" key, used as Up
local DIK_APOSTROPHE = 40    -- 0x28 — "'" key, used as Down
local DIK_PGUP       = 201   -- 0xC9
local DIK_PGDN       = 209   -- 0xD1

-- Move the selection by `delta` rows in the current filtered list, then
-- adjust ui.scroll so the selected row stays in the visible window.
local function move_selection(delta)
    local rows = rows_for_view()
    if not rows or #rows == 0 then return end
    -- Find current selection's index; if not in list (e.g. just changed
    -- tabs), start at the top or bottom depending on direction.
    local cur_idx = nil
    if settings.selected_spell and settings.selected_spell ~= '' then
        for i, e in ipairs(rows) do
            if e.name == settings.selected_spell then cur_idx = i; break end
        end
    end
    local new_idx
    if cur_idx then
        new_idx = math.max(1, math.min(#rows, cur_idx + delta))
    else
        new_idx = (delta > 0) and 1 or #rows
    end
    local new_entry = rows[new_idx]
    if not new_entry then return end
    if new_entry.name ~= settings.selected_spell then
        settings.selected_spell = new_entry.name
        ui.detail_scroll = 0
        config.save(settings)
    end
    -- Autoscroll: keep the selected row in the visible window
    if new_idx - 1 < ui.scroll then
        ui.scroll = new_idx - 1
    elseif new_idx > ui.scroll + VISIBLE_ROWS then
        ui.scroll = new_idx - VISIBLE_ROWS
    end
    ui.scroll = math.max(0, math.min(ui.scroll, math.max(0, #rows - VISIBLE_ROWS)))
    build_window()
end

windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then return false end

    local info = windower.ffxi.get_info()
    local chat_open = info and info.chat_open
    if chat_open then return false end

    -- Window toggle moved to Alt+M via libs/hotkey (bound on 'load').
    -- That route already respects chat-open state, and the modifier
    -- means a bare letter no longer fires the toggle (chat name /
    -- search box conflicts).

    -- Selection nav: only when the window is visible. Semicolon / apostrophe
    -- aren't polled by FFXI for any in-game action, so consuming them here
    -- (return true) reliably blocks them from chat-input fallthrough too.
    if not settings.visible then return false end
    if dik == DIK_SEMICOLON or dik == DIK_APOSTROPHE
       or dik == DIK_PGUP    or dik == DIK_PGDN then
        if pressed then
            if     dik == DIK_SEMICOLON  then move_selection(-1)
            elseif dik == DIK_APOSTROPHE then move_selection(1)
            elseif dik == DIK_PGUP       then move_selection(-VISIBLE_ROWS)
            elseif dik == DIK_PGDN       then move_selection( VISIBLE_ROWS)
            end
        end
        return true
    end

    return false
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Login-screen guard helper. Keeps build_window from drawing while the
-- player is sitting at character-select / launcher (Windower auto-loads
-- addons before the player picks a character; without this gate the
-- panel ghosts on top of the SE login UI).
local function _player_in_game()
    local info = windower.ffxi.get_info()
    return info and info.logged_in == true
end

-- Auto-hide while ANY FFXI text-entry surface is open: chat bar, macro
-- editor, search comment, /tell input. Two signals OR'd together:
--   1. windower.ffxi.get_info().chat_open  (chat bar / /tell)
--   2. _last_blocked_at -- last keyboard event flagged blocked=true.
--      The macro editor doesn't set chat_open but DOES route keys
--      through FFXI's intercept (blocked=true). 1.5 s window catches
--      pauses between keystrokes mid-edit.
-- settings.visible is preserved; panel reappears once both signals
-- clear.
local _was_input_open = false
local _last_blocked_at = 0
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then _last_blocked_at = os.clock() end
end)
windower.register_event('prerender', function()
    local info = windower.ffxi.get_info()
    local input_open = (info and info.chat_open == true)
                       or (os.clock() - _last_blocked_at) < 1.5
    if input_open and not _was_input_open then
        destroy_window()
        _was_input_open = true
    elseif (not input_open) and _was_input_open then
        if settings.visible and _player_in_game() then build_window() end
        _was_input_open = false
    end
end)

windower.register_event('load', function()
    coroutine.schedule(function()
        cmd_count(settings.job)
        if settings.visible and _player_in_game() then build_window() end
    end, 2)

    -- Toggle hotkey: Alt+M (mnemonic for Missing). Modifier+letter avoids
    -- the in-game macro slots (Alt/Ctrl+0..9) and bare-letter chat conflicts.
    hotkey.bind('ms', 'toggle', 'alt', 'm')
end)

windower.register_event('login', function()
    coroutine.schedule(function()
        cmd_count(settings.job)
        if settings.visible then build_window() end
    end, 3)
end)

windower.register_event('logout', function()
    -- Hide the panel when returning to character-select without
    -- clobbering the user's settings.visible preference.
    destroy_window()
end)

windower.register_event('zone change', function()
    coroutine.schedule(function()
        if _player_in_game() then refresh_window() end
    end, 1)
end)

windower.register_event('unload', function()
    pcall(hotkey.unbind, 'ms')
    destroy_window()
end)
