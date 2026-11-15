
local _unpack = table.unpack or unpack

local CAPTAIN_IDS = {
    20, --cleopatra
    26, --leonid
    22, --minamoto
    27  --hercules
}

-- The last two steps, from a captain window that is already on the Stars tab.
local function StarUpgradeFlow()
    WaitTime(500)
    ShowCursor("costPanel/upgradeButton", 180, 0)
    WaitClick()
end

-- Same, from a captain window that opened on the first tab.
local function StarsTabFlow()
    WaitTime(500)
    ShowCursor("tabStars", 0, 180)
    WaitClick()
    ClearCursor()
    StarUpgradeFlow()
end

Tutorial("autobattler_prefight_star_up",
    cond.All:new(
        cond.Event:new("AUTO_BATTLER_PREFIGHT_OPENED"),
        cond.CanStarUpgrade:new(_unpack(CAPTAIN_IDS))
    ),
    function()
        WaitTime(500)

        local captainId = tutor.Helper:findCaptainIdForStarUpgrade(_unpack(CAPTAIN_IDS))
        if captainId == 0 then
            return
        end

        -- The arrow over the captain standing on the field. Its own node is only there while he is
        -- deployed, and it hides itself when he has nothing to buy, so finding it answers both.
        local upgradeBtn = "captainsBarrelsPrefightCaptainUiView_" .. captainId .. "/upgradeBtn"
        if CheckNodeExist(upgradeBtn) then
            ShowTooltip(upgradeBtn .. "/image", "client.cap_minigames.prefight.tutor.tooltip_star_up")
            WaitClickWithAdditionalTargets(upgradeBtn)
            -- The arrow picks the tab itself, stars first, so the window is already where we want it.
            StarUpgradeFlow()
        else
            ShowCursor("buttonCaptains", 180, 90)
            WaitClick()
            WaitTime(500)

            local icon = "captainIcon_" .. captainId
            ScrollToNode(icon)
            WaitTime(500)
            ShowTooltip(icon, "client.cap_minigames.captains.tutor.tooltip_star_up", "BOTTOM_MIDDLE")
            WaitClick()
            StarsTabFlow()
        end
    end
)
