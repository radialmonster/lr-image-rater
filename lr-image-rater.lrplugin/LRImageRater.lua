local Require = require 'Require'.path ("/common").reload ()
local Debug = require 'Debug'.init ()
require 'strict.lua'

-- LRImageRater.lua
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrColor = import 'LrColor'
local LrSystemInfo = import 'LrSystemInfo'
local LrApplicationView = import 'LrApplicationView'
local LrProgressScope = import 'LrProgressScope'
local catalog = import 'LrApplication'.activeCatalog()

-- Initialize preferences with default values
local prefs = LrPrefs.prefsForPlugin()
if not prefs.windowWidth then prefs.windowWidth = 1600 end
if not prefs.windowHeight then prefs.windowHeight = 1000 end
if not prefs.photoWidth then prefs.photoWidth = 780 end
if not prefs.photoHeight then prefs.photoHeight = 880 end
if prefs.autoSizeToScreen == nil then prefs.autoSizeToScreen = true end

local calculateElo = Debug.showErrors(function(winnerRating, loserRating, k)
    local expectedWin = 1 / (1 + 10 ^ ((loserRating - winnerRating) / 400))
    winnerRating = winnerRating + k * (1 - expectedWin)
    loserRating = loserRating + k * (0 - expectedWin)
    return winnerRating, loserRating
end)

-- Report the pixel size of the screen currently hosting Lightroom, so the compare
-- window can open large enough to nearly fill it. Prefers the monitor Lightroom is
-- on (displayInfo); falls back to the Lightroom window size; returns nil on failure.
local getHostScreenSize = function()
    local screenW, screenH

    local ok, displays = Debug.pcall(function() return LrSystemInfo.displayInfo() end)
    if ok and type(displays) == "table" then
        local chosen
        for _, d in ipairs(displays) do
            if d.hasAppMain then chosen = d; break end
        end
        if not chosen then
            for _, d in ipairs(displays) do
                if d.isMain then chosen = d; break end
            end
        end
        chosen = chosen or displays[1]
        if chosen and tonumber(chosen.width) and tonumber(chosen.height) then
            screenW, screenH = chosen.width, chosen.height
        end
    end

    if not (screenW and screenH) then
        local ok2, w, h = Debug.pcall(function() return LrSystemInfo.appWindowSize() end)
        if ok2 and tonumber(w) and tonumber(h) then
            screenW, screenH = w, h
        end
    end

    return screenW, screenH
end

-- Effective photo-box sizes for the current run. These drive how large the compare
-- window opens (catalog_photo can't auto-resize, and the dialog sizes itself to its
-- contents). Seeded from the saved manual prefs and optionally replaced by the
-- screen-derived auto-fit sizes -- WITHOUT writing back to prefs, so the user's saved
-- manual Window Width/Height survive an auto-fit run.
local effPhotoWidth  = prefs.photoWidth
local effPhotoHeight = prefs.photoHeight

-- When auto-fit is enabled, derive the photo-box sizes from the host screen so the
-- photos fill (most of) it. Uses the same window->photo formula as the Settings
-- dialog, but keeps the result in locals instead of clobbering the persisted prefs.
local applyAutoSize = Debug.showErrors(function()
    -- Default to the user's saved manual sizes.
    effPhotoWidth  = prefs.photoWidth
    effPhotoHeight = prefs.photoHeight

    if not prefs.autoSizeToScreen then return end

    local screenW, screenH = getHostScreenSize()
    if not (screenW and screenH) then return end  -- keep the manual sizes on failure

    local windowW = math.floor(screenW * 0.92)
    local windowH = math.floor(screenH * 0.88)
    effPhotoWidth  = math.max(300, math.floor((windowW - 40) / 2))
    effPhotoHeight = math.max(300, math.floor(windowH - 120))
end)

local photos = {}
local photosById = {}  -- localIdentifier -> LrPhoto, built once per session for O(1) lookups
local originalSelection = nil  -- selection to restore after we hijack it for the 2nd display
local secondaryShowing = nil   -- 'left' / 'right': which photo is currently pushed to the 2nd display
local comparisons = {}
local totalComparisons = 0
local currentComparison = 0
local rejectedImages = {}
local ratings = {}

local completedComparisonCount = 0
local remainingComparisonCount = 0

local undoStack = {}  -- Stack to store previous states
local decisions = {}  -- Ordered history of {winner, loser} choices, used to recompute ratings

