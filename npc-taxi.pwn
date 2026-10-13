
	/*
		NPC-Taxi v1.0 by: moji
		仅支持open.mp服务端
		依赖omp/components/NPCs.dll   plugins/GPS.dll
		
		等待更新 依赖colandreas 以更精准规划路线
	*/
#define TAXI_MOVE_TYPE_JOG       (2)
#define TAXI_MOVE_TYPE_DRIVE     (4)
#define TAXI_MOVE_TYPE_AUTO      (-1)
#define TAXI_MOVE_SPEED_AUTO     (Float:(-1.0))
#define TAXI_MOVE_SPEED_DEFAULT  (Float:(2.5)) // 默认车速, 见下面 gTaxiSpeed 的说明
#define TAXI_NO_NPC              (-1)      // 没有出租车 NPC 时的 pTaxiNPC 取值
#define TAXI_NO_PATH             (Path:(-1))   // 没有路线时的 pTaxiPath 取值
#define TAXI_NO_TIMER            (-1)      // 没有行驶定时器时的 pTaxiTimer 取值
#define TAXI_STRAIGHT_LEG        (-1)      // pTaxiLeg 为负数 = 不走 GPS 路线, 直接开向终点

native NPC_Create(const name[]);
native bool:NPC_IsValid(npcid);
native bool:NPC_Destroy(npcid);
native bool:NPC_Spawn(npcid);
native bool:NPC_SetSkin(npcid, model);
native bool:NPC_SetInterior(npcid, interior);
native bool:NPC_SetVirtualWorld(npcid, virtualWorld);
native bool:NPC_SetPos(npcid, Float:x, Float:y, Float:z);
native bool:NPC_EnterVehicle(npcid, vehicleid, seatid, moveType = TAXI_MOVE_TYPE_AUTO);
native bool:NPC_Move(npcid, Float:x, Float:y, Float:z, moveType = TAXI_MOVE_TYPE_AUTO, Float:moveSpeed = TAXI_MOVE_SPEED_AUTO, Float:stopRange = 0.2);
native bool:NPC_StopMove(npcid);

forward OnNPCDeath(npcid, killerid, WEAPON:reason);

#define TAXI_VEHICLE_MODEL       (420)     // Taxi
#define TAXI_VEHICLE_COLOR1      (6)
#define TAXI_VEHICLE_COLOR2      (6)
#define TAXI_NPC_SKIN            (61)      // 司机model
#define TAXI_NPC_NAME_PREFIX     "Taxi_"   // NPC 名字前缀
#define TAXI_SPAWN_OFFSET        (4.0)     // 车生成在玩家前方多远
#define TAXI_PASSENGER_SEAT      (1)       // 玩家的固定座位
#define TAXI_WAYPOINT_RANGE      (8.0)     // 途经点/终点的到达半径
#define TAXI_MIN_DISTANCE        (15.0)    // 最小目的地距离
#define TAXI_MAX_DISTANCE        (3000.0)  // 最大目的地距离
#define TAXI_TICK                (100)     // 逐点推进的间隔 100ms
#define TAXI_STUCK_TICKS         (20)      // 连续多少次没前进就跳过当前途经点 2s
#define TAXI_ROUTE_TIMEOUT       (3000)    // GPS 回调没来就变成直线 3000ms
#define TAXI_ROUTE_TAIL          (40.0)    // 路线走完后离目的地还有多远就直接开过去
#define TAXI_Z_OFFSET_MAX        (3.0)     // 车底盘高度偏移量的合理范围 (见 Taxi_DriveZ)
#define TAXI_Z_STEP              (8.0)     // 单步允许的高度落差, 防单个坏节点把车拽飞 (见 Taxi_DriveZ)
#define TAXI_FARE_BASE           (50)      // 起步价
#define TAXI_FARE_PER_100M       (30)      // 每 100 米加收费用
#define TAXI_FARE_MAX_STEP       (6.0)     // 单次位移超过这个数就当瞬移 不计入里程

new Float:gTaxiSpeed = TAXI_MOVE_SPEED_DEFAULT;

new
	gTaxiToken[MAX_PLAYERS],      // 车主 playerid -> 本次出租车的随机令牌 (0 = 没叫车)
	gTaxiOwner[MAX_PLAYERS];      // npcid -> 车主 playerid (0 = 不是本系统的 NPC)

