#include "SpaceSimRenderer.h"

#include "SpaceSimSubsystem.h"
#include "Components/HierarchicalInstancedStaticMeshComponent.h"
#include "Components/StaticMeshComponent.h"
#include "DrawDebugHelpers.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/StaticMesh.h"
#include "Engine/World.h"
#include "Materials/MaterialInterface.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Components/PointLightComponent.h"

ASpaceSimRenderer::ASpaceSimRenderer()
{
	// Runtime/PIE is event-driven (OnWorldUpdated). We still tick so the EDITOR
	// preview path can pump its own connection (see Tick); the tick early-outs in
	// game worlds. ShouldTickIfViewportsOnly() lets it run without PIE.
	PrimaryActorTick.bCanEverTick = true;
	PrimaryActorTick.bStartWithTickEnabled = true;
	RootComponent = CreateDefaultSubobject<USceneComponent>(TEXT("Root"));

	// Any sphere works as the atmosphere proxy — its WorldPosition is never read.
	AtmosphereProxyMesh = TSoftObjectPtr<UStaticMesh>(FSoftObjectPath(TEXT("/Engine/BasicShapes/Sphere.Sphere")));
}

void ASpaceSimRenderer::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);

	UWorld* World = GetWorld();
	// Game/PIE worlds are driven by the GameInstance subsystem's OnWorldUpdated
	// event set up in BeginPlay — nothing to do here.
	if (!World || World->IsGameWorld())
	{
		return;
	}

	// While a PIE/game session is running, do NOT keep the editor-preview subsystem
	// alive. Its transient GameInstance gets held by the transaction buffer and lingers
	// into End-PIE GC verification -> "PIE object still referenced" assert -> crash.
	// Tear it down; the preview rebuilds automatically once PIE stops.
	if (GEngine)
	{
		for (const FWorldContext& WC : GEngine->GetWorldContexts())
		{
			if (WC.WorldType == EWorldType::PIE)
			{
				TeardownEditorPreview();
				return;
			}
		}
	}

	// Editor preview disabled (or just toggled off): tear down any live connection.
	if (!bRunInEditor)
	{
		TeardownEditorPreview();
		return;
	}

	// Stand up the editor-owned subsystem once (the connection is handled below so
	// it can also reconnect on endpoint changes / drops).
	if (!EditorSim)
	{
		// USpaceSimSubsystem is a UGameInstanceSubsystem — its ClassWithin is
		// UGameInstance, so it CANNOT be NewObject'd under the actor (UE ensures on
		// an invalid Outer). The editor world has no GameInstance, so host a
		// transient one purely as the required outer; the subsystem never calls
		// into it (it only uses sockets), so an uninitialised instance is fine.
		if (!EditorGameInstance)
		{
			// Outer to the TRANSIENT PACKAGE (not this actor) + RF_Transient. If it is a
			// subobject of the actor, PIE duplicates it and the transaction buffer holds
			// it, tripping the "PIE object still referenced" GC assert on End PIE (crash).
			// The UPROPERTY(Transient) refs below keep both alive; teardown nulls them.
			EditorGameInstance = NewObject<UGameInstance>(GetTransientPackage(), UGameInstance::StaticClass(), NAME_None, RF_Transient);
			EditorGameInstance->AddToRoot(); // not a UPROPERTY — root it so GC keeps it
		}
		EditorSim = NewObject<USpaceSimSubsystem>(EditorGameInstance, USpaceSimSubsystem::StaticClass(), NAME_None, RF_Transient);
		EditorSim->AddToRoot();
		EditorSim->OnWorldUpdated.AddDynamic(this, &ASpaceSimRenderer::HandleWorldUpdated);
		SimRef = EditorSim;
	}

	// (Re)connect ONLY on first run, a Host/Port edit, or a genuinely dropped
	// socket — never on a "stale" frame gap. A large frame spans many non-blocking
	// Recv calls / editor ticks, and Connect() calls Disconnect() which RESETS the
	// RxBuffer: a staleness re-dial would wipe a frame mid-assembly so it could
	// never complete, and the link flapped every few seconds. Throttled so a
	// missing server isn't dialed every frame.
	if (bAutoConnect)
	{
		const bool bEndpointChanged = (Host != ConnectedHost || Port != ConnectedPort);
		if (bEndpointChanged || !EditorSim->IsConnected())
		{
			ReconnectAccum += DeltaSeconds;
			if (bEndpointChanged || ReconnectAccum >= 2.0f)
			{
				ReconnectAccum = 0.f;
				EditorSim->Connect(Host, Port); // Connect() closes any prior socket first
				ConnectedHost = Host;
				ConnectedPort = Port;
			}
		}
		else
		{
			ReconnectAccum = 0.f;
		}
	}

	EditorSim->FocusBodyId = FocusBodyId; // live-editable in the detail panel
	EditorSim->EditorPump();              // recv -> ingest -> OnWorldUpdated -> render
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
	// Runtime/PIE: unbind from the GameInstance subsystem (SimRef). In the editor
	// SimRef IS EditorSim, which TeardownEditorPreview() unbinds — RemoveDynamic is
	// idempotent so the double-unbind is harmless.
	if (USpaceSimSubsystem* Sim = SimRef.Get())
	{
		Sim->OnWorldUpdated.RemoveDynamic(this, &ASpaceSimRenderer::HandleWorldUpdated);
	}
	TeardownEditorPreview(); // editor socket + preview actors (no-op extras at runtime)
	Super::EndPlay(Reason);
}