local isRejected = Debug.showErrors(function(photo)
    return rejectedImages[photo.localIdentifier] == true
end)

-- Push one photo of the current pair to Lightroom's secondary display (a separate
-- window even when there's only one monitor). The normal loupe shows the catalog's
-- active photo, so we select the photo first, then make sure the loupe is showing.
-- Wrapped in pcall + an async task so it never disturbs the rating flow if the
-- secondary display is unavailable or blocked.
local sendToSecondaryDisplay = Debug.showErrors(function(photo, side)
    -- Record the intended side synchronously so callers that decide the *next*
    -- side from secondaryShowing (e.g. toggleSide) see the up-to-date value even
    -- before the async repaint below has finished. Updating it only inside the
    -- async task caused rapid presses to read a stale side and fail to alternate.
    secondaryShowing = side
    LrTasks.startAsyncTask(Debug.showErrors(function()
        Debug.pcall(function()
            -- The compare window is a *floating* (non-modal) dialog, so Lightroom's
            -- main UI keeps running and the secondary normal loupe ("loupe") -- which
            -- shows the catalog's active photo -- repaints on its own as soon as we
            -- change the selection. (NOT "live_loupe": that's the secondary Loupe's
            -- "Live" mode, which follows the mouse hover and ignores the selection, so
            -- setSelectedPhotos had no effect on it.)
            catalog:setSelectedPhotos(photo, { photo })
            -- Make sure the secondary display is on and showing the normal loupe.
            -- getSecondaryViewName() returns nil when the display is off and the
            -- current view's name when on, so this turns it on / switches it to the
            -- loupe only when it isn't already there (never hides it).
            if LrApplicationView.getSecondaryViewName() ~= "loupe" then
                LrApplicationView.showSecondaryView("loupe")
            end
        end)
    end))
end)

-- Put the catalog selection back the way the user had it before we started
-- hijacking the active photo for the 2nd-display preview.
local restoreSelection = Debug.showErrors(function()
    if not originalSelection or #originalSelection == 0 then return end
    LrTasks.startAsyncTask(Debug.showErrors(function()
        Debug.pcall(function()
            catalog:setSelectedPhotos(originalSelection[1], originalSelection)
        end)
    end))
end)

local updateComparisonCounts = Debug.showErrors(function()
    -- Count comparisons still ahead of the one currently shown (exclude the current one).
    remainingComparisonCount = 0
    for i = currentComparison + 1, totalComparisons do
        local pair = comparisons[i]
        if pair and not (isRejected(pair[1]) or isRejected(pair[2])) then
            remainingComparisonCount = remainingComparisonCount + 1
        end
    end
end)

-- Recompute Elo ratings from scratch over the recorded decisions, skipping any
-- decision that involves a rejected photo. This prevents rejected images from
-- leaving "ghost" rating shifts on the surviving images.
local recomputeRatings = Debug.showErrors(function()
    local result = {}
    for _, photo in ipairs(photos) do
        if not isRejected(photo) then
            result[photo.localIdentifier] = 1500
        end
    end
    for _, decision in ipairs(decisions) do
        if result[decision.winner] and result[decision.loser] then
            result[decision.winner], result[decision.loser] =
                calculateElo(result[decision.winner], result[decision.loser], 32)
        end
    end
    return result
end)

local applyRatingsToPhotos = Debug.showErrors(function(allImages)
    local catalog = import 'LrApplication'.activeCatalog()

    Debug.callWithContext("Apply Ratings Context", Debug.showErrors(function(context)
        -- Progress UI so a large batch doesn't look like a frozen Lightroom.
        local progress = LrProgressScope {
            title = "Applying ratings and reject flags",
            functionContext = context,
        }
        progress:setCancelable(false)
        local total = #allImages

        local success, err = Debug.pcall(Debug.showErrors(function()
            catalog:withWriteAccessDo("Apply Ratings", Debug.showErrors(function()
                for i, data in ipairs(allImages) do
                    -- O(1) lookup instead of scanning all photos for every image.
                    local photo = photosById[data.id]
                    if photo then
                        if data.rating == "Rejected" then
                            photo:setRawMetadata('rating', nil)  -- Clear any existing rating
                            photo:setRawMetadata('pickStatus', -1)  -- Set as rejected
                        else
                            photo:setRawMetadata('pickStatus', 0)  -- Clear rejected status
                            photo:setRawMetadata('rating', data.rating) --Set the rating
                        end
                    end
                    progress:setPortionComplete(i, total)
                    LrTasks.yield()  -- let the progress bar repaint
                end
            end))
        end))

        progress:done()

        if success then
            LrDialogs.showBezel("Ratings and reject flags applied successfully")
        else
            LrDialogs.message("Failed to apply ratings", err or "Unknown error")
        end
    end))
end)

