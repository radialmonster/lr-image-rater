--[[----------------------------------------------------------------------------

Info.lua
Basic information for the LR Image Rater plugin

------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 2.0,
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
	
	VERSION = { major=1, minor=0, revision=0, build="20230321a" },
}
