-- First run of a PvE NvN level (Figma CapBattler 5401:170211).
--
-- Every step is a hint and none of them is a gate: the waits watch for a click on their own target
-- without swallowing the rest, so a player who ignores the tutorial is never stuck behind it.
local ENEMY_SQUADS = { "clash0/enemySquad", "clash1/enemySquad", "clash2/enemySquad" }
local PLAYER_SQUADS = { "clash0/playerSquad", "clash1/playerSquad", "clash2/playerSquad" }

-- The lit zone is a strip across the whole screen, as in the mockup, rather than one hole per squad:
-- the row is a column per round, and the gaps between the columns are part of "your squads".
local BAND_PADDING = { width = 0, height = 24 }

Tutorial("autobattler_nvn_intro",
    cond.All:new(
        cond.Event:new("NVN_BATTLE_OPENED")
    ),
    function()
        -- Not a millisecond anywhere in here. Every step either follows straight on from the one before or
        -- waits for the event that says its screen is ready, so the tutorial keeps step with the device it
        -- runs on instead of with a guess about how long the device takes.
        StartDialog({ "hero_garvel", "client.auto_battler.pve_nvn.tutor.dialog_01" })
        MarkFinished()

        -- Swallowing on: both of these are "read this, then tap anywhere", and the next step points at a
        -- squad and waits for it to be pressed. A tap that also opened the editor would leave that finger
        -- on a squad behind it, waiting for a click that cannot arrive.
        ShowTooltip(ENEMY_SQUADS, "client.auto_battler.pve_nvn.tutor.enemy_squads")
        Spotlight(ENEMY_SQUADS, "band", BAND_PADDING, true)
        WaitAnyClick(false)

        ShowTooltip(PLAYER_SQUADS, "client.auto_battler.pve_nvn.tutor.player_squads")
        Spotlight(PLAYER_SQUADS, "band", BAND_PADDING, true)
        WaitAnyClick(false)

        -- No mask from here on: the player is being pointed at a squad, not held away from the screen.
        ShowCursor(PLAYER_SQUADS[1], 180)
        WaitClick()

        -- The tap only asks for the editor; the curtain, the mount and the curtain lifting come after it,
        -- and the event is sent at the end of all three.
        WaitCondition(cond.Event:new("NVN_PREFIGHT_OPENED"))
        ShowCursor("buttonQuickDeploy", 180, 270)
        -- Either way out of this step: the button, or a captain placed by hand. The click target is a
        -- rectangle rather than the button's own handler, so a round that is already manned - and whose
        -- Quick Deploy is therefore disabled - still lets the tutorial move on.
        WaitClickOrConditions({ "buttonQuickDeploy" }, { { "filled", cond.Event:new("NVN_ROUND_FILLED") } })

        -- Last thing inside the editor. From here the rounds are his to arrange.
        if CheckNodeExist("buttonNextRound") then
            ShowCursor("buttonNextRound", 180)
            WaitClick()
        end
        ClearCursor()

        -- And once he is back on the planner, the fight itself (Figma 6941:55677). Waits for the event
        -- rather than for the button: the battle view is only hidden while the editor is up, so its Battle
        -- button is findable the whole time and "is it on screen" cannot be asked of the node.
        WaitCondition(cond.Event:new("NVN_BATTLE_RETURNED"))
        ShowCursor("buttonBattle", 180)
        WaitClick()
        ClearCursor()
    end
)