forward Taxi_IsOwnNPC(npcplayerid);
forward Taxi_ResetPlayerState(playerid);
forward Taxi_Despawn(playerid);
forward Taxi_StopTimer(playerid);
forward Taxi_FreeRoute(playerid);
forward Taxi_GetOwner(npcid);
forward Taxi_OnNPCDisconnect(npcplayerid);
forward Taxi_OnPlayerStateChange(playerid, PLAYER_STATE:newstate);
forward Taxi_Arrive(playerid);
forward Taxi_StartDriving(playerid);
forward Taxi_DriveStraight(playerid);
forward Float:Taxi_Distance(Float:x1, Float:y1, Float:z1, Float:x2, Float:y2, Float:z2);
forward Float:Taxi_DriveZ(Float:carZ, Float:nodeZ, Float:zOffset);
forward Taxi_FareOf(Float:meters);
forward Taxi_ChargeFare(playerid);
forward Taxi_EndTrip(playerid);
forward Taxi_OnPlayerClickMap(playerid, Float:x, Float:y, Float:z);
forward Taxi_RouteTick(playerid);
forward Taxi_RouteWatchdog(playerid, serial);
forward OnTaxiRouteReady(Path:pathid, playerid, serial);


enum pEnum
{
	pTaxiFare,
	pTaxiNPC,
	pTaxiVehicle,
	Path:pTaxiPath,
	pTaxiSerial,
	pTaxiDestSet,
	pTaxiLeg,
	pTaxiLegs,
	pTaxiWait,
	pTaxiTimer,
	pTaxiStuck,
	Float:pTaxiDestX,
	Float:pTaxiDestY,
	Float:pTaxiDestZ,
	Float:pTaxiLastD,
	Float:pTaxiZOffset,
	pTaxiEnded,
	pTaxiFareActive,
	Float:pTaxiMeters,
	Float:pTaxiMeterX,
	Float:pTaxiMeterY
};
new PlayerInfo[MAX_PLAYERS+1][pEnum];

stock CountTaxiDrivers()
{
	new count = 0;
	foreach(new i : Player)
	{
		if(PlayerInfo[i][pTaxiFare] > 0)
		{
			count ++;
		}
	}
	return count;
}

public OnPlayerConnect(playerid)
{
	Taxi_ResetPlayerState(playerid);
	return 1;
}

public OnPlayerDisconnect(playerid, reason)
{
	if(IsPlayerNPC(playerid))
	{
		return Taxi_OnNPCDisconnect(playerid);
	}
	Taxi_Despawn(playerid);
	return 1;
}

public OnPlayerRequestClass(playerid, classid)
{
    if(IsPlayerNPC(playerid))
	{
		return 1;
	}
    return 1;
}

public OnPlayerDeath(playerid, killerid, WEAPON:reason)
{
	Taxi_Despawn(playerid);
	return 1;
}

public OnPlayerStateChange(playerid, PLAYER_STATE:newstate, PLAYER_STATE:oldstate)
{
	Taxi_OnPlayerStateChange(playerid, newstate);
	return 1;
}

stock Taxi_FormatNPCName(playerid, dest[], length)
{
	format(dest, length, "%s%d_%d", TAXI_NPC_NAME_PREFIX, playerid, gTaxiToken[playerid]);
	return 1;
}

stock Taxi_GetOwner(npcid)
{
	if(!(0 <= npcid < MAX_PLAYERS))
	{
		return 0;
	}

	return gTaxiOwner[npcid];
}

stock Float:Taxi_Distance(Float:x1, Float:y1, Float:z1, Float:x2, Float:y2, Float:z2)
{
	new
		Float:dx = x1 - x2,
		Float:dy = y1 - y2,
		Float:dz = z1 - z2;

	return floatsqroot((dx * dx) + (dy * dy) + (dz * dz));
}

stock Float:Taxi_DriveZ(Float:carZ, Float:nodeZ, Float:zOffset)
{
	new Float:z = nodeZ + zOffset;
	if(z > carZ + TAXI_Z_STEP)
	{
		z = carZ + TAXI_Z_STEP;
	}
	else if(z < carZ - TAXI_Z_STEP)
	{
		z = carZ - TAXI_Z_STEP;
	}

	return z;
}

stock Taxi_FareOf(Float:meters)
{
	return TAXI_FARE_BASE + floatround(meters * TAXI_FARE_PER_100M / 100.0);
}