void ASpaceSimRenderer::Destroyed()
{
	// In-editor delete / map change tears the actor down WITHOUT a routed EndPlay
	// (it never had BeginPlay in the editor world), so clean up here too.
	TeardownEditorPreview();
	Super::Destroyed();
}

void ASpaceSimRenderer::TeardownEditorPreview()
{
	if (EditorSim)
	{
		EditorSim->OnWorldUpdated.RemoveDynamic(this, &ASpaceSimRenderer::HandleWorldUpdated);
		EditorSim->Disconnect(); // close the editor-owned socket
		EditorSim->RemoveFromRoot();
		EditorSim = nullptr;
	}
	if (EditorGameInstance)
	{
		EditorGameInstance->RemoveFromRoot();
		EditorGameInstance = nullptr;
	}
	ConnectedHost.Reset();
	ConnectedPort = 0;
	ReconnectAccum = 0.f;
	LastFrameTime = 0.0;
	DestroySpawnedActors();
}

void ASpaceSimRenderer::DestroySpawnedActors()
{
	for (const auto& Pair : BodyActors)
	{
		if (Pair.Value) Pair.Value->Destroy(); // destroys child meshes + building HISMs
	}
	for (const auto& Pair : VesselActors)
	{
		if (Pair.Value) Pair.Value->Destroy(); // destroys child part comps
	}
	BodyActors.Reset();
	VesselActors.Reset();
	PartComps.Reset();
	BuildingHisms.Reset();
	BuildingInstances.Reset();
	BuildingTypeScale.Reset();
	BodyRadiiCm.Reset();
	AtmoComps.Reset();
	AtmoMIDs.Reset();
	RingComps.Reset();
	AsteroidRingBuilt.Reset();
	SunLight = nullptr;
}

void ASpaceSimRenderer::HandleWorldUpdated()
{
	USpaceSimSubsystem* Sim = SimRef.Get();
	if (!Sim)
	{
		return;
	}
	LastFrameTime = FPlatformTime::Seconds(); // for editor staleness/reconnect
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
	// Transient + outliner-hidden: these are live render proxies, never saved into
	// the map (matters for the editor-preview path, harmless at runtime).
	FActorSpawnParameters SpawnParams;
	SpawnParams.ObjectFlags |= RF_Transient; // never saved into the map
	AActor* A = GetWorld()->SpawnActor<AActor>(SpawnParams);
	if (!A) return nullptr;
	USceneComponent* Root = NewObject<USceneComponent>(A, TEXT("CraftRoot"));
	A->SetRootComponent(Root);
	Root->RegisterComponent();
	return A;
}

