-- QuestTracker v2.0 (rebuild of the original)
--
--  * Mob tooltips show your kill quests with live progress (yellow / grey done).
--  * Blizzard's 5-quest watch frame is REMOVED and replaced with our own
--    tracker panel: no quest cap, scales to its content, draggable, position
--    and tracked quests persist per character.
--  * Shift-click quests in the quest log to add/remove them from the tracker.
--
-- 2.4.3 notes: no print()/wipe(); OnEvent handlers use implicit globals
-- (this/event/arg1); AddQuestWatch is capped at 5 in the client C code, which
-- is why the tracker keeps its own list and never calls it.

local function Msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuestTracker|r: " .. text)
end

QuestTrackerDB = QuestTrackerDB or {}
MAX_WATCHABLE_QUESTS = 10   -- silences Blizzard's cap error; its frame is hidden anyway

-- ===========================================================================
-- Tooltip: mob -> quest lines
-- ===========================================================================
local cache = {}
local dirty = true

local function RebuildCache()
    for k in pairs(cache) do cache[k] = nil end
    for entry = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(entry)
        if not isHeader and title then
            for obj = 1, GetNumQuestLeaderBoards(entry) do
                local text, objType, done = GetQuestLogLeaderBoard(obj, entry)
                if objType == "monster" and text then
                    local mob, have, need = string.match(text, "^(.-) slain: (%d+)/(%d+)$")
                    if not mob then
                        mob, have, need = string.match(text, "^(.-):%s*(%d+)/(%d+)$")
                    end
                    if mob and mob ~= "" then
                        cache[mob] = cache[mob] or {}
                        table.insert(cache[mob], {
                            title = title,
                            have = tonumber(have) or 0,
                            need = tonumber(need) or 0,
                            done = done and true or false,
                        })
                    end
                end
            end
        end
    end
    dirty = false
end

local lastAnnotated = nil
local function AnnotateTooltip(tooltip)
    if dirty then RebuildCache() end
    local name = tooltip:GetUnit()
    if not name or name == lastAnnotated then return end
    lastAnnotated = name
    local list = cache[name]
    if not list then return end
    for _, o in ipairs(list) do
        if o.done or (o.need > 0 and o.have >= o.need) then
            tooltip:AddLine(o.title .. " (done)", 0.6, 0.6, 0.6)
        else
            tooltip:AddLine(o.title .. " - " .. o.have .. "/" .. o.need, 1.0, 0.82, 0.0)
        end
    end
    tooltip:Show()
end

if GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function() AnnotateTooltip(GameTooltip) end)
end
hooksecurefunc(GameTooltip, "SetUnit", function() AnnotateTooltip(GameTooltip) end)
GameTooltip:HookScript("OnHide", function() lastAnnotated = nil end)

-- ===========================================================================
-- Custom tracker panel (replaces QuestWatchFrame)
-- ===========================================================================

-- bury the Blizzard watch frame for good
QuestWatchFrame:UnregisterAllEvents()
QuestWatchFrame:Hide()
hooksecurefunc("QuestWatch_Update", function() QuestWatchFrame:Hide() end)

local panel = CreateFrame("Frame", "QuestTrackerFrame", UIParent)
panel:SetWidth(220)
panel:SetHeight(40)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetClampedToScreen(true)
panel:SetScript("OnDragStart", function() panel:StartMoving() end)
panel:SetScript("OnDragStop", function()
    panel:StopMovingOrSizing()
    local point, _, relPoint, x, y = panel:GetPoint()
    QuestTrackerDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
end)

-- Classic WoW look: Morpheus (the ornate font WoW uses for quest-log TITLES) for the
-- header + quest titles; Friz Quadrata (the standard quest-body font) for objectives.
local FONT_TITLE = "Fonts\\MORPHEUS.TTF"
local FONT_BODY  = "Fonts\\FRIZQT__.TTF"
local SIZE_HEADER, SIZE_TITLE, SIZE_OBJ = 15, 13, 11
local STEP_TITLE, STEP_OBJ = 15, 13     -- line heights tuned to the above sizes
local function ClassicFont(fs, path, size)
    fs:SetFont(path, size)
    fs:SetShadowColor(0, 0, 0, 1)       -- the drop shadow is a big part of the old-school feel
    fs:SetShadowOffset(1, -1)
end

-- Sit far-right, but clear the two right action bars (Interface > Action Bars:
-- "Right Bar" = MultiBarRight, "Right Bar 2" = MultiBarLeft). Only whichever are
-- actually shown push us further in, so the quest text is never hidden behind them.
local function RightBarInset()
    local inset = 30
    if MultiBarRight and MultiBarRight:IsShown() then
        inset = inset + (MultiBarRight:GetWidth() or 40)
    end
    if MultiBarLeft and MultiBarLeft:IsShown() then
        inset = inset + (MultiBarLeft:GetWidth() or 40)
    end
    return inset
end

local function ApplyDefaultAnchor()
    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -RightBarInset(), -250)
end

local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
ClassicFont(header, FONT_TITLE, SIZE_HEADER)
header:SetText("|cff33ff99Quests|r")