stock Taxi_ChargeFare(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS) || !PlayerInfo[playerid][pLogged])
	{
		return -1;
	}

	if(!PlayerInfo[playerid][pTaxiFareActive])
	{
		return -1;
	}

	PlayerInfo[playerid][pTaxiFareActive] = 0;

	new
		Float:meters = PlayerInfo[playerid][pTaxiMeters],
		fare = Taxi_FareOf(meters);

	PlayerInfo[playerid][pTaxiMeters] = 0.0;

	if(GetPlayerCash(playerid) < fare)
	{
		SCMf(playerid, COLOR_RED, "车费 $%d (%.0f 米) 你身上只有 $%d 这次就算了", fare, meters, GetPlayerCash(playerid));
		return -1;
	}

	GivePlayerCash(playerid, -fare);
	SCMf(playerid, COLOR_AQUA, "** 车费 $%d 已支付 (%.0f 米)", fare, meters);
	return fare;
}

stock Taxi_EndTrip(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	Taxi_StopTimer(playerid);

	new npcid = PlayerInfo[playerid][pTaxiNPC];

	if((0 <= npcid < MAX_PLAYERS) && NPC_IsValid(npcid))
	{
		NPC_StopMove(npcid);
	}

	PlayerInfo[playerid][pTaxiDestSet] = 0;
	PlayerInfo[playerid][pTaxiLeg] = 0;
	PlayerInfo[playerid][pTaxiLegs] = 0;
	PlayerInfo[playerid][pTaxiWait] = 0;
	PlayerInfo[playerid][pTaxiStuck] = 0;
	PlayerInfo[playerid][pTaxiLastD] = 0.0;

	Taxi_ChargeFare(playerid);
	return 1;
}

stock Taxi_IsOwnNPC(npcplayerid)
{
	new
		name[MAX_PLAYER_NAME],
		pos = strlen(TAXI_NPC_NAME_PREFIX),
		owner,
		token;

	if(!IsPlayerNPC(npcplayerid))
	{
		return 0;
	}

	GetPlayerName(npcplayerid, name, sizeof(name));

	if(strcmp(name, TAXI_NPC_NAME_PREFIX, false, pos))
	{
		return 0;
	}

	owner = strval(name[pos]);

	while(name[pos] != '\0' && name[pos] != '_')
	{
		pos ++;
	}

	if(name[pos] != '_')
	{
		return 0;
	}

	token = strval(name[pos + 1]);

	if(!(0 <= owner < MAX_PLAYERS) || gTaxiToken[owner] == 0)
	{
		return 0;
	}

	return (gTaxiToken[owner] == token);
}

stock Taxi_ResetPlayerState(playerid)
{
	gTaxiToken[playerid] = 0;
	PlayerInfo[playerid][pTaxiNPC] = TAXI_NO_NPC;
	PlayerInfo[playerid][pTaxiVehicle] = INVALID_VEHICLE_ID;
	PlayerInfo[playerid][pTaxiPath] = TAXI_NO_PATH;
	PlayerInfo[playerid][pTaxiSerial] = 0;
	PlayerInfo[playerid][pTaxiDestSet] = 0;
	PlayerInfo[playerid][pTaxiLeg] = 0;
	PlayerInfo[playerid][pTaxiLegs] = 0;
	PlayerInfo[playerid][pTaxiWait] = 0;
	PlayerInfo[playerid][pTaxiTimer] = TAXI_NO_TIMER;
	PlayerInfo[playerid][pTaxiStuck] = 0;
	PlayerInfo[playerid][pTaxiLastD] = 0.0;
	PlayerInfo[playerid][pTaxiZOffset] = 0.0;
	PlayerInfo[playerid][pTaxiEnded] = 0;
	PlayerInfo[playerid][pTaxiFareActive] = 0;
	PlayerInfo[playerid][pTaxiMeters] = 0.0;
	PlayerInfo[playerid][pTaxiMeterX] = 0.0;
	PlayerInfo[playerid][pTaxiMeterY] = 0.0;
	return 1;
}

stock Taxi_StopTimer(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	if(PlayerInfo[playerid][pTaxiTimer] != TAXI_NO_TIMER)
	{
		KillTimer(PlayerInfo[playerid][pTaxiTimer]);
		PlayerInfo[playerid][pTaxiTimer] = TAXI_NO_TIMER;
	}

	return 1;
}

stock Taxi_FreeRoute(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	new Path:pathid = PlayerInfo[playerid][pTaxiPath];

	if(pathid != TAXI_NO_PATH)
	{
		if(IsValidPath(pathid))
		{
			DestroyPath(pathid);
		}

		PlayerInfo[playerid][pTaxiPath] = TAXI_NO_PATH;
	}

	return 1;
}