void ASpaceSimRenderer::UpdateBodies(USpaceSimSubsystem* Sim)
{
	TSet<FString> Seen;

	// The star's UE-space position drives every planet's sun direction below.
	FVector SunWorldPos = FVector::ZeroVector;
	for (const FSimBody& Star : Sim->GetBodies())
	{
		if (Star.Id == SunBodyId) { SunWorldPos = Star.Position * WorldScale; break; }
	}

	for (const FSimBody& B : Sim->GetBodies())
	{
		Seen.Add(B.Id);
		BodyRadiiCm.Add(B.Id, B.RadiusCm);

		AActor* Actor = BodyActors.FindRef(B.Id);
		if (!Actor)
		{
			FActorSpawnParameters SpawnParams;
			SpawnParams.ObjectFlags |= RF_Transient; // never saved into the map
			Actor = GetWorld()->SpawnActor<AActor>(SpawnParams);
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
			// Scale the body mesh so its visual radius == the real RadiusCm.
			// Read the mesh's actual radius from its bounds (works for ANY mesh —
			// ArcadeEditorSphere, a unit sphere, a custom planet); fall back to
			// BodyMeshUnitRadiusCm only if bounds are unavailable.
			float UnitRadiusCm = BodyMeshUnitRadiusCm;
			if (Mesh)
			{
				const float R = Mesh->GetBounds().SphereRadius;
				if (R > KINDA_SMALL_NUMBER) UnitRadiusCm = R;
			}
			const float K = (UnitRadiusCm > KINDA_SMALL_NUMBER)
								? B.RadiusCm / UnitRadiusCm
								: 1.f;
			MC->SetRelativeScale3D(FVector(K) * TableScale);

			// The star is a light source, not an occluder: if its own mesh casts a
			// shadow it blocks the point light at its centre and nothing gets lit.
			if (B.Id == SunBodyId) MC->SetCastShadow(false);

			BodyActors.Add(B.Id, Actor);
#if WITH_EDITOR
			Actor->SetActorLabel(FString::Printf(TEXT("Body_%s"), *B.Id));
#endif
		}
		// Bodies are full-scale (size matters): shrink size + position together by
		// WorldScale. Buildings parented under the root inherit it.
		Actor->SetActorScale3D(FVector(WorldScale));
		Actor->SetActorLocationAndRotation(B.Position * WorldScale, B.Orientation);

		// --- Sun point light (on the star body) ---
		if (bSpawnSunLight && B.Id == SunBodyId)
		{
			if (!SunLight)
			{
				SunLight = NewObject<UPointLightComponent>(Actor, TEXT("SunLight"));
				SunLight->SetMobility(EComponentMobility::Movable);
				SunLight->RegisterComponent();
				SunLight->AttachToComponent(Actor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
				SunLight->SetUsingAbsoluteScale(true); // don't inherit the body's WorldScale
			}
			SunLight->SetIntensity(SunLightIntensity);
			SunLight->SetLightColor(SunLightColor);
			SunLight->SetAttenuationRadius(SunLightAttenuationCm);
			SunLight->SetSourceRadius(B.RadiusCm * WorldScale); // soft-shadow size = the sun disk
		}

		// --- Atmosphere (optional, per body) ---
		// A camera-enclosing proxy sphere drawing M_PlanetAtmosphere. Its center
		// (ObjectPosition) is the body center; PlanetRadius/AtmosphereRadius are the
		// visual (WorldScale'd) radii; SunDirection points at the star body.
		if (AtmosphereTable)
		{
			const FAcroAtmosphereRow* ARow =
				AtmosphereTable->FindRow<FAcroAtmosphereRow>(FName(*B.Id), TEXT(""), false);
			if (ARow && !ARow->Material.IsNull())
			{
				UStaticMeshComponent* Atmo = AtmoComps.FindRef(B.Id);
				if (!Atmo)
				{
					Atmo = NewObject<UStaticMeshComponent>(Actor, *FString::Printf(TEXT("Atmo_%s"), *B.Id));
					Atmo->RegisterComponent();
					Atmo->AttachToComponent(Actor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
					if (UStaticMesh* Sphere = AtmosphereProxyMesh.LoadSynchronous()) Atmo->SetStaticMesh(Sphere);
					Atmo->SetCollisionEnabled(ECollisionEnabled::NoCollision);
					Atmo->SetCastShadow(false);
					UMaterialInstanceDynamic* MID =
						UMaterialInstanceDynamic::Create(ARow->Material.LoadSynchronous(), Atmo);
					Atmo->SetMaterial(0, MID);
					AtmoComps.Add(B.Id, Atmo);
					AtmoMIDs.Add(B.Id, MID);
				}
				// Hold the proxy at AtmosphereProxyRadiusCm in WORLD space (it is a child
				// of the WorldScale'd actor, so divide that back out).
				float UnitR = 50.f;
				if (UStaticMesh* PM = AtmosphereProxyMesh.LoadSynchronous())
				{
					const float R = PM->GetBounds().SphereRadius;
					if (R > KINDA_SMALL_NUMBER) UnitR = R;
				}
				const float WS = (FMath::Abs(WorldScale) > KINDA_SMALL_NUMBER) ? WorldScale : 1.f;
				Atmo->SetRelativeScale3D(FVector((AtmosphereProxyRadiusCm / UnitR) / WS));
				if (UMaterialInstanceDynamic* MID = AtmoMIDs.FindRef(B.Id))
				{
					MID->SetScalarParameterValue(TEXT("PlanetRadius"), B.RadiusCm * WorldScale);
					MID->SetScalarParameterValue(TEXT("AtmosphereRadius"),
						(B.RadiusCm + ARow->AtmosphereHeightKm * 100000.f) * WorldScale);
					const FVector ToSun = (SunWorldPos - B.Position * WorldScale).GetSafeNormal();
					MID->SetVectorParameterValue(TEXT("SunDirection"),
						FLinearColor(ToSun.X, ToSun.Y, ToSun.Z, 0.f));
				}
			}
		}

		// --- Rings (optional, per body) ---
		if (RingTable)
		{
			const FAcroRingRow* RRow = RingTable->FindRow<FAcroRingRow>(FName(*B.Id), TEXT(""), false);
			if (RRow)
			{
				// Disk (fades IN with camera distance via its material) — independent of
				// the asteroids so a body can carry BOTH for a LOD crossfade.
				if (!RRow->Mesh.IsNull())
				{
					UStaticMeshComponent* Ring = RingComps.FindRef(B.Id);
					if (!Ring)
					{
						Ring = NewObject<UStaticMeshComponent>(Actor, *FString::Printf(TEXT("Ring_%s"), *B.Id));
						Ring->RegisterComponent();
						Ring->AttachToComponent(Actor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
						if (UStaticMesh* RM = RRow->Mesh.LoadSynchronous()) Ring->SetStaticMesh(RM);
						if (!RRow->Material.IsNull()) Ring->SetMaterial(0, RRow->Material.LoadSynchronous());
						Ring->SetCollisionEnabled(ECollisionEnabled::NoCollision);
						Ring->SetCastShadow(false);
						RingComps.Add(B.Id, Ring);
					}
					// Outer edge = OuterRadiusFactor * planet radius; child of the WorldScale'd
					// root + sized off RadiusCm, so it tracks the planet's size + equatorial tilt.
					float RingUnitR = 1.f;
					if (UStaticMesh* RM = RRow->Mesh.LoadSynchronous())
					{
						const FVector BE = RM->GetBounds().BoxExtent;
						RingUnitR = FMath::Max(BE.X, BE.Y);
						if (RingUnitR < KINDA_SMALL_NUMBER) RingUnitR = RM->GetBounds().SphereRadius;
					}
					if (RingUnitR < KINDA_SMALL_NUMBER) RingUnitR = 1.f;
					Ring->SetRelativeScale3D(FVector(RRow->OuterRadiusFactor * B.RadiusCm / RingUnitR));
				}

				// Asteroid field (fades OUT with camera distance via its material): scatter
				// ONCE into HISMs in body-LOCAL space so it rides the planet's transform.
				// Deterministic per body id. Independent of the disk above.
				if (RRow->AsteroidMeshes.Num() > 0 && !AsteroidRingBuilt.Contains(B.Id))
				{
					AsteroidRingBuilt.Add(B.Id);
					UMaterialInterface* AstMat = RRow->AsteroidMaterial.IsNull() ? nullptr : RRow->AsteroidMaterial.LoadSynchronous();
					TArray<UHierarchicalInstancedStaticMeshComponent*> Hisms;
					for (const TSoftObjectPtr<UStaticMesh>& MeshPtr : RRow->AsteroidMeshes)
					{
						UStaticMesh* AM = MeshPtr.LoadSynchronous();
						if (!AM) continue;
						UHierarchicalInstancedStaticMeshComponent* H =
							NewObject<UHierarchicalInstancedStaticMeshComponent>(Actor);
						H->RegisterComponent();
						H->AttachToComponent(Actor->GetRootComponent(), FAttachmentTransformRules::KeepRelativeTransform);
						H->SetStaticMesh(AM);
						if (AstMat) H->SetMaterial(0, AstMat); // distance-fade LOD material
						H->SetCollisionEnabled(ECollisionEnabled::NoCollision);
						H->SetCastShadow(false);
						Hisms.Add(H);
					}
					if (Hisms.Num() > 0)
					{
						FRandomStream Rand(GetTypeHash(B.Id));
						const float Inner = RRow->InnerRadiusFactor * B.RadiusCm;
						const float Outer = RRow->OuterRadiusFactor * B.RadiusCm;
						const float Thick = RRow->ThicknessFactor * B.RadiusCm;
						for (int32 i = 0; i < RRow->AsteroidCount; ++i)
						{
							UHierarchicalInstancedStaticMeshComponent* H = Hisms[Rand.RandHelper(Hisms.Num())];
							const float Ang = Rand.FRandRange(0.f, 2.f * PI);
							const float Rr = FMath::Sqrt(Rand.FRandRange(Inner * Inner, Outer * Outer)); // area-uniform radial
							const FVector Pos(Rr * FMath::Cos(Ang), Rr * FMath::Sin(Ang), Rand.FRandRange(-Thick, Thick));
							const FRotator Rot(Rand.FRandRange(0.f, 360.f), Rand.FRandRange(0.f, 360.f), Rand.FRandRange(0.f, 360.f));
							float MeshR = 50.f;
							if (UStaticMesh* SM = H->GetStaticMesh())
							{
								const float Rb = SM->GetBounds().SphereRadius;
								if (Rb > KINDA_SMALL_NUMBER) MeshR = Rb;
							}
							const float DesiredR = Rand.FRandRange(RRow->AsteroidMinScaleFactor, RRow->AsteroidMaxScaleFactor) * B.RadiusCm;
							H->AddInstance(FTransform(Rot, Pos, FVector(DesiredR / MeshR))); // local space
						}
					}
				}
			}
		}

		// Body orbit ring ("rails") about its parent: world-space cm points,
		// scaled to match. Root bodies (the Sun) carry no ring, so this no-ops.
		if (bDrawBodyOrbits && B.Orbit.Num() > 1)
		{
			for (int32 i = 0; i + 1 < B.Orbit.Num(); ++i)
			{
				DrawDebugLine(GetWorld(),
					B.Orbit[i] * WorldScale, B.Orbit[i + 1] * WorldScale,
					BodyOrbitColor, /*bPersistent*/ false, /*Lifetime*/ 0.2f,
					/*DepthPriority*/ 0, OrbitThickness);
			}
		}
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
			AtmoComps.Remove(It.Key());  // proxy component dies with the body actor below
			AtmoMIDs.Remove(It.Key());
			RingComps.Remove(It.Key());
			AsteroidRingBuilt.Remove(It.Key());
			if (It.Key() == SunBodyId) SunLight = nullptr; // dies with the star actor
			if (It.Value()) It.Value()->Destroy(); // destroys its child HISMs + atmosphere too
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
#if WITH_EDITOR
			Actor->SetActorLabel(FString::Printf(TEXT("Craft_%s"), *V.Id));
#endif
		}
		// Position scaled by WorldScale, but the craft itself is kept at marker
		// size (NOT scaled) so it stays visible against a huge planet.
		Actor->SetActorLocationAndRotation(V.Position * WorldScale, V.Attitude);

		// Orbit line: world-space cm points, scaled to match; OrbitThickness wide.
		if (bDrawOrbits && V.Trajectory.Num() > 1)
		{
			for (int32 i = 0; i + 1 < V.Trajectory.Num(); ++i)
			{
				DrawDebugLine(GetWorld(),
					V.Trajectory[i] * WorldScale, V.Trajectory[i + 1] * WorldScale,
					OrbitColor, /*bPersistent*/ false, /*Lifetime*/ 0.2f,
					/*DepthPriority*/ 0, OrbitThickness);
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
