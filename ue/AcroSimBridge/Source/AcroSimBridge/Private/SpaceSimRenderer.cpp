#include "SpaceSimRenderer.h"

#include "SpaceSimSubsystem.h"
#include "Components/HierarchicalInstancedStaticMeshComponent.h"
#include "Components/StaticMeshComponent.h"
#include "DrawDebugHelpers.h"
#include "Engine/GameInstance.h"
#include "Engine/StaticMesh.h"
#include "Engine/World.h"
#include "Materials/MaterialInterface.h"

ASpaceSimRenderer::ASpaceSimRenderer()
{
	PrimaryActorTick.bCanEverTick = false; // event-driven via OnWorldUpdated
	RootComponent = CreateDefaultSubobject<USceneComponent>(TEXT("Root"));
}

void ASpaceSimRenderer::BeginPlay()
{
	Super::BeginPlay();

	UWorld* World = GetWorld();
	UGameInstance* GI = World ? World->GetGameInstance() : nullptr;
	USpaceSimSubsystem* Sim = GI ? GI->GetSubsystem<USpaceSimSubsystem>() : nullptr;
	if (!Sim)
	{
		UE_LOG(LogTemp, Warning, TEXT("ASpaceSimRenderer: no USpaceSimSubsystem"));
		return;
	}
	SimRef = Sim;
	Sim->FocusBodyId = FocusBodyId;
	Sim->OnWorldUpdated.AddDynamic(this, &ASpaceSimRenderer::HandleWorldUpdated);
	if (bAutoConnect)
	{
		Sim->Connect(Host, Port);
	}
}

void ASpaceSimRenderer::EndPlay(const EEndPlayReason::Type Reason)
{
	if (USpaceSimSubsystem* Sim = SimRef.Get())
	{
		Sim->OnWorldUpdated.RemoveDynamic(this, &ASpaceSimRenderer::HandleWorldUpdated);
	}
	Super::EndPlay(Reason);
}

void ASpaceSimRenderer::HandleWorldUpdated()
{
	USpaceSimSubsystem* Sim = SimRef.Get();
	if (!Sim)
	{
		return;
	}
	UpdateBodies(Sim);
	UpdateVessels(Sim);
	UpdateBuildings(Sim); // after bodies — buildings parent under body actors
}

UStaticMesh* ASpaceSimRenderer::MeshFor(const FString& Key, FVector& OutScale, UMaterialInterface*& OutMaterial) const
{
	OutScale = FVector::OneVector;
	OutMaterial = nullptr;
	if (AssetTable)
	{
		if (const FAcroAssetRow* Row = AssetTable->FindRow<FAcroAssetRow>(FName(*Key), TEXT(""), false))
		{
			OutScale = Row->Scale;
			OutMaterial = Row->OverrideMaterial.IsNull() ? nullptr : Row->OverrideMaterial.LoadSynchronous();
			if (!Row->Mesh.IsNull())
			{
				return Row->Mesh.LoadSynchronous();
			}
		}
	}
	return FallbackMesh.IsNull() ? nullptr : FallbackMesh.LoadSynchronous();
}

AActor* ASpaceSimRenderer::SpawnVesselActor()
{
	AActor* A = GetWorld()->SpawnActor<AActor>();
	if (!A) return nullptr;
	USceneComponent* Root = NewObject<USceneComponent>(A, TEXT("CraftRoot"));
	A->SetRootComponent(Root);
	Root->RegisterComponent();
	return A;
}