stock Taxi_Despawn(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	Taxi_StopTimer(playerid);

	new
		npcid = PlayerInfo[playerid][pTaxiNPC],
		vehicleid = PlayerInfo[playerid][pTaxiVehicle],
		hadTaxi = (gTaxiToken[playerid] != 0 || vehicleid != INVALID_VEHICLE_ID);

	if(!(0 <= npcid < MAX_PLAYERS))
	{
		npcid = TAXI_NO_NPC;
	}
	else
	{
		gTaxiOwner[npcid] = 0;
	}

	gTaxiToken[playerid] = 0;
	PlayerInfo[playerid][pTaxiNPC] = TAXI_NO_NPC;
	PlayerInfo[playerid][pTaxiVehicle] = INVALID_VEHICLE_ID;
	PlayerInfo[playerid][pTaxiDestSet] = 0;
	PlayerInfo[playerid][pTaxiLeg] = 0;
	PlayerInfo[playerid][pTaxiLegs] = 0;
	PlayerInfo[playerid][pTaxiWait] = 0;
	PlayerInfo[playerid][pTaxiStuck] = 0;
	PlayerInfo[playerid][pTaxiLastD] = 0.0;
	PlayerInfo[playerid][pTaxiZOffset] = 0.0;
	PlayerInfo[playerid][pTaxiEnded] = 0;
	PlayerInfo[playerid][pTaxiFareActive] = 0;
	PlayerInfo[playerid][pTaxiMeters] = 0.0;
	PlayerInfo[playerid][pTaxiMeterX] = 0.0;
	PlayerInfo[playerid][pTaxiMeterY] = 0.0;

	if(npcid != TAXI_NO_NPC && NPC_IsValid(npcid))
	{
		NPC_StopMove(npcid);
	}

	Taxi_FreeRoute(playerid);

	if(npcid != TAXI_NO_NPC && NPC_IsValid(npcid))
	{
		NPC_Destroy(npcid);
	}

	if(vehicleid != INVALID_VEHICLE_ID && IsValidVehicle(vehicleid))
	{
		DestroyVehicle(vehicleid);
	}

	if(!hadTaxi)
	{
		return 0;
	}

	if(IsPlayerConnected(playerid) && PlayerInfo[playerid][pLogged])
	{
		SCMf(playerid, COLOR_GREY2, "出租车已经离开");
	}

	return 1;
}

stock Taxi_OnNPCDisconnect(npcplayerid)
{
	new owner = Taxi_GetOwner(npcplayerid);

	gTaxiOwner[npcplayerid] = 0;

	if(!owner || PlayerInfo[owner][pTaxiNPC] != npcplayerid)
	{
		return 1;
	}

	Taxi_StopTimer(owner);
	Taxi_FreeRoute(owner);

	PlayerInfo[owner][pTaxiNPC] = TAXI_NO_NPC;
	PlayerInfo[owner][pTaxiVehicle] = INVALID_VEHICLE_ID;
	PlayerInfo[owner][pTaxiDestSet] = 0;
	PlayerInfo[owner][pTaxiLeg] = 0;
	PlayerInfo[owner][pTaxiLegs] = 0;
	PlayerInfo[owner][pTaxiWait] = 0;
	gTaxiToken[owner] = 0;

	if(IsPlayerConnected(owner) && PlayerInfo[owner][pLogged])
	{
		SCMf(owner, COLOR_SYNTAX, "出租车司机离线了...");
	}

	return 1;
}

stock Taxi_StartDriving(playerid)
{
	if(!(0 <= playerid < MAX_PLAYERS) ||
		!IsPlayerConnected(playerid) ||
		!(0 <= PlayerInfo[playerid][pTaxiNPC] < MAX_PLAYERS) ||
		!NPC_IsValid(PlayerInfo[playerid][pTaxiNPC]))
	{
		return Taxi_Despawn(playerid);
	}

	Taxi_StopTimer(playerid);
	PlayerInfo[playerid][pTaxiStuck] = 0;
	PlayerInfo[playerid][pTaxiLastD] = 0.0;

	PlayerInfo[playerid][pTaxiTimer] = SetTimerEx("Taxi_RouteTick", TAXI_TICK, true, "i", playerid);
	return 1;
}

stock Taxi_DriveStraight(playerid)
{
	PlayerInfo[playerid][pTaxiLeg] = TAXI_STRAIGHT_LEG;
	PlayerInfo[playerid][pTaxiWait] = 0;
	return Taxi_StartDriving(playerid);
}

