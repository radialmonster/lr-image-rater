local Require = require 'Require'.path ("/common").reload ()
local Debug = require 'Debug'.init ()
require 'strict.lua'

local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local Debug = require 'Debug'.init()

local function showSettings()
    return LrFunctionContext.callWithContext("Settings", function(context)
        local prefs = LrPrefs.prefsForPlugin()
        -- Ensure defaults are set if not already set
        if not prefs.windowWidth then prefs.windowWidth = 1600 end
        if not prefs.windowHeight then prefs.windowHeight = 1000 end
        if not prefs.photoWidth then prefs.photoWidth = 780 end
        if not prefs.photoHeight then prefs.photoHeight = 880 end
        if prefs.autoSizeToScreen == nil then prefs.autoSizeToScreen = true end

        local f = LrView.osFactory()
        local propertyTable = LrBinding.makePropertyTable(context)

        -- Initialize property table with current values
        propertyTable.windowWidth = prefs.windowWidth
        propertyTable.windowHeight = prefs.windowHeight
        propertyTable.autoSizeToScreen = prefs.autoSizeToScreen

        local settingsDialog = f:column {
            spacing = f:control_spacing(),
            bind_to_object = propertyTable,
            f:row {
                f:checkbox {
                    title = "Automatically fit the compare window to my screen",
                    value = LrView.bind("autoSizeToScreen"),
                },
            },
            f:row {
                f:static_text {
                    title = "(When checked, the width/height below are ignored.)",
                    text_color = LrColor(0.5, 0.5, 0.5),
                },
            },
            f:row {
                f:static_text {
                    title = "Window Width:",
                    alignment = 'right',
                    width = 100
                },
                f:edit_field {
                    value = LrView.bind("windowWidth"),
                    immediate = true,
                    width_in_chars = 6,
                },
            },
            f:row {
                f:static_text {
                    title = "Window Height:",
                    alignment = 'right',
                    width = 100
                },
                f:edit_field {
                    value = LrView.bind("windowHeight"),
                    immediate = true,
                    width_in_chars = 6,
                },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "LR Image Rater - Settings",
            contents = settingsDialog,
            resizable = true,
            save_frame = "settingsDialogPosition",
            actionVerb = "Save",
            cancelVerb = "Cancel"
        }

        if result == 'ok' then
            -- Save the values back to preferences
            prefs.autoSizeToScreen = propertyTable.autoSizeToScreen
            if tonumber(propertyTable.windowWidth) and tonumber(propertyTable.windowWidth) > 0 then
                prefs.windowWidth = tonumber(propertyTable.windowWidth)
                prefs.photoWidth = math.floor((prefs.windowWidth - 40) / 2)  -- Account for spacing
            end
            if tonumber(propertyTable.windowHeight) and tonumber(propertyTable.windowHeight) > 0 then
                prefs.windowHeight = tonumber(propertyTable.windowHeight)
                prefs.photoHeight = math.floor(prefs.windowHeight - 120)  -- Account for buttons and spacing
            end
            LrDialogs.showBezel("Settings saved")
        end
    end)
end

return Debug.callWithContext("showSettings",
    Debug.showErrors(function(context)
        LrTasks.startAsyncTask(Debug.showErrors(showSettings))
    end))