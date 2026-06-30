#include "SpaceSimSubsystem.h"

#include "Sockets.h"
#include "SocketSubsystem.h"
#include "Common/TcpSocketBuilder.h"
#include "Interfaces/IPv4/IPv4Address.h"

// FlatBuffers generated contract (wire/sim.fbs). Header-only runtime; see
// AcroSimBridge.Build.cs for the include path.
THIRD_PARTY_INCLUDES_START
#include "sim_generated.h"
THIRD_PARTY_INCLUDES_END

#include <vector>

// ---------------------------------------------------------------------------
// Coordinate conversion. Sim is right-handed / Z-up / metres; UE is
// left-handed / Z-up / centimetres. Negating Y flips handedness. The quaternion
// transform under a Y-axis mirror is (w, -x, y, -z) (handedness flip also
// negates the rotation sense). VERIFY against a known craft pose the first time
// — if your meshes face backwards, flip the sign convention here in one place.
// ---------------------------------------------------------------------------
static constexpr double kMetresToCm = 100.0;

FVector USpaceSimSubsystem::SimToUEPosition(double X, double Y, double Z)
{
	return FVector(X, -Y, Z) * kMetresToCm;
}

FVector USpaceSimSubsystem::SimToUEVelocity(double X, double Y, double Z)
{
	return FVector(X, -Y, Z) * kMetresToCm;
}

FVector USpaceSimSubsystem::SimToUEAngularVelocity(double X, double Y, double Z)
{
	// Axial/pseudo vector under the Y-mirror: extra sign flip -> (-x, y, -z).
	// rad/s is scale-invariant, so no cm conversion.
	return FVector(-X, Y, -Z);
}

FQuat USpaceSimSubsystem::SimToUEQuat(double W, double X, double Y, double Z)
{
	// FQuat ctor is (X, Y, Z, W).
	return FQuat(-X, Y, -Z, W).GetNormalized();
}

void USpaceSimSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	// Caller connects when ready (e.g. from BeginPlay): Connect("127.0.0.1", 5800).
}

void USpaceSimSubsystem::Deinitialize()
{
	Disconnect();
	Super::Deinitialize();
}

bool USpaceSimSubsystem::Connect(const FString& Host, int32 Port)
{
	Disconnect();

	ISocketSubsystem* SocketSub = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM);
	if (!SocketSub)
	{
		return false;
	}

	bool bIsValid = false;
	TSharedRef<FInternetAddr> Addr = SocketSub->CreateInternetAddr();
	Addr->SetIp(*Host, bIsValid);
	Addr->SetPort(Port);
	if (!bIsValid)
	{
		return false;
	}

	Socket = FTcpSocketBuilder(TEXT("AcroSimClient"))
				 .AsReusable()
				 .AsNonBlocking()
				 .Build();
	if (!Socket)
	{
		return false;
	}

	Socket->Connect(*Addr); // non-blocking; loopback completes promptly
	UE_LOG(LogTemp, Log, TEXT("AcroSim: connecting to %s:%d"), *Host, Port);
	return true;
}

void USpaceSimSubsystem::Disconnect()
{
	if (Socket)
	{
		Socket->Close();
		ISocketSubsystem* SocketSub = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM);
		if (SocketSub)
		{
			SocketSub->DestroySocket(Socket);
		}
		Socket = nullptr;
	}
	RxBuffer.Reset();
}

void USpaceSimSubsystem::Tick(float /*DeltaTime*/)
{
	if (!Socket)
	{
		return;
	}
	if (Socket->GetConnectionState() == SCS_ConnectionError)
	{
		UE_LOG(LogTemp, Warning, TEXT("AcroSim: connection error — disconnecting"));
		Disconnect();
		return;
	}
	FlushTx();    // drain queued outbound commands (also covers the connect race)
	PumpSocket();
}

TStatId USpaceSimSubsystem::GetStatId() const
{
	RETURN_QUICK_DECLARE_CYCLE_STAT(USpaceSimSubsystem, STATGROUP_Tickables);
}