stock Taxi_Arrive(playerid)
{
	Taxi_EndTrip(playerid);

	if(IsPlayerConnected(playerid) && PlayerInfo[playerid][pLogged])
	{
		SCMf(playerid, COLOR_AQUA, "** 已到达目的地附近 下车后出租车会自动离开 也可以继续在地图上标点去下一个地方");
	}

	return 1;
}

public Taxi_RouteTick(playerid)
{
	if(!IsPlayerConnected(playerid) || !PlayerInfo[playerid][pLogged])
	{
		Taxi_StopTimer(playerid);
		return 1;
	}

	new
		npcid = PlayerInfo[playerid][pTaxiNPC],
		vehicleid = PlayerInfo[playerid][pTaxiVehicle];

	if(!(0 <= npcid < MAX_PLAYERS) || !NPC_IsValid(npcid) ||
		vehicleid == INVALID_VEHICLE_ID || !IsValidVehicle(vehicleid))
	{
		Taxi_StopTimer(playerid);
		return 1;
	}

	if(GetPlayerVehicleID(playerid) != vehicleid)
	{
		Taxi_StopTimer(playerid);
		return 1;
	}

	if(PlayerInfo[playerid][pTaxiEnded])
	{
		Taxi_StopTimer(playerid);
		return 1;
	}

	new Float:nx, Float:ny, Float:nz;
	GetVehiclePos(vehicleid, nx, ny, nz);
	new Float:step = Taxi_Distance(nx, ny, 0.0, PlayerInfo[playerid][pTaxiMeterX], PlayerInfo[playerid][pTaxiMeterY], 0.0);

	if(step <= TAXI_FARE_MAX_STEP)
	{
		PlayerInfo[playerid][pTaxiMeters] += step;
	}

	PlayerInfo[playerid][pTaxiMeterX] = nx;
	PlayerInfo[playerid][pTaxiMeterY] = ny;

	if(PlayerInfo[playerid][pTaxiLeg] < 0)
	{
		if(Taxi_Distance(nx, ny, nz,
			PlayerInfo[playerid][pTaxiDestX],
			PlayerInfo[playerid][pTaxiDestY],
			nz) < TAXI_WAYPOINT_RANGE)
		{
			return Taxi_Arrive(playerid);
		}

		NPC_Move(npcid,
			PlayerInfo[playerid][pTaxiDestX],
			PlayerInfo[playerid][pTaxiDestY],
			Taxi_DriveZ(nz, PlayerInfo[playerid][pTaxiDestZ], PlayerInfo[playerid][pTaxiZOffset]),
			TAXI_MOVE_TYPE_DRIVE, gTaxiSpeed, 1.0);
		return 1;
	}

	new Path:pathid = PlayerInfo[playerid][pTaxiPath];

	if(pathid == TAXI_NO_PATH || !IsValidPath(pathid))
	{
		return Taxi_DriveStraight(playerid);
	}

	new
		leg = PlayerInfo[playerid][pTaxiLeg],
		MapNode:nodeid = INVALID_MAP_NODE_ID;

	if(leg >= PlayerInfo[playerid][pTaxiLegs])
	{
		if(Taxi_Distance(nx, ny, nz,
			PlayerInfo[playerid][pTaxiDestX],
			PlayerInfo[playerid][pTaxiDestY],
			PlayerInfo[playerid][pTaxiDestZ]) > TAXI_ROUTE_TAIL)
		{
			return Taxi_DriveStraight(playerid);
		}

		return Taxi_Arrive(playerid);
	}

	GetPathNode(pathid, leg, nodeid);

	if(!IsValidMapNode(nodeid))
	{
		PlayerInfo[playerid][pTaxiLeg] = leg + 1;
		return 1;
	}

	new Float:px, Float:py, Float:pz;

	GetMapNodePos(nodeid, px, py, pz);

	new Float:zdrive = Taxi_DriveZ(nz, pz, PlayerInfo[playerid][pTaxiZOffset]);
	new Float:dist = Taxi_Distance(nx, ny, nz, px, py, nz);

	if(dist < TAXI_WAYPOINT_RANGE)
	{
		PlayerInfo[playerid][pTaxiLeg] = leg + 1;
		PlayerInfo[playerid][pTaxiStuck] = 0;
		PlayerInfo[playerid][pTaxiLastD] = 0.0;
		return 1;
	}

	if(dist > PlayerInfo[playerid][pTaxiLastD] + 0.3)
	{
		PlayerInfo[playerid][pTaxiStuck] ++;
	}
	else
	{
		PlayerInfo[playerid][pTaxiStuck] = 0;
	}

	PlayerInfo[playerid][pTaxiLastD] = dist;

	if(PlayerInfo[playerid][pTaxiStuck] > TAXI_STUCK_TICKS)
	{
		PlayerInfo[playerid][pTaxiStuck] = 0;
		PlayerInfo[playerid][pTaxiLastD] = 0.0;
		PlayerInfo[playerid][pTaxiLeg] = leg + 1;
		return 1;
	}

	NPC_Move(npcid, px, py, zdrive, TAXI_MOVE_TYPE_DRIVE, gTaxiSpeed, 1.0);
	return 1;
}

