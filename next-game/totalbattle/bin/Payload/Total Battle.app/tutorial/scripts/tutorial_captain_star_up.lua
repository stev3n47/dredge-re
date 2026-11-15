RepeatableTutorial("captain_stars_needed",
    cond.All:new(
        cond.Event:new("CAPTAIN_STARS_NEEDED")
    ),
    function()
        ShowCursor("#captainsButton", 180)
        WaitClick()
    end
)

local function StarUpgradeFlow()
    WaitTime(500)
    ShowCursor("starsContainer/upgradeButton")
    WaitClick()
    WaitTime(500)
    ShowCursor("priceContainer/[3]", 180, 270)
    WaitClick()
end

-- PREFIGHT --
local _unpack = table.unpack or unpack

local function PrefightStarUpTutorial(...)
    local captainIds = { ... }

    Tutorial("prefight_star_up",
        cond.All:new(
            cond.Event:new("GO_TO_PREFIGHT"),
            cond.CanStarUpgrade:new(...)
        ),
        function()
            WaitTime(500)

            local captainId = tutor.Helper:findCaptainIdForStarUpgrade(_unpack(captainIds))

            local uiCapNodeName = "captainsBarrelsPrefightCaptainUiView_" .. captainId;
            if CheckNodeExist(uiCapNodeName) then
                ShowTooltip(uiCapNodeName .. "/upgradeBtn/image", "client.cap_minigames.prefight.tutor.tooltip_star_up")
                WaitClickWithAdditionalTargets(uiCapNodeName .. "/upgradeBtn")
                StarUpgradeFlow()
            else
                ShowCursor("captainListButton", 180, 90)
                WaitClick()
                WaitTime(500)
                ShowTooltip("captainIcon_" .. captainId, "client.cap_minigames.captains.tutor.tooltip_star_up", "BOTTOM_MIDDLE")
                WaitClick()
                StarUpgradeFlow()
            end
        end
    )
end

PrefightStarUpTutorial(
    20, --cleopatra
    26, --leonid
    22, --minamoto
    27  --hercules
)

-- The StarUp captain card opens the redesigned captain window on its Stars tab when AutoBattler is on, and
-- the legacy star upgrade screen otherwise. Wait for whichever comes up, then point at its upgrade button.
Tutorial("personal_star_up_flow",
    cond.All:new(
        cond.Event:new("PERSONAL_STAR_UP_FLOW")
    ),
    function()
        WaitCondition(cond.Any:new(
            cond.ViewShown:new("CaptainScreenView"),
            cond.ViewShown:new("CaptainUpgradeStarView")
        ))
        WaitTime(500)
        if CheckNodeExist("costPanel/upgradeButton") then
            ShowCursor("costPanel/upgradeButton", 180, 0)
        else
            ShowCursor("priceContainer/[3]", 180, 270)
        end
        WaitClick()
    end
)
