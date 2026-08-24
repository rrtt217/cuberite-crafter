-- Implements the g_PluginInfo standard plugin description
g_PluginInfo =
{
	Name = "Crafter",
	Version = "0.3",
	Date = "2026-08-24",
	Description = [[以投掷器为原型实现的合成器：3x3 合成格 + 可禁用槽位、
红石触发自动合成输出，支持漏斗规则、容器直存与掉落物。]],
	Commands =
	{
		["/crafter"] = { Permission = "crafter.get",
			HelpString = "获取一个合成器（可选自定义名称）；" ..
				"管理子命令需权限 crafter.admin" },
	},
	ConsoleCommands =
	{
		["crafter"] = { HelpString = "合成器管理：place/set/toggle/pulse/craft/info/list/del",
			Handler = HandleCrafterConsole, ParameterCombinations = {} },
	},
	Permissions =
	{
		["crafter.get"] = {
			Description = "允许使用 /crafter 命令获取合成器",
			RecommendedGroups = { "Default", "Moderator", "Operator" },
		},
		["crafter.admin"] = {
			Description = "允许在游戏内使用 /crafter 管理子命令",
			RecommendedGroups = { "Operator", "Admin" },
		},
	},
}