public Taxi_RouteWatchdog(playerid, serial)
{
	if(!IsPlayerConnected(playerid) || PlayerInfo[playerid][pTaxiSerial] != serial)
	{
		return 1;
	}

	if(!PlayerInfo[playerid][pTaxiWait])
	{
		return 1;
	}

	PlayerInfo[playerid][pTaxiWait] = 0;
	Taxi_DriveStraight(playerid);
	SCMf(playerid, COLOR_GREY2, "GPS 没算出路线 出租车改为直线前往目的地");
	return 1;
}

stock Taxi_OnPlayerClickMap(playerid, Float:x, Float:y, Float:z)
{
	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	new
		vehicleid = PlayerInfo[playerid][pTaxiVehicle],
		npcid = PlayerInfo[playerid][pTaxiNPC];

	if(vehicleid == INVALID_VEHICLE_ID || !IsValidVehicle(vehicleid))
	{
		Taxi_Despawn(playerid);
		return 0;
	}

	if(!(0 <= npcid < MAX_PLAYERS) || !NPC_IsValid(npcid))
	{
		Taxi_Despawn(playerid);
		return 0;
	}

	if(GetPlayerVehicleID(playerid) != vehicleid)
	{
		return 0;
	}

	if(GetPlayerVirtualWorld(playerid) != GetVehicleVirtualWorld(vehicleid))
	{
		return SCMf(playerid, COLOR_SYNTAX, "你和出租车不在同一个世界 没法规划路线");
	}

	if(PlayerInfo[playerid][pTaxiEnded])
	{
		return SCMf(playerid, COLOR_SYNTAX, "本次行程已经结束了 下车后出租车会自动离开");
	}

	new Float:px, Float:py, Float:pz;
	GetVehiclePos(vehicleid, px, py, pz);

	new Float:dist = Taxi_Distance(px, py, pz, x, y, z);

	if(dist < TAXI_MIN_DISTANCE)
	{
		return SCMf(playerid, COLOR_SYNTAX, "你已经在目的地附近了 (%.0f 米)", dist);
	}

	if(dist > TAXI_MAX_DISTANCE)
	{
		return SCMf(playerid, COLOR_SYNTAX, "太远了 (%.0f 米) 这辆车跑不了那么远。", dist);
	}

	PlayerInfo[playerid][pTaxiDestSet] = 1;
	PlayerInfo[playerid][pTaxiDestX] = x;
	PlayerInfo[playerid][pTaxiDestY] = y;
	PlayerInfo[playerid][pTaxiDestZ] = z;
	PlayerInfo[playerid][pTaxiWait] = 1;
	PlayerInfo[playerid][pTaxiFareActive] = 1;
	PlayerInfo[playerid][pTaxiMeters] = 0.0;
	PlayerInfo[playerid][pTaxiMeterX] = px;
	PlayerInfo[playerid][pTaxiMeterY] = py;
	PlayerInfo[playerid][pTaxiSerial] ++;

	Taxi_StopTimer(playerid);
	NPC_StopMove(npcid);
	Taxi_FreeRoute(playerid);

	new serial = PlayerInfo[playerid][pTaxiSerial];

	new MapNode:from = INVALID_MAP_NODE_ID, MapNode:to = INVALID_MAP_NODE_ID;

	GetClosestMapNodeToPoint(px, py, pz, from);
	GetClosestMapNodeToPoint(x, y, z, to);

	PlayerInfo[playerid][pTaxiZOffset] = 0.0;

	if(IsValidMapNode(from))
	{
		new Float:fx, Float:fy, Float:fz;
		GetMapNodePos(from, fx, fy, fz);

		new Float:offset = pz - fz;

		if(offset > TAXI_Z_OFFSET_MAX)
		{
			offset = TAXI_Z_OFFSET_MAX;
		}
		else if(offset < -TAXI_Z_OFFSET_MAX)
		{
			offset = -TAXI_Z_OFFSET_MAX;
		}

		PlayerInfo[playerid][pTaxiZOffset] = offset;
	}

	if(from == INVALID_MAP_NODE_ID || to == INVALID_MAP_NODE_ID)
	{
		SCMf(playerid, COLOR_GREY2, "GPS 找不到附近的道路节点 出租车改为直线前往目的地");
		return Taxi_DriveStraight(playerid);
	}

	SCMf(playerid, COLOR_GREY2, "正在规划路线 ... (%.0f 米 预计车费 $%d 起步价 $%d + 每 100 米 $%d)",
		dist, Taxi_FareOf(dist), TAXI_FARE_BASE, TAXI_FARE_PER_100M);

	FindPathThreaded(from, to, "OnTaxiRouteReady", "ii", playerid, serial);
	SetTimerEx("Taxi_RouteWatchdog", TAXI_ROUTE_TIMEOUT, false, "ii", playerid, serial);
	return 1;
}