void USpaceSimSubsystem::PumpSocket()
{
	// Drain all available bytes (non-blocking).
	uint8 Temp[16 * 1024];
	int32 Read = 0;
	while (Socket->Recv(Temp, sizeof(Temp), Read, ESocketReceiveFlags::None) && Read > 0)
	{
		RxBuffer.Append(Temp, Read);
	}

	// De-frame: [uint32 LE length][payload]. Apply only the most recent frame —
	// older frames in the same pump are stale; the latest wins for rendering.
	static constexpr int64 kMaxFrame = 16 * 1024 * 1024;
	int32 Offset = 0;
	const uint8* LastData = nullptr;
	int32 LastLen = 0;
	while (RxBuffer.Num() - Offset >= 4)
	{
		uint32 Len = 0;
		FMemory::Memcpy(&Len, RxBuffer.GetData() + Offset, 4); // LE on x86/x64
		// Compare as int64 so a corrupt huge Len cannot wrap to a negative int32.
		if (static_cast<int64>(Len) > kMaxFrame)
		{
			UE_LOG(LogTemp, Warning, TEXT("AcroSim: oversize frame (%u) — dropping connection"), Len);
			Disconnect();
			return;
		}
		if (static_cast<int64>(RxBuffer.Num() - Offset - 4) < static_cast<int64>(Len))
		{
			break; // incomplete frame — wait for more bytes
		}
		LastData = RxBuffer.GetData() + Offset + 4;
		LastLen = static_cast<int32>(Len);
		Offset += 4 + static_cast<int32>(Len);
	}

	if (LastData)
	{
		IngestWorldFrame(LastData, LastLen);
		OnWorldUpdated.Broadcast(); // game thread — BP can render on this event
	}
	if (Offset > 0)
	{
		// NOTE: bool overload (UE 5.0-5.4). On UE 5.5+ this is also valid; if you
		// pin to 5.5+ you may use EAllowShrinking::No instead.
		RxBuffer.RemoveAt(0, Offset, false);
	}
}

void USpaceSimSubsystem::IngestWorldFrame(const uint8* Data, int32 Len)
{
	LatestBytes.Reset();
	LatestBytes.Append(Data, Len);

	flatbuffers::Verifier Verifier(LatestBytes.GetData(), LatestBytes.Num());
	if (!acro::wire::VerifyWorldFrameBuffer(Verifier))
	{
		return; // corrupt/partial — drop
	}
	const acro::wire::WorldFrame* World = acro::wire::GetWorldFrame(LatestBytes.GetData());
	WorldTick = World->tick();

	// Body root positions in SIM metres (FVector used only as a triple here).
	TMap<FString, FVector> BodyRootSim;
	if (const auto* BodyVec = World->bodies())
	{
		for (const auto* B : *BodyVec)
		{
			if (!B || !B->id() || !B->pos()) continue;
			const auto* P = B->pos();
			BodyRootSim.Add(FString(UTF8_TO_TCHAR(B->id()->c_str())),
							FVector(P->x(), P->y(), P->z()));
		}
	}
	const FVector OriginSim = BodyRootSim.Contains(FocusBodyId)
								  ? BodyRootSim[FocusBodyId]
								  : FVector::ZeroVector;

	// Bodies (rebased).
	Bodies.Reset();
	if (const auto* BodyVec = World->bodies())
	{
		for (const auto* B : *BodyVec)
		{
			if (!B || !B->id() || !B->pos() || !B->orient()) continue;
			// Use the Vec3 in hand rather than re-indexing the map (operator[]
			// would insert-on-miss); same root position as the first pass stored.
			const auto* Bp = B->pos();
			const FVector RebasedSim = FVector(Bp->x(), Bp->y(), Bp->z()) - OriginSim;
			const auto* Q = B->orient();
			FSimBody Out;
			Out.Id = FString(UTF8_TO_TCHAR(B->id()->c_str()));
			Out.Position = SimToUEPosition(RebasedSim.X, RebasedSim.Y, RebasedSim.Z);
			Out.Orientation = SimToUEQuat(Q->w(), Q->x(), Q->y(), Q->z());
			Out.RadiusCm = static_cast<float>(B->radius() * kMetresToCm);
			Bodies.Add(MoveTemp(Out));
		}
	}

	// Vessels: world(root) = dominantBody root pos + body-relative pos, rebased.
	Vessels.Reset();
	if (const auto* VesselVec = World->vessels())
	{
		for (const auto* V : *VesselVec)
		{
			if (!V || !V->id() || !V->pos() || !V->vel() || !V->att()) continue;
			const FString Body = V->body() ? FString(UTF8_TO_TCHAR(V->body()->c_str())) : FString();
			const FVector BodyRoot = BodyRootSim.Contains(Body) ? BodyRootSim[Body] : FVector::ZeroVector;
			const auto* P = V->pos();
			const auto* Vel = V->vel();
			const auto* A = V->att();
			const FVector VesselRootSim = BodyRoot + FVector(P->x(), P->y(), P->z());
			const FVector RebasedSim = VesselRootSim - OriginSim;

			FSimVessel Out;
			Out.Id = FString(UTF8_TO_TCHAR(V->id()->c_str()));
			Out.Owner = V->owner() ? FString(UTF8_TO_TCHAR(V->owner()->c_str())) : FString();
			Out.Body = Body;
			Out.Position = SimToUEPosition(RebasedSim.X, RebasedSim.Y, RebasedSim.Z);
			Out.Velocity = SimToUEVelocity(Vel->x(), Vel->y(), Vel->z());
			if (const auto* Spin = V->spin())
			{
				Out.AngularVelocity = SimToUEAngularVelocity(Spin->x(), Spin->y(), Spin->z());
			}
			Out.Attitude = SimToUEQuat(A->w(), A->x(), A->y(), A->z());
			Out.Throttle = static_cast<float>(V->throttle());
			Out.bOnRails = V->on_rails();
			Out.bLanded = V->landed();

			if (const auto* PartVec = V->parts())
			{
				for (const auto* Pf : *PartVec)
				{
					if (!Pf || !Pf->id()) continue;
					FSimPart Part;
					Part.Id = FString(UTF8_TO_TCHAR(Pf->id()->c_str()));
					Part.Type = Pf->type() ? FString(UTF8_TO_TCHAR(Pf->type()->c_str())) : FString();
					if (const auto* O = Pf->offset())
					{
						Part.LocalOffset = SimToUEPosition(O->x(), O->y(), O->z());
					}
					Out.Parts.Add(MoveTemp(Part));
				}
			}
			Vessels.Add(MoveTemp(Out));
		}
	}

	// Buildings: body-FIXED. Parent under the matching body actor and apply the
	// local transform; it spins with the planet.
	Buildings.Reset();
	if (const auto* BuildingVec = World->buildings())
	{
		for (const auto* B : *BuildingVec)
		{
			if (!B || !B->id()) continue;
			FSimBuilding Out;
			Out.Id = FString(UTF8_TO_TCHAR(B->id()->c_str()));
			Out.Type = B->type() ? FString(UTF8_TO_TCHAR(B->type()->c_str())) : FString();
			Out.Colony = B->colony() ? FString(UTF8_TO_TCHAR(B->colony()->c_str())) : FString();
			Out.Body = B->body() ? FString(UTF8_TO_TCHAR(B->body()->c_str())) : FString();
			if (const auto* P = B->pos())
			{
				Out.LocalPosition = SimToUEPosition(P->x(), P->y(), P->z());
			}
			if (const auto* Q = B->orient())
			{
				Out.LocalOrientation = SimToUEQuat(Q->w(), Q->x(), Q->y(), Q->z());
			}
			Out.Lat = static_cast<float>(B->lat());
			Out.Lon = static_cast<float>(B->lon());
			Buildings.Add(MoveTemp(Out));
		}
	}
}