void ASpaceSimRenderer::UpdateBodies(USpaceSimSubsystem* Sim)
{
	TSet<FString> Seen;
	for (const FSimBody& B : Sim->GetBodies())
	{
		Seen.Add(B.Id);
		BodyRadiiCm.Add(B.Id, B.RadiusCm);

		AActor* Actor = BodyActors.FindRef(B.Id);
		if (!Actor)
		{
			Actor = GetWorld()->SpawnActor<AActor>();
			if (!Actor) continue;
			// Scale-1 root so attached buildings/HISMs are NOT multiplied by the
			// planet's display size; the planet mesh is a child carrying the scale.
			USceneComponent* Root = NewObject<USceneComponent>(Actor, TEXT("BodyRoot"));
			Actor->SetRootComponent(Root);
			Root->RegisterComponent();

			UStaticMeshComponent* MC = NewObject<UStaticMeshComponent>(Actor, TEXT("BodyMesh"));
			MC->RegisterComponent();
			MC->AttachToComponent(Root, FAttachmentTransformRules::KeepRelativeTransform);
			FVector TableScale;
			UMaterialInterface* Mat;
			UStaticMesh* Mesh = MeshFor(B.Id, TableScale, Mat);
			MC->SetStaticMesh(Mesh);
			if (Mat) MC->SetMaterial(0, Mat);
			// Body radius is constant — scale the unit-radius sphere mesh once.
			const float K = (BodyMeshUnitRadiusCm > KINDA_SMALL_NUMBER)
								? B.RadiusCm / BodyMeshUnitRadiusCm
								: 1.f;
			MC->SetRelativeScale3D(FVector(K) * TableScale);

			BodyActors.Add(B.Id, Actor);
		}
		Actor->SetActorLocationAndRotation(B.Position, B.Orientation);
	}
	// Prune vanished bodies + their building HISMs/instances together.
	for (auto It = BodyActors.CreateIterator(); It; ++It)
	{
		if (!Seen.Contains(It.Key()))
		{
			const FString Prefix = It.Key() + TEXT("|");
			for (auto H = BuildingHisms.CreateIterator(); H; ++H)
			{
				if (H.Key().StartsWith(Prefix)) H.RemoveCurrent();
			}
			for (auto I = BuildingInstances.CreateIterator(); I; ++I)
			{
				if (I.Value().Key.StartsWith(Prefix)) I.RemoveCurrent();
			}
			BodyRadiiCm.Remove(It.Key());
			if (It.Value()) It.Value()->Destroy(); // destroys its child HISMs too
			It.RemoveCurrent();
		}
	}
}

