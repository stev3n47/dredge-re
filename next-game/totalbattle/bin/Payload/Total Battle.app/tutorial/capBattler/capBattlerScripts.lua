local function LoadScripts(scripts)
    for _, script in ipairs(scripts) do
        package.loaded[script] = nil
        require(script)
    end
end

LoadScripts({
    "cap_battler_accent",
    "cap_battler_damage_taken",
})