public OnTaxiRouteReady(Path:pathid, playerid, serial)
{
	PlayerInfo[playerid][pTaxiWait] = 0;

	if(!IsPlayerConnected(playerid) || !PlayerInfo[playerid][pLogged])
	{
		if(IsValidPath(pathid))
		{
			DestroyPath(pathid);
		}

		return 1;
	}

	new npcid = PlayerInfo[playerid][pTaxiNPC];

	// 算路线期间玩家又标了一次点或者车已经被退了 这条路线直接作废
	if(PlayerInfo[playerid][pTaxiSerial] != serial ||
		PlayerInfo[playerid][pTaxiVehicle] == INVALID_VEHICLE_ID ||
		!(0 <= npcid < MAX_PLAYERS) || !NPC_IsValid(npcid))
	{
		if(IsValidPath(pathid))
		{
			DestroyPath(pathid);
		}

		return 1;
	}

	if(!IsValidPath(pathid))
	{
		SCMf(playerid, COLOR_GREY2, "[taxi] 出租车未找到可用道路行驶 更改为直线前往目的地");
		return Taxi_DriveStraight(playerid);
	}

	new size;
	GetPathSize(pathid, size);

	if(!size)
	{
		DestroyPath(pathid);

		SCMf(playerid, COLOR_GREY2, "[taxi] 出租车未找到可用道路行驶 更改为直线前往目的地");
		return Taxi_DriveStraight(playerid);
	}

	PlayerInfo[playerid][pTaxiPath] = pathid;
	PlayerInfo[playerid][pTaxiLeg] = 0;
	PlayerInfo[playerid][pTaxiLegs] = size;

	Taxi_StartDriving(playerid);
	SCMf(playerid, COLOR_AQUA, "** 出租车出发了。");
	return 1;
}

public OnNPCDeath(npcid, killerid, WEAPON:reason)
{
	new owner = Taxi_GetOwner(npcid);

	if(owner)
	{
		Taxi_Despawn(owner);
	}

	return 1;
}

stock Taxi_OnPlayerStateChange(playerid, PLAYER_STATE:newstate)
{
	if(IsPlayerNPC(playerid))
	{
		return 0;
	}

	if(!(0 <= playerid < MAX_PLAYERS))
	{
		return 0;
	}

	new vehicleid = PlayerInfo[playerid][pTaxiVehicle];

	if(vehicleid == INVALID_VEHICLE_ID)
	{
		return 0;
	}

	if(GetPlayerVehicleID(playerid) == vehicleid)
	{
		if(newstate == PLAYER_STATE_DRIVER)
		{
			// 抢驾驶位 自动放进副驾驶
			PutPlayerInVehicle(playerid, vehicleid, TAXI_PASSENGER_SEAT);
		}

		return 1;
	}

	Taxi_Despawn(playerid);
	return 1;
}

