local Require = require 'Require'.path ("/common").reload ()
local Debug = require 'Debug'.init ()
require 'strict.lua'

--[[----------------------------------------------------------------------------

PluginInfoProvider.lua
Manages the dialog entry in the Plugin Manager dialog window

------------------------------------------------------------------------------]]

local function sectionsForTopOfDialog(f, _)
    return {
        -- Section for the top of the dialog
        {
            title = "LR Image Rater",
            f:row {
                spacing = f:control_spacing(),
                
                f:static_text {
                    title = "This plugin helps you rate images by comparing them side by side.\n\nSelect images in the Library module, then go to Plugin Extras > LR Image Rater > Rate Images.\n\nYou will see two images at a time and choose which one you prefer.\n\nYou can also reject an image to remove it from comparisons and flag it as rejected.\n\nAfter all comparisons, the plugin calculates ratings from 1 to 5 for your images.\n\nYou can apply the ratings to the images in your Lightroom catalog.",
                    fill_horizontal = 1,
                    alignment = 'left'
                },
            },
        },
    }
end

return {
    sectionsForTopOfDialog = sectionsForTopOfDialog,
}