local lines = {}   -- FontString pool
local function GetLine(i)
    if not lines[i] then
        lines[i] = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lines[i]:SetJustifyH("LEFT")
    end
    return lines[i]
end

local function FindQuestByTitle(wanted)
    for entry = 1, GetNumQuestLogEntries() do
        local title, level, _, _, isHeader, _, isComplete = GetQuestLogTitle(entry)
        if not isHeader and title == wanted then
            return entry, level, isComplete
        end
    end
    return nil
end

local function RefreshPanel()
    QuestTrackerDB.watched = QuestTrackerDB.watched or {}
    local lineNum = 0
    local maxWidth = header:GetStringWidth()
    local y = -18

    for _, wanted in ipairs(QuestTrackerDB.watched) do
        local entry, level, isComplete = FindQuestByTitle(wanted)
        if entry then
            lineNum = lineNum + 1
            local titleLine = GetLine(lineNum)
            ClassicFont(titleLine, FONT_TITLE, SIZE_TITLE)
            titleLine:ClearAllPoints()
            titleLine:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
            if isComplete and isComplete > 0 then
                titleLine:SetText("[" .. level .. "] " .. wanted .. " (complete)")
                titleLine:SetTextColor(0.2, 1.0, 0.2)
            else
                titleLine:SetText("[" .. level .. "] " .. wanted)
                titleLine:SetTextColor(1.0, 0.82, 0.0)
            end
            titleLine:Show()
            if titleLine:GetStringWidth() > maxWidth then maxWidth = titleLine:GetStringWidth() end
            y = y - STEP_TITLE

            for obj = 1, GetNumQuestLeaderBoards(entry) do
                local text, _, done = GetQuestLogLeaderBoard(obj, entry)
                if text then
                    lineNum = lineNum + 1
                    local objLine = GetLine(lineNum)
                    ClassicFont(objLine, FONT_BODY, SIZE_OBJ)
                    objLine:ClearAllPoints()
                    objLine:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
                    objLine:SetText(text)
                    if done then
                        objLine:SetTextColor(0.5, 0.5, 0.5)
                    else
                        objLine:SetTextColor(0.85, 0.85, 0.85)
                    end
                    objLine:Show()
                    if objLine:GetStringWidth() + 10 > maxWidth then maxWidth = objLine:GetStringWidth() + 10 end
                    y = y - STEP_OBJ
                end
            end
            y = y - 4   -- gap between quests
        end
    end

    for i = lineNum + 1, table.getn(lines) do
        lines[i]:Hide()
    end

    -- scale the panel to its content
    panel:SetWidth(math.max(maxWidth + 4, 100))
    panel:SetHeight(math.max(-y + 4, 20))

    -- Unless the user dragged it somewhere, keep the auto-position clearing whichever
    -- right action bars are live (picks up bar on/off changes on the next quest update).
    if not QuestTrackerDB.pos then
        ApplyDefaultAnchor()
    end
end

local function IsTracked(title)
    QuestTrackerDB.watched = QuestTrackerDB.watched or {}
    for i, t in ipairs(QuestTrackerDB.watched) do
        if t == title then return i end
    end
    return nil
end

local function ToggleTracked(title)
    local at = IsTracked(title)
    if at then
        table.remove(QuestTrackerDB.watched, at)
        Msg("untracked: " .. title)
    else
        table.insert(QuestTrackerDB.watched, title)
        Msg("tracking: " .. title)
    end
    RefreshPanel()
end

-- shift-click in the quest log toggles OUR tracker
hooksecurefunc("QuestLogTitleButton_OnClick", function(button)
    if not IsShiftKeyDown() then return end
    local questIndex = this:GetID() + FauxScrollFrame_GetOffset(QuestLogListScrollFrame)
    local title, _, _, _, isHeader = GetQuestLogTitle(questIndex)
    if title and not isHeader then
        ToggleTracked(title)
    end
end)

-- ===========================================================================
-- Events / restore
-- ===========================================================================
local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:SetScript("OnEvent", function()
    dirty = true
    if event == "PLAYER_ENTERING_WORLD" and QuestTrackerDB.pos then
        panel:ClearAllPoints()
        panel:SetPoint(QuestTrackerDB.pos.point, UIParent, QuestTrackerDB.pos.relPoint,
            QuestTrackerDB.pos.x, QuestTrackerDB.pos.y)
    end
    RefreshPanel()
end)

if not QuestTrackerDB.pos then
    ApplyDefaultAnchor()
end

-- /qt — tooltip self-test; /qt clear — untrack everything
SLASH_QUESTTRACKER1 = "/qt"
SlashCmdList["QUESTTRACKER"] = function(msg)
    if msg == "clear" then
        QuestTrackerDB.watched = {}
        RefreshPanel()
        Msg("tracker cleared.")
        return
    end
    if dirty then RebuildCache() end
    local mobs = 0
    for _ in pairs(cache) do mobs = mobs + 1 end
    Msg(mobs .. " mob name(s) on tooltip watch. Shift-click quests in the log to track them (no cap). /qt clear to reset.")
end

Msg("v2.0 loaded — custom tracker panel, no quest cap. Shift-click quests to track; drag the panel to move it.")
