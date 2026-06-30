// AcroOrbitOverlay.h — a full-screen UMG overlay that draws celestial-body and
// vessel orbit lines in SCREEN space at a constant pixel width, with analytic
// ray-vs-sphere occlusion behind bodies.
//
// Why screen-space: world-space debug lines have a thickness in cm, so they
// foreshorten with distance (far orbits go hairline, near ones bloat). Projecting
// each orbit point to the viewport and drawing 2D lines gives a fixed pixel width
// at any zoom. Occlusion is computed analytically against the sim's spheres
// (exact — bodies are smooth spheres) rather than read back from the depth buffer.
//
// ASpaceSimRenderer creates + configures this and pushes its WorldScale / colors /
// toggles each frame; the overlay pulls the live frame data from USpaceSimSubsystem.
#pragma once

#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "AcroOrbitOverlay.generated.h"

UCLASS()
class ACROSIMBRIDGE_API UAcroOrbitOverlay : public UUserWidget
{
	GENERATED_BODY()

public:
	// Pushed by ASpaceSimRenderer (kept in sync with its detail-panel knobs).
	UPROPERTY() float WorldScale = 1.f;
	UPROPERTY() float OrbitWidthPx = 2.f;
	UPROPERTY() bool bDrawVesselOrbits = true;
	UPROPERTY() bool bDrawBodyOrbits = true;
	UPROPERTY() bool bOccludeBehindBodies = true;
	UPROPERTY() FLinearColor VesselOrbitColor = FLinearColor(0.f, 1.f, 1.f, 1.f);
	UPROPERTY() FLinearColor BodyOrbitColor = FLinearColor(1.f, 1.f, 0.f, 1.f);

protected:
	virtual int32 NativePaint(const FPaintArgs& Args, const FGeometry& AllottedGeometry,
		const FSlateRect& MyCullingRect, FSlateWindowElementList& OutDrawElements,
		int32 LayerId, const FWidgetStyle& InWidgetStyle, bool bParentEnabled) const override;
};
