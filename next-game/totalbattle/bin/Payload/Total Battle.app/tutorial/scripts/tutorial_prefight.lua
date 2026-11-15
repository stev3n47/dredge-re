-- Two names per button: CapBattler and Barrels still open the legacy prefight (deployButton /
-- battleButton), AutoBattler opens its own screen (buttonQuickDeploy / buttonFight).
--
local function PrefightOpened()
    return cond.Any:new(
        cond.Event:new("GO_TO_PREFIGHT"),
        cond.Event:new("AUTO_BATTLER_PREFIGHT_OPENED")
    )
end

local function FindButton(names)
    for _, name in ipairs(names) do
        local button = GetButton(name)
        if button then
            return button, name
        end
    end
    return nil, nil
end

local function QuickDeployFlow()
    MarkFinished("quick_deploy")
    local button, deployName = FindButton({"deployButton", "buttonQuickDeploy"})
    if button and button:isEnabled() then
        WaitTime(500)
        ShowCursor(deployName, 180, 270)
        MarkFinished()
        WaitCondition(cond.Event:new("CAPTAIN_ARRANGED_OPTIMAL"))
        local _, battleName = FindButton({"battleButton", "buttonFight"})
        if battleName then
            ShowCursor(battleName, 180, 270)
            WaitClick()
        end
    end
end

Tutorial("quick_deploy",
    cond.All:new(
        PrefightOpened()
    ),
    QuickDeployFlow,
    1
)

local function QuickDeployTutorial(name, captainId)
    Tutorial("quick_deploy_" .. name,
        cond.All:new(
            PrefightOpened(),
            cond.CheckCondition:new(string.format("HasHeroLevel(%d, 1, 10)", captainId))
        ),
        QuickDeployFlow,
        2
    )
end

QuickDeployTutorial("cleopatra", 20)
QuickDeployTutorial("leonid", 26)
QuickDeployTutorial("minamoto", 22)
QuickDeployTutorial("hercules", 27)
