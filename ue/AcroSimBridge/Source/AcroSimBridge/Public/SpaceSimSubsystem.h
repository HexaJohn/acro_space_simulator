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
#include "SpaceSimSubsystem.generated.h"

class FSocket;

/// One celestial body, already converted to UE space and rebased onto the
/// floating origin (FocusBodyId sits at the world origin).
USTRUCT(BlueprintType)
struct FSimBody
{
	GENERATED_BODY()
	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FVector Position = FVector::ZeroVector; // cm, UE world
	UPROPERTY(BlueprintReadOnly) FQuat Orientation = FQuat::Identity;
	UPROPERTY(BlueprintReadOnly) float RadiusCm = 0.f;
};

/// One part of a craft. Attach a mesh for [Type] under the craft actor at
/// [LocalOffset] (craft-local); it inherits the craft's world transform.
USTRUCT(BlueprintType)
struct FSimPart
{
	GENERATED_BODY()
	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Type;        // asset key (sim part name)
	UPROPERTY(BlueprintReadOnly) FVector LocalOffset = FVector::ZeroVector; // cm, craft-local
};

/// One vessel, converted to UE space and rebased. Position already folds in the
/// vessel's dominant-body world position, so it is a true scene-space location.
/// [Parts] is the assembly manifest — rebuild the craft actor's child meshes
/// when the part set changes (e.g. on staging).
USTRUCT(BlueprintType)
struct FSimVessel
{
	GENERATED_BODY()
	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Owner;
	UPROPERTY(BlueprintReadOnly) FString Body;
	UPROPERTY(BlueprintReadOnly) FVector Position = FVector::ZeroVector; // cm, UE world
	UPROPERTY(BlueprintReadOnly) FVector Velocity = FVector::ZeroVector; // cm/s, UE
	UPROPERTY(BlueprintReadOnly) FVector AngularVelocity = FVector::ZeroVector; // rad/s, UE
	UPROPERTY(BlueprintReadOnly) FQuat Attitude = FQuat::Identity;
	UPROPERTY(BlueprintReadOnly) float Throttle = 0.f;
	UPROPERTY(BlueprintReadOnly) bool bOnRails = false;
	UPROPERTY(BlueprintReadOnly) bool bLanded = false;
	UPROPERTY(BlueprintReadOnly) TArray<FSimPart> Parts;
};

/// A colony building, placed BODY-FIXED. Parent it under the body actor whose
/// id is [Body], then apply [LocalPosition]/[LocalOrientation] as the RELATIVE
/// transform — it spins with the planet for free. [Lat]/[Lon] (radians) let the
/// engine ray-cast its own landscape and report a height back via
/// SubmitReportTerrainHeight so the sim re-places the building to agree.
USTRUCT(BlueprintType)
struct FSimBuilding
{
	GENERATED_BODY()
	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Type;   // asset key (building spec type)
	UPROPERTY(BlueprintReadOnly) FString Colony;
	UPROPERTY(BlueprintReadOnly) FString Body;
	UPROPERTY(BlueprintReadOnly) FVector LocalPosition = FVector::ZeroVector; // cm, body-local
	UPROPERTY(BlueprintReadOnly) FQuat LocalOrientation = FQuat::Identity;
	UPROPERTY(BlueprintReadOnly) float Lat = 0.f; // radians
	UPROPERTY(BlueprintReadOnly) float Lon = 0.f; // radians
};

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

	// Latest world, already in UE space + rebased onto FocusBodyId.
	const TArray<FSimVessel>& GetVessels() const { return Vessels; }
	const TArray<FSimBody>& GetBodies() const { return Bodies; }
	const TArray<FSimBuilding>& GetBuildings() const { return Buildings; }
	int64 GetWorldTick() const { return WorldTick; }

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
