using UnrealBuildTool;
using System.IO;

public class AcroSimBridge : ModuleRules
{
	public AcroSimBridge(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
		CppStandard = CppStandardVersion.Cpp20; // UE 5.8 dropped C++17

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"Sockets",
			"Networking",
		});

		// FlatBuffers: the generated contract (Wire/) + the header-only runtime
		// vendored under ThirdParty/. Both are include-only; nothing to link.
		PublicIncludePaths.Add(Path.Combine(ModuleDirectory, "..", "..", "Wire"));
		PublicIncludePaths.Add(Path.Combine(ModuleDirectory, "..", "..", "ThirdParty", "flatbuffers", "include"));

		// FlatBuffers compiles fine without exceptions/RTTI under UE's defaults.
		// If a future schema feature needs them, flip these on:
		// bEnableExceptions = true;
	}
}