local showNextComparison

local pushUndoState = Debug.showErrors(function(leftPhoto, rightPhoto, action)
    table.insert(undoStack, {
        currentComparison = currentComparison,
        completedComparisonCount = completedComparisonCount,
        leftPhoto = leftPhoto,
        rightPhoto = rightPhoto,
        leftRating = ratings[leftPhoto.localIdentifier],
        rightRating = ratings[rightPhoto.localIdentifier],
        leftRejected = rejectedImages[leftPhoto.localIdentifier],
        rightRejected = rejectedImages[rightPhoto.localIdentifier],
        action = action
    })
end)

-- Roll state back by one decision. The comparison loop drives re-presentation, so
-- this only adjusts state: it lands currentComparison one *before* the comparison to
-- re-show, and the loop's own +1 brings it back to that comparison.
local applyUndo = Debug.showErrors(function()
    if #undoStack == 0 then
        LrDialogs.showBezel("Nothing to undo")
        -- Nothing to roll back; re-show the current comparison by cancelling the
        -- loop's upcoming +1.
        currentComparison = currentComparison - 1
        completedComparisonCount = completedComparisonCount - 1
        return
    end

    local lastState = table.remove(undoStack)
    currentComparison = lastState.currentComparison - 1 -- Go back one comparison
    -- Roll back the counter so the re-shown comparison keeps its original number
    -- (the loop will increment it again when it re-renders).
    completedComparisonCount = lastState.completedComparisonCount - 1

    -- Restore previous ratings and reject states
    if lastState.action == "rating" then
        ratings[lastState.leftPhoto.localIdentifier] = lastState.leftRating
        ratings[lastState.rightPhoto.localIdentifier] = lastState.rightRating
        table.remove(decisions)  -- Discard the decision recorded for this comparison
    elseif lastState.action == "reject" then
        rejectedImages[lastState.leftPhoto.localIdentifier] = lastState.leftRejected
        rejectedImages[lastState.rightPhoto.localIdentifier] = lastState.rightRejected
    end

    -- Update counts; the loop re-shows the comparison.
    updateComparisonCounts()
    LrDialogs.showBezel("Undid last action")
end)

