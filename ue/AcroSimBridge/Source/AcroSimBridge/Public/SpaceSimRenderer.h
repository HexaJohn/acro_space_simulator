// SpaceSimRenderer.h — turns the SpaceSimSubsystem stream into spawned, moving
// actors. Place one ASpaceSimRenderer in the level, point it at a Type->Mesh
// DataTable, and it renders bodies, craft (composed from parts) and colony
// buildings. You own only the DataTable; it owns actor/instance lifecycle.
#pragma once

#include "CoreMinimal.h"
#include "Engine/DataTable.h"
#include "GameFramework/Actor.h"
#include "SpaceSimRenderer.generated.h"

class USpaceSimSubsystem;
class UStaticMesh;
class UStaticMeshComponent;
class UHierarchicalInstancedStaticMeshComponent;
class UMaterialInterface;

/// One row of the asset table. Row name (FName) is the type-key the sim sends:
/// a craft part name, a building spec type, or a celestial body id.
USTRUCT(BlueprintType)
struct FAcroAssetRow : public FTableRowBase
{
	GENERATED_BODY()
	UPROPERTY(EditAnywhere, Category = "AcroSim") TSoftObjectPtr<UStaticMesh> Mesh;
	UPROPERTY(EditAnywhere, Category = "AcroSim") FVector Scale = FVector::OneVector;
	UPROPERTY(EditAnywhere, Category = "AcroSim") TSoftObjectPtr<UMaterialInterface> OverrideMaterial;
};

UCLASS()
class ACROSIMBRIDGE_API ASpaceSimRenderer : public AActor
{
	GENERATED_BODY()

public:
	ASpaceSimRenderer();

	virtual void BeginPlay() override;
	virtual void EndPlay(const EEndPlayReason::Type Reason) override;
	// Editor delete / map change does NOT reliably route EndPlay for an actor that
	// never had BeginPlay (editor world), so tear the editor preview down here too.
	virtual void Destroyed() override;

	// Tick even in the editor (no PIE) so the renderer can preview the live sim in
	// the level viewport. Enable the viewport's Realtime mode for a smooth update.
	virtual void Tick(float DeltaSeconds) override;
	virtual bool ShouldTickIfViewportsOnly() const override { return true; }

	// Type-key -> mesh. Row name = sim part name / building spec type / body id.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	UDataTable* AssetTable = nullptr;

	// Used when a type-key has no row (e.g. a debug cube so nothing is invisible).
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	TSoftObjectPtr<UStaticMesh> FallbackMesh;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bAutoConnect = true;
	// Preview the live sim in the EDITOR viewport (not just PIE). The renderer
	// owns its own connection in-editor; turn off to disable the editor preview.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bRunInEditor = true;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString Host = TEXT("127.0.0.1");
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	int32 Port = 5800;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString FocusBodyId = TEXT("earth");

	// Fallback only: the body mesh radius (cm) at scale 1 is normally read from
	// the mesh's own bounds, so the planet sizes correctly for ANY mesh. This is
	// used only if the mesh has no usable bounds.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	float BodyMeshUnitRadiusCm = 50.f;

	// Terrain reconciliation: raycast the landscape under each building and report
	// the height back so the sim agrees. OFF by default — needs your landscape +
	// collision channel set up.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bReportTerrain = false;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	TEnumAsByte<ECollisionChannel> TerrainTraceChannel = ECC_WorldStatic;

	// Draw each vessel's predicted orbit line (FSimVessel.Trajectory) as debug
	// lines. Quick "see it" visual; swap for a spline/ribbon mesh in production.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bDrawOrbits = true;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FColor OrbitColor = FColor::Cyan;
	// Orbit-line thickness (cm in the SCALED scene). Bump it up for visibility.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	float OrbitThickness = 8.f;

	// Draw each celestial body's orbit ring (FSimBody.Orbit) about its parent —
	// the planet/moon "rails" of the whole system. Distinct color from craft orbits.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bDrawBodyOrbits = true;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FColor BodyOrbitColor = FColor::Yellow;

	// Uniform render scale on all positions + sizes. The sim is 1:1 (a 600 km
	// body is a 600,000 m sphere), which is unwieldy in-editor — set e.g. 0.001
	// to shrink the whole scene to a navigable size. 1 = true scale.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	float WorldScale = 1.0f;

private:
	UFUNCTION()
	void HandleWorldUpdated();

	void UpdateBodies(USpaceSimSubsystem* Sim);
	void UpdateVessels(USpaceSimSubsystem* Sim);
	void UpdateBuildings(USpaceSimSubsystem* Sim);

	UStaticMesh* MeshFor(const FString& Key, FVector& OutScale, UMaterialInterface*& OutMaterial) const;
	AActor* SpawnVesselActor();

	// Destroy every spawned body/vessel actor + tracking state. Runtime worlds tear
	// these down automatically, but an editor-spawned renderer must clean up its
	// own transient preview actors when it stops.
	void DestroySpawnedActors();

	// Idempotent editor-preview shutdown: unbind + disconnect + drop EditorSim and
	// destroy the spawned preview actors. Safe to call repeatedly / at runtime.
	void TeardownEditorPreview();

	UPROPERTY() TMap<FString, AActor*> BodyActors;   // body id -> actor (scale-1 root)
	UPROPERTY() TMap<FString, AActor*> VesselActors; // vessel id -> actor
	UPROPERTY() TMap<FString, UStaticMeshComponent*> PartComps; // "vesselId/partId" -> comp
	UPROPERTY() TMap<FString, UHierarchicalInstancedStaticMeshComponent*> BuildingHisms; // "bodyId|type" -> HISM

	TMap<FString, float> BodyRadiiCm;       // body id -> radius (cm), for terrain baseline
	TMap<FString, FVector> BuildingTypeScale; // building type -> asset table scale
	// "colony/id" -> (hism key, instance index). Re-added if a body respawns.
	TMap<FString, TPair<FString, int32>> BuildingInstances;

	TWeakObjectPtr<USpaceSimSubsystem> SimRef;

	// EDITOR ONLY: there is no GameInstance (and thus no USpaceSimSubsystem) in the
	// editor world, so the renderer owns one here and pumps it from its editor
	// Tick. Null at runtime/PIE, where the real GameInstance subsystem is used.
	UPROPERTY(Transient) USpaceSimSubsystem* EditorSim = nullptr;

	// Editor-preview connection bookkeeping: the endpoint currently dialed (so a
	// Host/Port edit reconnects), a throttle for retrying a dead/missing server,
	// and the wall-clock time of the last received frame (for staleness detection).
	FString ConnectedHost;
	int32 ConnectedPort = 0;
	float ReconnectAccum = 0.f;
	double LastFrameTime = 0.0;
};
