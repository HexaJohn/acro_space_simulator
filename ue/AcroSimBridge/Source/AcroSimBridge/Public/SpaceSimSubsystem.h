// SpaceSimSubsystem.h — Unreal Engine client for the acro_space_simulator
// Dart bridge. Connects to bin/sim_server.dart over TCP loopback, consumes
// WorldFrame FlatBuffers, sends CommandFrame FlatBuffers.
//
// Drop this module under <YourProject>/Source/AcroSimBridge, or paste the
// subsystem into your existing game module and copy the Build.cs deps.
#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "Tickable.h"
#include "AcroSimTypes.h" // generated FSim* structs (dart run tool/gen_ue_bindings.dart)
#include "SpaceSimSubsystem.generated.h"

class FSocket;

// The FSim* data structs (FSimBody/FSimVessel/FSimBuilding/FSimPart/
// FSimResource/FSimEvent) are GENERATED from wire/sim.fbs into AcroSimTypes.h.
// To change them, edit the schema + tool/gen_ue_bindings.dart and regenerate —
// not here. The ingest/rebasing that fills them stays hand-written below.

/// Fired (game thread) after each WorldFrame is ingested, so Blueprints can
/// drive rendering on an event instead of polling every Tick.
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnWorldUpdated);

/// Fired once per discrete sim event in the frame — bind for FX/UI.
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnSimEvent, const FSimEvent&, Event);

UCLASS()
class ACROSIMBRIDGE_API USpaceSimSubsystem : public UGameInstanceSubsystem, public FTickableGameObject
{
	GENERATED_BODY()

public:
	// UGameInstanceSubsystem
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	// FTickableGameObject
	virtual void Tick(float DeltaTime) override;
	virtual TStatId GetStatId() const override;
	virtual bool IsTickable() const override { return Socket != nullptr; }

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	bool Connect(const FString& Host = TEXT("127.0.0.1"), int32 Port = 5800);

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void Disconnect();

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	bool IsConnected() const { return Socket != nullptr; }

	// Latest world, already in UE space + rebased onto FocusBodyId. Returned by
	// value so they are Blueprint-callable; cache the result in a BP variable and
	// loop over it rather than calling per element.
	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	TArray<FSimVessel> GetVessels() const { return Vessels; }

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	TArray<FSimBody> GetBodies() const { return Bodies; }

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	TArray<FSimBuilding> GetBuildings() const { return Buildings; }

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	int64 GetWorldTick() const { return WorldTick; }

	// Bind this in Blueprint to render on each new frame (event-driven).
	UPROPERTY(BlueprintAssignable, Category = "AcroSim")
	FOnWorldUpdated OnWorldUpdated;

	// Bind for FX/UI: fires once per discrete sim event in the frame. Fired
	// during ingest, BEFORE OnWorldUpdated, but with the new frame already
	// applied to GetVessels/GetBodies/GetBuildings — so Event.Subject's
	// transform is current when you handle it.
	UPROPERTY(BlueprintAssignable, Category = "AcroSim")
	FOnSimEvent OnSimEvent;

	// FTransform helpers so Blueprints get a ready transform pin (FQuat pins are
	// awkward in BP). Bodies/vessels are world-space; building is body-LOCAL —
	// apply it as the relative transform under the matching body actor.
	UFUNCTION(BlueprintPure, Category = "AcroSim")
	static FTransform VesselTransform(const FSimVessel& Vessel)
	{
		return FTransform(Vessel.Attitude, Vessel.Position);
	}

	UFUNCTION(BlueprintPure, Category = "AcroSim")
	static FTransform BodyTransform(const FSimBody& Body)
	{
		return FTransform(Body.Orientation, Body.Position);
	}

	UFUNCTION(BlueprintPure, Category = "AcroSim")
	static FTransform BuildingLocalTransform(const FSimBuilding& Building)
	{
		return FTransform(Building.LocalOrientation, Building.LocalPosition);
	}

	// Commands (engine -> sim). HeadingSim is a forward axis in SIM coordinates
	// (right-handed, Z up) — the same convention SetAttitudeCommand expects.
	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void SubmitThrottle(const FString& VesselId, float Throttle);

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void SubmitAttitude(const FString& VesselId, FVector HeadingSim);

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void SubmitSeparateStage(const FString& VesselId);

	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void SubmitPlaceBuilding(const FString& ColonyId, const FString& Kind, int32 GridX, int32 GridY);

	// Report the terrain height (metres above the smooth sphere) the engine's
	// landscape has at a building's Lat/Lon, so the sim re-places it to agree.
	UFUNCTION(BlueprintCallable, Category = "AcroSim")
	void SubmitReportTerrainHeight(const FString& Body, float Lat, float Lon, float Height);

	// The body whose root-relative position becomes the UE world origin.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString FocusBodyId = TEXT("kerbin");

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "AcroSim")
	FString PlayerId = TEXT("player-1");

	// --- coordinate conversion (sim -> UE) ---
	// Sim: right-handed, Z up, metres, quaternion Hamilton scalar-FIRST (w,x,y,z).
	// UE:  left-handed,  Z up, centimetres, FQuat scalar-LAST (x,y,z,w).
	// We negate Y to flip handedness and scale metres->cm.
	static FVector SimToUEPosition(double X, double Y, double Z); // metres -> cm
	static FVector SimToUEVelocity(double X, double Y, double Z); // m/s   -> cm/s
	// Angular velocity is an AXIAL (pseudo) vector: under the Y-mirror it picks
	// up an extra sign, so it maps as (-x, y, -z) — same sign pattern as the
	// quaternion's vector part, NOT the polar (x,-y,z) of position/velocity.
	static FVector SimToUEAngularVelocity(double X, double Y, double Z);
	static FQuat   SimToUEQuat(double W, double X, double Y, double Z);

private:
	void PumpSocket();
	void IngestWorldFrame(const uint8* Data, int32 Len);
	void SendFramed(const uint8* Data, int32 Len); // enqueues; flushed in Tick
	void FlushTx();

	FSocket* Socket = nullptr;
	TArray<uint8> RxBuffer;    // de-framing accumulator
	TArray<uint8> TxBuffer;    // outbound queue (handles partial writes + connect race)
	TArray<uint8> LatestBytes; // owns the buffer the parsed frame points into

	UPROPERTY() TArray<FSimVessel> Vessels;
	UPROPERTY() TArray<FSimBody> Bodies;
	UPROPERTY() TArray<FSimBuilding> Buildings;
	int64 WorldTick = 0;
};