local startComparison = Debug.showErrors(function()
    -- Start comparison immediately with default or saved settings
    photos = catalog:getTargetPhotos()
    if #photos < 2 then
        LrDialogs.message("Select at least two images to compare.")
        return
    end

    -- Index photos by id once so apply/results don't rescan the list per image.
    photosById = {}
    for _, photo in ipairs(photos) do
        photosById[photo.localIdentifier] = photo
    end

    -- Remember the user's selection so we can restore it after using the active
    -- photo to drive the 2nd-display preview.
    originalSelection = photos
    secondaryShowing = nil

    -- Size the compare window/photos to fill the screen (if auto-fit is enabled).
    applyAutoSize()

    -- Initialize ratings
    ratings = {}
    for _, photo in ipairs(photos) do
        ratings[photo.localIdentifier] = 1500
    end

    -- Clear rejected images and decision history
    rejectedImages = {}
    decisions = {}
    undoStack = {}

    -- Initialize comparisons
    comparisons = {}
    for i = 1, #photos - 1 do
        for j = i + 1, #photos do
            table.insert(comparisons, {photos[i], photos[j]})
        end
    end

    totalComparisons = #comparisons
    currentComparison = 0
    completedComparisonCount = 0
    updateComparisonCounts()

    local f = LrView.osFactory()

    -- Present one comparison as a *floating* (non-modal) dialog and block this task
    -- until the user chooses. Floating (not modal) is what makes the 2nd display
    -- update reliably -- Lightroom's main UI keeps running, so changing the selection
    -- repaints the secondary loupe on its own. Returns 'next' (a rating/reject was
    -- made), 'undo', or 'cancel' (the user closed the window).
    local presentOneComparison = Debug.showErrors(function(leftPhoto, rightPhoto)
        local outcome = 'cancel'  -- default if the window is closed (Esc / close box)
        local closeDialog

        LrFunctionContext.callWithContext("compareDialog", Debug.showErrors(function(dialogContext)
                local props = LrBinding.makePropertyTable(dialogContext)

                -- Reflect the current side in the side button's label.
                local setSideLabel = function(side)
                    props.sideLabel = (side == 'right') and "Showing: Right" or "Showing: Left"
                end

                -- Seed the two button labels from the live 2nd-display state.
                local displayOn = false
                Debug.pcall(function() displayOn = LrApplicationView.isSecondaryDisplayOn() end)
                props.powerLabel = displayOn and "2nd Display: On" or "2nd Display: Off"
                setSideLabel(secondaryShowing or 'left')

                -- If the 2nd display is already on from the previous comparison,
                -- refresh it to this pair's left photo so it isn't showing a stale one.
                if displayOn then
                    sendToSecondaryDisplay(leftPhoto, 'left')
                    setSideLabel('left')
                end

                -- Dismiss the floating dialog, recording why it closed so the
                -- comparison loop knows what to do next.
                local finish = function(reason)
                    outcome = reason
                    if closeDialog then closeDialog() end
                end

                -- Power button: turn the 2nd-display loupe on or off.
                local togglePower = Debug.showErrors(function()
                    LrTasks.startAsyncTask(Debug.showErrors(function()
                        Debug.pcall(function()
                            if LrApplicationView.isSecondaryDisplayOn() then
                                -- Re-showing the current view toggles the display off.
                                LrApplicationView.showSecondaryView(
                                    LrApplicationView.getSecondaryViewName() or "loupe")
                                secondaryShowing = nil  -- nothing is shown while off
                                props.powerLabel = "2nd Display: Off"
                            else
                                local side = secondaryShowing or 'left'
                                local photo = (side == 'right') and rightPhoto or leftPhoto
                                catalog:setSelectedPhotos(photo, { photo })
                                LrApplicationView.showSecondaryView("loupe")
                                secondaryShowing = side
                                props.powerLabel = "2nd Display: On"
                                setSideLabel(side)
                            end
                        end)
                    end))
                end)

                -- Side button: switch which photo of the pair is shown (turns the
                -- display on if it happens to be off).
                local toggleSide = Debug.showErrors(function()
                    -- Default to 'right' when nothing is shown yet (nil), since the
                    -- label seeds to "Left"; only flip back to 'left' when already 'right'.
                    local newSide = (secondaryShowing == 'right') and 'left' or 'right'
                    sendToSecondaryDisplay(newSide == 'right' and rightPhoto or leftPhoto, newSide)
                    setSideLabel(newSide)
                    props.powerLabel = "2nd Display: On"
                end)

                local c
                -- scrolled_view is one of the only containers that accepts a
                -- background_color, so it's used here purely to tint the popup's
                -- content area. Sized to the window so the content fits without
                -- scrollbars and the color fills the whole area.
                c = f:scrolled_view {
                    fill_horizontal = 1,
                    fill_vertical = 1,
                    bind_to_object = props,
                    -- Size the viewport a bit larger than the photo content (two
                    -- photo boxes + margins/buttons) so it fully contains it and
                    -- never shows scrollbars, while the color fills the whole area.
                    width = (effPhotoWidth * 2) + 100,
                    height = effPhotoHeight + 180,
                    background_color = LrColor(0.2, 0.2, 0.2),
                    f:column {
                        spacing = f:control_spacing(),
                        fill_horizontal = 1,
                        fill_vertical = 1,
                        margin_horizontal = 10,
                        margin_vertical = 10,
                        f:row {
                            spacing = f:control_spacing(),
                            fill_horizontal = 1,
                            fill_vertical = 1,
                            margin_horizontal = 10,
                            f:view {
                                fill_horizontal = 1,
                                fill_vertical = 1,
                                margin = 5,
                                f:catalog_photo {
                                    photo = leftPhoto,
                                    fill_horizontal = 1,
                                    fill_vertical = 1,
                                    margin = 5,
                                    width = effPhotoWidth,
                                    height = effPhotoHeight,
                                    selection_behavior = "preferences",
                                    background_color = LrColor(0.2, 0.2, 0.2),
                                    -- Click a photo to push it to the 2nd display.
                                    mouse_down = Debug.showErrors(function()
                                        sendToSecondaryDisplay(leftPhoto, 'left')
                                        setSideLabel('left')
                                        props.powerLabel = "2nd Display: On"
                                    end),
                                },
                            },
                            f:view {
                                fill_horizontal = 1,
                                fill_vertical = 1,
                                margin = 5,
                                f:catalog_photo {
                                    photo = rightPhoto,
                                    fill_horizontal = 1,
                                    fill_vertical = 1,
                                    margin = 5,
                                    width = effPhotoWidth,
                                    height = effPhotoHeight,
                                    selection_behavior = "preferences",
                                    background_color = LrColor(0.2, 0.2, 0.2),
                                    mouse_down = Debug.showErrors(function()
                                        sendToSecondaryDisplay(rightPhoto, 'right')
                                        setSideLabel('right')
                                        props.powerLabel = "2nd Display: On"
                                    end),
                                },
                            },
                        },
                        f:row {
                            spacing = f:control_spacing(),
                            f:spacer { fill_horizontal = 1 },
                            f:push_button {
                                title = "Left is Better",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "rating")
                                    LrDialogs.showBezel("Left is Better")
                                    local winner, loser = leftPhoto.localIdentifier, rightPhoto.localIdentifier
                                    ratings[winner], ratings[loser] = calculateElo(ratings[winner], ratings[loser], 32)
                                    table.insert(decisions, {winner = winner, loser = loser})
                                    finish('next')
                                end)
                            },
                            f:push_button {
                                title = "Reject Left",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "reject")
                                    rejectedImages[leftPhoto.localIdentifier] = true
                                    LrDialogs.showBezel("Reject Left")
                                    updateComparisonCounts()
                                    finish('next')
                                end)
                            },
                            f:push_button {
                                title = "Undo",
                                action = Debug.showErrors(function()
                                    finish('undo')
                                end)
                            },
                            f:push_button {
                                title = "Reject Right",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "reject")
                                    rejectedImages[rightPhoto.localIdentifier] = true
                                    LrDialogs.showBezel("Reject Right")
                                    updateComparisonCounts()
                                    finish('next')
                                end)
                            },
                            f:push_button {
                                title = "Right is Better",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "rating")
                                    LrDialogs.showBezel("Right is Better")
                                    local winner, loser = rightPhoto.localIdentifier, leftPhoto.localIdentifier
                                    ratings[winner], ratings[loser] = calculateElo(ratings[winner], ratings[loser], 32)
                                    table.insert(decisions, {winner = winner, loser = loser})
                                    finish('next')
                                end)
                            },
                            f:spacer { fill_horizontal = 1 },
                        },
                        f:row {
                            spacing = f:control_spacing(),
                            fill_horizontal = 1,
                            f:spacer { fill_horizontal = 1 },
                            f:push_button {
                                -- Turn the 2nd display on/off.
                                title = LrView.bind("powerLabel"),
                                width = 150,
                                action = togglePower,
                            },
                            f:push_button {
                                -- Switch which photo of the pair the 2nd display shows.
                                title = LrView.bind("sideLabel"),
                                width = 140,
                                action = toggleSide,
                            },
                            f:spacer { fill_horizontal = 1 },
                        },
                        f:row {
                            fill_horizontal = 1,
                            margins = { top = 10 },
                            f:spacer { fill_horizontal = 1 },
                            f:static_text {
                                title = string.format("Comparison %d - Remaining: %d", completedComparisonCount, remainingComparisonCount),
                                alignment = 'center',
                                font = { name = "<system/bold>", size = 18 },  -- bold + larger than the button text
                                text_color = LrColor(1, 1, 1),  -- white, readable on the dark popup
                                width = 500, -- fixed width for centering (wider for larger text)
                            },
                            f:spacer { fill_horizontal = 1 },
                        },
                    }
                }

                LrDialogs.presentFloatingDialog(_PLUGIN, {
                    title = "LR Image Rater - Compare",
                    contents = c,
                    blockTask = true,  -- block this task until the dialog closes
                    save_frame = "compareWindowPosition",
                    onShow = Debug.showErrors(function(funcs) closeDialog = funcs.close end),
                })
        end))

        return outcome
    end)

    -- Drive the whole comparison sequence in a single task: present each pairing,
    -- act on the result, and stop only on completion or when the user closes the
    -- window. The floating dialog blocks this task while open, so there's no
    -- per-button recursion to juggle.
    showNextComparison = Debug.showErrors(function()
        while true do
            currentComparison = currentComparison + 1
            if currentComparison > totalComparisons then break end

            local pair = comparisons[currentComparison]
            local leftPhoto, rightPhoto = pair[1], pair[2]

            if not isRejected(leftPhoto) and not isRejected(rightPhoto) then
                completedComparisonCount = completedComparisonCount + 1
                updateComparisonCounts()

                local outcome = presentOneComparison(leftPhoto, rightPhoto)
                if outcome == 'cancel' then
                    restoreSelection()  -- put the user's selection back before leaving
                    LrDialogs.showBezel("Rating cancelled")
                    return
                elseif outcome == 'undo' then
                    applyUndo()  -- rolls currentComparison and counts back one
                end
            end
        end

        -- All comparisons done: restore the user's original selection that we
        -- borrowed to drive the 2nd-display preview.
        restoreSelection()

        -- Authoritative final ratings: recompute from the decision history so that
        -- any photos rejected mid-session leave no residual effect on the survivors.
        ratings = recomputeRatings()

        local sortedRatings = {}
        for id, rating in pairs(ratings) do
            if not rejectedImages[id] then
                table.insert(sortedRatings, {id = id, rating = rating})
            end
        end
        table.sort(sortedRatings, function(a, b) return a.rating > b.rating end)

        local resultText = "Final Ratings:\n"
        
        -- Create a table for all images (including rejected ones)
        local allImages = {}
        
        -- Add rejected images
        for id, _ in pairs(rejectedImages) do
            table.insert(allImages, {id = id, rating = "Rejected"})
        end
        
        -- Add rated images
        for i, data in ipairs(sortedRatings) do
            local lrRating
            if #sortedRatings == 1 then
                lrRating = 3  -- If only one image, give it 3 stars
            else
                if i == 1 then
                    lrRating = 5  -- Top image always gets 5 stars
                elseif i == #sortedRatings then
                    lrRating = 1  -- Bottom image always gets 1 star
                else
                    -- For middle images, distribute more evenly
                    local position = i - 1  -- Position among middle images (excluding top)
                    local totalMiddle = #sortedRatings - 2  -- Number of middle images
                    if totalMiddle == 1 then
                        lrRating = 3  -- If only one middle image, give it 3 stars
                    elseif totalMiddle == 2 then
                        lrRating = position == 1 and 4 or 2  -- Two middle images: 4, 2
                    else
                        -- For 3 or more middle images
                        local segment = totalMiddle / 3  -- Split into three segments
                        if position <= segment then
                            lrRating = 4
                        elseif position <= segment * 2 then
                            lrRating = 3
                        else
                            lrRating = 2
                        end
                    end
                end
            end
            table.insert(allImages, {id = data.id, rating = lrRating})
        end
        
        -- Fetch all filenames in a single batch call instead of one catalog
        -- round-trip per image (and avoid the old O(n^2) inner scan over photos).
        local fileNameByPhoto = catalog:batchGetFormattedMetadata(photos, { 'fileName' })

        -- Create the final results text
        for _, data in ipairs(allImages) do
            local photo = photosById[data.id]
            local meta = photo and fileNameByPhoto[photo]
            local filename = meta and meta.fileName or "Unknown"
            resultText = resultText .. string.format("Filename: %s, Image ID: %s, Rating: %s\n",
                filename, data.id, data.rating)
        end

        LrTasks.startAsyncTask(Debug.showErrors(function()
            local f = LrView.osFactory()
            local resultsDialog 
            resultsDialog = f:column {
                spacing = f:control_spacing(),
                width = 600,
                height = 400,
                f:static_text {
                    title = "Comparison Complete!",
                    font = "<system/bold>",
                    alignment = 'center',
                },
                f:edit_field {
                    width = 580,
                    height = 300,
                    wrap = true,
                    multiline = true,
                    value = resultText,
                    enabled = true,
                    read_only = true,
                }
            }

            local result = LrDialogs.presentModalDialog {
                title = "LR Image Rater - Results",
                contents = resultsDialog,
                resizable = true,
                actionVerb = "Apply Ratings",
                cancelVerb = "Cancel"
            }

            if result == "ok" then
                applyRatingsToPhotos(allImages)
            end
        end))
    end)

    LrTasks.startAsyncTask(Debug.showErrors(showNextComparison))
end)

return Debug.callWithContext("showDialog",
    Debug.showErrors(function(context)
        LrTasks.startAsyncTask(Debug.showErrors(startComparison))
    end))