// --- commands -------------------------------------------------------------

void USpaceSimSubsystem::SubmitThrottle(const FString& VesselId, float Throttle)
{
	flatbuffers::FlatBufferBuilder Fbb;
	auto Cmd = acro::wire::CreateSetThrottleDirect(Fbb, TCHAR_TO_UTF8(*VesselId), Throttle);
	auto By = Fbb.CreateString(TCHAR_TO_UTF8(*PlayerId));
	auto Env = acro::wire::CreateCmdEnvelope(Fbb, By, 0, acro::wire::Cmd::SetThrottle, Cmd.Union());
	std::vector<flatbuffers::Offset<acro::wire::CmdEnvelope>> Cmds{Env};
	auto Frame = acro::wire::CreateCommandFrame(Fbb, 0.0, Fbb.CreateVector(Cmds));
	Fbb.Finish(Frame);
	SendFramed(Fbb.GetBufferPointer(), Fbb.GetSize());
}

void USpaceSimSubsystem::SubmitAttitude(const FString& VesselId, FVector HeadingSim)
{
	flatbuffers::FlatBufferBuilder Fbb;
	const acro::wire::Vec3 Heading(HeadingSim.X, HeadingSim.Y, HeadingSim.Z);
	auto VesselStr = Fbb.CreateString(TCHAR_TO_UTF8(*VesselId));
	auto Cmd = acro::wire::CreateSetAttitude(Fbb, VesselStr, &Heading);
	auto By = Fbb.CreateString(TCHAR_TO_UTF8(*PlayerId));
	auto Env = acro::wire::CreateCmdEnvelope(Fbb, By, 0, acro::wire::Cmd::SetAttitude, Cmd.Union());
	std::vector<flatbuffers::Offset<acro::wire::CmdEnvelope>> Cmds{Env};
	auto Frame = acro::wire::CreateCommandFrame(Fbb, 0.0, Fbb.CreateVector(Cmds));
	Fbb.Finish(Frame);
	SendFramed(Fbb.GetBufferPointer(), Fbb.GetSize());
}

