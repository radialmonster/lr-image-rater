local Require = require 'Require'.path ("/common").reload ()
local Debug = require 'Debug'.init ()
require 'strict.lua'

-- LRImageRater.lua
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local catalog = import 'LrApplication'.activeCatalog()

-- Initialize preferences with default values
local prefs = LrPrefs.prefsForPlugin()
if not prefs.windowWidth then prefs.windowWidth = 1600 end
if not prefs.windowHeight then prefs.windowHeight = 1000 end
if not prefs.photoWidth then prefs.photoWidth = 780 end
if not prefs.photoHeight then prefs.photoHeight = 880 end

local calculateElo = Debug.showErrors(function(winnerRating, loserRating, k)
    local expectedWin = 1 / (1 + 10 ^ ((loserRating - winnerRating) / 400))
    winnerRating = winnerRating + k * (1 - expectedWin)
    loserRating = loserRating + k * (0 - expectedWin)
    return winnerRating, loserRating
end)

local photos = {}
local comparisons = {}
local totalComparisons = 0
local currentComparison = 0
local rejectedImages = {}
local ratings = {}

local validComparisonCount = 0
local completedComparisonCount = 0
local remainingComparisonCount = 0

local undoStack = {}  -- Stack to store previous states

local isRejected = Debug.showErrors(function(photo)
    return rejectedImages[photo.localIdentifier] == true
end)

local recalculateComparisons = Debug.showErrors(function()
    local activePhotos = {}
    for _, photo in ipairs(photos) do
        if not isRejected(photo) then
            table.insert(activePhotos, photo)
        end
    end

    comparisons = {}
    for i = 1, #activePhotos - 1 do
        for j = i + 1, #activePhotos do
            table.insert(comparisons, {activePhotos[i], activePhotos[j]})
        end
    end

    totalComparisons = #comparisons
    currentComparison = 0
end)

local updateComparisonCounts = Debug.showErrors(function()
    remainingComparisonCount = 0
    for i = currentComparison, totalComparisons do
        local pair = comparisons[i]
        if pair and not (isRejected(pair[1]) or isRejected(pair[2])) then
            remainingComparisonCount = remainingComparisonCount + 1
        end
    end
end)

local applyRatingsToPhotos = Debug.showErrors(function(allImages)
    local catalog = import 'LrApplication'.activeCatalog()
    
    Debug.callWithContext("Apply Ratings Context", Debug.showErrors(function(context)
        local success, err = Debug.pcall(Debug.showErrors(function()
            catalog:withWriteAccessDo("Apply Ratings", Debug.showErrors(function()
                for _, data in ipairs(allImages) do
                    for _, photo in ipairs(photos) do
                        if photo.localIdentifier == data.id then
                            if data.rating == "Rejected" then
                                photo:setRawMetadata('rating', nil)  -- Clear any existing rating
                                photo:setRawMetadata('pickStatus', -1)  -- Set as rejected
                            else
                                photo:setRawMetadata('pickStatus', 0)  -- Clear rejected status
                                photo:setRawMetadata('rating', data.rating) --Set the rating
                            end
                            break
                        end
                    end
                end
            end))
        end))
        
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
        leftPhoto = leftPhoto,
        rightPhoto = rightPhoto,
        leftRating = ratings[leftPhoto.localIdentifier],
        rightRating = ratings[rightPhoto.localIdentifier],
        leftRejected = rejectedImages[leftPhoto.localIdentifier],
        rightRejected = rejectedImages[rightPhoto.localIdentifier],
        action = action
    })
end)

local undoLastAction = Debug.showErrors(function()
    if #undoStack == 0 then
        LrDialogs.showBezel("Nothing to undo")
        return
    end

    local lastState = table.remove(undoStack)
    currentComparison = lastState.currentComparison - 1 -- Go back one comparison
    
    -- Restore previous ratings and reject states
    if lastState.action == "rating" then
        ratings[lastState.leftPhoto.localIdentifier] = lastState.leftRating
        ratings[lastState.rightPhoto.localIdentifier] = lastState.rightRating
    elseif lastState.action == "reject" then
        rejectedImages[lastState.leftPhoto.localIdentifier] = lastState.leftRejected
        rejectedImages[lastState.rightPhoto.localIdentifier] = lastState.rightRejected
    end
    
    -- Update counts and reshow the comparison
    updateComparisonCounts()
    LrDialogs.showBezel("Undid last action")
    showNextComparison()
end)

