-- Dropped first so a reload re-reads the core too: require alone would hand back the cached chunk,
-- and a script calling something added to it would die on a nil.
package.loaded["tutorialCore"] = nil
require "tutorialCore"

LoadScripts({
    "tutorial_lose",
    "tutorial_prefight",
    "tutorial_watchtower",
    "tutorial_captain_star_up",
    "tutorial_autobattler_star_up",
    "expedition",
    "radar",
    "autobattler_nvn"
})
