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

	// Type-key -> mesh. Row name = sim part name / building spec type / body id.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	UDataTable* AssetTable = nullptr;

	// Used when a type-key has no row (e.g. a debug cube so nothing is invisible).
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	TSoftObjectPtr<UStaticMesh> FallbackMesh;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	bool bAutoConnect = true;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString Host = TEXT("127.0.0.1");
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	int32 Port = 5800;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString FocusBodyId = TEXT("kerbin");

	// Radius (cm) of the body mesh at scale 1. UE's engine sphere is 50 cm radius,
	// so the default maps RadiusCm -> uniform scale of RadiusCm / 50.
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

private:
	UFUNCTION()
	void HandleWorldUpdated();

	void UpdateBodies(USpaceSimSubsystem* Sim);
	void UpdateVessels(USpaceSimSubsystem* Sim);
	void UpdateBuildings(USpaceSimSubsystem* Sim);

	UStaticMesh* MeshFor(const FString& Key, FVector& OutScale, UMaterialInterface*& OutMaterial) const;
	AActor* SpawnVesselActor();

	UPROPERTY() TMap<FString, AActor*> BodyActors;   // body id -> actor (scale-1 root)
	UPROPERTY() TMap<FString, AActor*> VesselActors; // vessel id -> actor
	UPROPERTY() TMap<FString, UStaticMeshComponent*> PartComps; // "vesselId/partId" -> comp
	UPROPERTY() TMap<FString, UHierarchicalInstancedStaticMeshComponent*> BuildingHisms; // "bodyId|type" -> HISM

	TMap<FString, float> BodyRadiiCm;       // body id -> radius (cm), for terrain baseline
	TMap<FString, FVector> BuildingTypeScale; // building type -> asset table scale
	// "colony/id" -> (hism key, instance index). Re-added if a body respawns.
	TMap<FString, TPair<FString, int32>> BuildingInstances;

	TWeakObjectPtr<USpaceSimSubsystem> SimRef;
};