void ASpaceSimRenderer::UpdateVessels(USpaceSimSubsystem* Sim)
{
	TSet<FString> SeenVessels;
	for (const FSimVessel& V : Sim->GetVessels())
	{
		SeenVessels.Add(V.Id);
		AActor* Actor = VesselActors.FindRef(V.Id);
		if (!Actor)
		{
			Actor = SpawnVesselActor();
			if (!Actor) continue;
			VesselActors.Add(V.Id, Actor);
		}
		Actor->SetActorLocationAndRotation(V.Position, V.Attitude);

		// Orbit line: the trajectory is already world-space (rebased) cm points.
		if (bDrawOrbits && V.Trajectory.Num() > 1)
		{
			for (int32 i = 0; i + 1 < V.Trajectory.Num(); ++i)
			{
				DrawDebugLine(GetWorld(), V.Trajectory[i], V.Trajectory[i + 1],
					OrbitColor, /*bPersistent*/ false, /*Lifetime*/ 0.2f,
					/*DepthPriority*/ 0, /*Thickness*/ 2.f);
			}
		}

		// Compose / refresh the craft's part meshes (vessel root is scale 1).
		TSet<FString> SeenParts;
		for (const FSimPart& P : V.Parts)
		{
			const FString Key = V.Id + TEXT("/") + P.Id;
			SeenParts.Add(Key);
			UStaticMeshComponent* Comp = PartComps.FindRef(Key);
			if (!Comp)
			{
				Comp = NewObject<UStaticMeshComponent>(Actor);
				Comp->RegisterComponent();
				Comp->AttachToComponent(Actor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
				PartComps.Add(Key, Comp);
				FVector Scale;
				UMaterialInterface* Mat;
				UStaticMesh* Mesh = MeshFor(P.Type, Scale, Mat);
				Comp->SetStaticMesh(Mesh);
				if (Mat) Comp->SetMaterial(0, Mat);
				Comp->SetRelativeScale3D(Scale);
			}
			Comp->SetRelativeLocation(P.LocalOffset);
		}
		// Drop part comps that staging removed from this vessel.
		TArray<FString> Stale;
		const FString Prefix = V.Id + TEXT("/");
		for (const auto& Pair : PartComps)
		{
			if (Pair.Key.StartsWith(Prefix) && !SeenParts.Contains(Pair.Key))
			{
				Stale.Add(Pair.Key);
			}
		}
		for (const FString& K : Stale)
		{
			if (UStaticMeshComponent* C = PartComps.FindRef(K)) C->DestroyComponent();
			PartComps.Remove(K);
		}
	}
	// Prune vanished vessels (their part comps die with the actor).
	for (auto It = VesselActors.CreateIterator(); It; ++It)
	{
		if (!SeenVessels.Contains(It.Key()))
		{
			const FString Prefix = It.Key() + TEXT("/");
			TArray<FString> Drop;
			for (const auto& Pair : PartComps)
			{
				if (Pair.Key.StartsWith(Prefix)) Drop.Add(Pair.Key);
			}
			for (const FString& K : Drop) PartComps.Remove(K);
			if (It.Value()) It.Value()->Destroy();
			It.RemoveCurrent();
		}
	}
}

void ASpaceSimRenderer::UpdateBuildings(USpaceSimSubsystem* Sim)
{
	for (const FSimBuilding& Bld : Sim->GetBuildings())
	{
		AActor* BodyActor = BodyActors.FindRef(Bld.Body);
		if (!BodyActor) continue; // body not spawned yet — next frame

		const FString HismKey = Bld.Body + TEXT("|") + Bld.Type;
		UHierarchicalInstancedStaticMeshComponent* Hism = BuildingHisms.FindRef(HismKey);
		if (!Hism)
		{
			FVector Scale;
			UMaterialInterface* Mat;
			UStaticMesh* Mesh = MeshFor(Bld.Type, Scale, Mat);
			if (!Mesh) continue; // a HISM must have a valid mesh before AddInstance
			Hism = NewObject<UHierarchicalInstancedStaticMeshComponent>(BodyActor);
			Hism->RegisterComponent();
			Hism->AttachToComponent(BodyActor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
			Hism->SetStaticMesh(Mesh);
			if (Mat) Hism->SetMaterial(0, Mat);
			BuildingHisms.Add(HismKey, Hism);
			BuildingTypeScale.Add(Bld.Type, Scale);
		}

		FVector S = BuildingTypeScale.FindRef(Bld.Type);
		if (S.IsNearlyZero()) S = FVector::OneVector;
		const FTransform Local(Bld.LocalOrientation, Bld.LocalPosition, S);

		const FString InstanceKey = Bld.Colony + TEXT("/") + Bld.Id;
		TPair<FString, int32>* Found = BuildingInstances.Find(InstanceKey);
		if (Found && Found->Key == HismKey && Found->Value >= 0 &&
			Found->Value < Hism->GetInstanceCount())
		{
			Hism->UpdateInstanceTransform(Found->Value, Local, /*bWorldSpace*/ false,
				/*bMarkRenderStateDirty*/ true);
		}
		else
		{
			const int32 Index = Hism->AddInstance(Local); // local-space default (cross-version)
			BuildingInstances.Add(InstanceKey, TPair<FString, int32>(HismKey, Index));
		}

		// Optional terrain reconciliation: report ABSOLUTE height above the smooth
		// sphere (overwrite-stable), using the wire radius — not the display scale.
		if (bReportTerrain)
		{
			const FTransform BodyW = BodyActor->GetActorTransform(); // scale-1 root
			const FVector BuildingW = BodyW.TransformPosition(Bld.LocalPosition);
			const FVector UpW = BodyW.TransformVectorNoScale(Bld.LocalOrientation.GetUpVector()).GetSafeNormal();
			const FVector BodyCenter = BodyActor->GetActorLocation();
			const float SphereRadiusCm = BodyRadiiCm.FindRef(Bld.Body);

			FCollisionQueryParams Params;
			Params.AddIgnoredActor(BodyActor); // don't hit the planet's own collision
			Params.AddIgnoredActor(this);
			FHitResult Hit;
			const FVector Start = BuildingW + UpW * 100000.0; // 1 km up
			const FVector End = BuildingW - UpW * 100000.0;
			if (GetWorld()->LineTraceSingleByChannel(Hit, Start, End, TerrainTraceChannel, Params))
			{
				const double HeightM = (FVector::Dist(Hit.Location, BodyCenter) - SphereRadiusCm) / 100.0;
				Sim->SubmitReportTerrainHeight(Bld.Body, Bld.Lat, Bld.Lon, static_cast<float>(HeightM));
			}
		}
	}
}