void USpaceSimSubsystem::SubmitSeparateStage(const FString& VesselId)
{
	flatbuffers::FlatBufferBuilder Fbb;
	auto Cmd = acro::wire::CreateSeparateStageDirect(Fbb, TCHAR_TO_UTF8(*VesselId));
	auto By = Fbb.CreateString(TCHAR_TO_UTF8(*PlayerId));
	auto Env = acro::wire::CreateCmdEnvelope(Fbb, By, 0, acro::wire::Cmd::SeparateStage, Cmd.Union());
	std::vector<flatbuffers::Offset<acro::wire::CmdEnvelope>> Cmds{Env};
	auto Frame = acro::wire::CreateCommandFrame(Fbb, 0.0, Fbb.CreateVector(Cmds));
	Fbb.Finish(Frame);
	SendFramed(Fbb.GetBufferPointer(), Fbb.GetSize());
}

void USpaceSimSubsystem::SubmitPlaceBuilding(const FString& ColonyId, const FString& Kind, int32 GridX, int32 GridY)
{
	flatbuffers::FlatBufferBuilder Fbb;
	auto Cmd = acro::wire::CreatePlaceBuildingDirect(
		Fbb, TCHAR_TO_UTF8(*ColonyId), TCHAR_TO_UTF8(*Kind), GridX, GridY);
	auto By = Fbb.CreateString(TCHAR_TO_UTF8(*PlayerId));
	auto Env = acro::wire::CreateCmdEnvelope(Fbb, By, 0, acro::wire::Cmd::PlaceBuilding, Cmd.Union());
	std::vector<flatbuffers::Offset<acro::wire::CmdEnvelope>> Cmds{Env};
	auto Frame = acro::wire::CreateCommandFrame(Fbb, 0.0, Fbb.CreateVector(Cmds));
	Fbb.Finish(Frame);
	SendFramed(Fbb.GetBufferPointer(), Fbb.GetSize());
}

void USpaceSimSubsystem::SubmitReportTerrainHeight(const FString& Body, float Lat, float Lon, float Height)
{
	flatbuffers::FlatBufferBuilder Fbb;
	auto Cmd = acro::wire::CreateReportTerrainHeightDirect(Fbb, TCHAR_TO_UTF8(*Body), Lat, Lon, Height);
	auto By = Fbb.CreateString(TCHAR_TO_UTF8(*PlayerId));
	auto Env = acro::wire::CreateCmdEnvelope(Fbb, By, 0, acro::wire::Cmd::ReportTerrainHeight, Cmd.Union());
	std::vector<flatbuffers::Offset<acro::wire::CmdEnvelope>> Cmds{Env};
	auto Frame = acro::wire::CreateCommandFrame(Fbb, 0.0, Fbb.CreateVector(Cmds));
	Fbb.Finish(Frame);
	SendFramed(Fbb.GetBufferPointer(), Fbb.GetSize());
}

void USpaceSimSubsystem::SendFramed(const uint8* Data, int32 Len)
{
	// Enqueue only; FlushTx (driven from Tick) performs the actual non-blocking
	// send with partial-write handling. Buffering also covers the window before
	// the non-blocking Connect() completes, so commands issued right after
	// Connect() are not silently dropped.
	const uint32 Prefix = static_cast<uint32>(Len); // LE on x86/x64
	TxBuffer.Append(reinterpret_cast<const uint8*>(&Prefix), 4);
	TxBuffer.Append(Data, Len);
	FlushTx();
}

void USpaceSimSubsystem::FlushTx()
{
	if (!Socket || TxBuffer.Num() == 0)
	{
		return;
	}
	int32 TotalSent = 0;
	while (TotalSent < TxBuffer.Num())
	{
		int32 Sent = 0;
		const bool bOk = Socket->Send(TxBuffer.GetData() + TotalSent, TxBuffer.Num() - TotalSent, Sent);
		if (!bOk || Sent <= 0)
		{
			break; // would-block or error — keep the remainder, retry next Tick
		}
		TotalSent += Sent;
	}
	if (TotalSent > 0)
	{
		TxBuffer.RemoveAt(0, TotalSent, false);
	}
}