CMD:calltaxi(playerid, params[])
{
	#pragma unused params

	if(!PlayerInfo[playerid][pLogged])//改为你服务器的判断玩家登录
	{
		return SCMf(playerid, COLOR_SYNTAX, "你尚未登录，无法使用此命令");
	}

	if(PlayerInfo[playerid][pTaxiVehicle] != INVALID_VEHICLE_ID)
	{
		return SCMf(playerid, COLOR_SYNTAX, "你已经有一辆出租车了 上车后地图标点即可出发 或使用 /taxicancel 取消");
	}

	if(GetPlayerVirtualWorld(playerid) != 0 || GetPlayerInterior(playerid) != 0)
	{
		return SCMf(playerid, COLOR_SYNTAX, "只能在室外叫车");
	}

	if(IsPlayerInAnyVehicle(playerid))
	{
		return SCMf(playerid, COLOR_SYNTAX, "请先下车再叫车");
	}

	new Float:x, Float:y, Float:z, Float:a;

	GetPlayerPos(playerid, x, y, z);
	GetPlayerFacingAngle(playerid, a);

	x -= (TAXI_SPAWN_OFFSET * floatsin(a, degrees));
	y += (TAXI_SPAWN_OFFSET * floatcos(a, degrees));

	new vehicleid = CreateVehicle(TAXI_VEHICLE_MODEL, x, y, z, a, TAXI_VEHICLE_COLOR1, TAXI_VEHICLE_COLOR2, -1);

	if(vehicleid == INVALID_VEHICLE_ID)
	{
		return SCMf(playerid, COLOR_SYNTAX, "出租车生成失败，车辆池已满。");
	}

	gTaxiToken[playerid] = random(8999) + 1000;

	new name[MAX_PLAYER_NAME];
	Taxi_FormatNPCName(playerid, name, sizeof(name));

	new npcid = NPC_Create(name);

	if(!(0 <= npcid < MAX_PLAYERS) || !NPC_IsValid(npcid))
	{
		gTaxiToken[playerid] = 0;
		DestroyVehicle(vehicleid);

		return SCMf(playerid, COLOR_SYNTAX, "出租车调用失败");
	}

	gTaxiOwner[npcid] = playerid;
	PlayerInfo[playerid][pTaxiNPC] = npcid;
	PlayerInfo[playerid][pTaxiVehicle] = vehicleid;
	PlayerInfo[playerid][pTaxiPath] = TAXI_NO_PATH;
	PlayerInfo[playerid][pTaxiTimer] = TAXI_NO_TIMER;
	PlayerInfo[playerid][pTaxiDestSet] = 0;
	PlayerInfo[playerid][pTaxiLeg] = 0;
	PlayerInfo[playerid][pTaxiLegs] = 0;
	PlayerInfo[playerid][pTaxiWait] = 0;
	PlayerInfo[playerid][pTaxiStuck] = 0;
	PlayerInfo[playerid][pTaxiLastD] = 0.0;
	PlayerInfo[playerid][pTaxiZOffset] = 0.0;
	PlayerInfo[playerid][pTaxiEnded] = 0;
	PlayerInfo[playerid][pTaxiFareActive] = 0;
	PlayerInfo[playerid][pTaxiMeters] = 0.0;
	PlayerInfo[playerid][pTaxiMeterX] = 0.0;
	PlayerInfo[playerid][pTaxiMeterY] = 0.0;

	NPC_SetVirtualWorld(npcid, 0);
	NPC_SetInterior(npcid, 0);
	NPC_Spawn(npcid);
	NPC_SetSkin(npcid, TAXI_NPC_SKIN);
	NPC_SetPos(npcid, x, y, z);
	NPC_EnterVehicle(npcid, vehicleid, 0, TAXI_MOVE_TYPE_JOG);

	SCMf(playerid, COLOR_AQUA, "** 一辆出租车已经停在你面前。走到副驾驶上车，然后在地图上点一下目的地。");
	return 1;
}

CMD:taxicancel(playerid, params[])
{
	#pragma unused params

	if(!PlayerInfo[playerid][pLogged])  //改为你服务器的判断玩家登录
	{
		return SCMf(playerid, COLOR_SYNTAX, "你尚未登录，无法使用此命令。");
	}

	if(PlayerInfo[playerid][pTaxiVehicle] == INVALID_VEHICLE_ID)
	{
		return SCMf(playerid, COLOR_SYNTAX, "你现在没有出租车。");
	}

	if(IsPlayerInVehicle(playerid, PlayerInfo[playerid][pTaxiVehicle]))
	{
		return SCMf(playerid, COLOR_SYNTAX, "请先下车再遣散出租车。");
	}

	return Taxi_Despawn(playerid);
}

public OnPlayerClickMap(playerid, Float:fX, Float:fY, Float:fZ)
{
	if(Taxi_OnPlayerClickMap(playerid, fX, fY, fZ))
	{
		return 1;
	}
	return 0;
}