local startComparison = Debug.showErrors(function()
    -- Start comparison immediately with default or saved settings
    photos = catalog:getTargetPhotos()
    if #photos < 2 then
        LrDialogs.message("Select at least two images to compare.")
        return
    end

    -- Initialize ratings
    ratings = {}
    for _, photo in ipairs(photos) do
        ratings[photo.localIdentifier] = 1500
    end

    -- Clear rejected images
    rejectedImages = {}

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

    local remainingSkippedComparisons = Debug.showErrors(function()
        local skipped = 0
        for i = 1, totalComparisons do
            local pair = comparisons[i]
            if pair and (isRejected(pair[1]) or isRejected(pair[2])) then
                skipped = skipped + 1
            end
        end
        return skipped
    end)

    -- Initialize showNextComparison functionality
    showNextComparison = Debug.showErrors(function()
        currentComparison = currentComparison + 1

        while currentComparison <= totalComparisons do
            local pair = comparisons[currentComparison]
            local leftPhoto, rightPhoto = pair[1], pair[2]

            if not isRejected(leftPhoto) and not isRejected(rightPhoto) then
                completedComparisonCount = completedComparisonCount + 1
                updateComparisonCounts()
                
                local c
                c = f:view {
                    fill_horizontal = 1,
                    fill_vertical = 1,
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
                                    LrDialogs.stopModalWithResult(c, 'ok')
                                    LrTasks.startAsyncTask(Debug.showErrors(showNextComparison))
                                end)
                            },
                            f:push_button {
                                title = "Reject Left",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "reject")
                                    rejectedImages[leftPhoto.localIdentifier] = true
                                    LrDialogs.showBezel("Reject Left")
                                    updateComparisonCounts()
                                    
                                    LrDialogs.stopModalWithResult(c, 'ok')
                                    LrTasks.startAsyncTask(Debug.showErrors(showNextComparison))
                                end)
                            },
                            f:push_button {
                                title = "Undo",
                                action = Debug.showErrors(function()
                                    LrDialogs.stopModalWithResult(c, 'ok')
                                    undoLastAction()
                                end)
                            },
                            f:push_button {
                                title = "Reject Right",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "reject")
                                    rejectedImages[rightPhoto.localIdentifier] = true
                                    LrDialogs.showBezel("Reject Right")
                                    updateComparisonCounts()
                                    
                                    LrDialogs.stopModalWithResult(c, 'ok')
                                    LrTasks.startAsyncTask(Debug.showErrors(showNextComparison))
                                end)
                            },
                            f:push_button {
                                title = "Right is Better",
                                action = Debug.showErrors(function()
                                    pushUndoState(leftPhoto, rightPhoto, "rating")
                                    LrDialogs.showBezel("Right is Better")
                                    local winner, loser = rightPhoto.localIdentifier, leftPhoto.localIdentifier
                                    ratings[winner], ratings[loser] = calculateElo(ratings[winner], ratings[loser], 32)
                                    LrDialogs.stopModalWithResult(c, 'ok')
                                    LrTasks.startAsyncTask(Debug.showErrors(showNextComparison))
                                end)
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
                                width = 400, -- Set fixed width for better centering
                            },
                            f:spacer { fill_horizontal = 1 },
                        },
                    }
                }

                LrDialogs.presentModalDialog {
                    title = "LR Image Rater - Compare",
                    contents = c,
                    resizable = true,
                    width = prefs.windowWidth,
                    height = prefs.windowHeight
                }

                return
            end

            currentComparison = currentComparison + 1
        end

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
        
        -- Sort all images by ID (smallest to largest)

        -- Create the final results text
        for _, data in ipairs(allImages) do
            local filename = nil
            for _, photo in ipairs(photos) do
                if photo.localIdentifier == data.id then
                    filename = photo:getFormattedMetadata('fileName')
                    break
                end
            end
            resultText = resultText .. string.format("Filename: %s, Image ID: %s, Rating: %s\n", 
                filename or "Unknown", data.id, data.rating)
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