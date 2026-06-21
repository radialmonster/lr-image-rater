--[[----------------------------------------------------------------------------

Info.lua
Basic information for the LR Image Rater plugin

------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 15.0,
	LrSdkMinimumVersion = 6.0,  -- 6.0 = first version with LrApplicationView.showSecondaryView (used for the 2nd-display preview)
	LrToolkitIdentifier = 'com.radialmonster.lightroom.lrimagerater',
	
	LrPluginName = "LR Image Rater",
	LrPluginInfoUrl = "https://github.com/radialmonster/lr-image-rater",
	
	-- Add the entry for the Plug-in Manager Dialog
	LrPluginInfoProvider = 'PluginInfoProvider.lua',
	
	-- Add the menu items to the Library menu
	LrLibraryMenuItems = {
		{
			title = "Rate Images",
			file = 'LRImageRater.lua',
			enabledWhen = 'photosSelected',
		},
		{
			title = "Settings",
			file = 'Settings.lua',
		},
	},
	
	VERSION = { major=1, minor=1, revision=0, build="20260621a" },
}
