#include "AcroOrbitOverlay.h"

#include "SpaceSimSubsystem.h"
#include "Blueprint/WidgetLayoutLibrary.h"
#include "Camera/PlayerCameraManager.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Rendering/DrawElements.h"

int32 UAcroOrbitOverlay::NativePaint(const FPaintArgs& Args, const FGeometry& AllottedGeometry,
	const FSlateRect& MyCullingRect, FSlateWindowElementList& OutDrawElements,
	int32 LayerId, const FWidgetStyle& InWidgetStyle, bool bParentEnabled) const
{
	const int32 BaseLayer = Super::NativePaint(Args, AllottedGeometry, MyCullingRect,
		OutDrawElements, LayerId, InWidgetStyle, bParentEnabled);

	UWorld* World = GetWorld();
	APlayerController* PC = GetOwningPlayer();
	UGameInstance* GI = World ? World->GetGameInstance() : nullptr;
	USpaceSimSubsystem* Sim = GI ? GI->GetSubsystem<USpaceSimSubsystem>() : nullptr;
	if (!World || !PC || !Sim)
	{
		return BaseLayer;
	}

	// Slate works in DPI-scaled local units; ProjectWorldLocationToScreen returns
	// raw pixels — divide by the viewport scale so the line lands where it should.
	const float Dpi = UWidgetLayoutLibrary::GetViewportScale(World);
	const float SafeDpi = (Dpi > KINDA_SMALL_NUMBER) ? Dpi : 1.f;

	FVector CamPos = FVector::ZeroVector;
	if (APlayerCameraManager* Cam = PC->PlayerCameraManager)
	{
		CamPos = Cam->GetCameraLocation();
	}

	// One copy of each per paint (cheap; avoids re-copying per point).
	const TArray<FSimBody> Bodies = Sim->GetBodies();
	const float Scale = WorldScale;
	const bool bOcclude = bOccludeBehindBodies;
	const float WidthPx = OrbitWidthPx;

	// Is the camera->WorldPt ray blocked by a body sphere before reaching WorldPt?
	// Bodies are exact spheres (center = scaled Position, radius = scaled RadiusCm).
	// ExcludeId skips a body occluding its OWN ring (it sits on the ring at the
	// marker, which would otherwise nick a gap there).
	auto IsOccluded = [&](const FVector& WorldPt, const FString& ExcludeId) -> bool
	{
		const FVector D = WorldPt - CamPos;
		const double Len = D.Size();
		if (Len < 1.0) return false;
		const FVector Dir = D / Len;
		for (const FSimBody& B : Bodies)
		{
			if (B.Id == ExcludeId) continue;
			const double R = B.RadiusCm * Scale;
			if (R <= KINDA_SMALL_NUMBER) continue;
			const FVector C = B.Position * Scale;
			const FVector M = CamPos - C;
			const double BTerm = FVector::DotProduct(M, Dir);
			const double CTerm = FVector::DotProduct(M, M) - R * R;
			const double Disc = BTerm * BTerm - CTerm;
			if (Disc < 0.0) continue;
			const double Sq = FMath::Sqrt(Disc);
			// Either root strictly between the camera and the point hides it
			// (covers the rare camera-inside-sphere case via the far root).
			const double T0 = -BTerm - Sq;
			const double T1 = -BTerm + Sq;
			if ((T0 > 1.0 && T0 < Len - 1.0) || (T1 > 1.0 && T1 < Len - 1.0))
			{
				return true;
			}
		}
		return false;
	};

	const FPaintGeometry Geo = AllottedGeometry.ToPaintGeometry();

	// Project a world-space polyline and draw it, breaking the run wherever a point
	// is behind the camera or occluded by a body.
	auto EmitPolyline = [&](const TArray<FVector>& WorldPts, const FLinearColor& Color,
							const FString& ExcludeId)
	{
		if (WorldPts.Num() < 2) return;
		TArray<FVector2D> Run;
		Run.Reserve(WorldPts.Num());
		auto Flush = [&]()
		{
			if (Run.Num() >= 2)
			{
				FSlateDrawElement::MakeLines(OutDrawElements, LayerId, Geo, Run,
					ESlateDrawEffect::None, Color, /*bAntialias*/ true, WidthPx);
			}
			Run.Reset();
		};
		for (const FVector& Wp : WorldPts)
		{
			FVector2D Screen;
			const bool bOnScreen = PC->ProjectWorldLocationToScreen(Wp, Screen, false);
			const bool bVisible = bOnScreen && (!bOcclude || !IsOccluded(Wp, ExcludeId));
			if (!bVisible)
			{
				Flush(); // break the line here
				continue;
			}
			Run.Add(FVector2D(Screen.X / SafeDpi, Screen.Y / SafeDpi));
		}
		Flush();
	};

	if (bDrawBodyOrbits)
	{
		for (const FSimBody& B : Bodies)
		{
			if (B.Orbit.Num() < 2) continue;
			TArray<FVector> Pts;
			Pts.Reserve(B.Orbit.Num());
			for (const FVector& P : B.Orbit) Pts.Add(P * Scale);
			EmitPolyline(Pts, BodyOrbitColor, B.Id); // a body never occludes its own ring
		}
	}

	if (bDrawVesselOrbits)
	{
		const TArray<FSimVessel> Vessels = Sim->GetVessels();
		for (const FSimVessel& V : Vessels)
		{
			if (V.Trajectory.Num() < 2) continue;
			TArray<FVector> Pts;
			Pts.Reserve(V.Trajectory.Num());
			for (const FVector& P : V.Trajectory) Pts.Add(P * Scale);
			// No exclude: the dominant body SHOULD hide the far half of the orbit.
			EmitPolyline(Pts, VesselOrbitColor, FString());
		}
	}

	return FMath::Max(BaseLayer, LayerId);
}
