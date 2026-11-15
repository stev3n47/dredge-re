local tutorials = {}
local currentTutorial = nil

local function AddTutorial(name, condition, actions, priority, repeatable)
    priority = priority or 0

    local tutorial = tutor.Tutorial:new(name, condition, priority, repeatable)

    local peer = {
        actions = actions
    }
    setmetatable(peer, { __index = tutor.Tutorial })
    tolua.setpeer(tutorial, peer)

    ScriptHandlerMgr:getInstance():registerScriptHandler(
        tutorial,
        function(eventName, obj)
            obj[eventName](obj)
        end,
        10000
    )

    tutorials[name] = tutorial
end

function Tutorial(name, condition, actions, priority)
    AddTutorial(name, condition, actions, priority, false)
end

function RepeatableTutorial(name, condition, actions, priority)
    AddTutorial(name, condition, actions, priority, true)
end

function LoadScripts(scripts)
    for _, script in ipairs(scripts) do
        package.loaded[script] = nil
        require(script)
    end
end

function tutor.Tutorial:start()
    currentTutorial = self
    local peer = tolua.getpeer(self)
    peer.co = coroutine.create(peer.actions)
    self:resume()
end

function tutor.Tutorial:resume()
    local peer = tolua.getpeer(self)
    coroutine.resume(peer.co)

    if coroutine.status(peer.co) == "dead" then
        self:onFinished()
    end
end

local function showCursorImpl(path, direction, newDirection, offset, scale, attachToTarget)
    direction = direction or 0
    offset = offset or { x = 0, y = 0 }
    scale = scale or 0.8

    return currentTutorial:showCursor(path, direction, offset, scale, newDirection, attachToTarget)
end

-- Shows the cursor on the topmost tutorial overlay (drawn above the interface).
function ShowCursor(path, direction, newDirection, offset, scale)
    return showCursorImpl(path, direction, newDirection, offset, scale, false)
end

-- Shows the cursor directly on the target node, so it respects the interface z-order and clipping.
function ShowCursorOnTarget(path, direction, newDirection, offset, scale)
    return showCursorImpl(path, direction, newDirection, offset, scale, true)
end

-- `path` is one node, or a list of them - a list places the bubble against the box they all fit in,
-- so a row of cards gets one tooltip over its middle instead of one hanging off its first card.
function ShowTooltip(path, text, align, sideOffset)
    align = align or "TOP_MIDDLE"
    sideOffset = sideOffset or 0

    currentTutorial:showTooltip(path, text, align, sideOffset)
end

function ClearCursor()
    currentTutorial:clearCursor()
end

function ClearHelperCursor()
    currentTutorial:clearHelperCursor()
end

function WaitCondition(condition)
    currentTutorial:waitCondition(condition)
    coroutine.yield()
end

function WaitClick()
    currentTutorial:waitClick()
    coroutine.yield()
end

function WaitAnyClick(swallow)
    if swallow == nil then
        swallow = true
    end

    currentTutorial:waitAnyClick(swallow)
    coroutine.yield()
end

function Highlight(path, type, additionalSize)
    additionalSize = additionalSize or { width = 0, height = 0 }
    type = type or "rectangle"

    currentTutorial:highlight(path, type, additionalSize)
end

-- Blacks out the screen except around the given paths, and swallows every touch outside the lit area:
-- the step cannot be walked past by pressing something behind the mask.
--
-- shape: "node" (default) cuts each target's own silhouette, "rect" its box, "band" a single strip
-- across the screen covering all of them. Cleared by the next ShowCursor/ShowTooltip, like Highlight.
--
-- swallowTouches: what a press on the lit area does. true (default) eats it, so the step advances only
-- on what the script waits for; false lets it reach the targets and they act as usual. Say it out loud
-- for every call - the shape used to decide this on its own, and the two never agreed.
function Spotlight(paths, shape, padding, swallowTouches)
    shape = shape or "node"
    padding = padding or { width = 0, height = 0 }
    if swallowTouches == nil then
        swallowTouches = true
    end

    currentTutorial:showSpotlight(paths, shape, padding, swallowTouches)
end

function ClearSpotlight()
    currentTutorial:clearSpotlight()
end

function DismissVisualsOnAnyClick()
    currentTutorial:dismissVisualsOnAnyClick()
end

function WaitClickWithAdditionalTargets(...)
    currentTutorial:waitClickWithAdditionalTargets(...)
    coroutine.yield()
    return currentTutorial:getLastClickedTarget()
end

function WaitClickOrConditions(clickTargets, conditionTargets)
    currentTutorial:waitClickOrConditions(clickTargets, conditionTargets)
    coroutine.yield()
    return currentTutorial:getLastClickedTarget()
end

function WaitTime(milliseconds)
    currentTutorial:waitTime(milliseconds)
    coroutine.yield()
end

function MarkFinished(tutorialName) -- empty means self
    currentTutorial:markFinished(tutorialName or "")
end

function FollowMarch(maxSecondsToBlockScreen)
    currentTutorial:followMarch(maxSecondsToBlockScreen)
    coroutine.yield()
end

function StartDialog(...)
    currentTutorial:startDialog(...)
    coroutine.yield()
end

function CheckGameCondition(condition)
    return tutor.Helper:checkCondition(condition)
end

function GetSliderPercent(name)
    local slider = tutor.Helper:findNode(name, "ccui.Slider")
    return slider:getPercent()
end

function GetButton(name)
    return tutor.Helper:findNode(name, "ccui.Button")
end

function GetTextValue(name)
    local textNode = tutor.Helper:findNode(name, "ccui.Text")
    return textNode and textNode:getString() or ""
end

function CheckNodeExist(name)
    return tutor.Helper:findNode(name, "cc.Node") ~= nil
end

-- Brings `path` into the visible band of whatever list it sits in, so a cursor on it is not pointing
-- at empty screen. Returns false when nothing had to move; the scroll itself takes ~300ms.
function ScrollToNode(path)
    return tutor.Helper:scrollToNode(path)
end

function GetCurrentSceneType()
    return tutor.Helper:getCurrentSceneType()
end

-- Returns the current screen's view name (e.g. "Radar::RadarView"), or "" if none.
function GetCurrentViewName()
    return tutor.Helper:getCurrentViewName()
end

function SendEvent(name, ...)
    tutor.Helper:sendEvent(name, ...)
end

function HideGui(duration)
    tutor.Helper:hideGui(duration)
end

function ShowGui(duration)
    tutor.Helper:showGui(duration)
end
